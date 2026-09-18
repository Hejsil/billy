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
/// Room above the script when the formatted one is read back, so a formatter
/// that runs away cannot exhaust memory.
const format_slack = 1 << 20;

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
    /// How a bash command is laid out for the user. Shared with the transcript,
    /// so a replayed session shows the command the way the run did.
    format: Format,
    /// How the lines billy prints itself are decorated. Shared with the
    /// transcript, so a replayed session looks like the run it continues.
    style: Style,
    definitions: []const llm.Tool,

    pub fn init(
        io: Io,
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        log: *Io.Writer,
        format: Format,
        style: Style,
    ) !Tools {
        return .{
            .io = io,
            .arena = arena,
            .gpa = gpa,
            .log = log,
            .format = format,
            .style = style,
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
        try printHead(parsed, tools.format, tools.style, tools.log);
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

        try printResult(parsed, result, tools.style, tools.log);
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
            try out.writer.print("… {d} more lines\n", .{number - first + 1 - shown});
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
        return std.fmt.allocPrint(tools.arena, "{s}\n… {d} more bytes", .{
            text[0..max_result_len],
            text.len - max_result_len,
        });
    }
};

/// How a bash command is laid out for the user before it is shown. Null shows
/// the command as the model wrote it.
///
/// The formatting is presentation only: the command that runs, its result and
/// everything the session stores keep the text the model wrote.
pub const Format = ?Formatter;

/// The decorations billy puts on the lines it prints itself: the block header,
/// the label over the output, and the exit status billy reports. Only those
/// lines are decorated. What a tool returned, what a session stores and what the
/// model is sent are printed exactly as they are, which is also what leaves the
/// command of a bash call to the format script that lays it out.
pub const Style = enum {
    plain,
    ansi,

    /// The style to use on the terminal billy prints to. Escape codes are for a
    /// terminal, which a pipe or a redirection is not: `supportsAnsiEscapeCodes`
    /// answers whether stdout is one.
    pub fn detect(io: Io) Style {
        const supported = Io.File.stdout().supportsAnsiEscapeCodes(io) catch return .plain;
        return if (supported) .ansi else .plain;
    }

    /// `text` in bold.
    pub fn bold(style: Style, text: []const u8, out: *Io.Writer) !void {
        try out.print("{s}{s}{s}", .{ style.on("1"), text, style.off() });
    }

    /// `text` dimmed, for structure that should sit behind the content.
    pub fn dim(style: Style, text: []const u8, out: *Io.Writer) !void {
        try out.print("{s}{s}{s}", .{ style.on("2"), text, style.off() });
    }

    /// `text` in `hue`.
    pub fn color(style: Style, hue: Color, text: []const u8, out: *Io.Writer) !void {
        switch (style) {
            .plain => try out.writeAll(text),
            .ansi => try out.print("\x1b[{d}m{s}\x1b[0m", .{ @intFromEnum(hue), text }),
        }
    }

    /// The escape code that turns `code` on. Empty when the terminal takes no
    /// escape codes, so a caller that has to format decorated text around it can
    /// do so without a branch of its own.
    fn on(style: Style, comptime code: []const u8) []const u8 {
        return switch (style) {
            .plain => "",
            .ansi => "\x1b[" ++ code ++ "m",
        };
    }

    /// The escape code that turns every decoration back off.
    fn off(style: Style) []const u8 {
        return switch (style) {
            .plain => "",
            .ansi => "\x1b[0m",
        };
    }
};

/// A foreground colour, named by the escape code that selects it. Only the
/// colours every terminal has are used, so they read as part of the terminal
/// rather than as a theme of billy's own competing with the one a format script
/// paints the command in.
pub const Color = enum(u8) {
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    cyan = 36,
};

/// A formatter: a shell script that reads the command on standard input and
/// writes the formatted command on standard output, such as
/// `shfmt | bat -l bash`. That script is what a configuration sets.
pub const Formatter = struct {
    /// The shell script, run with `bash -c`.
    script: []const u8,
    io: Io,
    /// Holds the formatted command while the block is printed.
    gpa: std.mem.Allocator,
};

/// Runs `command` through the formatter and writes what it makes of the command
/// to `out`. Returns whether it could; false leaves `out` untouched, so the
/// caller can show the command as written. That is what no formatter gives, and
/// a formatter that cannot be run, rejects the command, writes nothing or
/// writes too much.
fn apply(format: Format, command: []const u8, out: *Io.Writer) !bool {
    const formatter = format orelse return false;
    var child = std.process.spawn(formatter.io, .{
        .argv = &.{ "bash", "-c", formatter.script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;
    defer child.kill(formatter.io);

    // The command goes in on standard input, which is what the format script
    // reads. Closing the pipe is what tells it there is no more.
    var in_buffer: [4096]u8 = undefined;
    var script: Io.File.Writer = .init(child.stdin.?, formatter.io, &in_buffer);
    try script.interface.writeAll(command);
    try script.interface.flush();
    child.stdin.?.close(formatter.io);
    child.stdin = null;

    var out_buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(child.stdout.?, formatter.io, &out_buffer);
    const written = reader.interface.allocRemaining(
        formatter.gpa,
        .limited(command.len +| format_slack),
    ) catch return false;
    defer formatter.gpa.free(written);

    // A formatter that failed, or left nothing behind, is one the user should
    // not see the command disappear for; it is shown as written instead.
    if (exitCode(child.wait(formatter.io) catch return false) != 0) return false;
    const formatted = std.mem.trimEnd(u8, written, "\n");
    if (formatted.len == 0) return false;

    try out.writeAll(formatted);
    return true;
}

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
pub fn describe(call: Call, result: []const u8, format: Format, style: Style, out: *Io.Writer) !void {
    try printHead(call, format, style, out);
    try printResult(call, result, style, out);
    try out.writeAll("\n");
}

/// How a tool's block header opens: the glyph it is marked with and the colour
/// the glyph is shown in, so a tool is recognisable from the left margin alone.
const Mark = struct {
    glyph: []const u8,
    hue: Color,
};

/// The mark of each tool. A glyph stands on the one line billy writes whole
/// rather than in front of every row of output, which the terminal wraps on its
/// own and cannot be marked without folding it here.
const marks = struct {
    const read = Mark{ .glyph = "▸", .hue = .blue };
    const write = Mark{ .glyph = "◂", .hue = .green };
    const edit = Mark{ .glyph = "✎", .hue = .yellow };
    const bash = Mark{ .glyph = "❯", .hue = .cyan };
    /// A call that could not be named: a tool billy does not implement, or
    /// arguments that could not be read.
    const unknown = Mark{ .glyph = "?", .hue = .red };
};

/// Prints the header block of a call: which tool it is and what it acts on. A
/// bash command is laid out by `format`, so it reads the way it runs; the
/// strings an edit works on are truncated, since they are there for context
/// rather than to be read in full.
fn printHead(call: Call, format: Format, style: Style, out: *Io.Writer) !void {
    switch (call) {
        .read => |args| try printHeader(marks.read, "read", args.path, style, out),
        .write => |args| try printHeader(marks.write, "write", args.path, style, out),
        .edit => |args| {
            try printHeader(marks.edit, "edit", args.path, style, out);
            try printLabel("find", null, style, out);
            try printTruncated(args.old_string, null, style, out);
            try printLabel("replace", null, style, out);
            try printTruncated(args.new_string, null, style, out);
        },
        .bash => |args| {
            try printHeader(marks.bash, "bash", "", style, out);
            try printScript(args.command, format, out);
        },
        // Only the name is known, so that is all there is to show; the reason it
        // could not run reaches the user through the output.
        .unknown => |name| try printHeader(marks.unknown, name, "", style, out),
        .malformed => |bad| try printHeader(marks.unknown, bad.name, "", style, out),
    }
}

/// Prints a block header: the glyph of the tool in its colour, its name in bold
/// and what it acts on, when there is one, dimmed: `▸ read a.zig`.
fn printHeader(mark: Mark, name: []const u8, target: []const u8, style: Style, out: *Io.Writer) !void {
    try style.color(mark.hue, mark.glyph, out);
    try out.writeAll(" ");
    try style.bold(name, out);
    if (target.len > 0) {
        try out.writeAll(" ");
        try style.dim(target, out);
    }
    try out.writeAll("\n");
}

/// The mark in front of the labels that break a block into sections, such as
/// `▾ output`. It points down at the lines under it, where the glyph of a tool
/// points at the call it names.
const label_mark = "▾";

/// A short note about the call, shown beside the label of the section it belongs
/// to: the exit status of a command. It carries its own colour, since what it
/// says is the point of putting it there.
const Note = struct {
    text: []const u8,
    hue: Color,
};

/// Prints a label such as `▾ output` dimmed, so it reads as structure rather
/// than as part of the output under it. A `note` follows on the same line, after
/// a separator and in its own colour, so it reads as a property of the section
/// rather than as its first line of output: `▾ output · exit 0`.
fn printLabel(name: []const u8, note: ?Note, style: Style, out: *Io.Writer) !void {
    const separator = if (note == null) "" else " ·";
    try out.print("{s}{s} {s}{s}{s}", .{ style.on("2"), label_mark, name, separator, style.off() });
    if (note) |n| {
        try out.writeAll(" ");
        try style.color(n.hue, n.text, out);
    }
    try out.writeAll("\n");
}

/// Prints a bash command on its own line under the block header, run through
/// the formatter when the configuration sets one and exactly as the model wrote
/// it when there is none, or the formatter cannot be used. The trailing newline
/// is dropped, so the block ends where the command does.
fn printScript(command: []const u8, format: Format, out: *Io.Writer) !void {
    const script = std.mem.trimEnd(u8, command, "\n");
    if (!try apply(format, script, out)) try out.writeAll(script);
    try out.writeAll("\n");
}

/// Prints what a call produced under the `output` label. A write shows the content
/// it put in the file; an edit shows nothing, since its result would only repeat
/// the strings shown above it. Anything that failed shows why instead, whatever
/// it was asked to do.
fn printResult(call: Call, result: []const u8, style: Style, out: *Io.Writer) !void {
    // A call that failed reports why, whatever it was asked to do. The whole
    // result is billy's own message, so it is shown the way billy shows a
    // failure.
    if (std.mem.startsWith(u8, result, "error: ")) {
        try printLabel("output", null, style, out);
        return printTruncated(result, .red, style, out);
    }
    switch (call) {
        // A write succeeds by putting the content in the file, so that content
        // is what it produced. It is on the call rather than in the result, so a
        // replayed session shows it without it having to be stored twice.
        .write => |args| {
            try printLabel("output", null, style, out);
            return printTruncated(args.content, null, style, out);
        },
        // An edit's result would only repeat the strings shown above it.
        .edit => {},
        .bash => return printBash(result, style, out),
        else => {
            try printLabel("output", null, style, out);
            return printTruncated(result, null, style, out);
        },
    }
}

/// Prints the output of a bash call: the status the result opens with goes on
/// the label line, and what the command printed follows it. The status is read
/// back from the first line, which is the line billy wrote there, so a replayed
/// session shows the same.
fn printBash(result: []const u8, style: Style, out: *Io.Writer) !void {
    const newline = std.mem.indexOfScalar(u8, result, '\n') orelse result.len;
    var buffer: [32]u8 = undefined;
    const note = statusNote(result[0..newline], &buffer) orelse {
        // A result that does not open with a status is shown as it is, so a
        // session saved before one was written still shows everything.
        try printLabel("output", null, style, out);
        return printTruncated(result, null, style, out);
    };
    try printLabel("output", note, style, out);
    if (newline < result.len) try printTruncated(result[newline + 1 ..], null, style, out);
}

/// The exit status a bash result opens with, as the note that goes beside the
/// `output` label: `exit 0` in green when the command succeeded, `exit 1` and
/// the rest in red when it did not. Null for a line that is not a status, which
/// is how a result stored before the status was written reads.
fn statusNote(status: []const u8, buffer: []u8) ?Note {
    const prefix = "exit code: ";
    if (!std.mem.startsWith(u8, status, prefix)) return null;
    const code = status[prefix.len..];
    return .{
        // The word is shortened and the number kept, so the note stays short
        // enough to read beside the label rather than as a line of its own.
        .text = std.fmt.bufPrint(buffer, "exit {s}", .{code}) catch status,
        .hue = if (std.mem.eql(u8, code, "0")) .green else .red,
    };
}

/// Prints `text`, keeping at most `max_block_lines` lines. When it had more, a
/// count of the rest is printed in place of them, so the block stays short
/// without hiding that there was more. A `hue` colours every line of the text,
/// for output that is billy's own message rather than a tool's.
fn printTruncated(text: []const u8, hue: ?Color, style: Style, out: *Io.Writer) !void {
    const body = std.mem.trimEnd(u8, text, "\n");
    if (body.len == 0) return;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (shown == max_block_lines) continue;
        if (hue) |h| {
            try style.color(h, line, out);
        } else {
            try out.writeAll(line);
        }
        try out.writeAll("\n");
        shown += 1;
    }
    if (total > shown) {
        try out.print("{s}… {d} more lines{s}\n", .{ style.on("2"), total - shown, style.off() });
    }
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
        "▸ read a.zig\n▾ output\nfile content\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "file content",
    );
    // A write shows the content it put in the file, not its result.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nhello\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "wrote 5 bytes to a.zig",
    );
    // A write that failed shows why instead of the content it never wrote.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nerror: cannot write a.zig: AccessDenied\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "error: cannot write a.zig: AccessDenied",
    );
    // An edit shows the strings it worked on instead of its result.
    try expectDescribe(
        "✎ edit a.zig\n▾ find\nold text\n▾ replace\nnew text\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"old text\",\"new_string\":\"new text\"}",
        "replaced 1 occurrence(s) in a.zig",
    );
    // The command of a bash call is printed whole.
    try expectDescribe(
        "❯ bash\nls -la\n▾ output · exit 0\n(no output)\n\n",
        "bash",
        "{\"command\":\"ls -la\"}",
        "exit code: 0\n(no output)\n",
    );
    // A tool that is not implemented shows its name, and the reason it could not
    // run reaches the user as the output.
    try expectDescribe(
        "? frobnicate\n▾ output\nerror: unknown tool 'frobnicate'\n\n",
        "frobnicate",
        "{}",
        "error: unknown tool 'frobnicate'",
    );
    // A known tool with broken arguments shows its name too.
    try expectDescribe(
        "? read\n▾ output\nerror: invalid arguments for read: SyntaxError\n\n",
        "read",
        "{",
        "error: invalid arguments for read: SyntaxError",
    );
    // A failed edit shows the error rather than hiding it behind its arguments.
    try expectDescribe(
        "✎ edit a.zig\n▾ find\nx\n▾ replace\ny\n▾ output\n" ++
            "error: old_string not found in a.zig\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"x\",\"new_string\":\"y\"}",
        "error: old_string not found in a.zig",
    );
}

test "a block header names the tool, its colour, the bold name and the target" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // On a terminal that takes an escape code, the glyph carries the colour of
    // the tool, only the name is bold, and the target and the label are dimmed.
    try describe(parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "", null, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[2m▾ output\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A terminal that takes no escape code gets the same text without them.
    try describe(parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "", null, .plain, &out.writer);
    try std.testing.expectEqualStrings("▸ read a.zig\n▾ output\n\n", out.written());
}

test "the exit status of a bash call is shown green or red" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\"}",
    } };

    // A command that succeeded.
    try describe(parseCall(arena, call), "exit code: 0\nbuilt\n", null, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[2m▾ output ·\x1b[0m " ++
            "\x1b[32mexit 0\x1b[0m\nbuilt\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // One that did not, whose output the terminal still shows as it is.
    try describe(parseCall(arena, call), "exit code: 2\nboom\n", null, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[2m▾ output ·\x1b[0m " ++
            "\x1b[31mexit 2\x1b[0m\nboom\n\n",
        out.written(),
    );
}

test "a bash result with no status line is shown as it is" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\"}",
    } };

    // A session saved before the status was written into the result has none,
    // so nothing is claimed about the call and the whole result is shown.
    try describe(parseCall(arena, call), "built\nnothing to do", null, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "❯ bash\nmake\n▾ output\nbuilt\nnothing to do\n\n",
        out.written(),
    );
}

test "what a call failed with is shown red, and what it left out is dimmed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A failure is billy's own message, so the whole result is shown as one.
    try describe(parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "error: cannot read a.zig: FileNotFound", null, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[2m▾ output\x1b[0m\n" ++
            "\x1b[31merror: cannot read a.zig: FileNotFound\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The count of the lines left out is structure too, so it is dimmed.
    try describe(
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        null,
        .ansi,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[2m▾ output\x1b[0m\n" ++
            "1\n2\n3\n4\n5\n\x1b[2m… 2 more lines\x1b[0m\n\n",
        out.written(),
    );
}

test "a bash command is shown the way the formatter lays it out" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The format script reads the command and writes it back upper case, the
    // way `shfmt | bat -l bash` reads it and writes it back laid out.
    const format: Format = .{ .script = "tr a-z A-Z | cat", .io = std.testing.io, .gpa = gpa };
    try describe(parseCall(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"ls -la\\n\"}",
    } }), "exit code: 0\n(no output)\n", format, .plain, &out.writer);

    // The command is shown as the formatter wrote it; its trailing newline does
    // not leave a blank line in the block.
    try std.testing.expectEqualStrings(
        "❯ bash\nLS -LA\n▾ output · exit 0\n(no output)\n\n",
        out.written(),
    );
}

test "a bash command is shown as written when the formatter cannot lay it out" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"ls -la\"}",
    } };
    const expected =
        "❯ bash\nls -la\n▾ output · exit 0\n(no output)\n\n";

    // A formatter that cannot be run, one that fails and one that writes
    // nothing all leave the command the model wrote for the user to read.
    const scripts = [_][]const u8{ "billy-no-such-formatter", "exit 1", "true" };
    for (scripts) |script| {
        const format: Format = .{ .script = script, .io = std.testing.io, .gpa = gpa };
        try describe(parseCall(arena, call), "exit code: 0\n(no output)\n", format, .plain, &out.writer);
        try std.testing.expectEqualStrings(expected, out.written());
        out.clearRetainingCapacity();
    }
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
        null,
        .plain,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "▸ read a.zig\n▾ output\n1\n2\n3\n4\n5\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // Past the limit: the rest is replaced by a count of the lines left out. The
    // trailing newline of a result is not a line of its own.
    try describe(
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        null,
        .plain,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "▸ read a.zig\n▾ output\n1\n2\n3\n4\n5\n… 2 more lines\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An empty result leaves the header with nothing under it.
    try describe(.{ .read = .{ .path = "a.zig" } }, "", null, .plain, &out.writer);
    try std.testing.expectEqualStrings("▸ read a.zig\n▾ output\n\n", out.written());
    out.clearRetainingCapacity();

    // A long find or replace string is cut short the same way.
    try describe(
        .{ .edit = .{
            .path = "a.zig",
            .old_string = "1\n2\n3\n4\n5\n6",
            .new_string = "b",
        } },
        "replaced 1 occurrence(s) in a.zig",
        null,
        .plain,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ find\n1\n2\n3\n4\n5\n… 1 more lines\n" ++
            "▾ replace\nb\n\n",
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

    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer, null, .plain);
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    const result = try tool_set.run(call);

    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(parseCall(arena, call), result, null, .plain, &described.writer);

    // The live log is the description, so a replayed session reads the same.
    try std.testing.expectEqualStrings(
        "❯ bash\ntrue\n▾ output · exit 0\n(no output)\n\n",
        log.written(),
    );
    try std.testing.expectEqualStrings(log.written(), described.written());
}

test "the format changes what is shown and nothing else" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();

    // The format script writes the command back upper case, so what is shown is
    // plainly not what runs.
    const format: Format = .{ .script = "tr a-z A-Z", .io = std.testing.io, .gpa = gpa };
    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer, format, .plain);
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };
    const result = try tool_set.run(call);

    // The command that ran is the one the model wrote, so the result is its
    // output, and the user reads the command as the formatter laid it out.
    try std.testing.expectEqualStrings("exit code: 0\nhi\n", result);
    try std.testing.expectEqualStrings(
        "❯ bash\nECHO HI\n▾ output · exit 0\nhi\n\n",
        log.written(),
    );

    // A replayed session describes the stored call the same way.
    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(parseCall(arena, call), result, format, .plain, &described.writer);
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
    } }), result, null, .plain, &out.writer);
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
