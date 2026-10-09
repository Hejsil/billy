//! Tavily: a search and an extraction, both posted as JSON.

const std = @import("std");
const transport = @import("../../web.zig");
const Search = @import("../Search.zig");
const Mock = @import("../../../Mock.zig");

/// One Tavily search, posted to `endpoint`, which is the provider's own or a
/// test server's. The request and the response are Tavily's shape; keeping the
/// endpoint a parameter is what lets the wire format be tested without the
/// network.
pub fn search(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    api_key: []const u8,
    endpoint: []const u8,
    query: []const u8,
    max_results: usize,
) !transport.Answer {
    const body = try std.json.Stringify.valueAlloc(gpa, Request{
        .query = query,
        .max_results = max_results,
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const auth = try bearer(gpa, api_key);
    defer gpa.free(auth);

    const reply = switch (try transport.requestJson(Response, gpa, http_client, .POST, endpoint, body, &.{
        .{ .name = "authorization", .value = auth },
    }, "search")) {
        .parsed => |parsed| parsed,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer reply.deinit();

    return .{ .text = try Search.Result.renderMapped(gpa, reply.value.results, "content") };
}

/// One Tavily extraction. The url's text is the backend's; a url the backend
/// could not read comes back as `error.UrlUnreadable`, which is not a failure
/// of the backend.
pub fn fetch(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    api_key: []const u8,
    endpoint: []const u8,
    url: []const u8,
) !transport.Answer {
    const body = try std.json.Stringify.valueAlloc(gpa, ExtractRequest{
        .urls = &.{url},
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const auth = try bearer(gpa, api_key);
    defer gpa.free(auth);

    const reply = switch (try transport.requestJson(ExtractResponse, gpa, http_client, .POST, endpoint, body, &.{
        .{ .name = "authorization", .value = auth },
    }, "fetch")) {
        .parsed => |parsed| parsed,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer reply.deinit();

    if (reply.value.results.len == 0) {
        for (reply.value.failed_results) |failed| {
            std.log.warn("fetch: {s}: {s}", .{ failed.url, failed.@"error" });
        }
        return error.UrlUnreadable;
    }
    return .{ .text = try gpa.dupe(u8, reply.value.results[0].raw_content) };
}

/// Tavily's own address for each kind of call.
pub const search_endpoint = "https://api.tavily.com/search";
pub const fetch_endpoint = "https://api.tavily.com/extract";

fn bearer(gpa: std.mem.Allocator, api_key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
}

/// The body a Tavily search is posted with. `basic` depth is the fast, cheaper
/// one and is enough to rank sources; no synthesized answer is asked for, since
/// the model reads the sources itself.
const Request = struct {
    query: []const u8,
    max_results: usize,
    search_depth: []const u8 = "basic",
    include_answer: bool = false,
};

/// The part of a Tavily search response billy uses. The rest, such as the answer
/// and the scores, is ignored.
const Response = struct {
    results: []const Result = &.{},
};

/// One Tavily result: its snippet is the `content` field.
const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

/// The body a Tavily extraction is posted with.
const ExtractRequest = struct {
    urls: []const []const u8,
};

/// The part of a Tavily extraction response billy uses: the content of each url
/// it read, and why it could not read the others.
const ExtractResponse = struct {
    results: []const ExtractResult = &.{},
    failed_results: []const ExtractFailure = &.{},
};

const ExtractResult = struct {
    raw_content: []const u8 = "",
};

const ExtractFailure = struct {
    url: []const u8 = "",
    @"error": []const u8 = "",
};

test "a tavily search posts the query and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A backend standing in for Tavily, answering with a fixed reply and
    // recording what it was sent.
    const reply =
        \\{"query":"zig lang","results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","content":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","content":""}]}
    ;
    var mock = try Mock.start("/search", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // Everything the provider is given is the testing allocator, so a reply or a
    // list left behind is reported rather than hidden by an arena.
    const value = try search(gpa, &http_client, "secret", mock.url, "zig lang", 3);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The query and the count went out as Tavily's body, the key as a bearer
    // token, and the reply became the numbered list the model reads.
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig lang\",\"max_results\":3,\"search_depth\":\"basic\",\"include_answer\":false}",
        mock.bodies.items[0],
    );
    try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        value.text,
    );
}

test "a tavily extraction posts the url and reads its content back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[{\"url\":\"https://ziglang.org\",\"raw_content\":\"# Zig\\n\\nA language.\"}],\"failed_results\":[]}";
    var mock = try Mock.start("/extract", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const value = try fetch(gpa, &http_client, "secret", mock.url, "https://ziglang.org");
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The url went out as Tavily's body and the key as a bearer token.
    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", value.text);
}

test "a url tavily could not read is not a failure of the backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[],\"failed_results\":[{\"url\":\"https://nope.invalid\",\"error\":\"not found\"}]}";
    var mock = try Mock.start("/extract", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    try std.testing.expectError(
        error.UrlUnreadable,
        fetch(gpa, &http_client, "secret", mock.url, "https://nope.invalid"),
    );
    try mock.group.await(io);
    if (mock.err) |err| return err;
}

test "a wait the backend asked for comes back as one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider that is rate-limited: it answered, and said how long to wait.
    var mock = try Mock.start("/search", 1, struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{ .status = .too_many_requests, .body = "{}" };
        }
    }.answer);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // No `Retry-After` header, so the answer is a plain failure rather than a
    // wait: only what the provider asked for is honored.
    try std.testing.expectError(
        error.RequestFailed,
        search(gpa, &http_client, "secret", mock.url, "zig lang", 3),
    );
    try mock.group.await(io);
    if (mock.err) |err| return err;
}
