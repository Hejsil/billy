//! The agent loop: read a request from the user, ask the model, run the tools
//! it asks for, and repeat until it answers with text.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const line_editor = @import("line_editor.zig");
const session_mod = @import("session.zig");

pub const Config = struct {
    api_key: []const u8,
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    model: []const u8,
    /// Model turns allowed for one request before the harness gives up on it.
    max_turns: usize,
};

const system_prompt =
    \\You are a coding agent working in the user's project directory.
    \\Inspect the code before you change it, and use the tools to do the work.
    \\Reply with plain text when the task is done.
;

/// Printed in front of every line the user types. The transcript reuses it so a
/// replayed session looks like the run it continues.
const prompt = "> ";

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    config: Config,
    session: *session_mod.Session,
) !void {
    var editor = line_editor.LineEditor.init(io, out, arena);
    var tool_set = try tools.Tools.init(io, arena, gpa, out);
    var client: llm.Client = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .api_key = config.api_key,
        .url = config.url,
        .model = config.model,
    };

    // The prompt is added on every start and never stored, so it can change
    // without invalidating saved sessions.
    try session.messages.insert(arena, 0, .{ .role = "system", .content = system_prompt });

    while (true) {
        const line = (try editor.readLine(prompt)) orelse break;
        if (line.len == 0) continue;
        try session.append(.{ .role = "user", .content = line });
        // A failed request must not end the session: report it and take the
        // next request from the user.
        turn(&client, &tool_set, out, session, config.max_turns) catch |err|
            std.log.err("request failed: {s}", .{@errorName(err)});
    }
    try out.flush();
}

/// Replays a stored conversation the way a live session showed it, so a resumed
/// session reads exactly like the run it continues. The rendering is shared with
/// the loop: replies go through `printReply` and tool calls through
/// `tools.parseCall` and `tools.describe`, and the user prompt through `prompt`.
pub fn printTranscript(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    messages: []const llm.Message,
) !void {
    for (messages) |message| try printMessage(arena, out, message);
    try out.flush();
}

/// Prints one message the way a live session shows it. The system prompt and the
/// tool results are never shown while running, so they are left out here too.
fn printMessage(arena: std.mem.Allocator, out: *Io.Writer, message: llm.Message) !void {
    if (std.mem.eql(u8, message.role, "user")) {
        // Mirrors what the line editor leaves on screen for a submitted line.
        return out.print("\n{s}{s}\n", .{ prompt, message.content orelse "" });
    }
    if (!std.mem.eql(u8, message.role, "assistant")) return;
    if (message.tool_calls) |calls| {
        if (calls.len > 0) {
            for (calls) |call| {
                try tools.describe(tools.parseCall(arena, call), out);
                try out.writeAll("\n");
            }
            return;
        }
    }
    try printReply(out, message.content);
}

/// Runs the model until it replies with text instead of tool calls.
fn turn(
    client: *llm.Client,
    tool_set: *tools.Tools,
    out: *Io.Writer,
    session: *session_mod.Session,
    max_turns: usize,
) !void {
    var remaining: usize = max_turns;
    while (remaining > 0) : (remaining -= 1) {
        const message = try client.complete(session.messages.items, tool_set.definitions);
        try session.append(message);

        const calls = message.tool_calls orelse return printReply(out, message.content);
        if (calls.len == 0) return printReply(out, message.content);

        for (calls) |call| {
            try session.append(.{
                .role = "tool",
                .tool_call_id = call.id,
                .content = try tool_set.run(call),
            });
        }
    }
    try out.print("stopped after {d} turns without a final answer\n", .{max_turns});
    try out.flush();
}

fn printReply(out: *Io.Writer, content: ?[]const u8) !void {
    const text = content orelse "";
    if (text.len == 0) {
        try out.writeAll("(empty reply)\n");
    } else {
        try out.writeAll(text);
        try out.writeAll("\n");
    }
    try out.flush();
}

test "printTranscript replays messages the way a live session shows them" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const messages = [_]llm.Message{
        // The system prompt and the tool results are never shown while running.
        .{ .role = "system", .content = "ignore me" },
        .{ .role = "user", .content = "hello" },
        .{ .role = "assistant", .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
        .{ .role = "assistant", .content = "done" },
    };
    try printTranscript(arena_state.allocator(), &out.writer, &messages);

    try std.testing.expectEqualStrings(
        "\n> hello\n" ++
            "read a.zig\n" ++
            "done\n",
        out.written(),
    );
}

test "printTranscript leaves out the system prompt and tool results" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try printTranscript(arena_state.allocator(), &out.writer, &.{
        .{ .role = "system", .content = "ignore me" },
        .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
    });
    try std.testing.expectEqualStrings("", out.written());
}
