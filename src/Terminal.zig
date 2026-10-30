//! Shows blocks on the terminal, the way billy always has: the block headers, a reply's markdown
//! laid out by the built-in renderer, and the tools printed as they were written.
const std = @import("std");

const Agent = @import("Agent.zig");
const LineEditor = @import("LineEditor.zig");
const llm = @import("llm.zig");
const Session = @import("Session.zig");

pub const tool = @import("Terminal/tool.zig");

const Answer = @import("Terminal/Answer.zig");

pub const Markdown = @import("Terminal/Markdown.zig");
pub const Writer = @import("Terminal/Writer.zig");

const Terminal = @This();

io: std.Io,
writer: Writer,
scratch: std.mem.Allocator,
answer: ?Answer = null,
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
        if (self.answer == null and text.len > 0) try self.streamReasoning(text);
    }

    const text = delta.content orelse return;
    if (text.len == 0) return;

    try self.endReasoning();
    if (self.answer == null) {
        try marks.answer.header("answer", "", self.writer);
        self.answer = Answer.open(self.scratch, self.writer);
    }
    if (self.answer) |*answer| try answer.push(text);
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
    if (self.answer == null) return false;
    var answer = self.answer.?;
    self.answer = null;
    defer answer.deinit();

    const closed = answer.close();
    // The answer's last block ends its own line, so this is the blank line after it.
    try self.writer.write("\n");
    try self.writer.flush();
    try closed;
    return true;
}

fn dropStream(self: *Terminal) void {
    if (self.answer) |*answer| answer.deinit();
    self.answer = null;
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

/// Replays a stored conversation on the terminal as the blocks it was made of, so remembering the
/// context of an earlier run is not left to the user.
pub fn printTranscript(self: *Terminal, session: *const Session, blocks: usize) !void {
    try Agent.walk(self.scratch, session, blocks, self.emitter());
    try self.writer.flush();
}

const input_prompt = "> ";

/// Runs a session here: reads the line the user types, gives it to the agent, and shows what comes
/// back, until the input ends.
pub fn run(
    self: *Terminal,
    options: Agent.Options,
    session: *Session,
    http_client: *std.http.Client,
) !void {
    const io = self.io;
    const gpa = self.scratch;
    const out = self.writer;

    var agent = try Agent.init(io, gpa, options, session.cwd(), http_client);
    defer agent.deinit();
    const resumed = session.messages.items.len > 0;
    if (resumed) try agent.prepare(session);

    var editor = LineEditor.init(io, out.out, gpa);
    defer editor.deinit();

    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        header.clearRetainingCapacity();
        try header.writer.print("{f}", .{Agent.SessionHeader.of(
            session,
            Agent.sessionModel(options.catalog, session, options.config.stored.model),
            options.home,
        )});
        const line = (try editor.readLine(header.written(), input_prompt)) orelse break;
        if (line.len == 0) continue;
        const waiting = try agent.take(self.emitter(), session, line);
        const text = switch (waiting) {
            .prompt => |asked| asked.text,
            .ran, .unresolved => {
                try out.flush();
                continue;
            },
        };
        agent.ask(self.emitter(), session, text) catch |err|
            std.log.err("could not show the turn: {t}", .{err});
        try out.flush();
    }
    try out.flush();
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

    // One paragraph, so nothing is a block yet: a block is only written once it has ended.
    try emit.showDelta(.{ .content = "lo\n**world**\n" });
    try std.testing.expectEqualStrings("◆ answer\n", out.written());

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

fn expectTranscript(
    expected: []const u8,
    messages: []const llm.Message,
    style: Writer.Style,
) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Plain, since what these cover is how a message is headed and laid out rather than how a
    // terminal decorates it.
    var terminal = Terminal{
        .writer = .{ .style = style, .out = &out.writer },
        .io = io,
        .scratch = gpa,
    };
    defer terminal.deinit();
    try terminal.printTranscript(&session, 0);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a transcript shows only the last blocks and counts the rest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
    } });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "contents a" });
    try session.append(.{ .role = .tool, .tool_call_id = "call_2", .content = "contents b" });
    try session.append(.{ .role = .assistant, .content = "done" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = Terminal{ .writer = .{ .out = &out.writer }, .io = io, .scratch = gpa };
    defer terminal.deinit();

    try terminal.printTranscript(&session, 2);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n\n" ++
            "▸ read b.zig\n▾ output\ncontents b\n\n" ++
            "◆ answer\ndone\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try terminal.printTranscript(&session, 10);
    try std.testing.expect(std.mem.find(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
    out.clearRetainingCapacity();

    try terminal.printTranscript(&session, 0);
    try std.testing.expect(std.mem.find(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
}

test "a transcript replays a conversation as the blocks it was made of" {
    // The system prompt is never shown while running, the tool result only as the output of the
    // call it belongs to.
    try expectTranscript(
        "» prompt\nhello\n\n" ++
            "▸ read a.zig\n▾ output\n1\tconst x = 1;\n\n" ++
            "◆ answer\ndone\n\n",
        &.{
            .{ .role = .system, .content = "ignore me" },
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "call_1",
                .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
            }} },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
            .{ .role = .assistant, .content = "done" },
        },
        .plain,
    );
}

test "a transcript leaves out the system prompt and an unpaired tool result" {
    // A result whose call is not in the session has nothing to belong to, and a system prompt is
    // never shown at all.
    try expectTranscript(
        "",
        &.{
            .{ .role = .system, .content = "ignore me" },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
        },
        .plain,
    );
}

test "a transcript shows a compaction as a single line" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .content = "a1" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = .user, .content = "two" });
    try session.append(.{ .role = .assistant, .content = "a2" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = Terminal{ .writer = .{ .out = &out.writer }, .io = io, .scratch = gpa };
    defer terminal.deinit();

    try terminal.printTranscript(&session, 0);
    try std.testing.expectEqualStrings(
        "» prompt\none\n\n" ++
            "◆ answer\na1\n\n" ++
            "⊟ compacted\n\n" ++
            "» prompt\ntwo\n\n" ++
            "◆ answer\na2\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try terminal.printTranscript(&session, 3);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n\n" ++
            "⊟ compacted\n\n" ++
            "» prompt\ntwo\n\n" ++
            "◆ answer\na2\n\n",
        out.written(),
    );
}

test "a compaction is headed by its own mark, and hides what it stands for" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "hi" });
    try session.appendCompaction("ASKEDFORTHEcompaction", "THESUMMARYTEXT");
    try session.append(.{ .role = .user, .content = "next" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = Terminal{ .writer = .{ .style = .ansi, .out = &out.writer }, .io = io, .scratch = gpa };
    defer terminal.deinit();
    try terminal.printTranscript(&session, 0);

    try std.testing.expect(std.mem.find(u8, out.written(), "\x1b[33m⊟\x1b[0m \x1b[1mcompacted\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "ASKEDFORTHEcompaction") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "THESUMMARYTEXT") == null);
}

test "a transcript gives each call the result that names it" {
    try expectTranscript(
        "▸ read a.zig\n▾ output\ncontents of a\n\n" ++
            "▸ read b.zig\n▾ output\ncontents of b\n\n",
        &.{
            .{ .role = .assistant, .tool_calls = &.{
                .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
                .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
            } },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "contents of a" },
            .{ .role = .tool, .tool_call_id = "call_2", .content = "contents of b" },
        },
        .plain,
    );
}

test "a transcript rebuilds an edit's diff from the stored call" {
    try expectTranscript(
        "✎ edit a.zig\n▾ diff\n-old\n+new\n\n",
        &.{
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "call_1",
                .function = .{
                    .name = "edit",
                    .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
                },
            }} },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "replaced 1 occurrence(s) in a.zig" },
        },
        .plain,
    );
}

test "a reply is headed by its own header, and its markdown laid out" {
    try expectTranscript(
        "◆ answer\nhi\n\n",
        &.{.{ .role = .assistant, .content = "**hi**" }},
        .plain,
    );

    try expectTranscript(
        "◆ answer\n(empty reply)\n\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt from the session is headed and laid out like a reply" {
    try expectTranscript(
        "» prompt\nhi\n\n",
        &.{.{ .role = .user, .content = "**hi**" }},
        .plain,
    );
}

test "an empty reply is shown under its header, in place of the text" {
    try expectTranscript(
        "◆ answer\n(empty reply)\n\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt and a reply are headed alike, in the colours of the display" {
    try expectTranscript(
        "\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\nhello\n\n" ++
            "\x1b[32m◆\x1b[0m \x1b[1manswer\x1b[0m\nhi\n\n",
        &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi" },
        },
        .ansi,
    );
}
