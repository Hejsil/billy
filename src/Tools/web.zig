//! The web tools, and the HTTP plumbing every provider they use shares.

const std = @import("std");

const brave = @import("web/provider/brave.zig");
const exa = @import("web/provider/exa.zig");
const Health = @import("../Health.zig");
const http = @import("../http.zig");
const searxng = @import("web/provider/searxng.zig");
const tavily = @import("web/provider/tavily.zig");

pub const Fetch = @import("web/Fetch.zig");
pub const Search = @import("web/Search.zig");

pub const Answer = union(enum) {
    text: []const u8,
    retry_after_ms: i64,
};

pub const Provider = enum {
    tavily,
    exa,
    brave,
    searxng,
    raw,

    pub fn descriptor(provider: Provider) *const Descriptor {
        return &table[@backingInt(provider)];
    }

    pub fn searches(provider: Provider) bool {
        return provider.descriptor().search != null;
    }

    pub fn fetches(provider: Provider) bool {
        return provider.descriptor().fetch != null;
    }

    pub fn service(provider: Provider) ?[]const u8 {
        return provider.descriptor().service;
    }
};

/// How a provider is asked: the address billy knows it by, the header its key goes in, and what the
/// two web tools ask it.
pub const Descriptor = struct {
    provider: Provider,
    service: ?[]const u8 = null,
    search_endpoint: ?[]const u8 = null,
    fetch_endpoint: ?[]const u8 = null,
    auth: Auth = .none,
    accept_json: bool = false,
    search: ?SearchSpec = null,
    fetch: ?FetchSpec = null,
};

pub const Auth = enum { none, bearer, x_api_key, x_subscription_token };

/// What a search's GET carries after the query it was given: Brave takes a result count; SearXNG
/// wants `format=json` and takes no count.
pub const QueryTail = enum { count, format_json };

pub const SearchSpec = struct {
    configured_path: []const u8 = "",
    request: union(enum) {
        get: QueryTail,
        post: *const fn (gpa: std.mem.Allocator, query: []const u8, max_results: usize) anyerror![]const u8,
    },
    render: *const fn (gpa: std.mem.Allocator, reply: []const u8, max_results: usize) anyerror![]const u8,
};

pub const FetchSpec = struct {
    configured_path: []const u8 = "",
    own_url: bool = false,
    request: union(enum) {
        get,
        post: *const fn (gpa: std.mem.Allocator, url: []const u8) anyerror![]const u8,
    },
    render: ?*const fn (gpa: std.mem.Allocator, reply: []const u8) anyerror![]const u8 = null,
};

const table = [_]Descriptor{
    .{
        .provider = .tavily,
        .service = "tavily",
        .search_endpoint = "https://api.tavily.com/search",
        .fetch_endpoint = "https://api.tavily.com/extract",
        .auth = .bearer,
        .search = .{
            .request = .{ .post = tavily.searchBody },
            .render = tavily.renderSearch,
        },
        .fetch = .{
            .request = .{ .post = tavily.fetchBody },
            .render = tavily.renderFetch,
        },
    },
    .{
        .provider = .exa,
        .service = "exa",
        .search_endpoint = "https://api.exa.ai/search",
        .fetch_endpoint = "https://api.exa.ai/contents",
        .auth = .x_api_key,
        .search = .{
            .request = .{ .post = exa.searchBody },
            .render = exa.renderSearch,
        },
        .fetch = .{
            .request = .{ .post = exa.fetchBody },
            .render = exa.renderFetch,
        },
    },
    .{
        .provider = .brave,
        .service = "brave",
        .search_endpoint = "https://api.search.brave.com/res/v1/web/search",
        .auth = .x_subscription_token,
        .accept_json = true,
        .search = .{
            .request = .{ .get = .count },
            .render = brave.renderSearch,
        },
    },
    .{
        .provider = .searxng,
        .search = .{
            .configured_path = "/search",
            .request = .{ .get = .format_json },
            .render = searxng.renderSearch,
        },
    },
    .{
        .provider = .raw,
        .fetch = .{
            .own_url = true,
            .request = .get,
        },
    },
};

comptime {
    for (table, 0..) |descriptor, i| {
        if (@backingInt(descriptor.provider) != i)
            @compileError("the provider table must follow the order of Provider");
    }
}

/// The address one call goes to: the backend's own when a test names one, or the provider's, and a
/// configured instance's path under it.
pub fn address(gpa: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return gpa.dupe(u8, base);
    return gpa.print("{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}

/// Sends one request to `descriptor`, with its key in the header the provider expects and JSON
/// asked for where it needs telling.
pub fn providerRequest(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    what: []const u8,
    descriptor: *const Descriptor,
    api_key: []const u8,
    method: std.http.Method,
    location: []const u8,
    payload: ?[]const u8,
) !Answer {
    var token: ?[]const u8 = null;
    defer if (token) |value| gpa.free(value);

    var headers: [2]std.http.Header = undefined;
    var count: usize = 0;
    switch (descriptor.auth) {
        .none => {},
        .bearer => {
            token = try gpa.print("Bearer {s}", .{api_key});
            headers[count] = .{ .name = "authorization", .value = token.? };
            count += 1;
        },
        .x_api_key => {
            headers[count] = .{ .name = "x-api-key", .value = api_key };
            count += 1;
        },
        .x_subscription_token => {
            headers[count] = .{ .name = "x-subscription-token", .value = api_key };
            count += 1;
        },
    }
    if (descriptor.accept_json) {
        headers[count] = .{ .name = "accept", .value = "application/json" };
        count += 1;
    }
    return request(gpa, http_client, method, location, payload, headers[0..count], what);
}

/// Does one request and returns its body, owned by `gpa`, or the wait the provider asked for.
pub fn request(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    method: std.http.Method,
    location: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    what: []const u8,
) !Answer {
    var req = try http_client.request(method, try std.Uri.parse(location), .{
        .headers = .{
            .content_type = if (payload) |_| .{ .override = "application/json" } else .default,
        },
        .extra_headers = headers,
    });
    defer req.deinit();

    if (payload) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var sending = try req.sendBodyUnflushed(&.{});
        try sending.writer.writeAll(body);
        try sending.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const retry_after_ms = Health.retryAfterMs(response.head.bytes);

    if (response.head.status.class() != .success) {
        // A provider failing is a warning rather than an error: with more than one configured the
        // caller tries the next, and the failure is reported to the model as the result of the
        // call.
        std.log.warn("{s}: HTTP {d}", .{ what, @backingInt(response.head.status) });
        const discarded = response.reader(&.{});
        _ = discarded.discardRemaining() catch {
            // What is left of a response being thrown away is thrown away too.
        };
        if (retry_after_ms) |ms| return .{ .retry_after_ms = @intCast(@min(ms, max_retry_after_ms)) };
        return error.RequestFailed;
    }

    return .{ .text = try http.readBody(gpa, &response) };
}

/// What `requestJson` came back with: the reply parsed as `T`, or the wait the provider asked for.
pub fn JsonAnswer(T: type) type {
    return union(enum) {
        parsed: std.json.Parsed(T),
        retry_after_ms: i64,
    };
}

/// As `request`, for a provider whose reply is JSON of type `T`.
pub fn requestJson(
    T: type,
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    method: std.http.Method,
    location: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    what: []const u8,
) !JsonAnswer(T) {
    const text = switch (try request(gpa, http_client, method, location, payload, headers, what)) {
        .text => |text| text,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(T, gpa, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("{s}: cannot read the reply: {s}", .{ what, @errorName(err) });
        return error.BadReply;
    };
    return .{ .parsed = parsed };
}

/// A url carrying `query` as the `q` parameter, followed by `tail`, which is whatever else the
/// provider wants such as a result count.
pub fn queryUrl(
    gpa: std.mem.Allocator,
    base: []const u8,
    query: []const u8,
    comptime tail: []const u8,
    tail_args: anytype,
) ![]const u8 {
    var url: std.Io.Writer.Allocating = .init(gpa);
    defer url.deinit();
    try url.writer.print("{s}?q=", .{base});
    for (query) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try url.writer.writeByte(c),
        else => try url.writer.print("%{x:0>2}", .{c}),
    };
    try url.writer.print(tail, tail_args);
    return url.toOwnedSlice();
}

const max_retry_after_ms: u64 = @intCast(Health.max_wait_ms);

const Mock = @import("../Mock.zig");

test "a query is percent-encoded into a url" {
    const gpa = std.testing.allocator;
    const url = try queryUrl(gpa, "https://x/search", "a b&c/dé", "&count={d}", .{3});
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://x/search?q=a%20b%26c%2fd%c3%a9&count=3", url);
}

test "the table names the credential and the jobs of each provider" {
    try std.testing.expectEqualStrings("tavily", Provider.tavily.service().?);
    try std.testing.expectEqualStrings("exa", Provider.exa.service().?);
    try std.testing.expectEqualStrings("brave", Provider.brave.service().?);
    try std.testing.expect(Provider.searxng.service() == null);
    try std.testing.expect(Provider.raw.service() == null);

    try std.testing.expect(Provider.tavily.searches());
    try std.testing.expect(Provider.tavily.fetches());
    try std.testing.expect(Provider.exa.searches());
    try std.testing.expect(Provider.exa.fetches());
    try std.testing.expect(Provider.brave.searches());
    try std.testing.expect(!Provider.brave.fetches());
    try std.testing.expect(Provider.searxng.searches());
    try std.testing.expect(!Provider.searxng.fetches());
    try std.testing.expect(!Provider.raw.searches());
    try std.testing.expect(Provider.raw.fetches());
}

test "a JSON reply is parsed, and one of another shape is a bad reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Shape = struct { a: u32 };

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var good = try Mock.start("/x", 1, Mock.fixed("{\"a\":7,\"extra\":1}"));
    defer good.deinit();
    try good.serve();
    const answer = try requestJson(Shape, gpa, &http_client, .GET, good.url, null, &.{}, "search");
    defer answer.parsed.deinit();
    try good.await();
    try std.testing.expectEqual(7, answer.parsed.value.a);

    var bad = try Mock.start("/x", 1, Mock.fixed("not json"));
    defer bad.deinit();
    try bad.serve();
    try std.testing.expectError(
        error.BadReply,
        requestJson(Shape, gpa, &http_client, .GET, bad.url, null, &.{}, "search"),
    );
    try bad.await();
}
