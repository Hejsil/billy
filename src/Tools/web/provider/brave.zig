//! Brave: a search, sent as a GET with the query in the url.

const std = @import("std");
const transport = @import("../../web.zig");
const outcome = @import("../Outcome.zig");
const Search = @import("../Search.zig");
const Mock = @import("../../../Mock.zig");

/// One Brave search, sent as a GET with the query in the url. Brave wants its
/// key in `x-subscription-token`, not an auth header, and the reply's results
/// sit under `web`.
pub fn search(
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    api_key: []const u8,
    endpoint: []const u8,
    query: []const u8,
    max_results: usize,
) !outcome.Value {
    const url = try transport.queryUrl(gpa, endpoint, query, "&count={d}", .{max_results});
    defer gpa.free(url);

    const text = switch (try transport.request(gpa, http, .GET, url, null, &.{
        .{ .name = "x-subscription-token", .value = api_key },
        .{ .name = "accept", .value = "application/json" },
    }, "search")) {
        .text => |text| text,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer gpa.free(text);

    var parsed = std.json.parseFromSlice(Response, gpa, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("search: cannot read the reply: {s}", .{@errorName(err)});
        return error.SearchFailed;
    };
    defer parsed.deinit();

    const mapped = try Search.Result.mapped(gpa, parsed.value.web.results, "description");
    defer gpa.free(mapped);

    return .{ .text = try Search.Result.renderAlloc(gpa, mapped) };
}

/// Brave's own address.
pub const search_endpoint = "https://api.search.brave.com/res/v1/web/search";

/// The part of a Brave search response billy uses. The results sit under `web`,
/// which a query that matched nothing leaves out, so it defaults to none.
const Response = struct {
    web: Web = .{},

    const Web = struct {
        results: []const Result = &.{},
    };
};

/// One Brave result: its snippet is the `description` field.
const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
};

test "a brave search sends the query in the url and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"web\":{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"description\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\"}]}}";
    var mock = try Mock.start("/res/v1/web/search", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const value = try search(gpa, &http, "secret", mock.url, "zig lang", 3);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The query is a GET, so nothing was posted; the key went out in Brave's own
    // header, and the reply rendered as the list the model reads.
    try std.testing.expectEqualStrings("", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("secret", mock.header("x-subscription-token").?);
    try std.testing.expectEqualStrings("application/json", mock.header("accept").?);
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        value.text,
    );
}

test "a query is percent-encoded into a url" {
    const gpa = std.testing.allocator;
    // A space, `&`, `/` and a non-ASCII character are all part of the query
    // value, not the url around it.
    const url = try transport.queryUrl(gpa, "https://x/search", "a b&c/dé", "&count={d}", .{3});
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://x/search?q=a%20b%26c%2fd%c3%a9&count=3", url);
}
