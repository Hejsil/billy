//! SearXNG: a search against the user's own instance.

const std = @import("std");
const transport = @import("../../web.zig");
const Search = @import("../Search.zig");
const Mock = @import("../../../Mock.zig");

/// One SearXNG search, sent as a GET to the instance the configuration names.
/// SearXNG needs no key, and answers with the same shape of results whatever
/// engines it searched. It takes no result count, so the cap is applied here.
pub fn search(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    base: []const u8,
    query: []const u8,
    max_results: usize,
) !transport.Answer {
    const endpoint = try std.fmt.allocPrint(gpa, "{s}/search", .{
        std.mem.trimEnd(u8, base, "/"),
    });
    defer gpa.free(endpoint);

    const url = try transport.queryUrl(gpa, endpoint, query, "&format=json", .{});
    defer gpa.free(url);

    const reply = switch (try transport.requestJson(Response, gpa, http_client, .GET, url, null, &.{}, "search")) {
        .parsed => |parsed| parsed,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer reply.deinit();

    const capped = reply.value.results[0..@min(reply.value.results.len, max_results)];
    return .{ .text = try Search.Result.renderMapped(gpa, capped, "content") };
}

/// The part of a SearXNG response billy uses, which is the same from every engine
/// it searched.
const Response = struct {
    results: []const Result = &.{},
};

/// One SearXNG result: its snippet is the `content` field.
const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

test "a searxng search sends the query to the instance, and caps the results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\",\"content\":\"\"}]}";
    // The instance is the mock's base, which SearXNG's `/search` is added to.
    var mock = try Mock.start("", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // The cap is applied here, since SearXNG takes no result count: only the
    // first of the two results is rendered.
    const value = try search(gpa, &http_client, mock.url, "zig lang", 1);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The query is a GET with no key: SearXNG is the user's own instance.
    try std.testing.expectEqualStrings("", mock.bodies.items[0]);
    try std.testing.expect(mock.header("authorization") == null);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", value.text);
}
