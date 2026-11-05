//! Web fetch: one url out to the backends the configuration named, in order, until one reads it.

const std = @import("std");

const Credentials = @import("../../Credentials.zig");
const Health = @import("../../Health.zig");
const Mock = @import("../../Mock.zig");
const Tools = @import("../../Tools.zig");
const web = @import("../web.zig");

const Fetch = @This();

url: []const u8,
raw: bool = false,

/// Fetches one url and writes its content as text.
pub fn run(fetch: Fetch, tools: Tools, out: *std.Io.Writer) !void {
    if (fetch.url.len == 0) return Tools.fail(out, "no url to fetch", .{});
    // Reading the url directly needs nothing from the configuration.
    if (fetch.raw) return readDirectly(tools, fetch.url, out);

    const settings = tools.settings.fetch;
    if (settings.providers.len == 0) return Tools.fail(
        out,
        "no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        .{},
    );

    // The key is read as the call is made, so one stored while billy runs is the one the next fetch
    // asks with, and a run that never fetches asks for none of them.
    var backends: [max_backends]web.Backend = undefined;
    var usable: usize = 0;
    for (settings.providers) |provider| {
        if (usable == max_backends) {
            std.log.warn("fetch: {d} backends named, which is more than billy knows", .{settings.providers.len});
            break;
        }
        backends[usable] = backendFor(tools.settings.keys, provider) catch |err| {
            std.log.warn("fetch: {t} cannot be asked: {t}, trying the next", .{ provider, err });
            continue;
        };
        usable += 1;
    }
    if (usable == 0) return Tools.fail(
        out,
        "no key is stored for a fetch backend; run `billy login` to store one",
        .{},
    );
    return fetch.ask(tools, backends[0..usable], out);
}

/// The most backends one call asks, which is as many providers as billy knows.
const max_backends = @typeInfo(web.Provider).@"enum".field_names.len;

/// The backend `provider` is asked as, or the reason it cannot be asked.
fn backendFor(keys: *const Credentials, provider: web.Provider) !web.Backend {
    return .{
        .provider = provider,
        .api_key = if (provider.service()) |service|
            keys.get(service) orelse return error.MissingApiKey
        else
            "",
    };
}

/// Asks each backend in turn until one reads the url.
fn ask(fetch: Fetch, tools: Tools, backends: []const web.Backend, out: *std.Io.Writer) !void {
    const now_ms = std.Io.Clock.real.now(tools.http.io).toMilliseconds();

    var failed: ?anyerror = null;
    // Set when a backend answered but could not read this url, which is not a failure of the
    // backend: the url is then read directly rather than the call coming back with nothing.
    var unreadable = false;
    for (backends) |backend| {
        if (Health.isSetAside(tools.settings.health, @tagName(backend.provider), now_ms)) continue;
        const value = fetchBackend(tools, backend, fetch.url) catch |err| {
            if (err == error.UrlUnreadable) {
                std.log.warn("fetch: {t} could not read the url, trying the next", .{
                    backend.provider,
                });
                unreadable = true;
                continue;
            }
            Health.recordFailure(tools.settings.health, @tagName(backend.provider), null, now_ms);
            std.log.warn("fetch: {t} failed: {t}, trying the next", .{
                backend.provider, err,
            });
            failed = err;
            continue;
        };
        switch (value) {
            .text => |text| {
                defer tools.gpa.free(text);
                Health.recordAnswer(tools.settings.health, @tagName(backend.provider));
                return out.writeAll(text);
            },
            .retry_after_ms => |ms| {
                Health.recordFailure(tools.settings.health, @tagName(backend.provider), ms, now_ms);
                std.log.warn("fetch: {t} is set aside for {d}ms, trying the next", .{
                    backend.provider, ms,
                });
            },
        }
    }
    if (failed) |err| return Tools.fail(out, "fetch failed: {t}", .{err});
    // A backend answered and could not read this url, so it is read directly: a page billy can
    // reach itself is still worth having.
    if (unreadable) return readDirectly(tools, fetch.url, out);
    return Tools.fail(out, "every fetch backend is set aside after failing; wait", .{});
}

fn readDirectly(tools: Tools, url: []const u8, out: *std.Io.Writer) !void {
    const answer = fetchBackend(tools, .{ .provider = .raw }, url) catch |err|
        return Tools.fail(out, "cannot read {s}: {t}", .{ url, err });
    switch (answer) {
        .text => |text| {
            defer tools.gpa.free(text);
            return out.writeAll(text);
        },
        .retry_after_ms => |ms| return Tools.fail(
            out,
            "{s} asked to be waited {d}ms before it is read again",
            .{ url, ms },
        ),
    }
}

fn fetchBackend(tools: Tools, backend: web.Backend, url: []const u8) !web.Answer {
    const descriptor = backend.provider.descriptor();
    const spec = descriptor.fetch orelse return error.NotAFetchProvider;

    const base = if (spec.own_url)
        url
    else
        backend.endpoint orelse descriptor.fetch_endpoint orelse return error.MissingFetchUrl;
    const location = try web.address(
        tools.gpa,
        base,
        if (!spec.own_url and descriptor.fetch_endpoint == null) spec.configured_path else "",
    );
    defer tools.gpa.free(location);

    var payload: ?[]const u8 = null;
    defer if (payload) |body| tools.gpa.free(body);

    const method: std.http.Method = switch (spec.request) {
        .get => .GET,
        .post => |build| post: {
            payload = try build(tools.gpa, url);
            break :post .POST;
        },
    };

    const answer = try web.providerRequest(
        tools.gpa,
        tools.http,
        "fetch",
        descriptor,
        backend.api_key,
        method,
        location,
        payload,
    );
    return switch (answer) {
        .text => |text| text: {
            const render = spec.render orelse break :text .{ .text = text };
            defer tools.gpa.free(text);
            break :text .{ .text = try render(tools.gpa, text) };
        },
        .retry_after_ms => |ms| .{ .retry_after_ms = ms },
    };
}

test "each fetch backend is asked the way its table says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    {
        var mock = try Mock.start("/extract", 1, Mock.fixed(
            "{\"results\":[{\"url\":\"https://ziglang.org\",\"raw_content\":\"# Zig\"}],\"failed_results\":[]}",
        ));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
        const fetch: Fetch = .{ .url = "https://ziglang.org" };
        try fetch.ask(tool_set, &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }}, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
        try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
        try std.testing.expectEqualStrings("# Zig", out.written());
    }

    {
        var mock = try Mock.start("/contents", 1, Mock.fixed(
            "{\"results\":[{\"url\":\"https://ziglang.org\",\"text\":\"# Zig\"}]}",
        ));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
        const fetch: Fetch = .{ .url = "https://ziglang.org" };
        try fetch.ask(tool_set, &.{.{ .provider = .exa, .api_key = "secret", .endpoint = mock.url }}, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
        try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
        try std.testing.expectEqualStrings("# Zig", out.written());
    }
}

test "a url no backend could read does not set the backend aside" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mock = try Mock.start("/extract", 2, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{
                .body = "{\"results\":[],\"failed_results\":[{\"url\":\"https://nope.invalid\",\"error\":\"not found\"}]}",
            };
            return .{ .body = "<html>a page</html>" };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();

    const backends: []const web.Backend = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }};

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Tavily is the only configured backend and it could not read the url, so the url is read
    // directly instead -- from the same mock.
    const fetch: Fetch = .{ .url = mock.url };
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .health = &health, .keys = &Credentials.empty });
    try fetch.ask(tool_set, backends, &out.writer);
    try mock.await();

    try std.testing.expectEqualStrings("<html>a page</html>", out.written());
    try std.testing.expect(!health.skips("tavily", std.Io.Clock.real.now(io).toMilliseconds()));
    try std.testing.expectEqual(@as(usize, 0), health.entries.count());
    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expect(mock.header("authorization") == null);
}

test "a raw fetch reads the url directly, without any backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"node_id\":\"abc\"}";
    var mock = try Mock.start("/api", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{},
    });
    try run(.{ .url = mock.url, .raw = true }, tool_set, &out.writer);
    try mock.await();

    try std.testing.expectEqualStrings(reply, out.written());
}

test "a raw fetch keeps a body of any size whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply: [(1 << 20) + 10]u8 = @splat('x');
    var mock = try Mock.start("/big", 1, Mock.fixed(&reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{},
    });
    try run(.{ .url = mock.url, .raw = true }, tool_set, &out.writer);
    try mock.await();

    try std.testing.expectEqual(reply.len, out.written().len);
}

test "a backend whose key is not stored is not asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{ .providers = &.{.tavily} },
    });
    try run(.{ .url = "https://example.org" }, tool_set, &out.writer);
    try std.testing.expectEqualStrings(
        "error: no key is stored for a fetch backend; run `billy login` to store one",
        out.written(),
    );
}

test "a fetch with no backend named says so rather than reading the url" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // An empty set is a configuration that wants no page extraction; a call that did not ask for
    // `raw` cannot be answered by guessing the address.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{ .providers = &.{} },
    });
    try run(.{ .url = "https://example.org" }, tool_set, &out.writer);
    try std.testing.expectEqualStrings(
        "error: no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        out.written(),
    );
}

test "a fetch of an empty url is refused before any backend is asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{},
    });
    try run(.{ .url = "" }, tool_set, &out.writer);
    try std.testing.expectEqualStrings("error: no url to fetch", out.written());
}

const closed_port_url = "http://127.0.0.1:1/page";

test "a raw fetch of a url that cannot be read fails as the call, not the run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Nothing is returned.
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{},
    });
    try run(.{ .url = closed_port_url, .raw = true }, tool_set, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: cannot read " ++ closed_port_url ++ ": "));
}

test "a url neither a backend nor a direct read could reach is a failed call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/extract", 1, Mock.fixed(
        "{\"results\":[],\"failed_results\":[{\"url\":\"x\",\"error\":\"not found\"}]}",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const backends: []const web.Backend = &.{.{
        .provider = .tavily,
        .api_key = "secret",
        .endpoint = mock.url,
    }};

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const fetch: Fetch = .{ .url = closed_port_url };
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
    try fetch.ask(tool_set, backends, &out.writer);
    try mock.await();

    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: cannot read " ++ closed_port_url ++ ": "));
}

test "a url that asked to be waited is a failed call, and says how long for" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/page", 1, struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{
                .status = .too_many_requests,
                .body = "{}",
                .headers = &.{.{ .name = "retry-after", .value = "2" }},
            };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .fetch = .{},
    });
    try run(.{ .url = mock.url, .raw = true }, tool_set, &out.writer);
    try mock.await();

    const expected = try gpa.print("error: {s} asked to be waited 2000ms before it is read again", .{mock.url});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}
