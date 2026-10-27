//! Web fetch: one url out to the backends the configuration named, in order,
//! until one reads it.

const std = @import("std");
const Health = @import("../../Health.zig");
const Tools = @import("../../Tools.zig");
const web = @import("../web.zig");
const Mock = @import("../../Mock.zig");

const Fetch = @This();

/// One backend to fetch with, and what it is asked with: the key `billy login`
/// stored for it.
pub const Backend = struct {
    provider: web.Provider,
    /// The key the backend is asked with. Empty for `raw`, which asks no one.
    api_key: []const u8 = "",
    /// Where the backend is reached, when it is not the address billy knows, as
    /// in a test. Null uses the backend's own address, and is unused by `raw`,
    /// which reads the url of the call.
    endpoint: ?[]const u8 = null,
};

/// What the configuration says about fetching, with the keys already resolved.
/// A set with no backend leaves `web_fetch` out of a request, which is a
/// configuration that wants no page extraction at all.
pub const Config = struct {
    backends: []const Backend,
};

url: []const u8,
/// Read the url directly instead of extracting a page, for an address
/// whose bytes are wanted as they are, such as a JSON API. Extraction
/// escapes its text as markdown, which would mangle it.
///
/// This picks the `raw` provider rather than a backend: the call is asking for
/// the url itself, whatever the configuration extracts with.
raw: bool = false,

/// Fetches one url and writes its content as text. A page is extracted by a
/// backend; `raw` reads the url directly, for an API or a file.
///
/// A url that cannot be read is written as the call's failure, like any other
/// tool's: the model asked for something that is not there, and is told why so
/// it can ask for another address, rather than the turn stopping under it.
pub fn run(fetch: Fetch, gpa: std.mem.Allocator, http_client: *std.http.Client, config: ?Config, health: ?*Health, out: *std.Io.Writer) !void {
    if (fetch.url.len == 0) return Tools.fail(out, "no url to fetch", .{});

    const fetch_config = config orelse return Tools.fail(
        out,
        "web fetch is not configured",
        .{},
    );

    const now_ms = std.Io.Clock.real.now(http_client.io).toMilliseconds();

    // A raw fetch asks for the url itself, so no backend is consulted.
    if (fetch.raw) return readDirectly(gpa, http_client, fetch.url, out);

    var failed: ?anyerror = null;
    // Set when a backend answered but could not read this url, which is not a
    // failure of the backend: the url is then read directly rather than the call
    // coming back with nothing.
    var unreadable = false;
    for (fetch_config.backends) |backend| {
        if (Health.isSetAside(health, @tagName(backend.provider), now_ms)) continue;
        const value = fetchBackend(gpa, http_client, backend, fetch.url) catch |err| {
            // A url the backend could not read is not a backend that is down:
            // it answered, so the next backend is tried without setting this
            // one aside. Anything else -- no answer, or an answer that is not a
            // success -- is a failure of the backend itself, and it waits.
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
    // A backend answered and could not read this url, so it is read directly: a
    // page billy can reach itself is still worth having. A set with no backend
    // in it asks for no extraction at all, so that is where it ends.
    if (unreadable) return readDirectly(gpa, http_client, fetch.url, out);
    if (fetch_config.backends.len == 0) return Tools.fail(
        out,
        "no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        .{},
    );
    return Tools.fail(out, "every fetch backend is set aside after failing; wait", .{});
}

/// Reads `url` with no backend at all, which is what a fetch falls back to when
/// no configured backend reads it, and what the `raw` provider does on its own.
///
/// Every way this can go wrong is the call's failure and not the run's, so
/// nothing here is returned as an error: a url that cannot be reached, and one
/// that asked to be waited before it is read again, both reach the model as the
/// result of the call it made.
fn readDirectly(gpa: std.mem.Allocator, http_client: *std.http.Client, url: []const u8, out: *std.Io.Writer) !void {
    // The raw provider is the url itself: no service, no key, no extraction.
    const answer = fetchBackend(gpa, http_client, .{ .provider = .raw }, url) catch |err|
        return Tools.fail(out, "cannot read {s}: {s}", .{ url, @errorName(err) });
    switch (answer) {
        .text => |text| {
            defer gpa.free(text);
            return out.writeAll(text);
        },
        // A provider that answered with a wait answered: it is not broken, and
        // there is nothing for it to wait for here, since the next call reads
        // the url afresh.
        .retry_after_ms => |ms| return Tools.fail(
            out,
            "{s} asked to be waited {d}ms before it is read again",
            .{ url, ms },
        ),
    }
}

/// Fetches one url with one backend, whichever it is.
fn fetchBackend(gpa: std.mem.Allocator, http_client: *std.http.Client, backend: Backend, url: []const u8) !web.Answer {
    const descriptor = backend.provider.descriptor();
    const spec = descriptor.fetch orelse return error.NotAFetchProvider;

    // Raw reads the url of the call; a service is reached at its own address,
    // or the instance the configuration named.
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
            // A provider with no mapping answers with the bytes as they are,
            // which is what `raw` does.
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

    // Tavily: the url as its JSON body, the key as a bearer token, and the
    // reply as the url's content.
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

    // Exa: the same shape with its own key header and content field.
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

    // Two requests: Tavily answers that it could not read the url, and the
    // direct read that follows gets the page.
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
    // Tavily is the only configured backend and it could not read the url, so
    // the url is read directly instead -- from the same mock.
    try run(.{ .url = mock.url }, gpa, &http_client, config, &health, &out.writer);
    try mock.await();

    try std.testing.expectEqualStrings("<html>a page</html>", out.written());
    // Tavily answered, so it is not set aside: a search after this fetch still
    // reaches it. The direct read carried no key, so it was not Tavily's.
    try std.testing.expect(!health.skips("tavily", std.Io.Clock.real.now(io).toMilliseconds()));
    try std.testing.expectEqual(@as(usize, 0), health.entries.count());
    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expect(mock.header("authorization") == null);
}

test "a raw fetch reads the url directly, without any backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // No backend is configured at all, which is what a call asking for the bytes
    // as they are needs: the url is read whatever the configuration extracts with.
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

    // Larger than the 1 MiB the read used to be cut to.
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

    // An empty set is a configuration that wants no page extraction; a call that
    // did not ask for `raw` cannot be answered by guessing the address.
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

/// An address nothing listens on, so a read of it fails the way a url that is
/// not there does. The same one `Agent.TestSetup` points a provider at.
const closed_port_url = "http://127.0.0.1:1/page";

test "a raw fetch of a url that cannot be read fails as the call, not the run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Nothing is returned. A url that is not there is the call's result, written
    // with the mark both readers branch on, so the model is told why and goes on
    // to ask for another address instead of the turn ending under it.
    try run(.{ .url = closed_port_url, .raw = true }, gpa, &http_client, .{ .backends = &.{} }, null, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: cannot read " ++ closed_port_url ++ ": "));
}

test "a url neither a backend nor a direct read could reach is a failed call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The backend answers that it could not read the url, which is not a failure
    // of the backend, so the url is read directly -- and that read fails too,
    // since the url is a closed port. The fallback is part of the call's answer
    // as much as the backend's was.
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

    // A raw read of a url that is rate-limiting: it answered, so there is
    // nothing to try next and nothing to wait for here, since the next call
    // reads the url afresh. It is the call that is told, with the wait the url
    // asked for.
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
