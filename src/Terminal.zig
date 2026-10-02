///! Shows blocks on the terminal, the way billy always has: the block headers, a
///! reply's markdown laid out by the format script, and the tools laid out by
///! theirs.
const std = @import("std");
const agent = @import("agent.zig");
const Tools = @import("Tools.zig");

pub const Style = @import("Terminal/style.zig").Style;
pub const Markdown = @import("Terminal/Markdown.zig");

const Terminal = @This();

out: *std.Io.Writer,
display: agent.Display,
/// For what showing a block builds, such as an edit's diff. Each block frees
/// what it takes, so nothing is kept between them.
scratch: std.mem.Allocator,
/// Whether a prompt opens with the blank line that sets it off from what came
/// before. Replaying a stored conversation wants it; a live prompt does not,
/// since the line editor has already ended the line the prompt is typed on.
replay: bool = false,

pub fn emitter(self: *Terminal) agent.Emitter {
    return .{ .context = self, .vtable = &.{ .block = show } };
}

fn show(context: *anyopaque, block: agent.Block) anyerror!void {
    const self = selfOf(context);
    switch (block) {
        .prompt => |text| {
            if (self.replay) try self.out.writeAll("\n");
            try printPrompt(self.scratch, self.out, text, self.display);
            // The prompt goes out as it is typed, before the request that
            // answers it, so what was sent is on screen while the model
            // works. Without this it waits in the buffer until the answer
            // or a tool call flushes it.
            try self.out.flush();
        },
        .answer => |content| try printAnswer(self.scratch, self.out, content, self.display),
        // The header goes out as the call begins, so a command that runs
        // long has it on screen while it runs.
        .tool_begin => |call| {
            try Tools.printHead(self.scratch, call, self.display.formats, self.display.style, self.out);
            try self.out.flush();
        },
        // The header is out already, so only the result is left; the blank
        // line ends the block as it always has.
        .tool_end => |tool| {
            try Tools.printResult(tool.call, tool.result, self.display.style, self.out);
            try self.out.writeAll("\n");
            try self.out.flush();
        },
        // The terminal stands the two in with one line rather than showing
        // them, which is what a compaction has always looked like here.
        .compacted => try printCompacted(self.out, self.display.style),
        .notice => |text| {
            try self.out.print("{s}\n", .{text});
            try self.out.flush();
        },
        .elided => |count| try printElided(count, self.display.style, self.out),
    }
}

fn selfOf(context: *anyopaque) *Terminal {
    return @ptrCast(@alignCast(context));
}

/// Prints a prompt as its own block: the `» prompt` header, then the text, laid
/// out by `markdown` when one is set, and a blank line after it. A live prompt
/// and a replayed one are both printed by this, so the two read the same. The
/// `> ` the line is typed behind is not part of the prompt and is not printed.
///
/// The blank line keeps the prompt from reading as the label of the answer or
/// the tool block that follows it, which begin on the very next row otherwise.
fn printPrompt(gpa: std.mem.Allocator, out: *std.Io.Writer, text: []const u8, display: agent.Display) !void {
    try marks.prompt.header("prompt", "", display.style, out);
    try Markdown.write(gpa, text, display.style, out);
    try out.writeAll("\n\n");
}

/// Prints a reply under its own header, laid out as markdown. Only the display
/// changes; the session and the model keep the text itself.
fn printAnswer(gpa: std.mem.Allocator, out: *std.Io.Writer, content: ?[]const u8, display: agent.Display) !void {
    try marks.answer.header("answer", "", display.style, out);
    const text = content orelse "";
    if (text.len == 0) {
        try display.style.dim("(empty reply)", out);
    } else {
        try Markdown.write(gpa, text, display.style, out);
    }
    try out.writeAll("\n");
    try out.flush();
}

/// Prints the one line that stands in for a compaction: the prompt that asked
/// for it and the summary it produced are both kept in the session, so a run
/// that compacts shows the event rather than the two messages. It is headed like
/// every other block, with its own mark, and opens with the blank line that
/// separates it from the block before it.
fn printCompacted(out: *std.Io.Writer, style: Style) !void {
    try out.writeAll("\n");
    try marks.compacted.header("compacted", "", style, out);
    try out.flush();
}

/// Prints how many blocks a trimmed transcript left out, dimmed, so a resume does
/// not read as the whole session. It is the count a short block gives of the
/// lines it cut, standing where the blocks it names would have been.
fn printElided(count: usize, style: Style, out: *std.Io.Writer) !void {
    try out.print("{s}… {d} earlier blocks{s}\n", .{ style.on("2"), count, style.off() });
}

/// The marks the messages of the transcript are headed by. None of them is a
/// tool, so none carries a tool's glyph.
/// The marks the blocks of a run are headed by, which is the vocabulary both
/// frontends show a block in: the terminal colours them and the web gives them
/// classes, but a prompt is a prompt in either.
pub const marks = struct {
    pub const prompt = Style.Mark{ .glyph = "»", .hue = .blue };
    pub const answer = Style.Mark{ .glyph = "◆", .hue = .green };
    /// The line a compaction shows as, standing in for the prompt that asked for
    /// it and the summary it produced.
    pub const compacted = Style.Mark{ .glyph = "⊟", .hue = .yellow };
};

test "a prompt is headed by the same block live and replayed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The block a replay shows, but with no blank line in front: it is printed
    // where the line editor left the cursor, on the row the header stood on.
    try printPrompt(gpa, &out.writer, "hello", .{ .style = .plain });
    try std.testing.expectEqualStrings("» prompt\nhello\n\n", out.written());
    out.clearRetainingCapacity();

    // A prompt is markdown, so it is laid out by the same renderer as a reply.
    try printPrompt(gpa, &out.writer, "**hello**", .{ .style = .ansi });
    try std.testing.expectEqualStrings(
        "\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\n\x1b[1mhello\x1b[0m\n\n",
        out.written(),
    );
}
