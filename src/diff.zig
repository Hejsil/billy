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
            .context => try writer.print("{s} {s}{s}", .{ writer.dim(), line.text, writer.reset() }),
            .removed => try markedLine(line.kind, line.text, .red, writer),
            .added => try markedLine(line.kind, line.text, .green, writer),
            .elided => try writer.print("{s} … {d} more lines{s}", .{ writer.dim(), line.hidden, writer.reset() }),
        }
        try writer.write("\n");
    }
}

fn markedLine(kind: Kind, text: []const u8, hue: Terminal.Writer.Color, writer: Terminal.Writer) !void {
    try writer.print("{s}{c}{s}{s}", .{ writer.color(hue), kind.mark(), text, writer.reset() });
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
