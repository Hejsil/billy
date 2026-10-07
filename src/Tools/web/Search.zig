//! Web search: one query out to the backends the configuration named, in order,
//! until one answers.

const std = @import("std");
const Health = @import("../../Health.zig");
const tools = @import("../../Tools.zig");
const Mock = @import("../../Mock.zig");
const outcome = @import("Outcome.zig");
const brave = @import("provider/brave.zig");
const exa = @import("provider/exa.zig");
const searxng = @import("provider/searxng.zig");
const tavily = @import("provider/tavily.zig");

pub const Result = @import("Search/Result.zig");

const Search = @This();

/// The backends billy can search with. The name is what the configuration holds,
/// stored as the variant itself so an unknown name is refused when the file is
/// read rather than carried around as a string.
///
/// A search provider takes a query and answers with results; a provider that can
/// also read a url is listed in `Fetch.Provider` too, and is the same service
/// either way.
pub const Provider = enum {
    tavily,
    exa,
    brave,
    searxng,

    /// The names a configuration may hold, in the order a listing shows them.
    pub const all: []const Provider = &.{ .tavily, .exa, .brave, .searxng };
};

/// One backend to search with, and what it is asked with: the key, from the
/// credential `billy login` stored or its environment variable, and the instance
/// for a backend that is the user's own.
pub const Backend = struct {
    provider: Provider,
    /// The key the backend is asked with. Empty for one that needs none, which
    /// is SearXNG, whose instance the user runs.
    api_key: []const u8 = "",
    /// Where the backend is reached, when it is not the address billy knows:
    /// SearXNG's instance, or, in a test, the server standing in for a backend.
    /// Null uses the backend's own address.
    endpoint: ?[]const u8 = null,
};

/// What the configuration says about searching, with the keys already resolved:
/// the backends to try, in order, and how many results to ask for. A null of
/// this in a tool set is what leaves web search out of a request.
pub const Config = struct {
    backends: []const Backend,
    /// Results asked for per query. A backend may return fewer.
    max_results: usize,
};

query: []const u8,

/// Runs one web search and writes its results as text. No backend is configured
/// only when a resumed session carries the tool from a run that had one; the
/// model is told so rather than the call failing outright.
pub fn run(search: Search, gpa: std.mem.Allocator, http: *std.http.Client, config: ?Config, health: ?*Health, out: *std.Io.Writer) !void {
    const search_config = config orelse return tools.fail(
        out,
        "web search is not configured",
        .{},
    );

    const now_ms = std.Io.Clock.real.now(http.io).toMilliseconds();
    var failed: ?anyerror = null;
    for (search_config.backends) |backend| {
        // A backend that failed not long ago is skipped, so a backend that is
        // down, rate-limited or out of credit is not asked again yet.
        if (setAside(health, backend.provider, now_ms)) continue;
        const value = searchBackend(gpa, http, backend, search.query, search_config.max_results) catch |err| {
            try giveUp(health, backend.provider, null, now_ms);
            std.log.warn("search: {s} failed: {s}, trying the next", .{
                @tagName(backend.provider), @errorName(err),
            });
            failed = err;
            continue;
        };
        switch (value) {
            .text => |text| {
                defer gpa.free(text);
                try answered(health, backend.provider);
                return out.writeAll(text);
            },
            .retry_after_ms => |ms| {
                try giveUp(health, backend.provider, ms, now_ms);
                std.log.warn("search: {s} is set aside for {d}ms, trying the next", .{
                    @tagName(backend.provider), ms,
                });
            },
        }
    }
    // Every backend was tried and failed. A search with none named is a
    // configuration mistake rather than a failure of a backend, and a resumed
    // session can carry the tool from a run that had one.
    if (failed) |err| return tools.fail(out, "search failed: {s}", .{@errorName(err)});
    return tools.fail(
        out,
        "every search backend is set aside after failing; add another to tools.web_search.providers, or wait",
        .{},
    );
}

/// Runs one query against one backend, whichever it is.
fn searchBackend(
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    backend: Backend,
    query: []const u8,
    max_results: usize,
) !outcome.Value {
    return switch (backend.provider) {
        .tavily => tavily.search(gpa, http, backend.api_key, reach(backend), query, max_results),
        .exa => exa.search(gpa, http, backend.api_key, reach(backend), query, max_results),
        .brave => brave.search(gpa, http, backend.api_key, reach(backend), query, max_results),
        // The instance is the configuration's, so it is always named.
        .searxng => searxng.search(gpa, http, reach(backend), query, max_results),
    };
}

/// The address to send to: the one named for this backend, or the address billy
/// knows the service by. SearXNG has none: the instance is always named.
fn reach(backend: Backend) []const u8 {
    return backend.endpoint orelse switch (backend.provider) {
        .tavily => tavily.search_endpoint,
        .exa => exa.search_endpoint,
        .brave => brave.search_endpoint,
        .searxng => unreachable,
    };
}

/// Whether `provider` is set aside at `now`, and so should be skipped.
fn setAside(health: ?*Health, provider: Provider, now: i64) bool {
    const store = health orelse return false;
    return store.skips(@tagName(provider), now);
}

/// Records that `provider` failed, so it is skipped for a while.
fn giveUp(health: ?*Health, provider: Provider, retry_after_ms: ?i64, now: i64) !void {
    const store = health orelse return;
    try store.record(@tagName(provider), retry_after_ms, now);
}

/// Records that `provider` answered, clearing any wait it had.
fn answered(health: ?*Health, provider: Provider) !void {
    const store = health orelse return;
    try store.clear(@tagName(provider));
}

test "the backends are tried in order until one answers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The first reply is a server error and the second is results, so the first
    // backend fails and the second answers.
    var mock = try Mock.start("/search", 2, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{ .status = .internal_server_error, .body = "{}" };
            return .{ .body = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}]}" };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    // Two backends, both standing in for the same server, so what is tested is
    // the order rather than which backend it is.
    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .tavily, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http, config, null, &out.writer);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // Both were tried: the first failed and the second answered.
    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", out.written());
}

test "a search fails only when every backend has failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/search", 2, struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{ .status = .internal_server_error, .body = "{}" };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http, config, null, &out.writer);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expectEqualStrings("error: search failed: RequestFailed", out.written());
}

test "a backend that failed is set aside, so the next search skips it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three requests: Tavily fails the first search, Brave answers it, and Brave
    // answers the second search, which never asks Tavily again.
    var mock = try Mock.start("/search", 3, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{ .status = .internal_server_error, .body = "{}" };
            return .{ .body = "{\"web\":{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"description\":\"A language.\"}]}}" };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();

    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The first search falls through Tavily, which fails, to Brave, which
    // answers, and Tavily is left set aside.
    try run(.{ .query = "zig lang" }, gpa, &http, config, &health, &out.writer);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", out.written());
    try std.testing.expect(health.skips("tavily", std.Io.Clock.real.now(io).toMilliseconds()));
    try std.testing.expect(!health.skips("brave", std.Io.Clock.real.now(io).toMilliseconds()));

    // The second search is Brave alone: Tavily posts its query as a body and
    // Brave asks in the url, so the third request arriving with no body is
    // Brave answering, not Tavily being asked again.
    out.clearRetainingCapacity();
    try run(.{ .query = "zig lang" }, gpa, &http, config, &health, &out.writer);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("", mock.bodies.items[2]);
    try std.testing.expectEqualStrings("b", mock.header("x-subscription-token").?);
}

test "a search with every backend set aside says so, without asking any" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A listener that never serves: no backend should be reached.
    var mock = try Mock.start("/search", 1, Mock.fixed("{}"));
    defer mock.deinit();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    try health.record("tavily", null, now);
    try health.record("brave", null, now);

    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http, config, &health, &out.writer);

    try std.testing.expectEqual(@as(usize, 0), mock.served);
    try std.testing.expectEqualStrings(
        "error: every search backend is set aside after failing; " ++
            "add another to tools.web_search.providers, or wait",
        out.written(),
    );
}
