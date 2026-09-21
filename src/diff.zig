//! A line diff of an edit: what the model asked to remove and what it asked to
//! put in its place. It is the intent, not what the file actually became, so it
//! is computed from the two strings of the call alone and a replayed session
//! shows the same diff as the run it continues.
//!
//! A configuration may run the diff through a script for better colours or
//! word-level changes; billy's own rendering is a `-`/`+` block with a few lines
//! of context. Either way the layout is presentation only: the file, the session
//! and the model keep the text as it was written.

const std = @import("std");
const Io = std.Io;
const styling = @import("style.zig");

/// Context lines kept on each side of the change. A model often hands over the
/// whole block it matched; only the lines nearest the change are worth showing.
const context_lines = 3;
/// Most removed, or added, lines shown before the rest is counted instead, so a
/// whole file passed as one edit cannot flood the display.
const max_hunk_lines = 20;

/// How a line relates to the change, which is also the mark it is printed with.
pub const Kind = enum {
    context,
    removed,
    added,
    /// Stands in for lines left out, holding the count in `hidden`.
    elided,

    /// The single character a line of this kind opens with, as a unified diff
    /// does. A line left out carries no mark of its own.
    fn mark(kind: Kind) u8 {
        return switch (kind) {
            .context => ' ',
            .removed => '-',
            .added => '+',
            .elided => ' ',
        };
    }
};

/// One line of the diff. `text` points into the old or new string, so only the
/// list of lines is allocated.
pub const Line = struct {
    kind: Kind,
    text: []const u8 = "",
    /// For an `elided` line, how many lines it stands in for.
    hidden: usize = 0,
};

/// The diff of `old` into `new`, line by line. Common leading and trailing lines
/// are context, trimmed to the few nearest the change; what is left of each
/// string is the change itself, capped so a large edit stays readable. An empty
/// result means the two are the same, so there is nothing to show.
pub fn lines(gpa: std.mem.Allocator, old: []const u8, new: []const u8) ![]Line {
    const old_lines = try splitLines(gpa, old);
    defer gpa.free(old_lines);
    const new_lines = try splitLines(gpa, new);
    defer gpa.free(new_lines);

    // The lines both sides open with, and the lines both sides close with. They
    // cannot overlap: each is bounded by the other.
    var prefix: usize = 0;
    while (prefix < old_lines.len and prefix < new_lines.len and
        std.mem.eql(u8, old_lines[prefix], new_lines[prefix])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (prefix + suffix < old_lines.len and prefix + suffix < new_lines.len and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - suffix], new_lines[new_lines.len - 1 - suffix])) : (suffix += 1)
    {}

    const removed = old_lines[prefix .. old_lines.len - suffix];
    const added = new_lines[prefix .. new_lines.len - suffix];
    // Nothing changed: there is no diff to show.
    if (removed.len == 0 and added.len == 0) return gpa.alloc(Line, 0);

    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);

    // Only the context nearest the change is kept, so a wide match does not push
    // the change off the screen.
    const kept_prefix = @min(prefix, context_lines);
    for (old_lines[prefix - kept_prefix .. prefix]) |line| {
        try out.append(gpa, .{ .kind = .context, .text = line });
    }
    try appendHunk(gpa, &out, .removed, removed);
    try appendHunk(gpa, &out, .added, added);
    const kept_suffix = @min(suffix, context_lines);
    for (old_lines[old_lines.len - kept_suffix ..]) |line| {
        try out.append(gpa, .{ .kind = .context, .text = line });
    }
    return out.toOwnedSlice(gpa);
}

/// Adds a whole side of the change, up to `max_hunk_lines` of it, counting the
/// rest on an elided line.
fn appendHunk(gpa: std.mem.Allocator, out: *std.ArrayList(Line), kind: Kind, lines_of: []const []const u8) !void {
    const shown = @min(lines_of.len, max_hunk_lines);
    for (lines_of[0..shown]) |line| try out.append(gpa, .{ .kind = kind, .text = line });
    if (lines_of.len > shown) {
        try out.append(gpa, .{ .kind = .elided, .hidden = lines_of.len - shown });
    }
}

/// The diff as the plain text a formatter reads: every line on its own, opened
/// with the mark of its kind, as a unified diff opens a line.
pub fn render(gpa: std.mem.Allocator, diff: []const Line) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (diff) |line| {
        if (line.kind == .elided) {
            try out.writer.print(" … {d} more lines\n", .{line.hidden});
        } else {
            try out.writer.print("{c}{s}\n", .{ line.kind.mark(), line.text });
        }
    }
    return out.toOwnedSlice();
}

/// Writes the diff the way billy shows it: a removed line red, an added line
/// green, the context dim, and each line opened with the mark of its kind. The
/// marks carry the meaning where the colour does not, such as a pipe or a
/// colour-blind terminal.
pub fn print(diff: []const Line, style: styling.Style, out: *Io.Writer) !void {
    for (diff) |line| {
        switch (line.kind) {
            .context => {
                try style.dim(" ", out);
                try style.dim(line.text, out);
            },
            .removed => try markedLine(line.kind, line.text, .red, style, out),
            .added => try markedLine(line.kind, line.text, .green, style, out),
            .elided => {
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, " … {d} more lines", .{line.hidden}) catch " …";
                try style.dim(text, out);
            },
        }
        try out.writeAll("\n");
    }
}

/// Writes one line as its mark and its text in `hue`, so a removed line reads
/// `-what it was` and an added line `+what it is`.
fn markedLine(kind: Kind, text: []const u8, hue: styling.Color, style: styling.Style, out: *Io.Writer) !void {
    try style.color(hue, &.{kind.mark()}, out);
    try style.color(hue, text, out);
}

/// The lines of `text`, without a trailing empty line for a terminating newline:
/// `"a\nb\n"` is two lines, `"a\n\n"` is three, and `""` is none.
fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    // Each segment is appended once the next is seen, so the last one can be
    // dropped when it is only the terminator of the line before it.
    var it = std.mem.splitScalar(u8, text, '\n');
    var previous: ?[]const u8 = null;
    while (it.next()) |line| {
        if (previous) |held| try list.append(gpa, held);
        previous = line;
    }
    if (previous) |last| {
        if (last.len > 0) try list.append(gpa, last);
    }
    return list.toOwnedSlice(gpa);
}

test "a change in the middle keeps the lines around it" {
    const gpa = std.testing.allocator;
    const diff = try lines(gpa, "a\nb\nc", "a\nx\nc");
    defer gpa.free(diff);

    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(Kind.context, diff[0].kind);
    try std.testing.expectEqualStrings("a", diff[0].text);
    try std.testing.expectEqual(Kind.removed, diff[1].kind);
    try std.testing.expectEqualStrings("b", diff[1].text);
    try std.testing.expectEqual(Kind.added, diff[2].kind);
    try std.testing.expectEqualStrings("x", diff[2].text);
    try std.testing.expectEqual(Kind.context, diff[3].kind);
    try std.testing.expectEqualStrings("c", diff[3].text);
}

test "the lines both sides share are context, and only the nearest are kept" {
    const gpa = std.testing.allocator;
    // Five shared lines open the match, so only the last three are shown, and the
    // shared line that closes it is kept.
    const diff = try lines(gpa, "1\n2\n3\n4\n5\nold\nz", "1\n2\n3\n4\n5\nnew\nz");
    defer gpa.free(diff);

    try std.testing.expectEqual(@as(usize, 6), diff.len);
    try std.testing.expectEqualStrings("3", diff[0].text);
    try std.testing.expectEqualStrings("4", diff[1].text);
    try std.testing.expectEqualStrings("5", diff[2].text);
    try std.testing.expectEqual(Kind.removed, diff[3].kind);
    try std.testing.expectEqualStrings("old", diff[3].text);
    try std.testing.expectEqual(Kind.added, diff[4].kind);
    try std.testing.expectEqualStrings("new", diff[4].text);
    try std.testing.expectEqual(Kind.context, diff[5].kind);
    try std.testing.expectEqualStrings("z", diff[5].text);
}

test "an unchanged edit has no diff" {
    const gpa = std.testing.allocator;
    const diff = try lines(gpa, "same\ntext", "same\ntext");
    defer gpa.free(diff);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "a large side is counted rather than shown whole" {
    const gpa = std.testing.allocator;
    // 25 old lines replaced by one new line: only 20 are shown, the rest counted.
    var old: std.Io.Writer.Allocating = .init(gpa);
    defer old.deinit();
    for (0..25) |i| try old.writer.print("line {d}\n", .{i});
    const diff = try lines(gpa, old.written(), "replacement");
    defer gpa.free(diff);

    try std.testing.expectEqual(@as(usize, 22), diff.len); // 20 shown + elided + added
    try std.testing.expectEqual(Kind.elided, diff[20].kind);
    try std.testing.expectEqual(@as(usize, 5), diff[20].hidden);
    try std.testing.expectEqual(Kind.added, diff[21].kind);
}

test "the plain text opens each line with the mark of its kind" {
    const gpa = std.testing.allocator;
    const diff = try lines(gpa, "a\nb\nc", "a\nx\nc");
    defer gpa.free(diff);
    const text = try render(gpa, diff);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(" a\n-b\n+x\n c\n", text);
}
