//! SearXNG's reply: a search against the user's own instance.

const std = @import("std");

const reply = @import("reply.zig");
const SearchResult = @import("../Search/Result.zig");

/// A SearXNG search reply as the numbered list the model reads.
pub fn renderSearch(gpa: std.mem.Allocator, bytes: []const u8, max_results: usize) ![]const u8 {
    const parsed = try reply.parse("searxng", Response, gpa, bytes);
    defer parsed.deinit();

    const capped = parsed.value.results[0..@min(parsed.value.results.len, max_results)];
    return SearchResult.renderMapped(gpa, capped, "content");
}

const Response = struct {
    results: []const Result = &.{},
};

const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

test "a searxng reply becomes the numbered list, capped at what was asked" {
    const gpa = std.testing.allocator;
    const bytes = "{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\",\"content\":\"\"}]}";

    const text = try renderSearch(gpa, bytes, 1);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", text);
}
