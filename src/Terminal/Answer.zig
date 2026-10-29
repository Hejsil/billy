//! A reply on the terminal as it arrives: the text is kept, markdown is read again from the start
//! every time more of it comes, and the block still being written is taken back and written again.
//! The blocks before it are written once, in the form the terminal wraps itself, and left alone.

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
/// What the block being written takes of the screen.
drawn: ?terminal_width.Laid = null,

pub fn open(gpa: std.mem.Allocator, writer: Writer) Answer {
    return .{ .gpa = gpa, .writer = writer };
}

pub fn deinit(self: *Answer) void {
    self.text.deinit(self.gpa);
}

/// Writes more of the reply, and what the whole of it now says.
pub fn push(self: *Answer, delta: []const u8) !void {
    try self.text.appendSlice(self.gpa, delta);
    try self.show();
}

/// Ends the reply: the block that was still being written is written for the last time, unwrapped.
pub fn close(self: *Answer) !void {
    try self.frame(finish);
}

fn finish(self: *Answer) !void {
    try self.undo();
    var document = try markdown.read(self.gpa, self.text.items, self.writer);
    defer document.deinit();
    for (document.blocks.items[self.finished..]) |block| try self.writer.write(block.text);
    self.finished = document.blocks.items.len;
}

fn show(self: *Answer) !void {
    try self.frame(repaint);
}

fn repaint(self: *Answer) !void {
    try self.undo();
    var document = try markdown.read(self.gpa, self.text.items, self.writer);
    defer document.deinit();
    const blocks = document.blocks.items;
    if (blocks.len <= self.finished) return;
    while (self.finished + 1 < blocks.len) : (self.finished += 1) {
        try self.writer.write(blocks[self.finished].text);
    }
    try self.draw(blocks[blocks.len - 1].text);
}

/// Writes one frame: all of it is shown at once, so the taken-back block is never seen alone.
fn frame(self: *Answer, body: *const fn (self: *Answer) anyerror!void) !void {
    // A frame is only worth declaring when something in it is drawn again and taken back.
    const bracketed = self.writer.width > 0;
    if (bracketed) try self.writer.write(Writer.syncBegin(self.writer));
    body(self) catch |err| {
        if (bracketed) try self.writer.write(Writer.syncEnd(self.writer));
        try self.writer.flush();
        return err;
    };
    if (bracketed) try self.writer.write(Writer.syncEnd(self.writer));
    try self.writer.flush();
}

fn draw(self: *Answer, text: []const u8) !void {
    if (self.writer.width == 0) return;
    self.drawn = try terminal_width.wrap(text, self.writer.out, self.writer.width);
}

/// Takes back the block that was being written, before what it says now is written.
fn undo(self: *Answer) !void {
    const drawn = self.drawn orelse return;
    self.drawn = null;
    if (drawn.rows > 0) try self.writer.print("\x1b[{d}A", .{drawn.rows});
    try self.writer.write("\r\x1b[0J");
}

/// What a terminal shows after `text` was written, so a test can say what a reply looks like.
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

fn expectScreen(expected: []const u8, deltas: []const []const u8, width: usize) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var answer = Answer.open(gpa, .{ .style = .ansi, .width = width, .out = &out.writer });
    defer answer.deinit();
    for (deltas) |delta| try answer.push(delta);
    try answer.close();
    const shown = try screen(gpa, out.written());
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(expected, shown);
}

test "the block still being written is written again as it grows" {
    try expectScreen("one two\n", &.{ "one", " two" }, 20);
    try expectScreen("bold\n", &.{ "**bo", "ld**" }, 20);
    try expectScreen("**bo\n", &.{"**bo"}, 20);
}

test "a block that has finished is written once, and left to the terminal to wrap" {
    try expectScreen("one\n\ntwo\n", &.{ "one\n\n", "two" }, 20);
    try expectScreen("aaaaaa\n", &.{ "aaa", "aaa" }, 4);
}

test "a table is read again once the whole of it gives the columns their width" {
    try expectScreen(
        "name  age\n----  ---\nana   3\n",
        &.{ "| na", "me | age |\n| --- | ---", " |\n| ana | 3 |" },
        40,
    );
}

test "a block is written only when it is finished if the width cannot be known" {
    try expectScreen("one\n\ntwo\n", &.{ "one\n\n", "two" }, 0);
}
