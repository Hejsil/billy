//! The web tools, and the HTTP plumbing every provider they use shares.

const std = @import("std");
const Health = @import("../Health.zig");
const http = @import("../http.zig");
const tavily = @import("web/provider/tavily.zig");
const exa = @import("web/provider/exa.zig");
const brave = @import("web/provider/brave.zig");
const searxng = @import("web/provider/searxng.zig");

pub const Search = @import("web/Search.zig");
pub const Fetch = @import("web/Fetch.zig");

/// What a call to a provider came back with: its text, or the wait the provider
/// asked for before it is asked again. The text is the response body for
/// `request`, and what the model reads for a provider's `search` or `fetch`.
pub const Answer = union(enum) {
    text: []const u8,
    retry_after_ms: i64,
};

/// The services billy can call for a search or a page. One list for both tools:
/// a service that answers a search may also read a url, and the configuration,
/// the credentials, the waits and the tools all name it the same way.
pub const Provider = enum {
    tavily,
    exa,
    brave,
    searxng,
    raw,

    /// How this provider is asked.
    pub fn descriptor(provider: Provider) *const Descriptor {
        return &table[@backingInt(provider)];
    }

    /// Whether it can answer a search, and so may be named under
    /// `tools.web_search.providers`.
    pub fn searches(provider: Provider) bool {
        return provider.descriptor().search != null;
    }

    /// Whether it can read a url, and so may be named under
    /// `tools.web_fetch.providers`.
    pub fn fetches(provider: Provider) bool {
        return provider.descriptor().fetch != null;
    }

    /// The credential the key is stored under, or null when the provider asks
    /// none: SearXNG is the user's own instance and `raw` reads the url itself.
    pub fn service(provider: Provider) ?[]const u8 {
        return provider.descriptor().service;
    }
};

/// How a provider is asked: the address billy knows it by, the header its key
/// goes in, and what the two web tools ask it. A provider file keeps the request
/// body and reply type that really are its own; everything the five share is
/// here.
pub const Descriptor = struct {
    provider: Provider,
    /// The credential the key is stored under, or null for one that asks no
    /// service.
    service: ?[]const u8 = null,
    /// The address of its search and of its extraction; null when the
    /// configuration names the instance, or the call names the url.
    search_endpoint: ?[]const u8 = null,
    fetch_endpoint: ?[]const u8 = null,
    auth: Auth = .none,
    /// Whether the request asks for JSON in `accept`, which Brave needs.
    accept_json: bool = false,
    search: ?SearchSpec = null,
    fetch: ?FetchSpec = null,
};

/// Where a provider's key goes, which is the one thing its services differ on.
pub const Auth = enum { none, bearer, x_api_key, x_subscription_token };

/// What a search's GET carries after the query it was given: Brave takes a result
/// count; SearXNG wants `format=json` and takes no count. It is the tail of the
/// query string, appended to the `q=` the search wrote, so it is not a query of
/// its own.
pub const QueryTail = enum { count, format_json };

/// One web search a provider answers.
pub const SearchSpec = struct {
    /// Appended to an address this table does not give: SearXNG's, whose
    /// instance the configuration names and which answers under a known path on
    /// it. A provider whose address the table gives is reached at that address
    /// whole, whoever named it.
    configured_path: []const u8 = "",
    request: union(enum) {
        get: QueryTail,
        /// A POST, with the body this builds.
        post: *const fn (gpa: std.mem.Allocator, query: []const u8, max_results: usize) anyerror![]const u8,
    },
    /// Turns the reply's bytes into the text the model reads.
    render: *const fn (gpa: std.mem.Allocator, reply: []const u8, max_results: usize) anyerror![]const u8,
};

/// One page a provider reads.
pub const FetchSpec = struct {
    /// As `SearchSpec.configured_path`.
    configured_path: []const u8 = "",
    /// The call's url is the location, rather than the service's address.
    own_url: bool = false,
    request: union(enum) {
        get,
        /// A POST, with the body this builds.
        post: *const fn (gpa: std.mem.Allocator, url: []const u8) anyerror![]const u8,
    },
    /// Null returns the reply as it is, which is what `raw` does.
    render: ?*const fn (gpa: std.mem.Allocator, reply: []const u8) anyerror![]const u8 = null,
};

/// The five providers, in the order of `Provider`, so the enum's value indexes
/// the row.
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
    // The row of a provider is found by its enum value, so the table's order is
    // part of the lookup. A row out of place would reach the wrong provider's
    // address and key header.
    for (table, 0..) |descriptor, i| {
        if (@backingInt(descriptor.provider) != i)
            @compileError("the provider table must follow the order of Provider");
    }
}

/// The address one call goes to: the backend's own when a test names one, or
/// the provider's, and a configured instance's path under it. The result is
/// owned by `gpa`, so the caller frees it whatever else it does.
pub fn address(gpa: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return gpa.dupe(u8, base);
    return gpa.print("{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}

/// Sends one request to `descriptor`, with its key in the header the provider
/// expects and JSON asked for where it needs telling.
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
    // The bearer token is the one header whose value has to be built.
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

/// Does one request and returns its body, owned by `gpa`, or the wait the
/// provider asked for.
///
/// This is `std.http.Client.fetch` done by hand, because `fetch` throws the
/// response headers away and a `Retry-After` is one of them: what the provider
/// asked to be waited is read here and handed back rather than kept beside the
/// client. The body is read the way `fetch` reads it, so a compressed reply
/// still parses.
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

    // What the provider asked to be waited, when it said, is the answer: a
    // provider that is rate-limited is not one that is broken.
    const retry_after_ms = Health.retryAfterMs(response.head.bytes);

    if (response.head.status.class() != .success) {
        // A provider failing is a warning rather than an error: with more than
        // one configured the caller tries the next, and the failure is reported
        // to the model as the result of the call.
        std.log.warn("{s}: HTTP {d}", .{ what, @backingInt(response.head.status) });
        const discarded = response.reader(&.{});
        _ = discarded.discardRemaining() catch {
            // The answer this response carried is being thrown away, so what is
            // left of it is too.
        };
        if (retry_after_ms) |ms| return .{ .retry_after_ms = @intCast(@min(ms, max_retry_after_ms)) };
        return error.RequestFailed;
    }

    return .{ .text = try http.readBody(gpa, &response) };
}

/// What `requestJson` came back with: the reply parsed as `T`, or the wait the
/// provider asked for.
pub fn JsonAnswer(T: type) type {
    return union(enum) {
        parsed: std.json.Parsed(T),
        retry_after_ms: i64,
    };
}

/// As `request`, for a provider whose reply is JSON of type `T`. The parsed reply
/// owns its strings. A reply that does not parse is `error.BadReply`.
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

/// A url carrying `query` as the `q` parameter, followed by `tail`, which is
/// whatever else the provider wants such as a result count. The query is
/// percent-encoded, so a space or an `&` in it is part of the value rather than
/// breaking the url.
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

/// The longest a `Retry-After` is honored, so a provider cannot set billy aside
/// for longer than the waits ever reach anyway.
const max_retry_after_ms: u64 = @intCast(Health.max_wait_ms);

const Mock = @import("../Mock.zig");

test "a query is percent-encoded into a url" {
    const gpa = std.testing.allocator;
    // A space, `&`, `/` and a non-ASCII character are all part of the query
    // value, not the url around it.
    const url = try queryUrl(gpa, "https://x/search", "a b&c/dé", "&count={d}", .{3});
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://x/search?q=a%20b%26c%2fd%c3%a9&count=3", url);
}

test "the table names the credential and the jobs of each provider" {
    // The web tools share one list of providers, so the table is what says which
    // name belongs to which tool and which credential it is stored under.
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
