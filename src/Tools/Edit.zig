const std = @import("std");

const Tools = @import("../Tools.zig");

const Edit = @This();

path: []const u8,
old_string: []const u8,
new_string: []const u8,
replace_all: bool = false,

pub fn run(edit: Edit, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    if (edit.old_string.len == 0)
        return Tools.fail(out, "old_string must not be empty", .{});

    const contents = dir.readFileAlloc(io, edit.path, gpa, .unlimited) catch |err|
        return Tools.fail(out, "cannot read {s}: {t}", .{ edit.path, err });
    defer gpa.free(contents);

    const amount: Amount = if (edit.replace_all) .all else .one;
    var change = try replace(gpa, contents, edit.old_string, edit.new_string, amount);

    switch (change) {
        .not_found => return Tools.fail(out, "old_string not found in {s}", .{edit.path}),
        .ambiguous => |count| return Tools.fail(
            out,
            "old_string appears {d} times in {s}; add context or pass replace_all",
            .{ count, edit.path },
        ),
        .applied => |*applied| {
            defer applied.text.deinit(gpa);
            Tools.writeFile(io, dir, edit.path, applied.text.items) catch |err|
                return Tools.fail(out, "cannot write {s}: {t}", .{ edit.path, err });

            try out.print("replaced {d} occurrence(s) in {s}", .{ applied.count, edit.path });
        },
    }
}

const Amount = enum {
    one,
    all,
};

fn replace(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    amount: Amount,
) !Change {
    var found = try find(gpa, haystack, needle);
    defer found.spans.deinit(gpa);

    if (found.spans.items.len == 0)
        return .not_found;
    if (found.spans.items.len > 1 and amount == .one)
        return .{ .ambiguous = found.spans.items.len };

    const reindented = if (found.rule == .exact)
        replacement
    else
        try reindent(
            gpa,
            replacement,
            indentOf(firstLine(needle)),
            indentOf(haystack[found.spans.items[0].start..]),
        );
    defer if (found.rule != .exact) gpa.free(reindented);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    var at: usize = 0;
    for (found.spans.items) |span| {
        try text.appendSlice(gpa, haystack[at..span.start]);
        try text.appendSlice(gpa, reindented);
        at = span.end;
    }
    try text.appendSlice(gpa, haystack[at..]);

    return .{ .applied = .{ .text = text, .count = found.spans.items.len } };
}

const Matching = enum {
    exact,
    trailing_whitespace,
    indentation,
};

const Found = struct {
    rule: Matching,
    spans: std.ArrayList(Span),
};

fn find(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8) !Found {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    if (needle.len == 0)
        return .{ .rule = .exact, .spans = spans };

    var from: usize = 0;
    while (std.mem.findPos(u8, haystack, from, needle)) |at| {
        try spans.append(gpa, .{ .start = at, .end = at + needle.len });
        from = at + needle.len;
    }

    if (spans.items.len > 0)
        return .{ .rule = .exact, .spans = spans };

    for ([_]Matching{ .trailing_whitespace, .indentation }) |tier| {
        spans.clearRetainingCapacity();

        const trim: Trim = if (tier == .indentation) .trim else .trim_end;
        try findLines(gpa, haystack, needle, trim, &spans);
        if (spans.items.len > 0) {
            return .{ .rule = tier, .spans = spans };
        }
    }

    return .{ .rule = .exact, .spans = spans };
}

const Span = struct { start: usize, end: usize };

fn findLines(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    trim: Trim,
    spans: *std.ArrayList(Span),
) !void {
    const haystack_lines = try splitLines(gpa, haystack);
    defer gpa.free(haystack_lines);

    const needle_lines = try splitLines(gpa, needle);
    defer gpa.free(needle_lines);

    if (needle_lines.len == 0 or needle_lines.len > haystack_lines.len)
        return;

    const ends_with_newline = needle[needle.len - 1] == '\n';

    var i: usize = 0;
    while (i + needle_lines.len <= haystack_lines.len) : (i += 1) {
        var matches = true;
        for (needle_lines, 0..) |want, j| {
            const have = haystack_lines[i + j];
            const want_text = normalize(needle[want.start..want.content_end], trim);
            const have_text = normalize(haystack[have.start..have.content_end], trim);
            if (!std.mem.eql(u8, want_text, have_text)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const last = haystack_lines[i + needle_lines.len - 1];
        try spans.append(gpa, .{
            .start = haystack_lines[i].start,
            .end = if (ends_with_newline) last.end else last.content_end,
        });
    }
}

const Line = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);

    var at: usize = 0;
    while (at < text.len) {
        const newline = std.mem.findScalarPos(u8, text, at, '\n');
        const end = if (newline) |i| i + 1 else text.len;
        var content_end = if (newline) |i| i else text.len;
        if (content_end > at and text[content_end - 1] == '\r') content_end -= 1;
        try lines.append(gpa, .{ .start = at, .content_end = content_end, .end = end });
        at = end;
    }
    return lines.toOwnedSlice(gpa);
}

const Trim = enum {
    trim_start,
    trim_end,
    trim,
};

fn normalize(line: []const u8, trim: Trim) []const u8 {
    var text = line;
    if (trim != .trim_end) text = std.mem.trimStart(u8, text, " \t");
    if (trim != .trim_start) text = std.mem.trimEnd(u8, text, " \t\r");
    return text;
}

fn reindent(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    if (std.mem.eql(u8, from, to))
        return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (std.mem.trim(u8, line, " \t").len == 0 or !std.mem.startsWith(u8, line, from)) {
            try out.appendSlice(gpa, line);
            continue;
        }
        try out.appendSlice(gpa, to);
        try out.appendSlice(gpa, line[from.len..]);
    }
    return out.toOwnedSlice(gpa);
}

fn indentOf(line: []const u8) []const u8 {
    return line[0 .. line.len - std.mem.trimStart(u8, line, " \t").len];
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
}

const Change = union(enum) {
    applied: struct {
        text: std.ArrayList(u8),
        count: usize,
    },
    not_found,
    ambiguous: usize,
};

fn expectReplace(
    expected: []const u8,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    amount: Amount,
) !void {
    const gpa = std.testing.allocator;
    const change = try replace(gpa, haystack, needle, replacement, amount);

    var applied = switch (change) {
        .applied => |applied| applied,
        else => return error.TestExpectedAnAppliedChange,
    };
    defer applied.text.deinit(gpa);

    try std.testing.expectEqualStrings(expected, applied.text.items);
}

fn expectReplaceOne(expected: []const u8, contents: []const u8, old_string: []const u8, new_string: []const u8) !void {
    return try expectReplace(expected, contents, old_string, new_string, .one);
}

fn expectReplaceAll(expected: []const u8, contents: []const u8, old_string: []const u8, new_string: []const u8) !void {
    return try expectReplace(expected, contents, old_string, new_string, .all);
}

test "an exact match is changed where it is" {
    try expectReplaceOne("let x = 42;\nlet y = 2;\n", "let x = 1;\nlet y = 2;\n", "let x = 1;", "let x = 42;");
    try expectReplaceOne("qux();\n", "foo();\n", "foo();\n", "qux();\n");
    try expectReplaceOne("a = 2; b = 3;\n", "a = 1; b = 3;\n", "a = 1;", "a = 2;");
}

test "an exact match is preferred over a loose one" {
    // The first line matches exactly, so it is changed even though the second matches only once
    // whitespace is ignored, which would be two candidates.
    try expectReplaceOne("x = 1\n  x = 1\n", "x = 0\n  x = 1\n", "x = 0", "x = 1");
}

test "text that appears more than once is ambiguous unless replace_all" {
    const gpa = std.testing.allocator;
    const contents = "a = 1;\na = 1;\n";

    switch (try replace(gpa, contents, "a = 1;", "a = 2;", .one)) {
        .ambiguous => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.TestExpectedAnAmbiguousMatch,
    }
    try expectReplaceAll("a = 2;\na = 2;\n", contents, "a = 1;", "a = 2;");
}

test "text that is not in the haystack is not found" {
    const gpa = std.testing.allocator;
    switch (try replace(gpa, "abc\ndef\n", "xyz", "q", .one)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
    switch (try replace(gpa, "def\nabc\n", "abc\ndef\n", "q", .one)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
}

test "trailing whitespace and the line ending are ignored when exact fails" {
    try expectReplaceOne("qux();\nbar();\n", "foo();   \nbar();\n", "foo();\n", "qux();\n");
    try expectReplaceOne("qux();\nbar();\r\n", "foo();\r\nbar();\r\n", "foo();\n", "qux();\n");
    try expectReplaceOne("qux();\n", "foo();\n", "foo();   ", "qux();");
}

test "indentation is ignored when the haystack is indented differently" {
    try expectReplaceOne(
        "    if (x) {\n        z();\n    }\n",
        "    if (x) {\n        y();\n    }\n",
        "if (x) {\n    y();\n}\n",
        "if (x) {\n    z();\n}\n",
    );
    try expectReplaceOne(
        "if (x) {\n    z();\n}\n",
        "if (x) {\n    y();\n}\n",
        "    if (x) {\n        y();\n    }\n",
        "    if (x) {\n        z();\n    }\n",
    );
}

test "a blank line in a loosely matched replacement carries no indentation" {
    try expectReplaceOne(
        "    a();\n\n    b();\n",
        "    a();\n\n    b();\n",
        "a();\n\nb();\n",
        "a();\n\nb();\n",
    );
}

test "a replacement matched exactly is not re-indented" {
    try expectReplaceOne(
        "one();\n        three();\n",
        "one();\n    two();\n",
        "    two();\n",
        "        three();\n",
    );
}
