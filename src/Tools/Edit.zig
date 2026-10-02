const std = @import("std");

const Edit = @This();

path: []const u8,
old_string: []const u8,
new_string: []const u8,
replace_all: bool = false,

pub fn run(edit: Edit, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    if (edit.old_string.len == 0)
        return out.writeAll("error: old_string must not be empty");

    const contents = dir.readFileAlloc(io, edit.path, gpa, .limited(16 << 20)) catch |err|
        return out.print("error: cannot read {s}: {s}", .{ edit.path, @errorName(err) });
    defer gpa.free(contents);

    const amount: Amount = if (edit.replace_all) .all else .one;
    var change = try replace(gpa, contents, edit.old_string, edit.new_string, amount);

    switch (change) {
        .not_found => return out.print("error: old_string not found in {s}", .{edit.path}),
        .ambiguous => |count| return out.print(
            "error: old_string appears {d} times in {s}; add context or pass replace_all",
            .{ count, edit.path },
        ),
        .applied => |*applied| {
            defer applied.text.deinit(gpa);
            dir.writeFile(io, .{
                .sub_path = edit.path,
                .data = applied.text.items,
            }) catch |err| return out.print("error: cannot write {s}: {s}", .{ edit.path, @errorName(err) });
            try out.print("error: replaced {d} occurrence(s) in {s}", .{ applied.count, edit.path });
        },
    }
}

const Amount = enum {
    one,
    all,
};

/// Replaces `needle` with `replacement` in `haystack`, matching exactly when it
/// can and ignoring whitespace when it cannot. `replace == .all` changes every
/// place the text appears. Without it, text that appears more than once is
/// `ambiguous` rather than changed at a guess
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

    // An exact match is already laid out the way the haystack is, so only a loosely
    // matched one is re-indented, to the indentation of the line it replaces.
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

/// How `needle` was found
const Matching = enum {
    /// The text appears as it is written, byte for byte.
    exact,
    /// The text appears once trailing whitespace and the line ending are ignored
    /// on each line
    trailing_whitespace,
    /// The text also appears ignoring the indentation in front of each line
    indentation,
};

const Found = struct {
    rule: Matching,
    spans: std.ArrayList(Span),
};

/// Finds `needle` in `haystack`, exact first and then loosely, returning the
/// spans it covers and the rule that found them. An empty result means it was
/// not found at all
fn find(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8) !Found {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    if (needle.len == 0)
        return .{ .rule = .exact, .spans = spans };

    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        try spans.append(gpa, .{ .start = at, .end = at + needle.len });
        from = at + needle.len;
    }

    if (spans.items.len > 0)
        return .{ .rule = .exact, .spans = spans };

    // Whole lines now: the text is lined up line by line, with the whitespace a
    // line carries left out of the comparison.
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

/// Finds `needle` in `haystack` as a run of whole lines, ignoring whitespace
/// based on `trim`
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

    // Whether the text ends on a newline says whether the line it stops on is
    // taken whole; without one, that line's own ending is left in the haystack.
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

/// One line of a haystack, by the offsets it occupies: `start` is its first byte,
/// `content_end` the byte after its text, and `end` the byte after its line
/// ending, which is `content_end` on a last line that has none.
const Line = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

/// Splits `text` into the lines it holds, each with its offsets. Text that ends
/// on a newline does not gain an empty line after it.
fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);

    var at: usize = 0;
    while (at < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, at, '\n');
        const end = if (newline) |i| i + 1 else text.len;
        var content_end = if (newline) |i| i else text.len;
        // A carriage return before the newline is the line ending, not the line.
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

/// A line as it is compared, with whitespace trimmed based on `trim`
fn normalize(line: []const u8, trim: Trim) []const u8 {
    var text = line;
    if (trim != .trim_end) text = std.mem.trimStart(u8, text, " \t");
    if (trim != .trim_start) text = std.mem.trimEnd(u8, text, " \t\r");
    return text;
}

/// `text` with its lines shifted so that a block indented at `from` sits at `to`
/// instead. This is how a loosely matched replacement keeps the indentation of
/// the text it lands in: a line indented at least as far as `from` is moved with
/// it, and one that is not, such as a blank line, is left where it is. The
/// result is owned by `gpa`.
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

/// The whitespace in front of `line`, which is its indentation.
fn indentOf(line: []const u8) []const u8 {
    return line[0 .. line.len - std.mem.trimStart(u8, line, " \t").len];
}

/// The first line of `text`, up to its line ending.
fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// What replacing `needle` produced: the new contents and how many places changed,
/// or why no change could be made.
const Change = union(enum) {
    applied: struct {
        /// The haystack with the replacement applied
        text: std.ArrayList(u8),
        /// How many places were changed.
        count: usize,
    },
    /// The `needle` was not in the `haystack`, even ignoring whitespace.
    not_found,
    /// The `needle` was in the `haystack` this many times, so which one to
    /// change is unclear.
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
    return expectReplace(expected, contents, old_string, new_string, .one);
}

fn expectReplaceAll(expected: []const u8, contents: []const u8, old_string: []const u8, new_string: []const u8) !void {
    return expectReplace(expected, contents, old_string, new_string, .all);
}

test "an exact match is changed where it is" {
    // The line's own ending is not part of the text, so it is left in the `haystack`.
    try expectReplaceOne("let x = 42;\nlet y = 2;\n", "let x = 1;\nlet y = 2;\n", "let x = 1;", "let x = 42;");
    // The ending is part of the text when the text carries it.
    try expectReplaceOne("qux();\n", "foo();\n", "foo();\n", "qux();\n");
    // Text in the middle of a line, not only whole lines.
    try expectReplaceOne("a = 2; b = 3;\n", "a = 1; b = 3;\n", "a = 1;", "a = 2;");
}

test "an exact match is preferred over a loose one" {
    // The first line matches exactly, so it is changed even though the second
    // matches only once whitespace is ignored, which would be two candidates.
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
    // Nor when it is a different haystack than the one the lines were copied from.
    switch (try replace(gpa, "def\nabc\n", "abc\ndef\n", "q", .one)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
}

test "trailing whitespace and the line ending are ignored when exact fails" {
    // Trailing spaces the model dropped from a copied line.
    try expectReplaceOne("qux();\nbar();\n", "foo();   \nbar();\n", "foo();\n", "qux();\n");
    // A carriage return line ending where the text was written with a newline.
    // Only the matched line is changed, so the rest keeps its own ending.
    try expectReplaceOne("qux();\nbar();\r\n", "foo();\r\nbar();\r\n", "foo();\n", "qux();\n");
    // Trailing spaces the model added that the haystack does not have, in text
    // written without a line ending, so the haystack keeps its own.
    try expectReplaceOne("qux();\n", "foo();\n", "foo();   ", "qux();");
}

test "indentation is ignored when the haystack is indented differently" {
    // The text was written unindented but sits inside a block in the haystack. The
    // replacement is indented to sit where the text did, so the block keeps its
    // shape.
    try expectReplaceOne(
        "    if (x) {\n        z();\n    }\n",
        "    if (x) {\n        y();\n    }\n",
        "if (x) {\n    y();\n}\n",
        "if (x) {\n    z();\n}\n",
    );
    // The same the other way: text indented more than the haystack it lands in.
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
    // The text matches byte for byte, so the replacement is left as written even
    // though its own first line is indented differently.
    try expectReplaceOne(
        "one();\n        three();\n",
        "one();\n    two();\n",
        "    two();\n",
        "        three();\n",
    );
}
