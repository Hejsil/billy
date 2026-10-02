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

    const change = try replaceInFile(
        gpa,
        contents,
        edit.old_string,
        edit.new_string,
        edit.replace_all,
    );
    switch (change) {
        .not_found => return out.print("error: old_string not found in {s}", .{edit.path}),
        .ambiguous => |count| return out.print(
            "error: old_string appears {d} times in {s}; add context or pass replace_all",
            .{ count, edit.path },
        ),
        .applied => |applied| {
            defer gpa.free(applied.text);
            dir.writeFile(io, .{
                .sub_path = edit.path,
                .data = applied.text,
            }) catch |err| return out.print("error: cannot write {s}: {s}", .{ edit.path, @errorName(err) });
            try out.print("error: replaced {d} occurrence(s) in {s}", .{ applied.count, edit.path });
        },
    }
}

/// How `old_string` was found in the file. The rules are tried strictest first,
/// so text that matches exactly is changed where it is and only text that does
/// not is matched loosely: a loose rule never stands in for a real match, and
/// one that does match is never mistaken for another.
const Matching = enum {
    /// The text appears as it is written, byte for byte.
    exact,
    /// The text appears once trailing whitespace and the line ending are ignored
    /// on each line, which is what a model that retyped a copied line gets
    /// wrong.
    trailing_whitespace,
    /// The text also appears ignoring the indentation in front of each line,
    /// which is what a model that lost the file's indentation writes. The
    /// replacement is indented to match the file, so an edit does not flatten
    /// code the file had indented.
    indentation,
};

/// Replaces `old_string` with `new_string` in `contents`, matching exactly when
/// it can and ignoring whitespace when it cannot. `replace_all` changes every
/// place the text appears; without it, text that appears more than once is
/// `ambiguous` rather than changed at a guess. The result is owned by `gpa`.
fn replaceInFile(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !Change {
    var rule: Matching = .exact;
    const spans = try findInFile(gpa, contents, old_string, &rule);
    defer gpa.free(spans);

    if (spans.len == 0) return .not_found;
    if (spans.len > 1 and !replace_all) return .{ .ambiguous = spans.len };

    // An exact match is already laid out the way the file is, so only a loosely
    // matched one is re-indented, to the indentation of the line it replaces.
    const replacement = if (rule == .exact)
        try gpa.dupe(u8, new_string)
    else
        try reindent(
            gpa,
            new_string,
            indentOf(firstLine(old_string)),
            indentOf(contents[spans[0].start..]),
        );
    defer gpa.free(replacement);

    const count = if (replace_all) spans.len else 1;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var at: usize = 0;
    for (spans[0..count]) |span| {
        try text.appendSlice(gpa, contents[at..span.start]);
        try text.appendSlice(gpa, replacement);
        at = span.end;
    }
    try text.appendSlice(gpa, contents[at..]);
    return .{ .applied = .{ .text = try text.toOwnedSlice(gpa), .count = count } };
}

/// Finds `old_string` in `contents`, exact first and then loosely, returning the
/// spans it covers in order and the rule that found them in `rule`. An empty
/// result means it was not found at all. The spans are owned by `gpa`.
fn findInFile(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    rule: *Matching,
) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    if (old_string.len == 0) return spans.toOwnedSlice(gpa);

    rule.* = .exact;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, contents, from, old_string)) |at| {
        try spans.append(gpa, .{ .start = at, .end = at + old_string.len });
        from = at + old_string.len;
    }
    if (spans.items.len > 0) return spans.toOwnedSlice(gpa);

    // Whole lines now: the text is lined up line by line, with the whitespace a
    // line carries left out of the comparison.
    for ([_]Matching{ .trailing_whitespace, .indentation }) |tier| {
        spans.clearRetainingCapacity();
        try findLines(gpa, contents, old_string, tier == .indentation, &spans);
        if (spans.items.len > 0) {
            rule.* = tier;
            return spans.toOwnedSlice(gpa);
        }
    }
    return spans.toOwnedSlice(gpa);
}

/// A byte range of the file.
const Span = struct { start: usize, end: usize };

/// Finds `old_string` in `contents` as a run of whole lines, ignoring trailing
/// whitespace and, when `trim_leading`, the indentation in front of each line.
/// Every line of the text has to line up with a line of the file, so a match
/// spans as many lines as the text to find. The spans are appended to `spans`.
fn findLines(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    trim_leading: bool,
    spans: *std.ArrayList(Span),
) !void {
    const file = try splitLines(gpa, contents);
    defer gpa.free(file);
    const find = try splitLines(gpa, old_string);
    defer gpa.free(find);
    if (find.len == 0 or find.len > file.len) return;

    // Whether the text ends on a newline says whether the line it stops on is
    // taken whole; without one, that line's own ending is left in the file.
    const ends_with_newline = old_string[old_string.len - 1] == '\n';

    var i: usize = 0;
    while (i + find.len <= file.len) : (i += 1) {
        var matches = true;
        for (find, 0..) |want, j| {
            const have = file[i + j];
            const want_text = normalized(old_string[want.start..want.content_end], trim_leading);
            const have_text = normalized(contents[have.start..have.content_end], trim_leading);
            if (!std.mem.eql(u8, want_text, have_text)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const last = file[i + find.len - 1];
        try spans.append(gpa, .{
            .start = file[i].start,
            .end = if (ends_with_newline) last.end else last.content_end,
        });
    }
}

/// One line of a file, by the offsets it occupies: `start` is its first byte,
/// `content_end` the byte after its text, and `end` the byte after its line
/// ending, which is `content_end` on a last line that has none.
const FileLine = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

/// Splits `text` into the lines it holds, each with its offsets. Text that ends
/// on a newline does not gain an empty line after it.
fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]FileLine {
    var lines: std.ArrayList(FileLine) = .empty;
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

/// A line as it is compared: without the trailing whitespace it carries and,
/// when `trim_leading`, without its indentation either.
fn normalized(line: []const u8, trim_leading: bool) []const u8 {
    var text = std.mem.trimEnd(u8, line, " \t\r");
    if (trim_leading) text = std.mem.trimStart(u8, text, " \t");
    return text;
}

/// `text` with its lines shifted so that a block indented at `from` sits at `to`
/// instead. This is how a loosely matched replacement keeps the indentation of
/// the file it lands in: a line indented at least as far as `from` is moved with
/// it, and one that is not, such as a blank line, is left where it is. The
/// result is owned by `gpa`.
fn reindent(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    if (std.mem.eql(u8, from, to)) return gpa.dupe(u8, text);

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
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

/// The first line of `text`, up to its line ending.
fn firstLine(text: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..newline];
}

/// What replacing `old_string` in a file produced: the new contents and how many
/// places changed, or why no change could be made.
const Change = union(enum) {
    applied: struct {
        /// The file with the change made. Owned by the allocator the search ran
        /// with.
        text: []u8,
        /// How many places were changed.
        count: usize,
    },
    /// The text was not in the file, even ignoring whitespace.
    not_found,
    /// The text was in the file this many times, so which one to change is
    /// unclear.
    ambiguous: usize,
};

/// Replaces `old_string` in `contents` and checks what the file became, so a
/// test reads as the edit it makes rather than as the plumbing around it.
fn expectReplace(expected: []const u8, contents: []const u8, old_string: []const u8, new_string: []const u8) !void {
    return expectReplaceAll(expected, contents, old_string, new_string, false);
}

fn expectReplaceAll(
    expected: []const u8,
    contents: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !void {
    const gpa = std.testing.allocator;
    const change = try replaceInFile(gpa, contents, old_string, new_string, replace_all);
    const applied = switch (change) {
        .applied => |applied| applied,
        else => return error.TestExpectedAnAppliedChange,
    };
    defer gpa.free(applied.text);
    try std.testing.expectEqualStrings(expected, applied.text);
}

test "an exact match is changed where it is" {
    // The line's own ending is not part of the text, so it is left in the file.
    try expectReplace("let x = 42;\nlet y = 2;\n", "let x = 1;\nlet y = 2;\n", "let x = 1;", "let x = 42;");
    // The ending is part of the text when the text carries it.
    try expectReplace("qux();\n", "foo();\n", "foo();\n", "qux();\n");
    // Text in the middle of a line, not only whole lines.
    try expectReplace("a = 2; b = 3;\n", "a = 1; b = 3;\n", "a = 1;", "a = 2;");
}

test "an exact match is preferred over a loose one" {
    // The first line matches exactly, so it is changed even though the second
    // matches only once whitespace is ignored, which would be two candidates.
    try expectReplace("x = 1\n  x = 1\n", "x = 0\n  x = 1\n", "x = 0", "x = 1");
}

test "text that appears more than once is ambiguous unless replace_all" {
    const gpa = std.testing.allocator;
    const contents = "a = 1;\na = 1;\n";

    switch (try replaceInFile(gpa, contents, "a = 1;", "a = 2;", false)) {
        .ambiguous => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.TestExpectedAnAmbiguousMatch,
    }
    try expectReplaceAll("a = 2;\na = 2;\n", contents, "a = 1;", "a = 2;", true);
}

test "text that is not in the file is not found" {
    const gpa = std.testing.allocator;
    switch (try replaceInFile(gpa, "abc\ndef\n", "xyz", "q", false)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
    // Nor when it is a different file than the one the lines were copied from.
    switch (try replaceInFile(gpa, "def\nabc\n", "abc\ndef\n", "q", false)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
}

test "trailing whitespace and the line ending are ignored when exact fails" {
    // Trailing spaces the model dropped from a copied line.
    try expectReplace("qux();\nbar();\n", "foo();   \nbar();\n", "foo();\n", "qux();\n");
    // A carriage return line ending where the text was written with a newline.
    // Only the matched line is changed, so the rest keeps its own ending.
    try expectReplace("qux();\nbar();\r\n", "foo();\r\nbar();\r\n", "foo();\n", "qux();\n");
    // Trailing spaces the model added that the file does not have, in text
    // written without a line ending, so the file keeps its own.
    try expectReplace("qux();\n", "foo();\n", "foo();   ", "qux();");
}

test "indentation is ignored when the file is indented differently" {
    // The text was written unindented but sits inside a block in the file. The
    // replacement is indented to sit where the text did, so the block keeps its
    // shape.
    try expectReplace(
        "    if (x) {\n        z();\n    }\n",
        "    if (x) {\n        y();\n    }\n",
        "if (x) {\n    y();\n}\n",
        "if (x) {\n    z();\n}\n",
    );
    // The same the other way: text indented more than the file it lands in.
    try expectReplace(
        "if (x) {\n    z();\n}\n",
        "if (x) {\n    y();\n}\n",
        "    if (x) {\n        y();\n    }\n",
        "    if (x) {\n        z();\n    }\n",
    );
}

test "a blank line in a loosely matched replacement carries no indentation" {
    try expectReplace(
        "    a();\n\n    b();\n",
        "    a();\n\n    b();\n",
        "a();\n\nb();\n",
        "a();\n\nb();\n",
    );
}

test "a replacement matched exactly is not re-indented" {
    // The text matches byte for byte, so the replacement is left as written even
    // though its own first line is indented differently.
    try expectReplace(
        "one();\n        three();\n",
        "one();\n    two();\n",
        "    two();\n",
        "        three();\n",
    );
}
