//! A reply on the terminal as it arrives: markdown is read again from the start every time more of
//! it comes, the block still being written is taken back and written again, and the blocks before
//! it are written once. The width is asked each frame, so a resize is answered, not outlived.

const std = @import("std");

const markdown = @import("Markdown.zig");
const terminal_width = @import("width.zig");
const Writer = @import("Writer.zig");

const Answer = @This();

gpa: std.mem.Allocator,
writer: Writer,
text: std.ArrayList(u8) = .empty,
/// How many of its blocks are written and are not to be written again.
finished: usize = 0,
/// What the block being written took of the screen, which is what has to be taken back.
drawn: ?terminal_width.Laid = null,
drawn_text: std.ArrayList(u8) = .empty,

pub fn open(gpa: std.mem.Allocator, writer: Writer) Answer {
    return .{ .gpa = gpa, .writer = writer };
}

pub fn deinit(self: *Answer) void {
    self.text.deinit(self.gpa);
    self.drawn_text.deinit(self.gpa);
}

pub fn push(self: *Answer, delta: []const u8) !void {
    try self.text.appendSlice(self.gpa, delta);
    try self.show();
}

/// Ends the reply: the block that was still being written is written for the last time, unwrapped.
pub fn close(self: *Answer) !void {
    try self.frame(finish);
}

fn finish(self: *Answer, width: usize) !void {
    try self.undo(width);
    var document = try markdown.read(self.gpa, self.text.items, self.writer, self.finished);
    defer document.deinit();
    for (document.blocks.items) |block| try self.writer.write(block.text);
    self.finished += document.blocks.items.len;
}

fn show(self: *Answer) !void {
    try self.frame(repaint);
}

fn repaint(self: *Answer, width: usize) !void {
    try self.undo(width);
    var document = try markdown.read(self.gpa, self.text.items, self.writer, self.finished);
    defer document.deinit();
    const blocks = document.blocks.items;
    if (blocks.len == 0) return;
    for (blocks[0 .. blocks.len - 1]) |block| try self.writer.write(block.text);
    self.finished += blocks.len - 1;
    try self.draw(blocks[blocks.len - 1].text, width);
}

/// Writes one frame: all of it is shown at once, so the taken-back block is never seen alone.
fn frame(self: *Answer, body: *const fn (self: *Answer, width: usize) anyerror!void) !void {
    // Once for the whole frame: laid out at two widths, the rows to take back would be neither's.
    const width = self.writer.width();
    // A frame is only worth declaring when something in it is drawn again and taken back.
    const bracketed = width > 0;
    if (bracketed) try self.writer.write(Writer.syncBegin(self.writer));
    body(self, width) catch |err| {
        if (bracketed) try self.writer.write(Writer.syncEnd(self.writer));
        try self.writer.flush();
        return err;
    };
    if (bracketed) try self.writer.write(Writer.syncEnd(self.writer));
    try self.writer.flush();
}

fn draw(self: *Answer, text: []const u8, width: usize) !void {
    if (width == 0) return;
    self.drawn_text.clearRetainingCapacity();
    try self.drawn_text.appendSlice(self.gpa, text);
    self.drawn = try terminal_width.wrap(text, self.writer.out, width);
}

/// Takes back the block that was being written, before what it says now is written.
fn undo(self: *Answer, width: usize) !void {
    const drawn = self.drawn orelse return;
    self.drawn = null;
    // The terminal re-wraps what it holds when it is resized, so the block is as many rows up as its
    // text takes now; but it cannot join the lines billy broke, so it is at least where it was drawn.
    const rows = @max(drawn.rows, try terminal_width.rows(self.drawn_text.items, width));
    if (rows > 0) try self.writer.print("\x1b[{d}A", .{rows});
    try self.writer.write("\r\x1b[0J");
}

fn screen(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(gpa);
    var row_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = sequenceEnd(text, i);
            const bytes = text[i + 2 .. end];
            if (std.mem.endsWith(u8, bytes, "A")) {
                const up = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch 0;
                var back: usize = 0;
                while (back < up and row_start > 0) : (back += 1) {
                    row_start = if (std.mem.findScalarLast(u8, shown.items[0 .. row_start - 1], '\n')) |at| at + 1 else 0;
                }
            } else if (std.mem.eql(u8, bytes, "0J")) {
                shown.shrinkRetainingCapacity(row_start);
            }
            i = end;
            continue;
        }
        if (text[i] == '\r') {
            i += 1;
            continue;
        }
        if (text[i] == '\n') row_start = shown.items.len + 1;
        try shown.append(gpa, text[i]);
        i += 1;
    }
    return shown.toOwnedSlice(gpa);
}

fn sequenceEnd(text: []const u8, at: usize) usize {
    var i = at + 2;
    while (i < text.len) : (i += 1) {
        if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
    }
    return text.len;
}

/// A delta as it arrives, and the width the terminal has when it does.
const Step = struct {
    text: []const u8,
    width: ?usize = null,
};

fn expectScreen(expected: []const u8, steps: []const Step) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var answer = Answer.open(gpa, .{ .style = .ansi, .out = &out.writer });
    defer answer.deinit();
    for (steps) |step| {
        if (step.width) |width| answer.writer.source = .{ .fixed = width };
        try answer.push(step.text);
    }
    try answer.close();
    const shown = try screen(gpa, out.written());
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(expected, shown);
}

test "the block still being written is written again as it grows" {
    try expectScreen("one two\n", &.{ .{ .text = "one", .width = 20 }, .{ .text = " two" } });
    try expectScreen("bold\n", &.{ .{ .text = "**bo", .width = 20 }, .{ .text = "ld**" } });
    try expectScreen("**bo\n", &.{.{ .text = "**bo", .width = 20 }});
}

test "a block that has finished is written once, and left to the terminal to wrap" {
    try expectScreen("one\n\ntwo\n", &.{ .{ .text = "one\n\n", .width = 20 }, .{ .text = "two" } });
    try expectScreen("aaaaaa\n", &.{ .{ .text = "aaa", .width = 4 }, .{ .text = "aaa" } });
}

test "a table is read again once the whole of it gives the columns their width" {
    try expectScreen(
        "name  age\n----  ---\nana   3\n",
        &.{
            .{ .text = "| na", .width = 40 },
            .{ .text = "me | age |\n| --- | ---" },
            .{ .text = " |\n| ana | 3 |" },
        },
    );
}

test "a block is written only when it is finished if the width cannot be known" {
    try expectScreen("one\n\ntwo\n", &.{ .{ .text = "one\n\n" }, .{ .text = "two" } });
}

test "a block drawn before the terminal grew is written again at the columns it has now" {
    try expectScreen(
        "one two three four\n",
        &.{ .{ .text = "one two three", .width = 6 }, .{ .text = " four", .width = 20 } },
    );
}

test "a block is taken back by the rows it takes at the width the terminal has now" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var answer = Answer.open(gpa, .{ .style = .ansi, .out = &out.writer });
    defer answer.deinit();

    answer.writer.source = .{ .fixed = 20 };
    try answer.push("one two three four");
    try std.testing.expectEqual(@as(?terminal_width.Laid, .{ .rows = 1 }), answer.drawn);

    out.clearRetainingCapacity();
    answer.writer.source = .{ .fixed = 4 };
    try answer.push(" five");
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[?2026h\x1b[5A\r\x1b[0J"));
}
