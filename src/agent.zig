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
        const line = (try editor.readLine("> ")) orelse break;
        if (line.len == 0) continue;
        try session.append(.{ .role = "user", .content = line });
        // A failed request must not end the session: report it and take the
        // next request from the user.
        turn(&client, &tool_set, out, session, config.max_turns) catch |err|
            std.log.err("request failed: {s}", .{@errorName(err)});
    }
    try out.flush();
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
