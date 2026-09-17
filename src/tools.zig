//! The tools the agent can call, together with their JSON Schema descriptions.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");

/// Longest result handed back to the model, so one command cannot flood the
/// conversation.
const max_result_len = 30_000;
/// Longest output captured from one command.
const max_command_output = 1 << 20;
/// A command that outlives this is killed, so the agent cannot hang forever.
const command_timeout_s = 120;

pub const Tools = struct {
    io: Io,
    /// Holds results, which are kept in the conversation.
    arena: std.mem.Allocator,
    /// For temporary buffers.
    gpa: std.mem.Allocator,
    /// Reports tool activity to the user.
    log: *Io.Writer,
    definitions: []const llm.Tool,

    pub fn init(
        io: Io,
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        log: *Io.Writer,
    ) !Tools {
        return .{
            .io = io,
            .arena = arena,
            .gpa = gpa,
            .log = log,
            .definitions = try definitions(arena),
        };
    }

    /// Runs one tool call and returns its result. Tool failures are reported to
    /// the model as text so that it can react to them.
    pub fn run(tools: *Tools, call: llm.ToolCall) ![]const u8 {
        const name = call.function.name;
        if (std.mem.eql(u8, name, "read")) return tools.read(call.function.arguments);
        if (std.mem.eql(u8, name, "write")) return tools.write(call.function.arguments);
        if (std.mem.eql(u8, name, "edit")) return tools.edit(call.function.arguments);
        if (std.mem.eql(u8, name, "bash")) return tools.bash(call.function.arguments);
        return tools.fail("unknown tool '{s}'", .{name});
    }

    fn read(tools: *Tools, arguments: []const u8) ![]const u8 {
        const Args = struct {
            path: []const u8,
            offset: ?usize = null,
            limit: ?usize = null,
        };
        const args = std.json.parseFromSliceLeaky(Args, tools.arena, arguments, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| return tools.invalid("read", err);
        try tools.log.print("read {s}\n", .{args.path});
        try tools.log.flush();

        const contents = std.Io.Dir.cwd().readFileAlloc(
            tools.io,
            args.path,
            tools.gpa,
            .limited(16 << 20),
        ) catch |err| return tools.fail("cannot read {s}: {s}", .{ args.path, @errorName(err) });
        defer tools.gpa.free(contents);

        // A trailing newline would otherwise read as a final empty line.
        const text = std.mem.trimEnd(u8, contents, "\n");
        if (text.len == 0) return tools.arena.dupe(u8, "(empty file)");

        const first = args.offset orelse 1;
        const limit = args.limit orelse 2000;
        var out: std.Io.Writer.Allocating = .init(tools.gpa);
        defer out.deinit();

        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        var shown: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            if (number < first) continue;
            if (shown == limit) break;
            shown += 1;
            try out.writer.print("{d:>6}\t{s}\n", .{ number, line });
        }
        if (shown == 0) {
            return std.fmt.allocPrint(tools.arena, "offset {d} is past the end; {d} lines", .{ first, number });
        }
        if (shown == limit) {
            try out.writer.print("... {d} more lines\n", .{number - first + 1 - shown});
        }
        return tools.finish(out.written());
    }

    fn write(tools: *Tools, arguments: []const u8) ![]const u8 {
        const Args = struct {
            path: []const u8,
            content: []const u8,
        };
        const args = std.json.parseFromSliceLeaky(Args, tools.arena, arguments, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| return tools.invalid("write", err);
        try tools.log.print("write {s} ({d} bytes)\n", .{ args.path, args.content.len });
        try tools.log.flush();

        if (std.fs.path.dirname(args.path)) |parent| {
            std.Io.Dir.cwd().createDirPath(tools.io, parent) catch |err|
                return tools.fail("cannot create {s}: {s}", .{ parent, @errorName(err) });
        }
        std.Io.Dir.cwd().writeFile(tools.io, .{ .sub_path = args.path, .data = args.content }) catch |err|
            return tools.fail("cannot write {s}: {s}", .{ args.path, @errorName(err) });
        return std.fmt.allocPrint(tools.arena, "wrote {d} bytes to {s}", .{ args.content.len, args.path });
    }

    fn edit(tools: *Tools, arguments: []const u8) ![]const u8 {
        const Args = struct {
            path: []const u8,
            old_string: []const u8,
            new_string: []const u8,
            replace_all: bool = false,
        };
        const args = std.json.parseFromSliceLeaky(Args, tools.arena, arguments, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| return tools.invalid("edit", err);
        try tools.log.print("edit {s}\n", .{args.path});
        try tools.log.flush();

        if (args.old_string.len == 0) return tools.fail("old_string must not be empty", .{});

        const contents = std.Io.Dir.cwd().readFileAlloc(
            tools.io,
            args.path,
            tools.gpa,
            .limited(16 << 20),
        ) catch |err| return tools.fail("cannot read {s}: {s}", .{ args.path, @errorName(err) });
        defer tools.gpa.free(contents);

        const found = std.mem.count(u8, contents, args.old_string);
        if (found == 0) return tools.fail("old_string not found in {s}", .{args.path});
        if (found > 1 and !args.replace_all) {
            return tools.fail(
                "old_string appears {d} times in {s}; add context or pass replace_all",
                .{ found, args.path },
            );
        }

        const updated = if (args.replace_all)
            try std.mem.replaceOwned(u8, tools.gpa, contents, args.old_string, args.new_string)
        else blk: {
            const at = std.mem.indexOf(u8, contents, args.old_string).?;
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(tools.gpa, contents[0..at]);
            try list.appendSlice(tools.gpa, args.new_string);
            try list.appendSlice(tools.gpa, contents[at + args.old_string.len ..]);
            break :blk try list.toOwnedSlice(tools.gpa);
        };
        defer tools.gpa.free(updated);

        std.Io.Dir.cwd().writeFile(tools.io, .{ .sub_path = args.path, .data = updated }) catch |err|
            return tools.fail("cannot write {s}: {s}", .{ args.path, @errorName(err) });
        return std.fmt.allocPrint(tools.arena, "replaced {d} occurrence(s) in {s}", .{ found, args.path });
    }

    fn bash(tools: *Tools, arguments: []const u8) ![]const u8 {
        const Args = struct { command: []const u8 };
        const args = std.json.parseFromSliceLeaky(Args, tools.arena, arguments, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| return tools.invalid("bash", err);
        try tools.log.print("$ {s}\n", .{args.command});
        try tools.log.flush();

        const result = std.process.run(tools.gpa, tools.io, .{
            .argv = &.{ "bash", "-c", args.command },
            .stdout_limit = .limited(max_command_output),
            .stderr_limit = .limited(max_command_output),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(command_timeout_s) } },
        }) catch |err| switch (err) {
            error.StreamTooLong => return tools.fail(
                "command produced more than {d} bytes of output",
                .{max_command_output},
            ),
            else => return tools.fail("cannot run command: {s}", .{@errorName(err)}),
        };
        defer tools.gpa.free(result.stdout);
        defer tools.gpa.free(result.stderr);

        var out: std.Io.Writer.Allocating = .init(tools.gpa);
        defer out.deinit();
        try out.writer.print("exit code: {d}\n", .{exitCode(result.term)});
        if (result.stdout.len == 0 and result.stderr.len == 0) {
            try out.writer.writeAll("(no output)\n");
        }
        try out.writer.writeAll(result.stdout);
        if (result.stderr.len > 0) {
            if (result.stdout.len > 0) try out.writer.writeAll("\n");
            try out.writer.print("stderr:\n{s}", .{result.stderr});
        }
        return tools.finish(out.written());
    }

    fn fail(tools: *Tools, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(tools.arena, "error: " ++ format, args);
    }

    fn invalid(tools: *Tools, name: []const u8, err: anyerror) ![]const u8 {
        return tools.fail("invalid arguments for {s}: {s}", .{ name, @errorName(err) });
    }

    fn finish(tools: *Tools, text: []const u8) ![]const u8 {
        if (text.len <= max_result_len) return tools.arena.dupe(u8, text);
        return std.fmt.allocPrint(tools.arena, "{s}\n... {d} more bytes", .{
            text[0..max_result_len],
            text.len - max_result_len,
        });
    }
};

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(128 + @as(u32, @intFromEnum(signal))),
        .stopped => 128,
        .unknown => 255,
    };
}

const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

const specs = [_]Spec{
    .{
        .name = "read",
        .description = "Read a file. Returns the lines with their line numbers.",
        .parameters =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {"type": "string", "description": "File to read."},
        \\    "offset": {"type": "integer", "description": "First line to read, 1-based. Defaults to 1."},
        \\    "limit": {"type": "integer", "description": "Maximum number of lines. Defaults to 2000."}
        \\  },
        \\  "required": ["path"]
        \\}
        ,
    },
    .{
        .name = "write",
        .description = "Write a file, creating parent directories and replacing any existing content.",
        .parameters =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {"type": "string", "description": "File to write."},
        \\    "content": {"type": "string", "description": "Complete content of the file."}
        \\  },
        \\  "required": ["path", "content"]
        \\}
        ,
    },
    .{
        .name = "edit",
        .description = "Replace exact text in a file. Fails unless old_string is found exactly once, unless replace_all is true.",
        .parameters =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {"type": "string", "description": "File to edit."},
        \\    "old_string": {"type": "string", "description": "Exact text to replace, including indentation."},
        \\    "new_string": {"type": "string", "description": "Replacement text."},
        \\    "replace_all": {"type": "boolean", "description": "Replace every occurrence instead of requiring a unique match. Defaults to false."}
        \\  },
        \\  "required": ["path", "old_string", "new_string"]
        \\}
        ,
    },
    .{
        .name = "bash",
        .description = "Run a shell command with bash -c and return its output and exit code.",
        .parameters =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "command": {"type": "string", "description": "Command to run."}
        \\  },
        \\  "required": ["command"]
        \\}
        ,
    },
};

fn definitions(arena: std.mem.Allocator) ![]const llm.Tool {
    const tools = try arena.alloc(llm.Tool, specs.len);
    for (specs, tools) |spec, *tool| {
        tool.* = .{ .function = .{
            .name = spec.name,
            .description = spec.description,
            .parameters = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                spec.parameters,
                .{},
            ),
        } };
    }
    return tools;
}

test "exit codes of signals follow the shell convention" {
    try std.testing.expectEqual(0, exitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(1, exitCode(.{ .exited = 1 }));
    try std.testing.expectEqual(130, exitCode(.{ .signal = .INT }));
    try std.testing.expectEqual(143, exitCode(.{ .signal = .TERM }));
}

test "definitions cover every tool the loop dispatches" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const defs = try definitions(arena_state.allocator());
    try std.testing.expectEqual(specs.len, defs.len);
    for (defs) |definition| {
        try std.testing.expect(definition.parameters == .object);
    }
}
