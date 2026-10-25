//! Web search: one query out to the backends the configuration named, in order,
//! until one answers.

const std = @import("std");
const Health = @import("../../Health.zig");
const Tools = @import("../../Tools.zig");
const Mock = @import("../../Mock.zig");
const web = @import("../web.zig");

pub const Result = @import("Search/Result.zig");

const Search = @This();

/// One backend to search with, and what it is asked with: the key `billy login`
/// stored for it, and the instance for a backend that is the user's own.
pub const Backend = struct {
    provider: web.Provider,
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
pub fn run(search: Search, gpa: std.mem.Allocator, http_client: *std.http.Client, config: ?Config, health: ?*Health, out: *std.Io.Writer) !void {
    const search_config = config orelse return Tools.fail(
        out,
        "web search is not configured",
        .{},
    );

    const now_ms = std.Io.Clock.real.now(http_client.io).toMilliseconds();
    var failed: ?anyerror = null;
    for (search_config.backends) |backend| {
        // A backend that failed not long ago is skipped, so a backend that is
        // down, rate-limited or out of credit is not asked again yet.
        if (Health.isSetAside(health, @tagName(backend.provider), now_ms)) continue;
        const value = searchBackend(gpa, http_client, backend, search.query, search_config.max_results) catch |err| {
            Health.recordFailure(health, @tagName(backend.provider), null, now_ms);
            std.log.warn("search: {s} failed: {s}, trying the next", .{
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
                std.log.warn("search: {s} is set aside for {d}ms, trying the next", .{
                    @tagName(backend.provider), ms,
                });
            },
        }
    }
    // Every backend that could be asked was tried and failed.
    if (failed) |err| return Tools.fail(out, "search failed: {s}", .{@errorName(err)});
    // A set with no backend in it names nothing to try, so nothing failed and
    // nothing was set aside. Only a session carrying the tool from a run that
    // had a backend reaches this.
    if (search_config.backends.len == 0) return Tools.fail(
        out,
        "no search backend is configured; add one to tools.web_search.providers",
        .{},
    );
    return Tools.fail(
        out,
        "every search backend is set aside after failing; add another to tools.web_search.providers, or wait",
        .{},
    );
}

/// Runs one query against one backend, whichever it is.
fn searchBackend(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    backend: Backend,
    query: []const u8,
    max_results: usize,
) !web.Answer {
    // The same cap for every backend, whatever the configuration says.
    const asked = @min(max_results, Result.result_limit);

    const descriptor = backend.provider.descriptor();
    const spec = descriptor.search orelse return error.NotASearchProvider;
    const base = backend.endpoint orelse descriptor.search_endpoint orelse return error.MissingSearchUrl;
    // A provider whose address the configuration names lives under a known path
    // on that instance; one whose address the table gives is used whole.
    const location = try web.address(gpa, base, if (descriptor.search_endpoint == null) spec.configured_path else "");
    defer gpa.free(location);

    // A GET asks in the url and a POST in a body; one of the two is built here.
    var payload: ?[]const u8 = null;
    defer if (payload) |body| gpa.free(body);
    var asked_url: ?[]const u8 = null;
    defer if (asked_url) |url| gpa.free(url);
    var target = location;

    const method: std.http.Method = switch (spec.request) {
        .get => |kind| get: {
            asked_url = switch (kind) {
                .count => try web.queryUrl(gpa, location, query, "&count={d}", .{asked}),
                .format_json => try web.queryUrl(gpa, location, query, "&format=json", .{}),
            };
            target = asked_url.?;
            break :get .GET;
        },
        .post => |build| post: {
            payload = try build(gpa, query, asked);
            break :post .POST;
        },
    };

    const answer = try web.providerRequest(
        gpa,
        http_client,
        "search",
        descriptor,
        backend.api_key,
        method,
        target,
        payload,
    );
    return switch (answer) {
        .text => |text| text: {
            defer gpa.free(text);
            break :text .{ .text = try spec.render(gpa, text, asked) };
        },
        .retry_after_ms => |ms| .{ .retry_after_ms = ms },
    };
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

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

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
    try run(.{ .query = "zig lang" }, gpa, &http_client, config, null, &out.writer);
    try mock.await();

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

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http_client, config, null, &out.writer);
    try mock.await();

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

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

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
    try run(.{ .query = "zig lang" }, gpa, &http_client, config, &health, &out.writer);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", out.written());
    try std.testing.expect(health.skips("tavily", std.Io.Clock.real.now(io).toMilliseconds()));
    try std.testing.expect(!health.skips("brave", std.Io.Clock.real.now(io).toMilliseconds()));

    // The second search is Brave alone: Tavily posts its query as a body and
    // Brave asks in the url, so the third request arriving with no body is
    // Brave answering, not Tavily being asked again.
    out.clearRetainingCapacity();
    try run(.{ .query = "zig lang" }, gpa, &http_client, config, &health, &out.writer);
    try mock.await();

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("", mock.bodies.items[2]);
    try std.testing.expectEqualStrings("b", mock.header("x-subscription-token").?);
}

test "brave is asked for no more results than billy allows any backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/search", 1, Mock.fixed("{\"web\":{\"results\":[]}}"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const config: Config = .{
        .backends = &.{.{ .provider = .brave, .api_key = "b", .endpoint = mock.url }},
        .max_results = 1000,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig" }, gpa, &http_client, config, null, &out.writer);
    try mock.await();

    try std.testing.expectEqualStrings("/search?q=zig&count=20", mock.targets.items[0]);
    // Brave is told the reply is JSON as well as being asked in its own header.
    try std.testing.expectEqualStrings("application/json", mock.header("accept").?);
}

test "each provider is asked the way its table says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // Tavily: the query and the count as its JSON body, the key as a bearer
    // token.
    {
        var mock = try Mock.start("/search", 1, Mock.fixed("{\"results\":[]}"));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try run(.{ .query = "zig lang" }, gpa, &http_client, .{
            .backends = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }},
            .max_results = 3,
        }, null, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings(
            "{\"query\":\"zig lang\",\"max_results\":3,\"search_depth\":\"basic\",\"include_answer\":false}",
            mock.bodies.items[0],
        );
        try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    }

    // Exa: its own camelCase body, and its key in `x-api-key`.
    {
        var mock = try Mock.start("/search", 1, Mock.fixed("{\"results\":[]}"));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try run(.{ .query = "zig lang" }, gpa, &http_client, .{
            .backends = &.{.{ .provider = .exa, .api_key = "secret", .endpoint = mock.url }},
            .max_results = 3,
        }, null, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings(
            "{\"query\":\"zig lang\",\"numResults\":3,\"contents\":{\"text\":{\"maxCharacters\":500}}}",
            mock.bodies.items[0],
        );
        try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    }

    // SearXNG: a GET with no key, asking for JSON instead of a count.
    {
        var mock = try Mock.start("", 1, Mock.fixed("{\"results\":[]}"));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try run(.{ .query = "zig lang" }, gpa, &http_client, .{
            .backends = &.{.{ .provider = .searxng, .endpoint = mock.url }},
            .max_results = 3,
        }, null, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings("/search?q=zig%20lang&format=json", mock.targets.items[0]);
        try std.testing.expect(mock.header("authorization") == null);
        try std.testing.expectEqualStrings("", mock.bodies.items[0]);
    }
}

test "searxng results are capped at the most billy allows any backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = comptime blk: {
        var text: []const u8 = "{\"results\":[";
        for (0..25) |i| {
            text = text ++ (if (i > 0) "," else "") ++ "{\"title\":\"t\",\"url\":\"u\",\"content\":\"c\"}";
        }
        break :blk text ++ "]}";
    };
    var mock = try Mock.start("", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const config: Config = .{
        .backends = &.{.{ .provider = .searxng, .endpoint = mock.url }},
        .max_results = 1000,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig" }, gpa, &http_client, config, null, &out.writer);
    try mock.await();

    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, out.written(), "   u\n"));
}

test "a search with no backend named says one is not configured" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // An empty set is a configuration that names no backend: nothing was tried,
    // so saying that every backend failed and was set aside would be a lie.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http_client, .{ .backends = &.{}, .max_results = 3 }, null, &out.writer);
    try std.testing.expectEqualStrings(
        "error: no search backend is configured; add one to tools.web_search.providers",
        out.written(),
    );
}

test "a search with every backend set aside says so, without asking any" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A listener that never serves: no backend should be reached.
    var mock = try Mock.start("/search", 1, Mock.fixed("{}"));
    defer mock.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    health.record("tavily", null, now);
    health.record("brave", null, now);

    const config: Config = .{
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try run(.{ .query = "zig lang" }, gpa, &http_client, config, &health, &out.writer);

    try std.testing.expectEqual(@as(usize, 0), mock.served);
    try std.testing.expectEqualStrings(
        "error: every search backend is set aside after failing; " ++
            "add another to tools.web_search.providers, or wait",
        out.written(),
    );
}
