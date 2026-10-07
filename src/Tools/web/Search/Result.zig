//! The results a search came back with: the one shape every provider is mapped
//! into, and the numbered list the model reads them as.

const std = @import("std");

const Result = @This();

title: []const u8 = "",
url: []const u8 = "",
snippet: []const u8 = "",

/// Most results a backend is asked for, whatever the configuration says, so one
/// query cannot be turned into a wall of text.
pub const result_limit = 20;

/// Most characters a result's snippet is asked to hold, so a backend that would
/// return a whole page of text still comes back as a list of results.
pub const snippet_len = 500;

/// Formats results as the numbered list the model reads and the user sees the
/// top of: each result's title, its url, and whatever snippet the backend
/// returned. A query that matched nothing says so, which is not an error.
///
/// The shape is meant to be read back as easily as it is read. Each result is
/// one heading line at the margin -- `N. title` -- and then, indented under it,
/// its url and its snippet, one field to a line. Nothing inside a field can
/// reach the margin, since every field carries the indent and every newline in
/// one is turned into a space, so a line at the margin is always a heading and a
/// blank line always falls between two results. See `parseResults`.
pub fn render(results: []const Result, out: *std.Io.Writer) !void {
    if (results.len == 0)
        return out.writeAll("(no results)");

    for (results, 1..) |result, number| {
        if (number > 1) try out.writeByte('\n');
        try out.print("{d}. ", .{number});
        try writeField(out, result.title);
        try out.writeByte('\n');
        try out.writeAll(indent);
        try writeField(out, result.url);
        try out.writeByte('\n');
        // A result with no snippet is still worth its title and url, so the
        // line is left out rather than written empty.
        if (std.mem.trim(u8, result.snippet, " \t\r\n").len == 0) continue;
        try out.writeAll(indent);
        try writeField(out, result.snippet);
        try out.writeByte('\n');
    }
}

pub fn renderAlloc(gpa: std.mem.Allocator, results: []const Result) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render(results, &out.writer);
    return out.toOwnedSlice();
}

/// The prefix a result's url and snippet are written under, so a line that
/// reaches the margin is the heading of a result and a line under it a field.
const indent = "   ";

/// Writes one field of a result on one line: the surrounding whitespace trimmed
/// and every newline turned into a space, so the field stays on the one line the
/// reading back expects, however the backend wrote it.
fn writeField(out: *std.Io.Writer, text: []const u8) !void {
    for (std.mem.trim(u8, text, " \t\r\n")) |c| {
        try out.writeByte(switch (c) {
            '\n', '\r' => ' ',
            else => c,
        });
    }
}

/// Reads back the results `render` wrote, one at a time. Every value is a slice
/// of the text it reads, so nothing is copied and nothing has to be freed, and a
/// caller that wants them twice simply reads the text again.
///
/// A result begins at a line that reaches the margin -- `N. title` -- and its
/// url and snippet are the next fields under it. A line that does not reach the
/// margin is part of no heading, so it is skipped; that is what makes text that
/// is not a result list, such as `(no results)`, yield nothing rather than
/// something wrong.
/// Reads a list of results back, one at a time.
pub const Reader = struct {
    rest: []const u8,

    pub fn next(self: *Reader) ?Result {
        while (self.rest.len > 0) {
            const line = takeLine(&self.rest);
            const marker = markerLen(line) orelse continue;
            const title = std.mem.trimEnd(u8, line[marker..], " \t\r");
            // The url line is always written; the snippet only when there is
            // one, which the next line being a field tells.
            const url = self.field() orelse "";
            const snippet = self.field() orelse "";
            return .{ .title = title, .url = url, .snippet = snippet };
        }
        return null;
    }

    /// The next field, trimmed, consumed; null when the next line is blank or a
    /// heading, which is where this result ends.
    fn field(self: *Reader) ?[]const u8 {
        var ahead = self.rest;
        const line = takeLine(&ahead);
        if (markerLen(line) != null) return null;
        const value = std.mem.trim(u8, line, " \t\r");
        if (value.len == 0) return null;
        self.rest = ahead;
        return value;
    }
};

/// Reads the results out of `text`, which is the text `render` wrote.
pub fn parseResults(text: []const u8) Reader {
    return .{ .rest = text };
}

/// The next line of `text`, advancing it past the newline that ends it. The last
/// line of a text without a newline is the whole of what is left.
fn takeLine(text: *[]const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text.*, '\n') orelse text.*.len;
    const line = text.*[0..end];
    text.* = if (end < text.*.len) text.*[end + 1 ..] else text.*[text.*.len..];
    return line;
}

/// The length of the `N. ` heading at the start of `line`, or null when the line
/// is not one. Only a heading reaches the margin, so this is what tells a result
/// from the text under it.
fn markerLen(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i >= line.len or line[i] != '.') return null;
    i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    return i;
}
test "results are formatted as a numbered list of title, url and snippet" {
    const gpa = std.testing.allocator;

    const results = [_]Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A language." },
        // A result with no snippet is still worth its title and url.
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
    };

    const text = try renderAlloc(gpa, &results);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "a query that matched nothing says so" {
    const gpa = std.testing.allocator;

    const text = try renderAlloc(gpa, &.{});
    defer gpa.free(text);

    try std.testing.expectEqualStrings("(no results)", text);
}

test "the list reads back as the results it was built from" {
    const gpa = std.testing.allocator;

    const results = [_]Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A language." },
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
        .{ .title = "Blog", .url = "https://ziglang.org/blog", .snippet = "Notes." },
    };

    const text = try renderAlloc(gpa, &results);
    defer gpa.free(text);

    var parsed = parseResults(text);
    for (results) |expected| {
        const found = parsed.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.title, found.title);
        try std.testing.expectEqualStrings(expected.url, found.url);
        try std.testing.expectEqualStrings(expected.snippet, found.snippet);
    }
    try std.testing.expect(parsed.next() == null);
}

test "a field with a newline in it does not read as another result" {
    const gpa = std.testing.allocator;

    // A title and a snippet that would each read as a heading or a field if the
    // newlines in them were kept, so the shape has to fold them away.
    const results = [_]Result{.{
        .title = "Node.js\n2. Not a result",
        .url = "https://nodejs.org",
        .snippet = "One line.\n\n3. Also not a result",
    }};

    const text = try renderAlloc(gpa, &results);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "1. Node.js 2. Not a result\n" ++
            "   https://nodejs.org\n" ++
            "   One line.  3. Also not a result\n",
        text,
    );

    // Read back it is one result, with the newlines folded to spaces.
    var parsed = parseResults(text);
    const found = parsed.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Node.js 2. Not a result", found.title);
    try std.testing.expectEqualStrings("https://nodejs.org", found.url);
    try std.testing.expectEqualStrings("One line.  3. Also not a result", found.snippet);
    try std.testing.expect(parsed.next() == null);
}

test "text that is not a list of results reads back as none" {
    var parsed = parseResults("(no results)");
    try std.testing.expect(parsed.next() == null);
}

/// A backend's own results in the one shape `render` writes, where `snippet`
/// names the field that backend puts its text in. `gpa` owns the mapped list,
/// which the caller frees once the text is written.
pub fn mapped(gpa: std.mem.Allocator, backend_results: anytype, comptime snippet: []const u8) ![]const Result {
    const mapped_results = try gpa.alloc(Result, backend_results.len);
    for (backend_results, mapped_results) |result, *one| {
        one.* = .{ .title = result.title, .url = result.url, .snippet = @field(result, snippet) };
    }
    return mapped_results;
}
