//! Brave's reply: a search sent as a GET with the query in the url.

const std = @import("std");

const SearchResult = @import("../Search/Result.zig");

/// A Brave search reply as the numbered list the model reads.
pub fn renderSearch(gpa: std.mem.Allocator, reply: []const u8, _: usize) ![]const u8 {
    const parsed = std.json.parseFromSlice(Response, gpa, reply, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("brave: cannot read the reply: {t}", .{err});
        return error.BadReply;
    };
    defer parsed.deinit();
    return SearchResult.renderMapped(gpa, parsed.value.web.results, "description");
}

const Response = struct {
    web: Web = .{},

    const Web = struct {
        results: []const Result = &.{},
    };
};

const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
};

test "a brave search reply becomes the numbered list" {
    const gpa = std.testing.allocator;
    const text = try renderSearch(
        gpa,
        "{\"web\":{\"results\":[" ++
            "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"description\":\"A language.\"}," ++
            "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\"}]}}",
        3,
    );
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}
