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
/// Lines of a result shown before the rest is summarized. The model still gets
/// the whole result; only the display is cut short.
const max_block_lines = 5;

/// A tool call parsed into the arguments of the call it names. Parsing happens
/// once, in `run`, and both the block the user sees and the tool itself read
/// from here.
pub const Call = union(enum) {
    read: Read,
    write: Write,
    edit: Edit,
    bash: Bash,
    /// A call naming a tool this harness does not implement.
    unknown: []const u8,
    /// A known tool whose arguments could not be read; `name` is still known.
    malformed: Malformed,

    pub const Read = struct {
        path: []const u8,
        /// First line to read, 1-based.
        offset: ?usize = null,
        /// Maximum number of lines.
        limit: ?usize = null,
    };

    pub const Write = struct {
        path: []const u8,
        content: []const u8,
    };

    pub const Edit = struct {
        path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
        replace_all: bool = false,
    };

    pub const Bash = struct {
        command: []const u8,
    };

    pub const Malformed = struct {
        name: []const u8,
        reason: anyerror,
    };
};

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
    ///
    /// What the user sees comes from `printHead` and `printResult`, which the
    /// transcript reuses, so a replayed session shows exactly what a live one
    /// did. The head goes out before the tool runs, so a slow command shows what
    /// it is doing, and the result follows it.
    pub fn run(tools: *Tools, call: llm.ToolCall) ![]const u8 {
        const parsed = parseCall(tools.arena, call);
        try printHead(parsed, tools.log);
        try tools.log.flush();

        const result = switch (parsed) {
            .read => |args| try tools.read(args),
            .write => |args| try tools.write(args),
            .edit => |args| try tools.edit(args),
            .bash => |args| try tools.bash(args),
            .unknown => |name| try tools.fail("unknown tool '{s}'", .{name}),
            .malformed => |bad| try tools.fail(
                "invalid arguments for {s}: {s}",
                .{ bad.name, @errorName(bad.reason) },
            ),
        };

        try printResult(parsed, result, tools.log);
        try tools.log.writeAll("\n");
        try tools.log.flush();
        return result;
    }

    fn read(tools: *Tools, args: Call.Read) ![]const u8 {
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

    fn write(tools: *Tools, args: Call.Write) ![]const u8 {
        if (std.fs.path.dirname(args.path)) |parent| {
            std.Io.Dir.cwd().createDirPath(tools.io, parent) catch |err|
                return tools.fail("cannot create {s}: {s}", .{ parent, @errorName(err) });
        }
        std.Io.Dir.cwd().writeFile(tools.io, .{ .sub_path = args.path, .data = args.content }) catch |err|
            return tools.fail("cannot write {s}: {s}", .{ args.path, @errorName(err) });
        return std.fmt.allocPrint(tools.arena, "wrote {d} bytes to {s}", .{ args.content.len, args.path });
    }

    fn edit(tools: *Tools, args: Call.Edit) ![]const u8 {
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

    fn bash(tools: *Tools, args: Call.Bash) ![]const u8 {
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

    fn finish(tools: *Tools, text: []const u8) ![]const u8 {
        if (text.len <= max_result_len) return tools.arena.dupe(u8, text);
        return std.fmt.allocPrint(tools.arena, "{s}\n... {d} more bytes", .{
            text[0..max_result_len],
            text.len - max_result_len,
        });
    }
};

/// Parses a tool call into the arguments of the call it names. It never fails:
/// an unimplemented tool becomes `unknown` and arguments that do not fit become
/// `malformed`, so a caller can still name the call it could not run.
pub fn parseCall(arena: std.mem.Allocator, call: llm.ToolCall) Call {
    const name = call.function.name;
    const arguments = call.function.arguments;
    if (std.mem.eql(u8, name, "read")) {
        return .{ .read = parse(Call.Read, arena, arguments) catch |reason|
            return .{ .malformed = .{ .name = name, .reason = reason } } };
    }
    if (std.mem.eql(u8, name, "write")) {
        return .{ .write = parse(Call.Write, arena, arguments) catch |reason|
            return .{ .malformed = .{ .name = name, .reason = reason } } };
    }
    if (std.mem.eql(u8, name, "edit")) {
        return .{ .edit = parse(Call.Edit, arena, arguments) catch |reason|
            return .{ .malformed = .{ .name = name, .reason = reason } } };
    }
    if (std.mem.eql(u8, name, "bash")) {
        return .{ .bash = parse(Call.Bash, arena, arguments) catch |reason|
            return .{ .malformed = .{ .name = name, .reason = reason } } };
    }
    return .{ .unknown = name };
}

/// Parses arguments that live as long as `arena`. Unknown fields are dropped, so
/// a call from a newer model does not fail on the fields this version ignores.
fn parse(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Prints the block a live session shows for a tool call and its result: a
/// header naming the tool, what it acts on, and its output. The transcript
/// reuses it so that replaying a session matches the run exactly.
pub fn describe(call: Call, result: []const u8, out: *Io.Writer) !void {
    try printHead(call, out);
    try printResult(call, result, out);
    try out.writeAll("\n");
}

/// Prints the header block of a call: which tool it is and what it acts on. The
/// command of a bash call is printed in full, since it is what the user asked
/// for; the strings an edit works on are truncated, since they are there for
/// context rather than to be read in full.
fn printHead(call: Call, out: *Io.Writer) !void {
    switch (call) {
        .read => |args| try out.print("--- tool - read ---\n{s}\n", .{args.path}),
        .write => |args| try out.print("--- tool - write ---\n{s}\n", .{args.path}),
        .edit => |args| {
            try out.print("--- tool - edit ---\n{s}\n", .{args.path});
            try out.writeAll("--- find ---\n");
            try printTruncated(out, args.old_string);
            try out.writeAll("--- replace ---\n");
            try printTruncated(out, args.new_string);
        },
        .bash => |args| try out.print("--- tool - bash ---\n{s}\n", .{args.command}),
        // Only the name is known, so that is all there is to show; the reason it
        // could not run reaches the user through the output.
        .unknown => |name| try out.print("--- tool - {s} ---\n", .{name}),
        .malformed => |bad| try out.print("--- tool - {s} ---\n", .{bad.name}),
    }
}

/// Prints a call's result under `--- output ---`.
fn printOutput(out: *Io.Writer, result: []const u8) !void {
    try out.writeAll("--- output ---\n");
    try printTruncated(out, result);
}

/// Prints what a call produced under `--- output ---`. A write shows the content
/// it put in the file; an edit shows nothing, since its result would only repeat
/// the strings shown above it. Anything that failed shows why instead, whatever
/// it was asked to do.
fn printResult(call: Call, result: []const u8, out: *Io.Writer) !void {
    // A call that failed reports why, whatever it was asked to do.
    if (std.mem.startsWith(u8, result, "error: ")) return printOutput(out, result);
    switch (call) {
        // A write succeeds by putting the content in the file, so that content
        // is what it produced. It is on the call rather than in the result, so a
        // replayed session shows it without it having to be stored twice.
        .write => |args| {
            try out.writeAll("--- output ---\n");
            try printTruncated(out, args.content);
        },
        // An edit's result would only repeat the strings shown above it.
        .edit => {},
        else => try printOutput(out, result),
    }
}

/// Prints `text`, keeping at most `max_block_lines` lines. When it had more, a
/// count of the rest is printed in place of them, so the block stays short
/// without hiding that there was more.
fn printTruncated(out: *Io.Writer, text: []const u8) !void {
    const body = std.mem.trimEnd(u8, text, "\n");
    if (body.len == 0) return;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (shown == max_block_lines) continue;
        try out.writeAll(line);
        try out.writeAll("\n");
        shown += 1;
    }
    if (total > shown) try out.print("... {d} more lines\n", .{total - shown});
}

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

test "describe frames a call and its output" {
    try expectDescribe(
        "--- tool - read ---\na.zig\n--- output ---\nfile content\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "file content",
    );
    // A write shows the content it put in the file, not its result.
    try expectDescribe(
        "--- tool - write ---\na.zig\n--- output ---\nhello\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "wrote 5 bytes to a.zig",
    );
    // A write that failed shows why instead of the content it never wrote.
    try expectDescribe(
        "--- tool - write ---\na.zig\n--- output ---\nerror: cannot write a.zig: AccessDenied\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "error: cannot write a.zig: AccessDenied",
    );
    // An edit shows the strings it worked on instead of its result.
    try expectDescribe(
        "--- tool - edit ---\na.zig\n--- find ---\nold text\n--- replace ---\nnew text\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"old text\",\"new_string\":\"new text\"}",
        "replaced 1 occurrence(s) in a.zig",
    );
    // The command of a bash call is printed whole.
    try expectDescribe(
        "--- tool - bash ---\nls -la\n--- output ---\nexit code: 0\n(no output)\n\n",
        "bash",
        "{\"command\":\"ls -la\"}",
        "exit code: 0\n(no output)\n",
    );
    // A tool that is not implemented shows its name, and the reason it could not
    // run reaches the user as the output.
    try expectDescribe(
        "--- tool - frobnicate ---\n--- output ---\nerror: unknown tool 'frobnicate'\n\n",
        "frobnicate",
        "{}",
        "error: unknown tool 'frobnicate'",
    );
    // A known tool with broken arguments shows its name too.
    try expectDescribe(
        "--- tool - read ---\n--- output ---\nerror: invalid arguments for read: SyntaxError\n\n",
        "read",
        "{",
        "error: invalid arguments for read: SyntaxError",
    );
    // A failed edit shows the error rather than hiding it behind its arguments.
    try expectDescribe(
        "--- tool - edit ---\na.zig\n--- find ---\nx\n--- replace ---\ny\n--- output ---\n" ++
            "error: old_string not found in a.zig\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"x\",\"new_string\":\"y\"}",
        "error: old_string not found in a.zig",
    );
}

test "describe keeps a block short and says how much it left out" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Exactly the limit: nothing is left out.
    try describe(
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5",
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "--- tool - read ---\na.zig\n--- output ---\n1\n2\n3\n4\n5\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // Past the limit: the rest is replaced by a count of the lines left out. The
    // trailing newline of a result is not a line of its own.
    try describe(
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "--- tool - read ---\na.zig\n--- output ---\n1\n2\n3\n4\n5\n... 2 more lines\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An empty result leaves the header with nothing under it.
    try describe(.{ .read = .{ .path = "a.zig" } }, "", &out.writer);
    try std.testing.expectEqualStrings("--- tool - read ---\na.zig\n--- output ---\n\n", out.written());
    out.clearRetainingCapacity();

    // A long find or replace string is cut short the same way.
    try describe(
        .{ .edit = .{
            .path = "a.zig",
            .old_string = "1\n2\n3\n4\n5\n6",
            .new_string = "b",
        } },
        "replaced 1 occurrence(s) in a.zig",
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "--- tool - edit ---\na.zig\n--- find ---\n1\n2\n3\n4\n5\n... 1 more lines\n" ++
            "--- replace ---\nb\n\n",
        out.written(),
    );
}

test "run logs exactly what describe prints" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();

    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer);
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    const result = try tool_set.run(call);

    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(parseCall(arena, call), result, &described.writer);

    // The live log is the description, so a replayed session reads the same.
    try std.testing.expectEqualStrings(
        "--- tool - bash ---\ntrue\n--- output ---\nexit code: 0\n(no output)\n\n",
        log.written(),
    );
    try std.testing.expectEqualStrings(log.written(), described.written());
}

test "parseCall splits known, unknown and malformed calls" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read = parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\",\"offset\":5}",
    } });
    try std.testing.expectEqualStrings("a.zig", read.read.path);
    try std.testing.expectEqual(@as(?usize, 5), read.read.offset);

    const missing = parseCall(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{}",
    } });
    try std.testing.expectEqualStrings("bash", missing.malformed.name);

    const unknown = parseCall(arena, .{ .id = "1", .function = .{
        .name = "frobnicate",
        .arguments = "{}",
    } });
    try std.testing.expectEqualStrings("frobnicate", unknown.unknown);
}

fn expectDescribe(expected: []const u8, name: []const u8, arguments: []const u8, result: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try describe(parseCall(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), result, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "definitions cover every tool the loop dispatches" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const defs = try definitions(arena_state.allocator());
    try std.testing.expectEqual(specs.len, defs.len);
    for (defs) |definition| {
        try std.testing.expect(definition.function.parameters == .object);
    }
}
