//! Web search: one query out to the backends the configuration named, in order, until one answers.

const std = @import("std");

const Credentials = @import("../../Credentials.zig");
const Health = @import("../../Health.zig");
const Mock = @import("../../Mock.zig");
const Tools = @import("../../Tools.zig");
const web = @import("../web.zig");

pub const Result = @import("Search/Result.zig");

const Search = @This();

/// The most backends one call asks, which is as many providers as billy knows.
const max_backends = @typeInfo(web.Provider).@"enum".field_names.len;

query: []const u8,

/// Runs one web search and writes its results as text.
pub fn run(search: Search, tools: Tools, out: *std.Io.Writer) !void {
    const settings = tools.settings.search;
    if (settings.providers.len == 0) return Tools.fail(
        out,
        "no search backend is configured; add one to tools.web_search.providers",
        .{},
    );

    // The keys are read as the call is made, so one stored while billy runs is the one the next
    // search asks with, and a run that never searches asks for none of them.
    var backends: [max_backends]web.Backend = undefined;
    var usable: usize = 0;
    var unusable: ?anyerror = null;
    for (settings.providers) |provider| {
        if (usable == max_backends) {
            std.log.warn("search: {d} backends named, which is more than billy knows", .{settings.providers.len});
            break;
        }
        backends[usable] = backendFor(settings, tools.settings.keys, provider) catch |err| {
            std.log.warn("search: {t} cannot be asked: {t}, trying the next", .{ provider, err });
            unusable = err;
            continue;
        };
        usable += 1;
    }
    if (usable == 0) return switch (unusable.?) {
        error.MissingApiKey => Tools.fail(
            out,
            "no key is stored for a search backend; run `billy login` to store one",
            .{},
        ),
        error.MissingSearchUrl => Tools.fail(
            out,
            "the searxng backend has no address; set tools.web_search.searxng.url",
            .{},
        ),
        else => |err| Tools.fail(out, "search failed: {t}", .{err}),
    };

    return search.ask(tools, backends[0..usable], out);
}

/// The backend `provider` is asked as, or the reason it cannot be asked: a key billy does not have,
/// or a self-hosted backend with no address.
fn backendFor(settings: web.SearchSettings, keys: *const Credentials, provider: web.Provider) !web.Backend {
    return .{
        .provider = provider,
        .api_key = if (provider.service()) |service|
            keys.get(service) orelse return error.MissingApiKey
        else blk: {
            const url = settings.searxng.url orelse return error.MissingSearchUrl;
            if (url.len == 0) return error.MissingSearchUrl;
            break :blk "";
        },
        .endpoint = if (provider.service() == null) settings.searxng.url else null,
    };
}

/// Asks each backend in turn until one answers.
fn ask(search: Search, tools: Tools, backends: []const web.Backend, out: *std.Io.Writer) !void {
    const now_ms = std.Io.Clock.real.now(tools.http.io).toMilliseconds();
    var failed: ?anyerror = null;
    for (backends) |backend| {
        if (Health.isSetAside(tools.settings.health, @tagName(backend.provider), now_ms)) continue;
        const value = searchBackend(tools, backend, search.query, tools.settings.search.max_results) catch |err| {
            Health.recordFailure(tools.settings.health, @tagName(backend.provider), null, now_ms);
            std.log.warn("search: {t} failed: {t}, trying the next", .{
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
                std.log.warn("search: {t} is set aside for {d}ms, trying the next", .{
                    backend.provider, ms,
                });
            },
        }
    }
    if (failed) |err| return Tools.fail(out, "search failed: {t}", .{err});
    return Tools.fail(
        out,
        "every search backend is set aside after failing; add another to tools.web_search.providers, or wait",
        .{},
    );
}

fn searchBackend(tools: Tools, backend: web.Backend, query: []const u8, max_results: usize) !web.Answer {
    const asked = @min(max_results, Result.result_limit);

    const descriptor = backend.provider.descriptor();
    const spec = descriptor.search orelse return error.NotASearchProvider;
    const base = backend.endpoint orelse descriptor.search_endpoint orelse return error.MissingSearchUrl;
    const location = try web.address(tools.gpa, base, if (descriptor.search_endpoint == null) spec.configured_path else "");
    defer tools.gpa.free(location);

    var payload: ?[]const u8 = null;
    defer if (payload) |body| tools.gpa.free(body);
    var asked_url: ?[]const u8 = null;
    defer if (asked_url) |url| tools.gpa.free(url);
    var target = location;

    const method: std.http.Method = switch (spec.request) {
        .get => |tail| get: {
            asked_url = switch (tail) {
                .count => try web.queryUrl(tools.gpa, location, query, "&count={d}", .{asked}),
                .format_json => try web.queryUrl(tools.gpa, location, query, "&format=json", .{}),
            };
            target = asked_url.?;
            break :get .GET;
        },
        .post => |build| post: {
            payload = try build(tools.gpa, query, asked);
            break :post .POST;
        },
    };

    const answer = try web.providerRequest(
        tools.gpa,
        tools.http,
        "search",
        descriptor,
        backend.api_key,
        method,
        target,
        payload,
    );
    return switch (answer) {
        .text => |text| text: {
            defer tools.gpa.free(text);
            break :text .{ .text = try spec.render(tools.gpa, text, asked) };
        },
        .retry_after_ms => |ms| .{ .retry_after_ms = ms },
    };
}

test "the backends are tried in order until one answers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

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

    // Two backends, both standing in for the same server, so what is tested is the order rather
    // than which backend it is.
    const search: Search = .{ .query = "zig lang" };
    const backends: []const web.Backend = &.{
        .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
        .{ .provider = .tavily, .api_key = "b", .endpoint = mock.url },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 3 } });
    try search.ask(tool_set, backends, &out.writer);
    try mock.await();

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

    const search: Search = .{ .query = "zig lang" };
    const backends: []const web.Backend = &.{
        .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
        .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 3 } });
    try search.ask(tool_set, backends, &out.writer);
    try mock.await();

    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expectEqualStrings("error: search failed: RequestFailed", out.written());
}

test "a backend that failed is set aside, so the next search skips it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three requests: Tavily fails the first search, Brave answers it, and Brave answers the second
    // search, which never asks Tavily again.
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

    const search: Search = .{ .query = "zig lang" };
    const backends: []const web.Backend = &.{
        .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
        .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .search = .{ .max_results = 3 },
        .health = &health,
    });
    try search.ask(tool_set, backends, &out.writer);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", out.written());
    try std.testing.expect(health.skips("tavily", std.Io.Clock.real.now(io).toMilliseconds()));
    try std.testing.expect(!health.skips("brave", std.Io.Clock.real.now(io).toMilliseconds()));

    out.clearRetainingCapacity();
    try search.ask(tool_set, backends, &out.writer);
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

    const search: Search = .{ .query = "zig" };
    const backends: []const web.Backend = &.{.{ .provider = .brave, .api_key = "b", .endpoint = mock.url }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 1000 } });
    try search.ask(tool_set, backends, &out.writer);
    try mock.await();

    try std.testing.expectEqualStrings("/search?q=zig&count=20", mock.targets.items[0]);
    try std.testing.expectEqualStrings("application/json", mock.header("accept").?);
}

test "each provider is asked the way its table says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    {
        var mock = try Mock.start("/search", 1, Mock.fixed("{\"results\":[]}"));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 3 } });
        const search: Search = .{ .query = "zig lang" };
        try search.ask(tool_set, &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }}, &out.writer);
        try mock.await();

        try std.testing.expectEqualStrings(
            "{\"query\":\"zig lang\",\"max_results\":3,\"search_depth\":\"basic\",\"include_answer\":false}",
            mock.bodies.items[0],
        );
        try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    }

    {
        var mock = try Mock.start("/search", 1, Mock.fixed("{\"results\":[]}"));
        defer mock.deinit();
        try mock.serve();

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 3 } });
        const search: Search = .{ .query = "zig lang" };
        try search.ask(tool_set, &.{.{ .provider = .exa, .api_key = "secret", .endpoint = mock.url }}, &out.writer);
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
        const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 3 } });
        const search: Search = .{ .query = "zig lang" };
        try search.ask(tool_set, &.{.{ .provider = .searxng, .endpoint = mock.url }}, &out.writer);
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

    const search: Search = .{ .query = "zig lang" };
    const backends: []const web.Backend = &.{.{ .provider = .searxng, .endpoint = mock.url }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty, .search = .{ .max_results = 1000 } });
    try search.ask(tool_set, backends, &out.writer);
    try mock.await();

    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, out.written(), "   u\n"));
}

test "a backend with no key stored, or no address, is not asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A backend billy knows is asked for its key rather than the search going out without one.
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .search = .{ .providers = &.{.tavily} },
    });
    try run(.{ .query = "zig" }, tool_set, &out.writer);
    try std.testing.expectEqualStrings(
        "error: no key is stored for a search backend; run `billy login` to store one",
        out.written(),
    );
    out.clearRetainingCapacity();

    // SearXNG is the user's own instance, so what it needs is an address.
    const searxng_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .search = .{ .providers = &.{.searxng} },
    });
    try run(.{ .query = "zig" }, searxng_set, &out.writer);
    try std.testing.expectEqualStrings(
        "error: the searxng backend has no address; set tools.web_search.searxng.url",
        out.written(),
    );
}

test "a search with no backend named says one is not configured" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // An empty set is a configuration that names no backend: nothing was tried, so saying that
    // every backend failed and was set aside would be a lie.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
    try run(.{ .query = "zig lang" }, tool_set, &out.writer);
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

    const search: Search = .{ .query = "zig lang" };
    const backends: []const web.Backend = &.{
        .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
        .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, .cwd(), gpa, &http_client, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .search = .{ .max_results = 3 },
        .health = &health,
    });
    try search.ask(tool_set, backends, &out.writer);

    try std.testing.expectEqual(@as(usize, 0), mock.served);
    try std.testing.expectEqualStrings(
        "error: every search backend is set aside after failing; " ++
            "add another to tools.web_search.providers, or wait",
        out.written(),
    );
}
