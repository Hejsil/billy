//! Shows blocks on the terminal, the way billy always has: the block headers, a
//! reply's markdown laid out by the built-in renderer, and the tools printed as
//! they were written.
const std = @import("std");
const agent = @import("Agent.zig");

pub const tool = @import("Terminal/tool.zig");

pub const Writer = @import("Terminal/Writer.zig");
pub const Markdown = @import("Terminal/Markdown.zig");

const Terminal = @This();

io: std.Io,
/// Where the blocks go, and the style they are decorated in. Everything shown is
/// written through it, so a plain writer shows the same blocks with no escape
/// codes in them.
writer: Writer,
/// For what showing a block builds, such as an edit's diff. Each block frees
/// what it takes, so nothing is kept between them.
scratch: std.mem.Allocator,

pub fn emitter(self: *Terminal) agent.Emitter {
    return .{ .context = self, .vtable = &.{ .block = show } };
}

/// Shows one block. Each whole block ends with a blank line that sets it off
/// from whatever follows, so the block after reads as its own unit and the line
/// editor's prompt has a row between it and the block above. A tool call is two
/// blocks: the head ends with its own line alone, since the result continues
/// it, and the result ends the call with the blank line.
fn show(context: *anyopaque, block: agent.Block) anyerror!void {
    const self = selfOf(context);
    switch (block) {
        .prompt => |text| {
            try printPrompt(self.scratch, self.writer, text);
            // The prompt goes out as it is typed, before the request that
            // answers it, so what was sent is on screen while the model
            // works. Without this it waits in the buffer until the answer
            // or a tool call flushes it.
            try self.writer.flush();
        },
        .answer => |content| try printAnswer(self.scratch, self.writer, content),
        // The header goes out as the call begins, so a command that runs
        // long has it on screen while it runs.
        .tool_begin => |call| {
            try tool.printHead(self.scratch, call, self.writer);
            try self.writer.flush();
        },
        // The header is out already, so only the result is left; the blank
        // line ends the block as it always has.
        .tool_end => |ended| {
            try tool.printResult(ended.call, ended.result, self.writer);
            try self.writer.write("\n");
            try self.writer.flush();
        },
        // The terminal stands the two in with one line rather than showing
        // them, which is what a compaction has always looked like here.
        .compacted => try printCompacted(self.writer),
        .notice => |text| {
            try self.writer.print("{s}\n\n", .{text});
            try self.writer.flush();
        },
        .elided => |count| try printElided(count, self.writer),
    }
}

fn selfOf(context: *anyopaque) *Terminal {
    return @ptrCast(@alignCast(context));
}

/// Prints a prompt as its own block: the `» prompt` header, the text laid out by
/// `markdown` when one is set, and the blank line after it. A live prompt and a
/// replayed one are both printed by this, so the two read the same. The `> ` the
/// line is typed behind is not part of the prompt and is not printed.
fn printPrompt(gpa: std.mem.Allocator, writer: Writer, text: []const u8) !void {
    try marks.prompt.header("prompt", "", writer);
    try Markdown.write(gpa, text, writer);
    try writer.write("\n\n");
}

/// Prints a reply under its own header, laid out as markdown, and the blank
/// line that ends the block. Only the display changes; the session and the model
/// keep the text itself.
fn printAnswer(gpa: std.mem.Allocator, writer: Writer, content: ?[]const u8) !void {
    try marks.answer.header("answer", "", writer);
    const text = content orelse "";
    if (text.len == 0) {
        try writer.print("{s}(empty reply){s}", .{ writer.dim(), writer.reset() });
    } else {
        try Markdown.write(gpa, text, writer);
    }
    try writer.write("\n\n");
    try writer.flush();
}

/// Prints the one line that stands in for a compaction: the prompt that asked
/// for it and the summary it produced are both kept in the session, so a run
/// that compacts shows the event rather than the two messages. It is headed like
/// every other block, with its own mark, and ends with the blank line that sets
/// it off from the block after it.
fn printCompacted(writer: Writer) !void {
    try marks.compacted.header("compacted", "", writer);
    try writer.write("\n");
    try writer.flush();
}

/// Prints how many blocks a trimmed transcript left out, dimmed, so a resume does
/// not read as the whole session. It is the count a short block gives of the
/// lines it cut, standing where the blocks it names would have been, with the
/// blank line that sets off the blocks that follow.
fn printElided(count: usize, writer: Writer) !void {
    try writer.print("{s}… {d} earlier blocks{s}\n\n", .{ writer.dim(), count, writer.reset() });
}

/// The marks the blocks of a run are headed by, which is the vocabulary both
/// frontends show a block in: the terminal colours them and the web gives them
/// classes, but a prompt is a prompt in either.
pub const marks = struct {
    pub const prompt = Writer.Mark{ .glyph = "»", .hue = .blue };
    pub const answer = Writer.Mark{ .glyph = "◆", .hue = .green };
    /// The line a compaction shows as, standing in for the prompt that asked for
    /// it and the summary it produced.
    pub const compacted = Writer.Mark{ .glyph = "⊟", .hue = .yellow };
};

test "a prompt is headed by the same block live and replayed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The block is the header, the text and the blank line that ends it.
    const plain: Writer = .{ .out = &out.writer };
    try printPrompt(gpa, plain, "hello");
    try std.testing.expectEqualStrings("» prompt\nhello\n\n", out.written());
    out.clearRetainingCapacity();

    // A prompt is markdown, so it is laid out by the same renderer as a reply.
    const ansi: Writer = .{ .style = .ansi, .out = &out.writer };
    try printPrompt(gpa, ansi, "**hello**");
    try std.testing.expectEqualStrings(
        "\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\n\x1b[1mhello\x1b[0m\n\n",
        out.written(),
    );
}
