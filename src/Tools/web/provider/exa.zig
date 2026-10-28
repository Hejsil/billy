//! Exa's request bodies and replies: a search and a contents call, both posted as JSON.

const std = @import("std");

const SearchResult = @import("../Search/Result.zig");

/// The body an Exa search is posted with.
pub fn searchBody(gpa: std.mem.Allocator, query: []const u8, max_results: usize) ![]const u8 {
    return std.json.Stringify.valueAlloc(gpa, Request{
        .query = query,
        .numResults = max_results,
        .contents = .{ .text = .{ .maxCharacters = SearchResult.snippet_len } },
    }, .{ .emit_null_optional_fields = false });
}

/// An Exa search reply as the numbered list the model reads.
pub fn renderSearch(gpa: std.mem.Allocator, reply: []const u8, _: usize) ![]const u8 {
    const parsed = try parse(Response, gpa, reply);
    defer parsed.deinit();
    return SearchResult.renderMapped(gpa, parsed.value.results, "text");
}

/// The body an Exa contents call is posted with.
pub fn fetchBody(gpa: std.mem.Allocator, url: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(gpa, ContentsRequest{
        .urls = &.{url},
    }, .{ .emit_null_optional_fields = false });
}

/// An Exa contents reply as the url's text.
pub fn renderFetch(gpa: std.mem.Allocator, reply: []const u8) ![]const u8 {
    const parsed = try parse(ContentsResponse, gpa, reply);
    defer parsed.deinit();

    if (parsed.value.results.len == 0 or parsed.value.results[0].text.len == 0) return error.UrlUnreadable;
    return gpa.dupe(u8, parsed.value.results[0].text);
}

fn parse(T: type, gpa: std.mem.Allocator, reply: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, reply, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("exa: cannot read the reply: {s}", .{@errorName(err)});
        return error.BadReply;
    };
}

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

const Response = struct {
    results: []const Result = &.{},
};

const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    text: []const u8 = "",
};

const ContentsRequest = struct {
    urls: []const []const u8,
};

const ContentsResponse = struct {
    results: []const Content = &.{},
};

const Content = struct {
    url: []const u8 = "",
    text: []const u8 = "",
};

test "an exa search reply becomes the numbered list" {
    const gpa = std.testing.allocator;
    const text = try renderSearch(
        gpa,
        \\{"results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","text":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","text":""}]}
    ,
        3,
    );
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "an exa contents reply is the url's text" {
    const gpa = std.testing.allocator;
    const text = try renderFetch(
        gpa,
        "{\"results\":[{\"url\":\"https://ziglang.org\",\"text\":\"# Zig\\n\\nA language.\"}]}",
    );
    defer gpa.free(text);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}

test "an exa url it read no text for is not a failure of the backend" {
    try std.testing.expectError(
        error.UrlUnreadable,
        renderFetch(std.testing.allocator, "{\"results\":[{\"url\":\"https://nope.invalid\",\"text\":\"\"}]}"),
    );
}
