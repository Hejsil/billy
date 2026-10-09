//! Exa: a search and a contents call, both posted as JSON.

const std = @import("std");
const transport = @import("../../web.zig");
const Search = @import("../Search.zig");
const Mock = @import("../../../Mock.zig");

/// One Exa search, posted to `endpoint`. Exa would return the whole page of each
/// result, so the text is asked for capped: a search is a list of snippets, and
/// a page is what `web_fetch` is for.
pub fn search(
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    api_key: []const u8,
    endpoint: []const u8,
    query: []const u8,
    max_results: usize,
) !transport.Answer {
    const body = try std.json.Stringify.valueAlloc(gpa, Request{
        .query = query,
        .numResults = max_results,
        .contents = .{ .text = .{ .maxCharacters = Search.Result.snippet_len } },
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const reply = switch (try transport.requestJson(Response, gpa, http, .POST, endpoint, body, &.{
        .{ .name = "x-api-key", .value = api_key },
    }, "search")) {
        .parsed => |parsed| parsed,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer reply.deinit();

    return .{ .text = try Search.Result.renderMapped(gpa, reply.value.results, "text") };
}

/// One Exa contents call, posted to `endpoint`. A url the backend could not read
/// comes back as `error.UrlUnreadable`, which is not a failure of the backend.
pub fn fetch(
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    api_key: []const u8,
    endpoint: []const u8,
    url: []const u8,
) !transport.Answer {
    const body = try std.json.Stringify.valueAlloc(gpa, ContentsRequest{
        .urls = &.{url},
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const reply = switch (try transport.requestJson(ContentsResponse, gpa, http, .POST, endpoint, body, &.{
        .{ .name = "x-api-key", .value = api_key },
    }, "fetch")) {
        .parsed => |parsed| parsed,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer reply.deinit();

    if (reply.value.results.len == 0 or reply.value.results[0].text.len == 0) return error.UrlUnreadable;
    return .{ .text = try gpa.dupe(u8, reply.value.results[0].text) };
}

/// Exa's own address for each kind of call.
pub const search_endpoint = "https://api.exa.ai/search";
pub const fetch_endpoint = "https://api.exa.ai/contents";

/// The body an Exa search is posted with. The text it returns is capped, so a
/// result is a snippet rather than the whole page.
const Request = struct {
    query: []const u8,
    numResults: usize,
    contents: Contents,

    const Contents = struct {
        text: Text,
    };

    const Text = struct {
        maxCharacters: usize,
    };
};

/// The part of an Exa search response billy uses.
const Response = struct {
    results: []const Result = &.{},
};

/// One Exa result: its snippet is the `text` field.
const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    text: []const u8 = "",
};

/// The body an Exa contents call is posted with.
const ContentsRequest = struct {
    urls: []const []const u8,
};

/// The part of an Exa contents response billy uses: the text of each url.
const ContentsResponse = struct {
    results: []const Content = &.{},
};

const Content = struct {
    url: []const u8 = "",
    text: []const u8 = "",
};

test "an exa search posts the query and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply =
        \\{"results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","text":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","text":""}]}
    ;
    var mock = try Mock.start("/search", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const value = try search(gpa, &http, "secret", mock.url, "zig lang", 3);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The query, the count and the capped text went out as Exa's body (its field
    // names are camelCase), the key as `x-api-key`, and the reply became the
    // numbered list the model reads.
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig lang\",\"numResults\":3,\"contents\":{\"text\":{\"maxCharacters\":500}}}",
        mock.bodies.items[0],
    );
    try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        value.text,
    );
}

test "an exa contents call posts the url and reads its text back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[{\"url\":\"https://ziglang.org\",\"text\":\"# Zig\\n\\nA language.\"}]}";
    var mock = try Mock.start("/contents", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const value = try fetch(gpa, &http, "secret", mock.url, "https://ziglang.org");
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", value.text);
}

test "an exa url it read no text for is not a failure of the backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The call answered, and its result carries no text, so the url is one this
    // backend cannot read.
    const reply = "{\"results\":[{\"url\":\"https://nope.invalid\",\"text\":\"\"}]}";
    var mock = try Mock.start("/contents", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    try std.testing.expectError(
        error.UrlUnreadable,
        fetch(gpa, &http, "secret", mock.url, "https://nope.invalid"),
    );
    try mock.group.await(io);
    if (mock.err) |err| return err;
}
