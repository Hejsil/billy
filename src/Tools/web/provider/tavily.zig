//! Tavily's request bodies and replies: a search and an extraction, both posted as JSON.

const std = @import("std");

const SearchResult = @import("../Search/Result.zig");

/// The body a Tavily search is posted with.
pub fn searchBody(gpa: std.mem.Allocator, query: []const u8, max_results: usize) ![]const u8 {
    return try std.json.Stringify.valueAlloc(gpa, Request{
        .query = query,
        .max_results = max_results,
    }, .{ .emit_null_optional_fields = false });
}

/// A Tavily search reply as the numbered list the model reads.
pub fn renderSearch(gpa: std.mem.Allocator, reply: []const u8, _: usize) ![]const u8 {
    const parsed = try parse(Response, gpa, reply);
    defer parsed.deinit();
    return SearchResult.renderMapped(gpa, parsed.value.results, "content");
}

/// The body a Tavily extraction is posted with.
pub fn fetchBody(gpa: std.mem.Allocator, url: []const u8) ![]const u8 {
    return try std.json.Stringify.valueAlloc(gpa, ExtractRequest{
        .urls = &.{url},
    }, .{ .emit_null_optional_fields = false });
}

/// A Tavily extraction reply as the url's text.
pub fn renderFetch(gpa: std.mem.Allocator, reply: []const u8) ![]const u8 {
    const parsed = try parse(ExtractResponse, gpa, reply);
    defer parsed.deinit();

    if (parsed.value.results.len == 0) {
        for (parsed.value.failed_results) |failed| {
            std.log.warn("fetch: {s}: {s}", .{ failed.url, failed.@"error" });
        }
        return error.UrlUnreadable;
    }
    return gpa.dupe(u8, parsed.value.results[0].raw_content);
}

fn parse(T: type, gpa: std.mem.Allocator, reply: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, reply, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("tavily: cannot read the reply: {t}", .{err});
        return error.BadReply;
    };
}

const Request = struct {
    query: []const u8,
    max_results: usize,
    search_depth: []const u8 = "basic",
    include_answer: bool = false,
};

const Response = struct {
    results: []const Result = &.{},
};

const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

const ExtractRequest = struct {
    urls: []const []const u8,
};

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

fn expectSearch(expected: []const u8, reply: []const u8) !void {
    const gpa = std.testing.allocator;
    const text = try renderSearch(gpa, reply, 3);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "a tavily search reply becomes the numbered list" {
    try expectSearch("1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
        "2. Docs\n   https://ziglang.org/documentation\n",
        \\{"query":"zig lang","results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","content":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","content":""}]}
    );
}

test "a tavily extraction reply is the url's content" {
    const gpa = std.testing.allocator;
    const text = try renderFetch(
        gpa,
        "{\"results\":[{\"url\":\"https://ziglang.org\",\"raw_content\":\"# Zig\\n\\nA language.\"}],\"failed_results\":[]}",
    );
    defer gpa.free(text);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}

test "a url tavily could not read is not a failure of the backend" {
    try std.testing.expectError(
        error.UrlUnreadable,
        renderFetch(std.testing.allocator, "{\"results\":[],\"failed_results\":[{\"url\":\"https://nope.invalid\",\"error\":\"not found\"}]}"),
    );
}
