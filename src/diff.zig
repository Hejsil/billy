//! A line diff of an edit: what the model asked to remove and what it asked to put in its place.

const std = @import("std");

const Terminal = @import("Terminal.zig");

const context_lines = 3;
const max_hunk_lines = 20;

/// How a line relates to the change, which is also the mark it is printed with.
pub const Kind = enum {
    context,
    removed,
    added,
    elided,

    /// The single character a line of this kind opens with, as a unified diff does.
    pub fn mark(kind: Kind) u8 {
        return switch (kind) {
            .context => ' ',
            .removed => '-',
            .added => '+',
            .elided => ' ',
        };
    }
};

/// One line of the diff.
pub const Line = struct {
    kind: Kind,
    text: []const u8 = "",
    hidden: usize = 0,
};

/// The diff of `old` into `new`, line by line.
pub fn lines(gpa: std.mem.Allocator, old: []const u8, new: []const u8) ![]Line {
    const old_lines = try splitLines(gpa, old);
    defer gpa.free(old_lines);
    const new_lines = try splitLines(gpa, new);
    defer gpa.free(new_lines);

    // The lines both sides open with, and the lines both sides close with.
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
    if (removed.len == 0 and added.len == 0) return gpa.alloc(Line, 0);

    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);

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

fn appendHunk(gpa: std.mem.Allocator, out: *std.ArrayList(Line), kind: Kind, lines_of: []const []const u8) !void {
    const shown = @min(lines_of.len, max_hunk_lines);
    for (lines_of[0..shown]) |line| try out.append(gpa, .{ .kind = kind, .text = line });
    if (lines_of.len > shown) {
        try out.append(gpa, .{ .kind = .elided, .hidden = lines_of.len - shown });
    }
}

/// Writes the diff the way billy shows it: a removed line red, an added line green, the context
/// dim, and each line opened with the mark of its kind.
pub fn print(diff: []const Line, writer: Terminal.Writer) !void {
    for (diff) |line| {
        switch (line.kind) {
            .context => try markedLine(line.kind, line.text, writer.dim(), writer),
            .removed => try markedLine(line.kind, line.text, writer.color(.red), writer),
            .added => try markedLine(line.kind, line.text, writer.color(.green), writer),
            .elided => try writer.print("{s} … {d} more lines{s}", .{ writer.dim(), line.hidden, writer.reset() }),
        }
        try writer.write("\n");
    }
}

fn markedLine(kind: Kind, text: []const u8, style: []const u8, writer: Terminal.Writer) !void {
    try writer.print("{s}{c}", .{ style, kind.mark() });
    try writer.writeText(text);
    try writer.write(writer.reset());
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
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

const Want = struct {
    kind: Kind,
    text: []const u8 = "",
    hidden: usize = 0,
};

fn expectLines(old: []const u8, new: []const u8, expected: []const Want) !void {
    const gpa = std.testing.allocator;
    const diff = try lines(gpa, old, new);
    defer gpa.free(diff);

    try std.testing.expectEqual(expected.len, diff.len);
    for (expected, diff) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.text, got.text);
        try std.testing.expectEqual(want.hidden, got.hidden);
    }
}

fn expectPrinted(expected: []const u8, old: []const u8, new: []const u8, style: Terminal.Writer.Style) !void {
    const gpa = std.testing.allocator;
    const diff = try lines(gpa, old, new);
    defer gpa.free(diff);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try print(diff, .{ .style = style, .out = &out.writer });
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a diff line is written in the colour of what it is" {
    // The colour wraps the line and its mark, which is what makes a change readable at a glance.
    try expectPrinted(
        "\x1b[31m-old\x1b[0m\n\x1b[32m+new\x1b[0m\n",
        "old\n",
        "new\n",
        .ansi,
    );
}

test "a change in the middle keeps the lines around it" {
    try expectLines("a\nb\nc", "a\nx\nc", &.{
        .{ .kind = .context, .text = "a" },
        .{ .kind = .removed, .text = "b" },
        .{ .kind = .added, .text = "x" },
        .{ .kind = .context, .text = "c" },
    });
}

test "the lines both sides share are context, and only the nearest are kept" {
    try expectLines("1\n2\n3\n4\n5\nold\nz", "1\n2\n3\n4\n5\nnew\nz", &.{
        .{ .kind = .context, .text = "3" },
        .{ .kind = .context, .text = "4" },
        .{ .kind = .context, .text = "5" },
        .{ .kind = .removed, .text = "old" },
        .{ .kind = .added, .text = "new" },
        .{ .kind = .context, .text = "z" },
    });
}

test "an unchanged edit has no diff" {
    try expectLines("same\ntext", "same\ntext", &.{});
}

test "a large side is counted rather than shown whole" {
    const gpa = std.testing.allocator;
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
