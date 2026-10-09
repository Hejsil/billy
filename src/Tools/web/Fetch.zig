//! Web fetch: one url out to the backends the configuration named, in order,
//! until one reads it.

const std = @import("std");
const Health = @import("../../Health.zig");
const tools = @import("../../Tools.zig");
const outcome = @import("Outcome.zig");
const exa = @import("provider/exa.zig");
const direct = @import("provider/raw.zig");
const Mock = @import("../../Mock.zig");
const tavily = @import("provider/tavily.zig");

const Fetch = @This();

/// The backends billy can read a url with. `raw` is the url itself, read
/// directly: it is what a call that asks for the bytes as they are uses, and
/// what is left when no service extracts a page.
pub const Provider = enum {
    raw,
    tavily,
    exa,

    /// The names a configuration may hold, in the order a listing shows them.
    pub const all: []const Provider = &.{ .raw, .tavily, .exa };
};

/// One backend to fetch with, and what it is asked with: the key, from the
/// credential `billy login` stored or its environment variable.
pub const Backend = struct {
    provider: Provider,
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
pub fn run(fetch: Fetch, gpa: std.mem.Allocator, http: *std.http.Client, config: ?Config, health: ?*Health, out: *std.Io.Writer) !void {
    if (fetch.url.len == 0) return tools.fail(out, "no url to fetch", .{});

    const fetch_config = config orelse return tools.fail(
        out,
        "web fetch is not configured",
        .{},
    );

    const now_ms = std.Io.Clock.real.now(http.io).toMilliseconds();

    // A raw fetch asks for the url itself, so no backend is consulted.
    if (fetch.raw) {
        const value = try direct.fetch(gpa, http, fetch.url);
        defer gpa.free(value.text);
        return out.writeAll(value.text);
    }

    var failed: ?anyerror = null;
    // Set when a backend answered but could not read this url, which is not a
    // failure of the backend: the url is then read directly rather than the call
    // coming back with nothing.
    var unreadable = false;
    for (fetch_config.backends) |backend| {
        if (Health.isSetAside(health, @tagName(backend.provider), now_ms)) continue;
        const value = fetchBackend(gpa, http, backend, fetch.url) catch |err| {
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
            try Health.recordFailure(health, @tagName(backend.provider), null, now_ms);
            std.log.warn("fetch: {s} failed: {s}, trying the next", .{
                @tagName(backend.provider), @errorName(err),
            });
            failed = err;
            continue;
        };
        switch (value) {
            .text => |text| {
                defer gpa.free(text);
                try Health.recordAnswer(health, @tagName(backend.provider));
                return out.writeAll(text);
            },
            .retry_after_ms => |ms| {
                try Health.recordFailure(health, @tagName(backend.provider), ms, now_ms);
                std.log.warn("fetch: {s} is set aside for {d}ms, trying the next", .{
                    @tagName(backend.provider), ms,
                });
            },
        }
    }
    if (failed) |err| return tools.fail(out, "fetch failed: {s}", .{@errorName(err)});
    // A backend answered and could not read this url, so it is read directly: a
    // page billy can reach itself is still worth having. A set with no backend
    // in it asks for no extraction at all, so that is where it ends.
    if (unreadable) return readDirectly(gpa, http, fetch.url, out);
    if (fetch_config.backends.len == 0) return tools.fail(
        out,
        "no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        .{},
    );
    return tools.fail(out, "every fetch backend is set aside after failing; wait", .{});
}

/// Reads `url` with no backend at all, which is what a fetch falls back to when
/// no configured backend reads it, and what the `raw` provider does on its own.
fn readDirectly(gpa: std.mem.Allocator, http: *std.http.Client, url: []const u8, out: *std.Io.Writer) !void {
    const value = try direct.fetch(gpa, http, url);
    defer gpa.free(value.text);
    return out.writeAll(value.text);
}

/// Fetches one url with one backend, whichever it is.
fn fetchBackend(gpa: std.mem.Allocator, http: *std.http.Client, backend: Backend, url: []const u8) !outcome.Value {
    return switch (backend.provider) {
        .tavily => tavily.fetch(gpa, http, backend.api_key, reach(backend), url),
        .exa => exa.fetch(gpa, http, backend.api_key, reach(backend), url),
        .raw => direct.fetch(gpa, http, url),
    };
}

/// The address to send to: the one named for this backend, or the backend's own.
fn reach(backend: Backend) []const u8 {
    return backend.endpoint orelse switch (backend.provider) {
        .tavily => tavily.fetch_endpoint,
        .exa => exa.fetch_endpoint,
        // Raw reads the url of the call, so it is never reached here.
        .raw => unreachable,
    };
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

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();

    const config: Config = .{ .backends = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }} };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Tavily is the only configured backend and it could not read the url, so
    // the url is read directly instead -- from the same mock.
    try run(.{ .url = mock.url }, gpa, &http, config, &health, &out.writer);
    try mock.group.await(io);
    if (mock.err) |err| return err;

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

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .url = mock.url, .raw = true }, gpa, &http, .{ .backends = &.{} }, null, &out.writer);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqualStrings(reply, out.written());
}

test "a fetch with no backend named says so rather than reading the url" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // An empty set is a configuration that wants no page extraction; a call that
    // did not ask for `raw` cannot be answered by guessing the address.
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .url = "https://example.org" }, gpa, &http, .{ .backends = &.{} }, null, &out.writer);
    try std.testing.expectEqualStrings(
        "error: no fetch backend is configured; add one to tools.web_fetch.providers, or pass raw",
        out.written(),
    );
}

test "a fetch of an empty url is refused before any backend is asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .url = "" }, gpa, &http, .{ .backends = &.{} }, null, &out.writer);
    try std.testing.expectEqualStrings("error: no url to fetch", out.written());
}
