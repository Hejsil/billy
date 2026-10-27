//! SearXNG's reply: a search against the user's own instance. The instance, the
//! path and the method are the table's in `web.zig`; the reply shape and the cap
//! stay here.

const std = @import("std");

const SearchResult = @import("../Search/Result.zig");

/// A SearXNG search reply as the numbered list the model reads. SearXNG takes no
/// result count, so the cap is applied here.
pub fn renderSearch(gpa: std.mem.Allocator, reply: []const u8, max_results: usize) ![]const u8 {
    const parsed = std.json.parseFromSlice(Response, gpa, reply, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("searxng: cannot read the reply: {s}", .{@errorName(err)});
        return error.BadReply;
    };
    defer parsed.deinit();

    const capped = parsed.value.results[0..@min(parsed.value.results.len, max_results)];
    return SearchResult.renderMapped(gpa, capped, "content");
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

test "a searxng reply becomes the numbered list, capped at what was asked" {
    const gpa = std.testing.allocator;
    const reply = "{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\",\"content\":\"\"}]}";

    // SearXNG takes no result count, so the cap is applied here: only the first
    // of the two results is rendered.
    const text = try renderSearch(gpa, reply, 1);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", text);
}
