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
/// The answer the model is still writing, once its first fragment has arrived.
/// Its text goes out as it comes, so the reply is on screen while it is made;
/// the `answer` block that follows then only ends the block rather than writing
/// the text again. Null when no fragment has arrived, in which case the answer
/// is written whole by the block.
stream: ?Markdown.Stream = null,
/// Whether the model's reasoning is being shown, and whether its last write
/// ended a line, so the blank line that closes the block is not doubled.
reasoning: bool = false,
reasoning_at_line_start: bool = true,

pub fn emitter(self: *Terminal) agent.Emitter {
    return .{ .context = self, .vtable = &.{ .block = show, .delta = showDelta } };
}

/// Drops a streamed answer or reasoning block that will not be finished, so a
/// run that ends early leaves nothing held and the terminal is not left dim.
pub fn deinit(self: *Terminal) void {
    self.dropReasoning();
    self.dropStream();
}

/// Shows one fragment of an answer or its reasoning as the model writes it.
///
/// Reasoning is written dim under its own header, a fragment at a time, so it
/// appears as it is thought. The first answer fragment ends it, opens the answer
/// block, and continues there. Each fragment is flushed at once, which is what
/// puts it on screen before the model has finished.
fn showDelta(context: *anyopaque, delta: agent.Delta) anyerror!void {
    const self = selfOf(context);

    if (delta.reasoning) |text| {
        // Reasoning that arrives after the answer has begun would split the
        // answer block, so it is left out; providers send it first.
        if (self.stream == null and text.len > 0) try self.streamReasoning(text);
    }

    const text = delta.content orelse return;
    if (text.len == 0) return;

    try self.endReasoning();
    if (self.stream == null) {
        try marks.answer.header("answer", "", self.writer);
        self.stream = try Markdown.Stream.open(self.scratch, self.writer);
    }
    if (self.stream) |*stream| try stream.feed(text);
    try self.writer.flush();
}

/// Writes more of the model's reasoning under its header, dim and as it comes.
fn streamReasoning(self: *Terminal, text: []const u8) !void {
    if (!self.reasoning) {
        try marks.reasoning.header("reasoning", "", self.writer);
        // The code stays open across fragments, so the whole block is dim.
        try self.writer.write(self.writer.dim());
        self.reasoning = true;
        self.reasoning_at_line_start = true;
    }
    try self.writer.write(text);
    self.reasoning_at_line_start = text[text.len - 1] == '\n';
    try self.writer.flush();
}

/// Ends the reasoning block, if one is open: turns the dim off and writes the
/// blank line that sets the block off from what follows.
fn endReasoning(self: *Terminal) !void {
    if (!self.reasoning) return;
    self.reasoning = false;

    try self.writer.write(self.writer.reset());
    if (!self.reasoning_at_line_start) try self.writer.write("\n");
    try self.writer.write("\n");
    try self.writer.flush();
}

/// Drops an open reasoning block without writing more of it, turning the dim
/// off so the rest of the run is not left looking like reasoning.
fn dropReasoning(self: *Terminal) void {
    if (!self.reasoning) return;
    self.reasoning = false;
    self.writer.write(self.writer.reset()) catch {};
    self.writer.flush() catch {};
}

/// Ends a streamed answer, if one is being written: writes its last line and
/// closes it, then the blank line that sets the block off from what follows.
/// Returns whether there was an answer being streamed.
fn endStream(self: *Terminal) !bool {
    if (self.stream == null) return false;
    var stream = self.stream.?;
    self.stream = null;

    // `close` writes the rest of the reply and frees what the stream held,
    // whichever way it goes, so the block is finished before the error is
    // reported.
    const closed = stream.close();
    try self.writer.write("\n\n");
    try self.writer.flush();
    try closed;
    return true;
}

/// Drops a streamed answer without writing the rest of it, for a run that ends
/// without an answer.
fn dropStream(self: *Terminal) void {
    if (self.stream) |*stream| stream.deinit();
    self.stream = null;
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
            // A prompt begins a turn, so nothing can still be streaming from the
            // last one.
            try self.endReasoning();
            self.dropStream();
            try printPrompt(self.scratch, self.writer, text);
            // The prompt goes out as it is typed, before the request that
            // answers it, so what was sent is on screen while the model
            // works. Without this it waits in the buffer until the answer
            // or a tool call flushes it.
            try self.writer.flush();
        },
        // A reply that was streamed is already on screen; only the blank line
        // that ends its block is left. One that was not is written whole, which
        // is how a replayed session shows it.
        .answer => |content| {
            if (try self.endStream()) return;
            try printAnswer(self.scratch, self.writer, content);
        },
        // The header goes out as the call begins, so a command that runs
        // long has it on screen while it runs. A reply that said something
        // before asking for the call is ended first, so the two read as the
        // separate blocks they are.
        .tool_begin => |call| {
            _ = try self.endReasoning();
            _ = try self.endStream();
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
        .compacted => {
            try self.endReasoning();
            self.dropStream();
            try printCompacted(self.writer);
        },
        // A notice can end a turn that had already streamed part of an answer,
        // so the answer is ended before the line that says why.
        .notice => |text| {
            _ = try self.endReasoning();
            _ = try self.endStream();
            try self.writer.print("{s}\n\n", .{text});
            try self.writer.flush();
        },
        .elided => |count| {
            try self.endReasoning();
            self.dropStream();
            try printElided(count, self.writer);
        },
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
    /// The model's own thinking, shown dim before the answer it leads to.
    pub const reasoning = Writer.Mark{ .glyph = "◇", .hue = .magenta };
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

test "a streamed answer is written as it arrives, and is not written again" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var terminal = Terminal{ .writer = .{ .out = &out.writer }, .io = undefined, .scratch = gpa };
    defer terminal.deinit();
    const emit = terminal.emitter();

    // The first fragment opens the block. Its text waits for a complete line,
    // which is the smallest unit the streaming parser writes.
    try emit.showDelta(.{ .content = "hel" });
    try std.testing.expectEqualStrings("◆ answer\n", out.written());

    // The newline lets the first line out. The line after it is held, because
    // the parser cannot know yet whether it ends the paragraph, so it is written
    // when the block ends.
    try emit.showDelta(.{ .content = "lo\n**world**\n" });
    try std.testing.expectEqualStrings("◆ answer\nhello", out.written());

    // The answer block carries the whole reply, but it has already been shown,
    // so only the blank line that ends the block is left to write.
    try emit.show(.{ .answer = "hello\n**world**\n" });
    try std.testing.expectEqualStrings("◆ answer\nhello\nworld\n\n", out.written());
}

test "streamed reasoning is shown before the answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var terminal = Terminal{ .writer = .{ .out = &out.writer }, .io = undefined, .scratch = gpa };
    defer terminal.deinit();
    const emit = terminal.emitter();

    // Reasoning opens its own block and is written as it comes, not held for a
    // complete line the way markdown is.
    try emit.showDelta(.{ .reasoning = "I should check.\n" });
    try std.testing.expectEqualStrings("◇ reasoning\nI should check.\n", out.written());

    // The first answer fragment closes it and opens the answer block. Its line
    // is held until the paragraph ends, as a streamed answer's last line is.
    try emit.showDelta(.{ .content = "hello\n" });
    try std.testing.expectEqualStrings(
        "◇ reasoning\nI should check.\n\n◆ answer\n",
        out.written(),
    );

    try emit.show(.{ .answer = "hello\n" });
    try std.testing.expectEqualStrings(
        "◇ reasoning\nI should check.\n\n◆ answer\nhello\n\n",
        out.written(),
    );
}

test "reasoning is dim and the answer is not" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var terminal = Terminal{
        .writer = .{ .style = .ansi, .out = &out.writer },
        .io = undefined,
        .scratch = gpa,
    };
    defer terminal.deinit();
    const emit = terminal.emitter();

    try emit.showDelta(.{ .reasoning = "think" });
    try std.testing.expectEqualStrings(
        "\x1b[35m◇\x1b[0m \x1b[1mreasoning\x1b[0m\n\x1b[2mthink",
        out.written(),
    );

    // The dim is turned off before the blank line and the answer's header.
    try emit.showDelta(.{ .content = "hi" });
    try std.testing.expectEqualStrings(
        "\x1b[35m◇\x1b[0m \x1b[1mreasoning\x1b[0m\n\x1b[2mthink\x1b[0m\n\n" ++
            "\x1b[32m◆\x1b[0m \x1b[1manswer\x1b[0m\n",
        out.written(),
    );
}

test "an answer with no fragments is written whole" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var terminal = Terminal{ .writer = .{ .out = &out.writer }, .io = undefined, .scratch = gpa };
    defer terminal.deinit();

    try terminal.emitter().show(.{ .answer = "**hi**" });
    try std.testing.expectEqualStrings("◆ answer\nhi\n\n", out.written());
}
