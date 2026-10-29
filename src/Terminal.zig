//! Shows blocks on the terminal, the way billy always has: the block headers, a reply's markdown
//! laid out by the built-in renderer, and the tools printed as they were written.
const std = @import("std");

const Agent = @import("Agent.zig");

pub const tool = @import("Terminal/tool.zig");

pub const Markdown = @import("Terminal/Markdown.zig");
pub const Writer = @import("Terminal/Writer.zig");

const Terminal = @This();

io: std.Io,
writer: Writer,
scratch: std.mem.Allocator,
stream: ?Markdown.Stream = null,
reasoning: bool = false,
reasoning_at_line_start: bool = true,
interface: Agent.Emitter = .{ .vtable = &vtable },

const vtable: Agent.Emitter.VTable = .{ .block = show, .delta = showDelta };

pub fn emitter(self: *Terminal) *Agent.Emitter {
    return &self.interface;
}

/// Drops a streamed answer or reasoning block that will not be finished, so a run that ends early
/// leaves nothing held and the terminal is not left dim.
pub fn deinit(self: *Terminal) void {
    self.dropStream();
}

fn showDelta(e: *Agent.Emitter, delta: Agent.Delta) anyerror!void {
    const self = selfOf(e);

    if (delta.reasoning) |text| {
        // Reasoning that arrives after the answer has begun would split the answer block, so it is
        // left out; providers send it first.
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

fn streamReasoning(self: *Terminal, text: []const u8) !void {
    if (!self.reasoning) {
        try marks.reasoning.header("reasoning", "", self.writer);
        try self.writer.write(self.writer.dim());
        self.reasoning = true;
        self.reasoning_at_line_start = true;
    }
    try self.writer.write(text);
    self.reasoning_at_line_start = text[text.len - 1] == '\n';
    try self.writer.flush();
}

fn endReasoning(self: *Terminal) !void {
    if (!self.reasoning) return;
    self.reasoning = false;

    try self.writer.write(self.writer.reset());
    if (!self.reasoning_at_line_start) try self.writer.write("\n");
    try self.writer.write("\n");
    try self.writer.flush();
}

fn endStream(self: *Terminal) !bool {
    if (self.stream == null) return false;
    var stream = self.stream.?;
    self.stream = null;

    const closed = stream.close();
    try self.writer.write("\n\n");
    try self.writer.flush();
    try closed;
    return true;
}

fn dropStream(self: *Terminal) void {
    if (self.stream) |*stream| stream.deinit();
    self.stream = null;
}

fn show(e: *Agent.Emitter, block: Agent.Block) anyerror!void {
    const self = selfOf(e);
    switch (block) {
        .prompt => |text| {
            try self.endReasoning();
            self.dropStream();
            try printPrompt(self.scratch, self.writer, text);
            try self.writer.flush();
        },
        .answer => |content| {
            if (try self.endStream()) return;
            try self.endReasoning();
            try printAnswer(self.scratch, self.writer, content);
        },
        .tool_begin => |call| {
            _ = try self.endReasoning();
            _ = try self.endStream();
            try tool.printHead(self.scratch, call, self.writer);
            try self.writer.flush();
        },
        .tool_end => |ended| {
            try tool.printResult(ended.call, ended.result, self.writer);
            try self.writer.write("\n");
            try self.writer.flush();
        },
        // The terminal stands the two in with one line rather than showing them, which is what a
        // compaction has always looked like here.
        .compacted => {
            try self.endReasoning();
            self.dropStream();
            try printCompacted(self.writer);
        },
        .notice => |text| {
            _ = try self.endReasoning();
            _ = try self.endStream();
            try self.writer.print("{s}\n\n", .{text});
            try self.writer.flush();
        },
        .hidden => |count| {
            try self.endReasoning();
            self.dropStream();
            try printElided(count, self.writer);
        },
    }
}

fn selfOf(e: *Agent.Emitter) *Terminal {
    return @alignCast(@fieldParentPtr("interface", e));
}

fn printPrompt(gpa: std.mem.Allocator, writer: Writer, text: []const u8) !void {
    try marks.prompt.header("prompt", "", writer);
    try Markdown.write(gpa, text, writer);
    try writer.write("\n\n");
}

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

fn printCompacted(writer: Writer) !void {
    try marks.compacted.header("compacted", "", writer);
    try writer.write("\n");
    try writer.flush();
}

fn printElided(count: usize, writer: Writer) !void {
    try writer.print("{s}… {d} earlier blocks{s}\n\n", .{ writer.dim(), count, writer.reset() });
}

/// The marks the blocks of a run are headed by, which is the vocabulary both frontends show a block
/// in: the terminal colours them and the web gives them classes, but a prompt is a prompt in
/// either.
pub const marks = struct {
    pub const prompt = Writer.Mark{ .glyph = "»", .hue = .blue };
    pub const answer = Writer.Mark{ .glyph = "◆", .hue = .green };
    /// The model's own thinking, shown dim before the answer it leads to.
    pub const reasoning = Writer.Mark{ .glyph = "◇", .hue = .magenta };
    /// The line a compaction shows as, standing in for the prompt that asked for it and the summary
    /// it produced.
    pub const compacted = Writer.Mark{ .glyph = "⊟", .hue = .yellow };
};

test "a prompt is headed by the same block live and replayed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const plain: Writer = .{ .out = &out.writer };
    try printPrompt(gpa, plain, "hello");
    try std.testing.expectEqualStrings("» prompt\nhello\n\n", out.written());
    out.clearRetainingCapacity();

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

    try emit.showDelta(.{ .content = "hel" });
    try std.testing.expectEqualStrings("◆ answer\n", out.written());

    // The newline lets the first line out.
    try emit.showDelta(.{ .content = "lo\n**world**\n" });
    try std.testing.expectEqualStrings("◆ answer\nhello", out.written());

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

    try emit.showDelta(.{ .reasoning = "I should check.\n" });
    try std.testing.expectEqualStrings("◇ reasoning\nI should check.\n", out.written());

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

test "an answer that arrives as a block ends the reasoning before it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var terminal = Terminal{ .writer = .{ .style = .ansi, .out = &out.writer }, .io = undefined, .scratch = gpa };
    defer terminal.deinit();
    const emit = terminal.emitter();

    try emit.showDelta(.{ .reasoning = "think" });
    try emit.show(.{ .answer = "done" });
    try std.testing.expectEqualStrings(
        "\x1b[35m◇\x1b[0m \x1b[1mreasoning\x1b[0m\n\x1b[2mthink\x1b[0m\n\n" ++
            "\x1b[32m◆\x1b[0m \x1b[1manswer\x1b[0m\ndone\n\n",
        out.written(),
    );
}
