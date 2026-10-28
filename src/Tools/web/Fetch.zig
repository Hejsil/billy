//! Web fetch: one url out to the backends the configuration named, in order, until one reads it.

const std = @import("std");

const Health = @import("../../Health.zig");
const Mock = @import("../../Mock.zig");
const Tools = @import("../../Tools.zig");
const web = @import("../web.zig");

const Fetch = @This();

/// One backend to fetch with, and what it is asked with: the key `billy login` stored for it.
pub const Backend = struct {
    provider: web.Provider,
    api_key: []const u8 = "",
    endpoint: ?[]const u8 = null,
};

/// What the configuration says about fetching, with the keys already resolved.
pub const Config = struct {
    backends: []const Backend,
};

url: []const u8,
raw: bool = false,

/// Fetches one url and writes its content as text.
pub fn run(fetch: Fetch, gpa: std.mem.Allocator, http_client: *std.http.Client, config: ?Config, health: ?*Health, out: *std.Io.Writer) !void {
    if (fetch.url.len == 0) return Tools.fail(out, "no url to fetch", .{});

    const fetch_config = config orelse return Tools.fail(
        out,
        "web fetch is not configured",
        .{},
    );

    const now_ms = std.Io.Clock.real.now(http_client.io).toMilliseconds();

    if (fetch.raw) return readDirectly(gpa, http_client, fetch.url, out);

    var failed: ?anyerror = null;
    // Set when a backend answered but could not read this url, which is not a failure of the
    // backend: the url is then read directly rather than the call coming back with nothing.
    var unreadable = false;
    for (fetch_config.backends) |backend| {
        if (Health.isSetAside(health, @tagName(backend.provider), now_ms)) continue;
        const value = fetchBackend(gpa, http_client, backend, fetch.url) catch |err| {
            if (err == error.UrlUnreadable) {
                std.log.warn("fetch: {s} could not read the url, trying the next", .{
                    @tagName(backend.provider),
                });
                unreadable = true;
                continue;
            }
            Health.recordFailure(health, @tagName(backend.provider), null, now_ms);
            std.log.warn("fetch: {s} failed: {s}, trying the next", .{
                @tagName(backend.provider), @errorName(err),
            });
            failed = err;
            continue;
        };
        switch (value) {
            .text => |text| {
                defer gpa.free(text);
                Health.recordAnswer(health, @tagName(backend.provider));
                return out.writeAll(text);
            },
            .retry_after_ms => |ms| {
                Health.recordFailure(health, @tagName(backend.provider), ms, now_ms);
                std.log.warn("fetch: {s} is set aside for {d}ms, trying the next", .{
                    @tagName(backend.provider), ms,
                });
            },
        }
    }
    if (failed) |err| return Tools.fail(out, "fetch failed: {s}", .{@errorName(err)});
    // A backend answered and could not read this url, so it is read directly: a page billy can
    // reach itself is still worth having.
    if (unreadable) return readDirectly(gpa, http_client, fetch.url, out);
    if (fetch_config.backends.len == 0) return Tools.fail(
        out,
        "no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        .{},
    );
    return Tools.fail(out, "every fetch backend is set aside after failing; wait", .{});
}

fn readDirectly(gpa: std.mem.Allocator, http_client: *std.http.Client, url: []const u8, out: *std.Io.Writer) !void {
    const answer = fetchBackend(gpa, http_client, .{ .provider = .raw }, url) catch |err|
        return Tools.fail(out, "cannot read {s}: {s}", .{ url, @errorName(err) });
    switch (answer) {
        .text => |text| {
            defer gpa.free(text);
            return out.writeAll(text);
        },
        .retry_after_ms => |ms| return Tools.fail(
            out,
            "{s} asked to be waited {d}ms before it is read again",
            .{ url, ms },
        ),
    }
}

fn fetchBackend(gpa: std.mem.Allocator, http_client: *std.http.Client, backend: Backend, url: []const u8) !web.Answer {
    const descriptor = backend.provider.descriptor();
    const spec = descriptor.fetch orelse return error.NotAFetchProvider;

    const base = if (spec.own_url)
        url
    else
        backend.endpoint orelse descriptor.fetch_endpoint orelse return error.MissingFetchUrl;
    const location = try web.address(
        gpa,
        base,
        if (!spec.own_url and descriptor.fetch_endpoint == null) spec.configured_path else "",
    );
    defer gpa.free(location);

    var payload: ?[]const u8 = null;
    defer if (payload) |body| gpa.free(body);

    const method: std.http.Method = switch (spec.request) {
        .get => .GET,
        .post => |build| post: {
            payload = try build(gpa, url);
            break :post .POST;
        },
    };

    const answer = try web.providerRequest(
        gpa,
        http_client,
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
            defer gpa.free(text);
            break :text .{ .text = try render(gpa, text) };
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
        try run(.{ .url = "https://ziglang.org" }, gpa, &http_client, .{
            .backends = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }},
        }, null, &out.writer);
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
        try run(.{ .url = "https://ziglang.org" }, gpa, &http_client, .{
            .backends = &.{.{ .provider = .exa, .api_key = "secret", .endpoint = mock.url }},
        }, null, &out.writer);
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

    const config: Config = .{ .backends = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }} };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Tavily is the only configured backend and it could not read the url, so the url is read
    // directly instead -- from the same mock.
    try run(.{ .url = mock.url }, gpa, &http_client, config, &health, &out.writer);
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
    try run(.{ .url = mock.url, .raw = true }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
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
    try run(.{ .url = mock.url, .raw = true }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
    try mock.await();

    try std.testing.expectEqual(reply.len, out.written().len);
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
    try run(.{ .url = "https://example.org" }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
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
    try run(.{ .url = "" }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
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
    try run(.{ .url = closed_port_url, .raw = true }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
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

    const config: Config = .{ .backends = &.{.{
        .provider = .tavily,
        .api_key = "secret",
        .endpoint = mock.url,
    }} };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .url = closed_port_url }, gpa, &http_client, config, null, &out.writer);
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
    try run(.{ .url = mock.url, .raw = true }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
    try mock.await();

    const expected = try gpa.print("error: {s} asked to be waited 2000ms before it is read again", .{mock.url});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());
}
