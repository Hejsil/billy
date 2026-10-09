//! The tools the agent can call, together with their JSON Schema descriptions.

const std = @import("std");
const llm = @import("llm.zig");
const Health = @import("Health.zig");
const formatting = @import("format.zig");
const diffing = @import("diff.zig");
const Terminal = @import("Terminal.zig");
const Session = @import("Session.zig");
const agent = @import("Agent.zig");
const Bash = @import("Tools/Bash.zig");
const Edit = @import("Tools/Edit.zig");
const Read = @import("Tools/Read.zig");
const Write = @import("Tools/Write.zig");
pub const web = @import("Tools/web.zig");

const Tools = @This();

/// Laying a bash command out for the display.
pub const Format = formatting.Format;

/// The formatter scripts a tool's block is laid out with. Null shows the text as
/// written. Presentation only: what runs, what a session stores and what the
/// model is sent keep the text they were given.
pub const Formats = struct {
    /// How a bash command is laid out before it is shown.
    bash: Format = null,
    /// How an edit's diff is laid out before it is shown.
    edit: Format = null,
};

/// Longest result handed back to the model, so one command cannot flood the
/// conversation.
const max_result_len = 30_000;
/// Lines of a result shown before the rest is summarized. The model still gets
/// the whole result; only the display is cut short.
const max_block_lines = 5;

/// A tool call parsed into the arguments of the tool it names.
pub const Call = union(enum) {
    read: Read,
    write: Write,
    edit: Edit,
    bash: Bash,
    web_search: web.Search,
    web_fetch: web.Fetch,
    /// A call naming a tool this harness does not implement.
    unknown: []const u8,
    /// A known tool whose arguments could not be read; `name` is still known.
    malformed: Malformed,

    pub const Malformed = struct {
        name: []const u8,
        reason: anyerror,
    };
};

io: std.Io,
/// The session's own directory, so a resumed session works where it started.
/// Every path a tool is given is relative to it.
dir: std.Io.Dir,
/// For temporary buffers.
gpa: std.mem.Allocator,
/// Shared with the transcript, so a replay shows a call the way the run did.
formats: Formats,
/// Longest a bash command may run before it is killed, in seconds.
bash_timeout_s: usize,
/// Shared with the transcript, so a replay looks like the run.
style: Terminal.Style,
/// Null leaves `web_search` out of the tools offered, so the model is never given
/// one that could not run.
search: ?web.Search.Config,
/// As `search`, for `web_fetch`.
fetch: ?web.Fetch.Config,
/// The run's one HTTP client, shared with the model requests so connections and
/// scanned certificates are reused.
http: *std.http.Client,
/// Null runs without backend waits, which is what a test wants.
health: ?*Health,

/// What a tool set is built from. The fields are those of `Tools`.
pub const Options = struct {
    io: std.Io,
    dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    formats: Formats = .{},
    /// No default: a missing timeout is worth catching at the call site.
    bash_timeout_s: usize,
    style: Terminal.Style = .plain,
    search: ?web.Search.Config = null,
    fetch: ?web.Fetch.Config = null,
    http: *std.http.Client,
    health: ?*Health = null,
};

pub fn init(options: Options) !Tools {
    return .{
        .io = options.io,
        .dir = options.dir,
        .gpa = options.gpa,
        .formats = options.formats,
        .bash_timeout_s = options.bash_timeout_s,
        .style = options.style,
        .search = options.search,
        .fetch = options.fetch,
        .http = options.http,
        .health = options.health,
    };
}

/// Whether any web tool is offered. A configuration may have search without
/// fetch, or the reverse.
pub fn hasWeb(tools: *const Tools) bool {
    return tools.search != null or tools.fetch != null;
}

/// The definitions a session is given: the tools the mode allows, with the web
/// tools last when a backend is configured. Comptime strings, so nothing is built.
pub fn definitions(tools: *const Tools, mode: agent.Mode) []const Session.Definition {
    return switch (mode) {
        .general => if (tools.hasWeb()) &specs_with_web else &specs,
        .chat => if (tools.hasWeb()) &chat_specs_with_web else &chat_specs,
    };
}

/// The name of the tool `call` names, for checking it against a mode without
/// showing the call.
pub fn callName(call: Call) []const u8 {
    return switch (call) {
        .unknown => |name| name,
        .malformed => |bad| bad.name,
        inline else => |_, tag| @tagName(tag),
    };
}

/// Writes the result of `call` to `result`, cut at `max_result_len` with a count of
/// what was left out, so no tool can fill the model's context. The cap is applied
/// here so no tool has to know about it.
pub fn run(tools: *Tools, call: Call, result: *std.Io.Writer) !void {
    var buffer: [result_buffer_len]u8 = undefined;
    var limited = Limited.init(result, &buffer, max_result_len);
    try tools.dispatch(call, &limited.writer);
    // The dropped count is only final once what is gathered has been passed on.
    try limited.writer.flush();
    // Reads to the model as a truncation, not as the result ending.
    if (limited.dropped > 0) {
        try result.print("\n… {d} more bytes", .{limited.dropped});
    }
}

/// Gathered before being passed on, so a tool that writes a line at a time is not
/// a call to the writer behind this for every line.
///
/// TODO: `writeSplatHeaderLimit` would merge a format's slices, repeats and
/// header into one write, but it can consume less than it was given. Worth it
/// only if this shows up in a profile.
const result_buffer_len = 4096;

/// A writer that passes what is written to another writer up to a limit, and
/// counts and drops the rest. Writing past the limit is not an error, so a tool
/// that fills the buffer is not turned into a failed call.
const Limited = struct {
    /// Where the bytes that fit are passed on.
    inner: *std.Io.Writer,
    /// How many more bytes fit before the limit.
    remaining: usize,
    /// How many bytes were written past the limit and dropped.
    dropped: usize,
    writer: std.Io.Writer,

    fn init(inner: *std.Io.Writer, buffer: []u8, limit: usize) Limited {
        return .{
            .inner = inner,
            .remaining = limit,
            .dropped = 0,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Limited = @alignCast(@fieldParentPtr("writer", w));

        // What is already gathered goes first.
        const header = w.buffer[0..w.end];
        w.end = 0;
        try self.hand(header);

        // Every slice but the last is written once; the last is repeated `splat`
        // times.
        for (data[0 .. data.len - 1]) |bytes| try self.hand(bytes);

        // The repeats go over together, so padding is one write, not one per byte.
        try self.repeat(data[data.len - 1], splat);

        // Dropped bytes count as consumed, or the caller would offer them again.
        var offered: usize = data[data.len - 1].len * splat;
        for (data[0 .. data.len - 1]) |bytes| offered += bytes.len;
        return offered;
    }

    /// Hands on as much of `bytes` as the limit still allows, and counts the
    /// rest as dropped.
    fn hand(self: *Limited, bytes: []const u8) std.Io.Writer.Error!void {
        const fits = @min(bytes.len, self.remaining);
        if (fits > 0) try self.inner.writeAll(bytes[0..fits]);
        self.remaining -= fits;
        self.dropped += bytes.len - fits;
    }

    /// Hands on as many of `splat` copies of `pattern` as the limit allows, the
    /// whole copies in one write, and counts the rest as dropped.
    fn repeat(self: *Limited, pattern: []const u8, splat: usize) std.Io.Writer.Error!void {
        const offered = pattern.len * splat;
        const fits = @min(offered, self.remaining);
        self.remaining -= fits;
        self.dropped += offered - fits;
        if (fits == 0 or pattern.len == 0) return;

        // `writeSplatAll` takes the slice list mutably; only the list is copied.
        const whole = fits / pattern.len;
        if (whole > 0) {
            var repeated = [_][]const u8{pattern};
            try self.inner.writeSplatAll(&repeated, whole);
        }
        // A copy the limit cuts in half is written as far as it goes.
        if (fits % pattern.len != 0) try self.inner.writeAll(pattern[0 .. fits % pattern.len]);
    }
};

/// Writes why a call could not run. Every failure begins with `error: `, which
/// `printResult` and `html.block` read to tell a failure from an answer, so tools
/// write only what went wrong.
pub fn fail(out: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    try out.print("error: " ++ format, args);
}

/// Runs a parsed call, writing its result or the reason it could not run to `out`.
fn dispatch(tools: *Tools, call: Call, out: *std.Io.Writer) !void {
    switch (call) {
        .edit => |edit| try edit.run(tools.gpa, tools.io, tools.dir, out),
        .read => |read| try read.run(tools.gpa, tools.io, tools.dir, out),
        .write => |write| try write.run(tools.io, tools.dir, out),
        .bash => |bash| {
            const timeout_s = std.math.cast(i64, tools.bash_timeout_s) orelse std.math.maxInt(i64);
            const timeout = std.Io.Duration.fromSeconds(timeout_s);
            try bash.run(tools.gpa, tools.io, tools.dir, timeout, out);
        },
        .web_search => |search| try search.run(
            tools.gpa,
            tools.http,
            tools.search,
            tools.health,
            out,
        ),
        .web_fetch => |fetch| try fetch.run(
            tools.gpa,
            tools.http,
            tools.fetch,
            tools.health,
            out,
        ),
        .unknown => |name| try fail(out, "unknown tool '{s}'", .{name}),
        .malformed => |bad| try fail(
            out,
            "invalid arguments for {s}: {s}",
            .{ bad.name, @errorName(bad.reason) },
        ),
    }
}

/// Parses and runs one call as the agent does, and hands the parsed call back so a
/// test can give both to `describe`.
fn runCall(
    arena: std.mem.Allocator,
    tools: *Tools,
    call: llm.ToolCall,
    result: *std.Io.Writer,
) !Call {
    const parsed = parse(arena, call);
    try tools.run(parsed, result);
    return parsed;
}

/// Parses a tool call into the arguments of the tool it names. It never fails: an
/// unimplemented tool becomes `unknown` and arguments that do not fit become
/// `malformed`, so a caller can still name the call it could not run. The result
/// lives in `arena`.
pub fn parse(arena: std.mem.Allocator, call: llm.ToolCall) Call {
    return parseCallNamed(arena, call.function.name, call.function.arguments);
}

/// Parses a call from a tool's name and arguments, the pair a session stores, so a
/// transcript need not build the `llm.ToolCall` it came from.
pub fn parseCallNamed(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) Call {
    // The tag is the tool's name, so the two are not written side by side.
    const fields = @typeInfo(Call).@"union".field_types;
    inline for (.{ Call.read, Call.write, Call.edit, Call.bash, Call.web_search, Call.web_fetch }) |tag| {
        if (std.mem.eql(u8, name, @tagName(tag))) {
            const payload = fields[@backingInt(tag)];
            const parsed = fromJson(payload, arena, arguments) catch |reason|
                return .{ .malformed = .{ .name = name, .reason = reason } };
            return @unionInit(Call, @tagName(tag), parsed);
        }
    }
    return .{ .unknown = name };
}

/// Parses arguments that live as long as `arena`. Unknown fields are dropped, so
/// a call from a newer model does not fail on the fields this version ignores.
fn fromJson(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Prints the block for a tool call and its result: a header naming the tool and
/// what it acts on, then its output. The transcript reuses it so a replay matches
/// the run. `scratch` is the caller's, for what the block builds, such as an
/// edit's diff.
pub fn describe(
    scratch: std.mem.Allocator,
    call: Call,
    result: []const u8,
    formats: Formats,
    style: Terminal.Style,
    out: *std.Io.Writer,
) !void {
    try printHead(scratch, call, formats, style, out);
    try printResult(call, result, style, out);
    try out.writeAll("\n");
}

/// The mark of each tool. A glyph stands on the one line billy writes whole
/// rather than in front of every row of output, which the terminal wraps on its
/// own and cannot be marked without folding it here.
const marks = struct {
    const read = Terminal.Style.Mark{ .glyph = "▸", .hue = .blue };
    const write = Terminal.Style.Mark{ .glyph = "◂", .hue = .green };
    const edit = Terminal.Style.Mark{ .glyph = "✎", .hue = .yellow };
    const bash = Terminal.Style.Mark{ .glyph = "❯", .hue = .cyan };
    const search = Terminal.Style.Mark{ .glyph = "⌕", .hue = .magenta };
    const fetch = Terminal.Style.Mark{ .glyph = "⇣", .hue = .magenta };
    /// A call that could not be named: a tool billy does not implement, or
    /// arguments that could not be read.
    const unknown = Terminal.Style.Mark{ .glyph = "?", .hue = .red };
};

/// How a call is headed: the glyph its tool is marked with, the name of the tool
/// and what the call acts on. This is what a frontend needs to open a call's
/// block; the terminal colours the glyph and dims the target, and the web gives
/// each an element of its own.
pub const Heading = struct {
    /// The glyph the tool is marked with.
    glyph: []const u8,
    /// The colour the terminal shows the glyph in. The web has its own.
    hue: Terminal.Style.Color,
    /// The name of the tool the call names.
    name: []const u8,
    /// What the call acts on, such as a read's path or a search's query, or
    /// nothing when the call names nothing to act on.
    target: []const u8,

    /// The heading of `call`: the mark of the tool it names, the name, and what
    /// the call acts on. A call billy cannot run still has a name, so it is
    /// headed by that; the reason it could not run reaches the user as its output.
    pub fn of(call: Call) Heading {
        return switch (call) {
            .read => |args| .marked(marks.read, "read", args.path),
            .write => |args| .marked(marks.write, "write", args.path),
            .edit => |args| .marked(marks.edit, "edit", args.path),
            // A bash call names nothing it acts on, so its heading carries the
            // description of what the command does, which is what a reader wants
            // in front of a command it has not read. The command itself is shown
            // under the header, whole. A call from before the tool asked for a
            // description has none, and its heading comes out with no target.
            .bash => |args| .marked(marks.bash, "bash", headerLine(args.description orelse "")),
            .web_search => |args| .marked(marks.search, "web_search", args.query),
            .web_fetch => |args| .marked(marks.fetch, "web_fetch", args.url),
            .unknown => |name| .marked(marks.unknown, name, ""),
            .malformed => |bad| .marked(marks.unknown, bad.name, ""),
        };
    }

    /// The heading of a call to the tool `mark` stands for: the mark's glyph, the
    /// tool's name, and what the call acts on.
    fn marked(mark: Terminal.Style.Mark, name: []const u8, target: []const u8) Heading {
        return .{ .glyph = mark.glyph, .hue = mark.hue, .name = name, .target = target };
    }
};

/// The first line of `text`, with the whitespace around it taken off: what a
/// header shows of a string that may run over several lines, such as a command or
/// a description. A header is one line, so only the first is taken; what the
/// string holds in full is shown under the header, or in the call's body.
pub fn headerLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

/// Prints the header block of a call: which tool it is and what it acts on. A
/// bash command is laid out by the bash formatter, so it reads the way it runs;
/// an edit is shown as the diff of the strings it works on; and a search shows
/// the query it ran.
pub fn printHead(scratch: std.mem.Allocator, call: Call, formats: Formats, style: Terminal.Style, out: *std.Io.Writer) !void {
    const head = Heading.of(call);
    const mark = Terminal.Style.Mark{ .glyph = head.glyph, .hue = head.hue };
    try mark.header(head.name, head.target, style, out);
    // What a call shows under its header: the change it means to make, or the
    // command it runs. Every other call is its header alone.
    switch (call) {
        .edit => |args| try printDiff(scratch, args.old_string, args.new_string, formats.edit, style, out),
        .bash => |args| try printScript(args.command, formats.bash, out),
        else => {},
    }
}

/// Prints an edit as the diff of the strings it asked to change: what was there
/// and what replaces it. The diff is built from the call, so it shows the model's
/// intent and a replay recomputes the same one.
///
/// The diff is laid out by `format` when the configuration sets one, so a script
/// can colour it or show word-level changes; without one, billy's own rendering
/// is used. An edit that changes nothing shows no diff at all.
fn printDiff(
    scratch: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
    format: Format,
    style: Terminal.Style,
    out: *std.Io.Writer,
) !void {
    const diff = try diffing.lines(scratch, old, new);
    defer scratch.free(diff);
    if (diff.len == 0) return;

    try printLabel("diff", style, out);
    // The formatter reads the plain diff on standard input, so a filter such as
    // `bat -l diff` works; the two sides are also written to files and passed as
    // `$1` and `$2`, so a two-file differ such as `difft "$1" "$2"` needs no
    // pipeline of its own. A script that cannot run the diff leaves it to billy's
    // own rendering, the same as every other formatter. The laid-out text is
    // written without its trailing newline, so one is added here to end the block
    // the way every other block ends.
    if (format) |formatter| {
        const text = try diffing.render(formatter.gpa, diff);
        defer formatter.gpa.free(text);
        if (try formatting.runDiff(format, text, old, new, out)) {
            try out.writeAll("\n");
            return;
        }
    }
    try diffing.print(diff, style, out);
}

/// The mark in front of the labels that break a block into sections, such as
/// `▾ stdout`. It points down at the lines under it, where the glyph of a tool
/// points at the call it names.
const label_mark = "▾";

/// The mark in front of an exit status: a check when the command succeeded and a
/// cross when it did not. It repeats what the colour says, so the line reads the
/// same where the colour does not, such as a colour-blind terminal or a log with
/// the escape codes stripped. The web pill uses the same marks, so the two
/// frontends agree on what a status looks like.
pub const exit_marks = struct {
    pub const ok = "✓";
    pub const failed = "✗";
};

/// How a section of a block is printed. The label line is bold, so it reads as
/// the heading of what follows, and the output under it is dim, so it stays
/// readable without competing with it.
const Ink = union(enum) {
    plain,
    dim,
    hue: Terminal.Style.Color,
};

/// Prints a label such as `▾ stdout` in bold, so it reads as the heading of the
/// lines under it rather than as the first of them.
fn printLabel(name: []const u8, style: Terminal.Style, out: *std.Io.Writer) !void {
    try out.print("{s}{s} {s}{s}\n", .{ style.on("1"), label_mark, name, style.off() });
}

/// Prints `text` in the way `ink` asks for.
fn printInk(text: []const u8, ink: Ink, style: Terminal.Style, out: *std.Io.Writer) !void {
    switch (ink) {
        .plain => try out.writeAll(text),
        .dim => try style.dim(text, out),
        .hue => |hue| try style.color(hue, text, out),
    }
}

/// Prints a bash command on its own line under the block header, run through
/// the formatter when the configuration sets one and exactly as the model wrote
/// it when there is none, or the formatter cannot be used. The trailing newline
/// is dropped, so the block ends where the command does.
fn printScript(command: []const u8, format: Format, out: *std.Io.Writer) !void {
    const script = std.mem.trimEnd(u8, command, "\n");
    if (!try formatting.apply(format, script, out)) try out.writeAll(script);
    try out.writeAll("\n");
}

/// Prints what a call produced under the `output` label. A write shows the content
/// it put in the file; an edit shows nothing, since its result would only repeat
/// the change shown above it. Anything that failed shows why instead, whatever
/// it was asked to do.
pub fn printResult(call: Call, result: []const u8, style: Terminal.Style, out: *std.Io.Writer) !void {
    // A call that failed reports why, whatever it was asked to do. The whole
    // result is billy's own message, so it is shown the way billy shows a
    // failure.
    if (std.mem.startsWith(u8, result, "error: ")) {
        try printLabel("output", style, out);
        return printTruncated(result, .{ .hue = .red }, style, out);
    }
    switch (call) {
        // A write succeeds by putting the content in the file, so that content
        // is what it produced. It is on the call rather than in the result, so a
        // replayed session shows it without it having to be stored twice.
        .write => |args| {
            try printLabel("output", style, out);
            return printTruncated(args.content, .dim, style, out);
        },
        // An edit's result would only repeat the diff shown above it.
        .edit => {},
        .bash => return printBash(result, style, out),
        else => {
            try printLabel("output", style, out);
            return printTruncated(result, .dim, style, out);
        },
    }
}

/// Prints the output of a bash call: the status the command exited with, and
/// then whatever it printed, one stream at a time. A command that printed
/// nothing shows its status alone, and each stream that has anything follows on
/// its own lines under a label naming it.
///
/// The status and the split are read back from the result, which is what billy
/// stored and handed the model, so a replayed session shows the same block.
fn printBash(result: []const u8, style: Terminal.Style, out: *std.Io.Writer) !void {
    const parts = splitBash(result) orelse {
        // A result that is not one billy wrote is shown as it is, so a session
        // saved before the status was written still shows everything.
        try printLabel("output", style, out);
        return printTruncated(result, .dim, style, out);
    };
    try printExit(parts.status, style, out);
    const streams = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "stdout", .text = parts.stdout },
        .{ .name = "stderr", .text = parts.stderr },
    };
    for (streams) |stream| {
        if (stream.text.len == 0) continue;
        try printLabel(stream.name, style, out);
        try printTruncated(stream.text, .dim, style, out);
    }
}

/// Prints the status a bash result opens with, on a line of its own: `✓ exit 0`
/// in green when the command succeeded, `✗ exit 1` and the rest in red when it
/// did not. The stored line reads `exit code: N` for the model; only the line
/// the user sees is marked and shortened.
fn printExit(status: []const u8, style: Terminal.Style, out: *std.Io.Writer) !void {
    const exit = parseExit(status);
    const mark = if (exit.ok) exit_marks.ok else exit_marks.failed;
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} exit {s}", .{ mark, exit.code }) catch status;
    try style.boldColor(if (exit.ok) .green else .red, line, out);
    try out.writeAll("\n");
}

/// The status a bash command exited with, as the user is shown it: the code, and
/// whether it means the command succeeded.
pub const Exit = struct {
    /// The status billy wrote, which is the exit code as text, or the signal a
    /// killed command died from.
    code: []const u8,
    /// Whether the command succeeded, which is an exit code of zero.
    ok: bool,
};

/// Reads the status out of a stored status line, which reads `exit code: N`.
/// A line of some other shape is taken as the code itself, so nothing is lost.
fn parseExit(status: []const u8) Exit {
    const prefix = "exit code: ";
    const code = if (std.mem.startsWith(u8, status, prefix)) status[prefix.len..] else status;
    return .{ .code = code, .ok = std.mem.eql(u8, code, "0") };
}

/// A bash result split back into the status line billy wrote and what the
/// command printed on each stream. Null when the result does not open with a
/// status, which is how a result stored before one was written reads.
const BashResult = struct {
    status: []const u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// A bash result as a caller that shows it wants it: the status on its own, and
/// the two streams without the markers that separated them in the stored text.
pub const BashOutput = struct {
    exit: Exit,
    stdout: []const u8,
    stderr: []const u8,
};

/// Splits a stored bash result into the status and the streams, for a frontend
/// that shows them apart. Null when the result is not one billy wrote.
pub fn bashOutput(result: []const u8) ?BashOutput {
    const parts = splitBash(result) orelse return null;
    return .{
        .exit = parseExit(parts.status),
        .stdout = parts.stdout,
        .stderr = parts.stderr,
    };
}

/// Splits a stored bash result. The shape is the one `bash` writes: the status
/// on its own line, `(no output)` when the command printed nothing at all, the
/// standard output, and finally the standard error behind a `stderr:` line of
/// its own.
fn splitBash(result: []const u8) ?BashResult {
    const newline = std.mem.indexOfScalar(u8, result, '\n') orelse return null;
    const status = result[0..newline];
    if (!std.mem.startsWith(u8, status, "exit code: ")) return null;
    const body = result[newline + 1 ..];
    const trimmed = std.mem.trimEnd(u8, body, "\n");

    if (std.mem.eql(u8, trimmed, "(no output)")) {
        return .{ .status = status, .stdout = "", .stderr = "" };
    }
    // Standard error follows standard output, introduced by a `stderr:` line of
    // its own wherever the standard output ended.
    const marker = "stderr:\n";
    if (std.mem.startsWith(u8, body, marker)) {
        return .{ .status = status, .stdout = "", .stderr = body[marker.len..] };
    }
    if (std.mem.indexOf(u8, body, "\n" ++ marker)) |at| {
        return .{
            .status = status,
            .stdout = body[0..at],
            .stderr = body[at + marker.len + 1 ..],
        };
    }
    return .{ .status = status, .stdout = body, .stderr = "" };
}

/// Prints `text`, keeping at most `max_block_lines` lines. When it had more, a
/// count of the rest is printed in place of them, so the block stays short
/// without hiding that there was more. Every line is printed in `ink`, which is
/// dim for a tool's output and a colour for billy's own message.
fn printTruncated(text: []const u8, ink: Ink, style: Terminal.Style, out: *std.Io.Writer) !void {
    const body = std.mem.trimEnd(u8, text, "\n");
    if (body.len == 0) return;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (shown == max_block_lines) continue;
        try printInk(line, ink, style, out);
        try out.writeAll("\n");
        shown += 1;
    }
    if (total > shown) {
        try out.print("{s}… {d} more lines{s}\n", .{ style.on("2"), total - shown, style.off() });
    }
}

/// The tools every session is offered, in the order the model receives them.
const specs = [_]Session.Definition{
    .{
        .name = "read",
        .description = "Read a file. Returns the lines with their line numbers.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to read.\"}," ++
            "\"offset\":{\"type\":\"integer\",\"description\":\"First line to read, 1-based. Defaults to 1.\"}," ++
            "\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of lines. Defaults to 2000.\"}}," ++
            "\"required\":[\"path\"]}",
    },
    .{
        .name = "write",
        .description = "Write a file, creating parent directories and replacing any existing content.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to write.\"}," ++
            "\"content\":{\"type\":\"string\",\"description\":\"Complete content of the file.\"}}," ++
            "\"required\":[\"path\",\"content\"]}",
    },
    .{
        .name = "edit",
        .description = "Replace text in a file. The text is matched exactly when it can be and ignoring whitespace otherwise, so a copied line need not be perfect. Fails unless it is found exactly once, unless replace_all is true.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to edit.\"}," ++
            "\"old_string\":{\"type\":\"string\",\"description\":\"Text to replace, one or more whole lines. Matched exactly, or ignoring whitespace when it does not match exactly.\"}," ++
            "\"new_string\":{\"type\":\"string\",\"description\":\"Replacement text.\"}," ++
            "\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every occurrence instead of requiring a unique match. Defaults to false.\"}}," ++
            "\"required\":[\"path\",\"old_string\",\"new_string\"]}",
    },
    .{
        .name = "bash",
        .description = "Run a shell command with bash -c and return its output and exit code. " ++
            "Give a short description of what the command does, so the user can see the intent at a glance.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"command\":{\"type\":\"string\",\"description\":\"Command to run.\"}," ++
            "\"description\":{\"type\":\"string\",\"description\":\"A short, one-line description of what the command does, so the user can tell at a glance without reading the command, e.g. \\\"run the test suite\\\".\"}}," ++
            "\"required\":[\"command\",\"description\"]}",
    },
};

/// The tool that is offered only when a search backend is configured, since it
/// can do nothing without one. It comes last, after the tools every session
/// has, so a session that gains it appends to the set rather than reordering it.
const search_spec = Session.Definition{
    .name = "web_search",
    .description = "Search the web and return the top results: a title, a url and a snippet for each.",
    .parameters = "{\"type\":\"object\",\"properties\":{" ++
        "\"query\":{\"type\":\"string\",\"description\":\"What to search for.\"}}," ++
        "\"required\":[\"query\"]}",
};

/// The tool that fetches one url, offered with web search since both need a
/// backend's key. A page is returned as the markdown the backend extracted; a
/// JSON or plain-text address is read directly with `raw`, so its bytes are not
/// escaped.
const fetch_spec = Session.Definition{
    .name = "web_fetch",
    .description = "Fetch a url and return its content. A page comes back as markdown; set raw for an API or a file, whose bytes are returned as they are.",
    .parameters = "{\"type\":\"object\",\"properties\":{" ++
        "\"url\":{\"type\":\"string\",\"description\":\"The url to fetch.\"}," ++
        "\"raw\":{\"type\":\"boolean\",\"description\":\"Read the url directly instead of extracting a page, for JSON or plain text, whose bytes would be changed by extraction. Defaults to false.\"}}," ++
        "\"required\":[\"url\"]}",
};

/// The tools a backend adds: web search and web fetch. They come last, after the
/// tools every session has, so a session that gains them appends to the set
/// rather than reordering it.
const web_specs = [_]Session.Definition{ search_spec, fetch_spec };

/// `specs` with the web tools appended, for a run that has a backend. The order
/// is what keeps the set growing by appending rather than reordering.
const specs_with_web = specs ++ web_specs;

/// How many of `source` the mode allows.
fn allowedCount(comptime source: []const Session.Definition, comptime mode: agent.Mode) usize {
    var n: usize = 0;
    for (source) |spec| if (mode.allows(spec.name)) {
        n += 1;
    };
    return n;
}

/// The specs of `source` the mode allows, filtered at comptime so the result is
/// the spec table's own strings and nothing is built at run time. Returned by
/// value: a slice would point into a comptime local, which a global const may
/// not hold.
fn allowedSpecs(comptime source: []const Session.Definition, comptime mode: agent.Mode) [allowedCount(source, mode)]Session.Definition {
    var buffer: [allowedCount(source, mode)]Session.Definition = undefined;
    var n: usize = 0;
    for (source) |spec| {
        if (!mode.allows(spec.name)) continue;
        buffer[n] = spec;
        n += 1;
    }
    return buffer;
}

const chat_specs = allowedSpecs(&specs, .chat);
const chat_specs_with_web = allowedSpecs(&specs_with_web, .chat);

test "exit codes of signals follow the shell convention" {
    try std.testing.expectEqual(0, formatting.exitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(1, formatting.exitCode(.{ .exited = 1 }));
    try std.testing.expectEqual(130, formatting.exitCode(.{ .signal = .INT }));
    try std.testing.expectEqual(143, formatting.exitCode(.{ .signal = .TERM }));
}

test "describe frames a call and its output" {
    try expectDescribe(
        "▸ read a.zig\n▾ output\nfile content\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "file content",
        .{},
    );
    // A write shows the content it put in the file, not its result.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nhello\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "wrote 5 bytes to a.zig",
        .{},
    );
    // A write that failed shows why instead of the content it never wrote.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nerror: cannot write a.zig: AccessDenied\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "error: cannot write a.zig: AccessDenied",
        .{},
    );
    // An edit shows the diff of the strings it worked on, not its result.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-old text\n+new text\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"old text\",\"new_string\":\"new text\"}",
        "replaced 1 occurrence(s) in a.zig",
        .{},
    );
    // The command of a bash call is printed whole.
    try expectDescribe(
        "❯ bash\nls -la\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"ls -la\"}",
        "exit code: 0\n(no output)\n",
        .{},
    );
    // A web search shows the query it ran, and its results under the output
    // label like any other text a tool returned.
    try expectDescribe(
        "⌕ web_search zig lang\n▾ output\n1. Zig\n   https://ziglang.org\n\n",
        "web_search",
        "{\"query\":\"zig lang\"}",
        "1. Zig\n   https://ziglang.org",
        .{},
    );
    // A web fetch shows the url it fetched, and the content it got back.
    try expectDescribe(
        "⇣ web_fetch https://ziglang.org\n▾ output\n# Zig\n\nA language.\n\n",
        "web_fetch",
        "{\"url\":\"https://ziglang.org\"}",
        "# Zig\n\nA language.",
        .{},
    );
    // A tool that is not implemented shows its name, and the reason it could not
    // run reaches the user as the output.
    try expectDescribe(
        "? frobnicate\n▾ output\nerror: unknown tool 'frobnicate'\n\n",
        "frobnicate",
        "{}",
        "error: unknown tool 'frobnicate'",
        .{},
    );
    // A known tool with broken arguments shows its name too.
    try expectDescribe(
        "? read\n▾ output\nerror: invalid arguments for read: SyntaxError\n\n",
        "read",
        "{",
        "error: invalid arguments for read: SyntaxError",
        .{},
    );
    // A failed edit still shows the change it meant to make, then why it did not.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-x\n+y\n▾ output\n" ++
            "error: old_string not found in a.zig\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"x\",\"new_string\":\"y\"}",
        "error: old_string not found in a.zig",
        .{},
    );
}

test "a block header names the tool, its colour, the bold name and the target" {
    // On a terminal that takes an escape code, the glyph carries the colour of
    // the tool, only the name is bold, and the target and the label are dimmed.
    try expectDescribe(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "",
        .{ .style = .ansi },
    );
    // A terminal that takes no escape code gets the same text without them.
    try expectDescribe("▸ read a.zig\n▾ output\n\n", "read", "{\"path\":\"a.zig\"}", "", .{});
}

test "a bash call's description is shown in its header" {
    // The description the model gave is the header's target, and the command it
    // describes is still shown whole under it.
    try expectDescribe(
        "❯ bash run the test suite\ncargo test\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"cargo test\",\"description\":\"run the test suite\"}",
        "exit code: 0\n",
        .{},
    );
    // A call from before the tool asked for a description has none, so the header
    // names only the tool; the command is still shown under it.
    try expectDescribe(
        "❯ bash\ncargo test\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"cargo test\"}",
        "exit code: 0\n",
        .{},
    );
    // A description that runs over several lines is shown by its first line only,
    // since a header is one line.
    try expectHead(
        "❯ bash build the project\nmake\n",
        "bash",
        "{\"command\":\"make\",\"description\":\"build the project\\nand its docs\"}",
        .{},
    );
}

test "the exit status of a bash call is shown green or red" {
    // A command that succeeded.
    try expectDescribe(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;32m✓ exit 0\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mbuilt\x1b[0m\n\n",
        "bash",
        "{\"command\":\"make\"}",
        "exit code: 0\nbuilt\n",
        .{ .style = .ansi },
    );
    // One that did not, whose output the terminal still shows as it is.
    try expectDescribe(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;31m✗ exit 2\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mboom\x1b[0m\n\n",
        "bash",
        "{\"command\":\"make\"}",
        "exit code: 2\nboom\n",
        .{ .style = .ansi },
    );
}

test "a bash block shows only the streams the command filled" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });
    const cases = [_]struct { command: []const u8, expected: []const u8 }{
        // Nothing printed: the status is all there is.
        .{ .command = "true", .expected = "❯ bash\ntrue\n✓ exit 0\n\n" },
        // One stream: it follows the status under a label of its own.
        .{ .command = "echo hi", .expected = "❯ bash\necho hi\n✓ exit 0\n▾ stdout\nhi\n\n" },
        .{ .command = "echo oops >&2", .expected = "❯ bash\necho oops >&2\n✓ exit 0\n▾ stderr\noops\n\n" },
        // Both, each under its own label, standard output first.
        .{ .command = "echo out; echo err >&2", .expected = "❯ bash\necho out; echo err >&2\n" ++
            "✓ exit 0\n▾ stdout\nout\n▾ stderr\nerr\n\n" },
        // A command that failed is the same shape with the status in red.
        .{ .command = "exit 3", .expected = "❯ bash\nexit 3\n✗ exit 3\n\n" },
    };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    for (cases) |case| {
        log.clearRetainingCapacity();
        result.clearRetainingCapacity();
        const arguments = try std.fmt.allocPrint(arena, "{{\"command\":{f}}}", .{
            std.json.fmt(case.command, .{}),
        });
        const parsed = try runCall(
            arena,
            &tool_set,
            .{ .id = "1", .function = .{ .name = "bash", .arguments = arguments } },
            &result.writer,
        );
        // `run` writes the result but shows nothing, so what a call and its
        // result look like is rendered here the way the terminal renders it.
        try describe(gpa, parsed, result.written(), .{}, .plain, &log.writer);
        try std.testing.expectEqualStrings(case.expected, log.written());
    }
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
    try describe(gpa, parse(arena, call), "built\nnothing to do", .{}, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "❯ bash\nmake\n▾ output\nbuilt\nnothing to do\n\n",
        out.written(),
    );
    // The split a frontend showing the status apart reads it with is null for
    // the same result, so such a frontend falls back to showing it whole.
    try std.testing.expect(bashOutput("built\nnothing to do") == null);
}

test "a bash result splits into its status and its streams" {
    // The status is the code and whether it means success, and the two streams
    // come back without the markers that separated them in the stored text.
    const failed = bashOutput("exit code: 2\nbuilt\nstderr:\nboom\n").?;
    try std.testing.expectEqualStrings("2", failed.exit.code);
    try std.testing.expect(!failed.exit.ok);
    try std.testing.expectEqualStrings("built", failed.stdout);
    try std.testing.expectEqualStrings("boom\n", failed.stderr);

    const ok = bashOutput("exit code: 0\nhello\n").?;
    try std.testing.expectEqualStrings("0", ok.exit.code);
    try std.testing.expect(ok.exit.ok);
    try std.testing.expectEqualStrings("hello\n", ok.stdout);
    try std.testing.expectEqualStrings("", ok.stderr);

    // A command that printed nothing has no streams, and `(no output)` is not
    // one of them.
    const quiet = bashOutput("exit code: 0\n(no output)\n").?;
    try std.testing.expectEqualStrings("", quiet.stdout);
    try std.testing.expectEqualStrings("", quiet.stderr);
}

test "what a call failed with is shown red, and what it left out is dimmed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A failure is billy's own message, so the whole result is shown as one.
    try describe(gpa, parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "error: cannot read a.zig: FileNotFound", .{}, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n" ++
            "\x1b[31merror: cannot read a.zig: FileNotFound\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The count of the lines left out is structure too, so it is dimmed.
    try describe(
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        .{},
        .ansi,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n" ++
            "\x1b[2m1\x1b[0m\n\x1b[2m2\x1b[0m\n\x1b[2m3\x1b[0m\n\x1b[2m4\x1b[0m\n\x1b[2m5\x1b[0m\n" ++
            "\x1b[2m… 2 more lines\x1b[0m\n\n",
        out.written(),
    );
}

test "a bash command is shown the way the formatter lays it out" {
    // The format script reads the command and writes it back upper case, the
    // way `shfmt | bat -l bash` reads it and writes it back laid out. The
    // command is shown as the formatter wrote it; its trailing newline does not
    // leave a blank line in the block.
    const format: Format = .{ .script = "tr a-z A-Z | cat", .io = std.testing.io, .gpa = std.testing.allocator };
    try expectDescribe(
        "❯ bash\nLS -LA\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"ls -la\\n\"}",
        "exit code: 0\n(no output)\n",
        .{ .formats = .{ .bash = format } },
    );
}

test "a bash command is shown as written when the formatter cannot lay it out" {
    // A formatter that cannot be run, one that fails and one that writes nothing
    // all leave the command the model wrote for the user to read.
    const scripts = [_][]const u8{ "billy-no-such-formatter", "exit 1", "true" };
    for (scripts) |script| {
        const format: Format = .{ .script = script, .io = std.testing.io, .gpa = std.testing.allocator };
        try expectDescribe(
            "❯ bash\nls -la\n✓ exit 0\n\n",
            "bash",
            "{\"command\":\"ls -la\"}",
            "exit code: 0\n(no output)\n",
            .{ .formats = .{ .bash = format } },
        );
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
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5",
        .{},
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
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        .{},
        .plain,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "▸ read a.zig\n▾ output\n1\n2\n3\n4\n5\n… 2 more lines\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An empty result leaves the header with nothing under it.
    try describe(arena_state.allocator(), .{ .read = .{ .path = "a.zig" } }, "", .{}, .plain, &out.writer);
    try std.testing.expectEqualStrings("▸ read a.zig\n▾ output\n\n", out.written());
    out.clearRetainingCapacity();

    // An edit shows the diff of the strings it worked on: the whole old side,
    // then the new, each line marked.
    try describe(
        arena_state.allocator(),
        .{ .edit = .{
            .path = "a.zig",
            .old_string = "1\n2\n3\n4\n5\n6",
            .new_string = "b",
        } },
        "replaced 1 occurrence(s) in a.zig",
        .{},
        .plain,
        &out.writer,
    );
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\n-1\n-2\n-3\n-4\n-5\n-6\n+b\n\n",
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
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const parsed = try runCall(arena, &tool_set, call, &result.writer);

    try describe(gpa, parsed, result.written(), .{}, .plain, &log.writer);
    try std.testing.expectEqualStrings(
        "❯ bash\ntrue\n✓ exit 0\n\n",
        log.written(),
    );
}

test "the format changes what is shown and nothing else" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    // The format script writes the command back upper case, so what is shown is
    // plainly not what runs.
    const format: Format = .{ .script = "tr a-z A-Z", .io = std.testing.io, .gpa = gpa };
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .formats = .{ .bash = format },
        .bash_timeout_s = 120,
        .http = &http,
    });
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const parsed = try runCall(arena, &tool_set, call, &result.writer);

    // The command that ran is the one the model wrote, so the result is its
    // output, and the user reads the command as the formatter laid it out.
    try std.testing.expectEqualStrings("exit code: 0\nhi\n", result.written());
    try describe(gpa, parsed, result.written(), .{ .bash = format }, .plain, &log.writer);
    try std.testing.expectEqualStrings(
        "❯ bash\nECHO HI\n✓ exit 0\n▾ stdout\nhi\n\n",
        log.written(),
    );
}

test "an edit diff is laid out by the edit format" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The script writes the diff back upper case, so what is shown is plainly not
    // what billy would render itself.
    const format: Format = .{ .script = "tr a-z A-Z", .io = std.testing.io, .gpa = gpa };
    const call: Call = .{ .edit = .{
        .path = "a.zig",
        .old_string = "old",
        .new_string = "new",
    } };
    try describe(gpa, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\n-OLD\n+NEW\n\n",
        out.written(),
    );
}

test "an edit's two sides reach the format script as files" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The script ignores its standard input and reads back the two files it was
    // handed, so what it shows proves the sides arrived as files it can name.
    const format: Format = .{
        .script = "printf '%s %s' \"$(cat \"$1\")\" \"$(cat \"$2\")\"",
        .io = std.testing.io,
        .gpa = gpa,
    };
    const call: Call = .{ .edit = .{
        .path = "a.zig",
        .old_string = "was here",
        .new_string = "now here",
    } };
    try describe(gpa, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\nwas here now here\n\n",
        out.written(),
    );
}

test "an edit's sides are billy's own files in the temporary directory" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The arguments are the paths, which are billy's own in the temporary
    // directory, each with a random suffix before the kind so two runs do not
    // collide.
    const format: Format = .{
        .script = "printf '%s %s' \"$1\" \"$2\"",
        .io = std.testing.io,
        .gpa = gpa,
    };
    const call: Call = .{ .edit = .{ .path = "a.zig", .old_string = "x", .new_string = "y" } };
    try describe(gpa, call, "", .{ .edit = format }, .plain, &out.writer);

    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "✎ edit a.zig\n▾ diff\n/tmp/billy-edit-"));
    try std.testing.expect(std.mem.indexOf(u8, written, "-old /tmp/billy-edit-") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, written, "\n"), "-new"));
}

test "an edit whose format script fails falls back to billy's own diff" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const format: Format = .{ .script = "exit 1", .io = std.testing.io, .gpa = gpa };
    const call: Call = .{ .edit = .{ .path = "a.zig", .old_string = "b", .new_string = "x" } };
    try describe(gpa, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
    try std.testing.expectEqualStrings("✎ edit a.zig\n▾ diff\n-b\n+x\n\n", out.written());
}

test "a bash command that outlives the timeout is killed and reported" {
    const gpa = std.testing.allocator;

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    // A one-second limit kills a command that would otherwise run far longer,
    // and the model is told so rather than left waiting for it to finish.
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .bash_timeout_s = 1,
        .http = &http,
    });
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"sleep 30\"}",
    } };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    var parse_state = std.heap.ArenaAllocator.init(gpa);
    defer parse_state.deinit();
    _ = try runCall(parse_state.allocator(), &tool_set, call, &result.writer);

    try std.testing.expectEqualStrings(
        "error: command did not finish within 1s and was killed",
        result.written(),
    );
}

test "parseCall splits known, unknown and malformed calls" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_call = parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\",\"offset\":5}",
    } });
    try std.testing.expectEqualStrings("a.zig", read_call.read.path);
    try std.testing.expectEqual(@as(?usize, 5), read_call.read.offset);

    const missing = parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{}",
    } });
    try std.testing.expectEqualStrings("bash", missing.malformed.name);

    // A bash call carries the description the model wrote when there is one, and
    // none when there is not, which is how a call stored before the tool asked
    // for one reads.
    const described = parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\",\"description\":\"build it\"}",
    } });
    try std.testing.expectEqualStrings("make", described.bash.command);
    try std.testing.expectEqualStrings("build it", described.bash.description.?);

    const bare = parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\"}",
    } });
    try std.testing.expect(bare.bash.description == null);

    const unknown = parse(arena, .{ .id = "1", .function = .{
        .name = "frobnicate",
        .arguments = "{}",
    } });
    try std.testing.expectEqualStrings("frobnicate", unknown.unknown);
}

/// How a call is shown, for a test: the formatter scripts for a tool's block
/// and the terminal style. `.{}` is what the tests mostly want -- no script, no
/// escape codes -- so a test that wants a colour or a formatter says only that.
const Shown = struct {
    formats: Formats = .{},
    style: Terminal.Style = .plain,
};

/// Renders a call named `name` with `arguments` and the `result` it produced,
/// and checks it against `expected`. One call is one line of the test.
fn expectDescribe(
    expected: []const u8,
    name: []const u8,
    arguments: []const u8,
    result: []const u8,
    shown: Shown,
) !void {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try describe(arena_state.allocator(), parse(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), result, shown.formats, shown.style, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Writes the header of a call named `name` with `arguments`, and checks it
/// against `expected`. A header alone, without a result under it.
fn expectHead(expected: []const u8, name: []const u8, arguments: []const u8, shown: Shown) !void {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try printHead(arena_state.allocator(), parse(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), shown.formats, shown.style, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

fn testTools(with_search: bool) !Tools {
    return Tools.init(.{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .dir = .cwd(),
        .bash_timeout_s = 120,
        .search = if (with_search) .{
            .backends = &.{.{ .provider = .tavily, .api_key = "key" }},
            .max_results = 3,
        } else null,

        // A web tool that actually makes a request needs a live client; the
        // tests here only exercise the ones that refuse before any request, so
        // this is never reached.
        .http = undefined,
    });
}

test "a failure is written the way a reader knows it is one" {
    // Every tool that fails goes through `fail`, so what it writes begins with
    // the mark both readers branch on: the terminal colours it as a failure and
    // the page draws it as one. A tool that wrote its own message without that
    // mark would read as a call that answered.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try fail(&out.writer, "cannot do {s}", .{"the thing"});
    try std.testing.expectEqualStrings("error: cannot do the thing", out.written());
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: "));
}

test "a fetch that fails reaches the reader as a failure" {
    // The mark is not decoration: `printResult` and `html.block` both tell a
    // failed call from one that answered by looking for it, so a fetch that
    // failed without it would be shown as a call that succeeded and said
    // "fetch failed: ...".
    //
    // The url is empty, which the tool refuses before it reaches a backend, so
    // this says what a reader is given without a request being made.
    const gpa = std.testing.allocator;
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();

    const call = parse(gpa, .{ .id = "1", .function = .{
        .name = "web_fetch",
        .arguments = "{\"url\":\"\"}",
    } });
    var tool_set = try testTools(true);
    try tool_set.run(call, &result.writer);
    try std.testing.expectEqualStrings("error: no url to fetch", result.written());

    // And the reader is told it failed, rather than reading the text as an
    // answer the call gave.
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try printResult(call, result.written(), .ansi, &shown.writer);
    try std.testing.expect(std.mem.indexOf(u8, shown.written(), "output") != null);
}

test "the definitions cover every tool the loop dispatches" {
    const gpa = std.testing.allocator;
    var tool_set = try testTools(false);

    // The names are exactly the tools the loop can dispatch, in the order the
    // model receives them, so it is never offered one that does not run.
    const offered = tool_set.definitions(.general);
    const expected = [_][]const u8{ "read", "write", "edit", "bash" };
    try std.testing.expectEqual(expected.len, offered.len);
    for (offered, expected) |definition, name| {
        try std.testing.expectEqualStrings(name, definition.name);
        // The schema is the JSON text it is sent as, so it has to be JSON: it is
        // built by hand, and a mistyped escape would make every request carrying
        // it invalid. Parsing it here is what catches that.
        const schema = try std.json.parseFromSlice(std.json.Value, gpa, definition.parameters, .{});
        defer schema.deinit();
        try std.testing.expect(schema.value == .object);
    }
}

test "the web tools are offered only when a backend is configured" {
    // With nothing configured neither web tool is offered at all, and the tools
    // every session has come first so the set only grows.
    var plain = try testTools(false);
    const without = plain.definitions(.general);
    try std.testing.expectEqual(specs.len, without.len);
    for (without) |definition| {
        try std.testing.expect(!std.mem.eql(u8, definition.name, "web_search"));
        try std.testing.expect(!std.mem.eql(u8, definition.name, "web_fetch"));
    }

    // With one backend, both tools are appended -- a search is offered with the
    // fetch that reads what it found -- so a session that gains them keeps the
    // tools it had.
    var searched = try testTools(true);
    const with = searched.definitions(.general);
    try std.testing.expectEqual(specs.len + web_specs.len, with.len);
    try std.testing.expectEqualStrings("web_search", with[with.len - 2].name);
    try std.testing.expectEqualStrings("web_fetch", with[with.len - 1].name);
}

test "the tools work in the directory they are given, wherever billy runs" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A project directory that is not the one the tests run in, which is the
    // case a resumed session is in: it was started somewhere else.
    try tmp.dir.createDirPath(std.testing.io, "project");
    var work = try tmp.dir.openDir(std.testing.io, "project", .{});
    defer work.close(std.testing.io);

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = work,
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });

    // A file written by the tool lands in that directory. The result is not
    // what this is about, so it is discarded.
    var sink: std.Io.Writer.Discarding = .init("");
    _ = try runCall(arena, &tool_set, .{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"note.txt\",\"content\":\"hi\"}",
    } }, &sink.writer);
    const written = try tmp.dir.readFileAlloc(std.testing.io, "project/note.txt", arena, .limited(64));
    try std.testing.expectEqualStrings("hi", written);

    // And a command runs there too, so `pwd` reports that directory and not the
    // one billy was started in.
    log.clearRetainingCapacity();
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    _ = try runCall(arena, &tool_set, .{ .id = "2", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }, &result.writer);
    try std.testing.expect(std.mem.indexOf(u8, result.written(), "/project\n") != null);
}

test "the limiting writer gathers writes, then passes on what fits" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Small, so writes spill out of it and the limit is exercised across the
    // gathers rather than all in one go.
    var buffer: [4]u8 = undefined;

    // What is written is gathered, not passed on, until the buffer fills or it
    // is flushed: the point of the buffer is that writing a little at a time is
    // not a call to the writer behind this every time.
    var roomy = Limited.init(&out.writer, &buffer, 100);
    try roomy.writer.writeAll("he");
    try std.testing.expectEqualStrings("", out.written());
    try roomy.writer.writeAll("llo");
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(0, roomy.dropped);

    // A write still in the buffer at the end reaches the writer on a flush, and
    // is counted only then.
    out.clearRetainingCapacity();
    var gathered = Limited.init(&out.writer, &buffer, 100);
    try gathered.writer.writeAll("ab");
    try std.testing.expectEqualStrings("", out.written());
    try gathered.writer.flush();
    try std.testing.expectEqualStrings("ab", out.written());
    try std.testing.expectEqual(0, gathered.dropped);
    // Two bytes of the hundred are spent, so what is left of the limit is 98.
    try std.testing.expectEqual(98, gathered.remaining);

    // Exactly to the limit is still nothing dropped, so a result that lands on
    // the cap is not reported as cut.
    out.clearRetainingCapacity();
    var exact = Limited.init(&out.writer, &buffer, 5);
    try exact.writer.writeAll("hello");
    try exact.writer.flush();
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(0, exact.dropped);

    // Past it, the limit is where the writing stops and the rest is counted, in
    // as many writes as it took.
    out.clearRetainingCapacity();
    var tight = Limited.init(&out.writer, &buffer, 5);
    try tight.writer.writeAll("he");
    try tight.writer.writeAll("llo wor");
    try tight.writer.writeAll("ld");
    try tight.writer.flush();
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(6, tight.dropped);

    // A write that arrives repeated counts every repeat, and the ones past the
    // limit are dropped like any other. This is the shape `{s:>5}` and its
    // padding take, so the count has to be right for it too.
    out.clearRetainingCapacity();
    var splatted = Limited.init(&out.writer, &buffer, 4);
    var repeated = [_][]const u8{"ab"};
    try splatted.writer.writeSplatAll(&repeated, 3);
    try splatted.writer.flush();
    try std.testing.expectEqualStrings("abab", out.written());
    try std.testing.expectEqual(2, splatted.dropped);

    // A writer with a limit of zero writes nothing and counts all of it.
    out.clearRetainingCapacity();
    var none = Limited.init(&out.writer, &buffer, 0);
    try none.writer.writeAll("gone");
    try none.writer.flush();
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqual(4, none.dropped);
}

/// A writer with no buffer of its own, so every write is handed straight to it
/// and it can count how many hand-offs there were. What a test uses to tell
/// batching from byte-at-a-time.
const Counter = struct {
    written: usize = 0,
    hand_offs: usize = 0,
    writer: std.Io.Writer,

    fn init() Counter {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counter = @alignCast(@fieldParentPtr("writer", w));
        self.hand_offs += 1;
        var count: usize = data[data.len - 1].len * splat;
        for (data[0 .. data.len - 1]) |bytes| count += bytes.len;
        self.written += count;
        return count;
    }
};

test "the limiting writer hands the repeats over together" {
    // A buffer too small to gather the repeats, so they reach the writer behind
    // this and the count of hand-offs says whether they went one at a time.
    var buffer: [2]u8 = undefined;

    var counter = Counter.init();
    var limited = Limited.init(&counter.writer, &buffer, 1000);
    var repeats = [_][]const u8{"x"};
    try limited.writer.writeSplatAll(&repeats, 6);
    try limited.writer.flush();

    // Six copies of one byte, handed over in a couple of writes rather than six:
    // the padding of a format such as `{d:>6}` is one write, not one per space.
    try std.testing.expectEqual(6, counter.written);
    try std.testing.expect(counter.hand_offs <= 2);
}

test "a result longer than the cap is cut and says what it lost" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Far more than the cap, so the cut is plainly not the whole file.
    const line = @as([99]u8, @splat('x')) ++ "\n";
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..1000) |_| try big.appendSlice(gpa, line);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = big.items });

    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = tmp.dir,
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    _ = try runCall(arena, &tool_set, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"big.txt\"}",
    } }, &result.writer);

    // What is kept is the cap and the note, and what the note counts is exactly
    // what the tool wrote past the cap.
    const written = result.written();
    const marker = "\n… ";
    const cut = std.mem.indexOf(u8, written, marker) orelse return error.NoTruncation;
    // What the reader kept is exactly the cap, and what the note counts is
    // everything past it. The reader numbers each line, so what it wrote is not
    // the file's length: four columns for the number (1000 is the largest), a
    // colon and a space, the ninety-nine characters of the line and its newline,
    // a thousand times.
    try std.testing.expectEqual(max_result_len, cut);
    const per_line = 4 + 2 + 99 + 1;
    const written_by_tool = 1000 * per_line;
    const lost = try std.fmt.parseInt(usize, written[cut + marker.len .. written.len - " more bytes".len], 10);
    try std.testing.expectEqual(written_by_tool - max_result_len, lost);
}
