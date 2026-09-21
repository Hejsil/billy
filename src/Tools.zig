//! The tools the agent can call, together with their JSON Schema descriptions.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const Search = @import("search.zig");
const formatting = @import("format.zig");
const diffing = @import("diff.zig");
const styling = @import("style.zig");
const Session = @import("Session.zig");

const Tools = @This();

/// Laying a bash command out for the display.
pub const Format = formatting.Format;
/// How billy decorates the lines it prints itself.
pub const Style = styling.Style;
/// A foreground colour for those lines.
pub const Color = styling.Color;

/// The formatter scripts a tool's block is laid out with, gathered so a caller
/// passes one value rather than a run of them. A bash command and an edit diff
/// are the two things a script lays out; either may be null to show the text as
/// written.
///
/// The layout is presentation only: the command that runs, the diff of the call,
/// what a session stores and what the model is sent keep the text it was given.
pub const Formats = struct {
    /// How a bash command is laid out before it is shown.
    bash: Format = null,
    /// How an edit's diff is laid out before it is shown.
    edit: Format = null,
};

/// The mark a block header opens with.
const Mark = styling.Mark;

/// Longest result handed back to the model, so one command cannot flood the
/// conversation.
const max_result_len = 30_000;
/// Longest output captured from one command.
const max_command_output = 1 << 20;
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
    web_search: WebSearch,
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

    pub const WebSearch = struct {
        query: []const u8,
    };

    pub const Malformed = struct {
        name: []const u8,
        reason: anyerror,
    };
};

io: Io,
/// The directory the tools work in: the one the session was started in, so a
/// resumed session reads and writes where it did rather than wherever billy
/// happens to be run from. Every path a tool is given is relative to it.
dir: Io.Dir,
/// For temporary buffers.
gpa: std.mem.Allocator,
/// Reports tool activity to the user.
log: *Io.Writer,
/// How a tool's block is laid out for the user. Shared with the transcript, so a
/// replayed session shows a call the way the run did.
formats: Formats,
/// Longest a bash command may run before it is killed, in seconds. Set by
/// the configuration, so a runaway command cannot hang the agent forever.
bash_timeout_s: usize,
/// How the lines billy prints itself are decorated. Shared with the
/// transcript, so a replayed session looks like the run it continues.
style: Style,
/// The web search client, or null when no backend is configured. A null
/// leaves `web_search` out of the tool set billy offers, so the model is never
/// given a tool that could not run.
search: ?Search.Client,
/// One call's scratch: the parsed arguments and the result. It is reset at the
/// start of every call, so nothing here outlives the call that made it; the
/// caller interns what it keeps. That is what keeps a long conversation from
/// holding every result, and what lets the tools take no allocator of their own.
scratch: std.heap.ArenaAllocator,

/// What a tool set is built from, gathered into one so the constructor reads
/// as what each value is rather than as a run of positional arguments, which
/// had grown too long to read at the call site.
pub const Options = struct {
    io: Io,
    /// The directory the tools work in. See `Tools.dir`.
    dir: Io.Dir,
    /// For temporary buffers.
    gpa: std.mem.Allocator,
    /// Reports tool activity to the user.
    log: *Io.Writer,
    /// How a tool's block is laid out for the user. Null layouts, for both a bash
    /// command and an edit diff, show the text as written.
    formats: Formats = .{},
    /// Longest a bash command may run before it is killed, in seconds. No
    /// default: every caller has one to give, and a missing one is a mistake
    /// worth catching at the call site rather than papering over with 120.
    bash_timeout_s: usize,
    /// How the lines billy prints itself are decorated.
    style: Style = .plain,
    /// The backend the configuration asked for, with its key resolved, or null
    /// to leave web search out. A null also leaves `web_search` out of the
    /// tool set billy offers, so the model is never given a tool that could
    /// not run.
    search: ?Search.Config = null,
    /// The run's one HTTP client, borrowed by the search backend when one is
    /// configured, so a search shares connections and scanned certificates
    /// with the model requests.
    http: *std.http.Client,
};

pub fn init(options: Options) !Tools {
    return .{
        .io = options.io,
        .dir = options.dir,
        .gpa = options.gpa,
        .log = options.log,
        .formats = options.formats,
        .bash_timeout_s = options.bash_timeout_s,
        .style = options.style,
        .search = if (options.search) |config| .{
            .io = options.io,
            .gpa = options.gpa,
            .provider = config.provider,
            .api_key = config.api_key,
            .max_results = config.max_results,
            .http = options.http,
        } else null,
        .scratch = .init(options.gpa),
    };
}

/// Frees what a tool set owns. The definitions are built from comptime strings
/// and go straight into the session, so the scratch is all there is.
pub fn deinit(tools: *Tools) void {
    tools.scratch.deinit();
}

/// The definitions a session should be given: every tool billy offers, with the
/// search tool last when a backend is configured. The strings are the spec
/// table's own, which are comptime, so this builds nothing; the session interns
/// and stores them.
pub fn definitions(tools: *const Tools) []const Session.Definition {
    return if (tools.search != null) &specs_with_search else &specs;
}

/// Runs one tool call and returns its result. Tool failures are reported to
/// the model as text so that it can react to them.
///
/// What the user sees comes from `printHead` and `printResult`, which the
/// transcript reuses, so a replayed session shows exactly what a live one
/// did. The head goes out before the tool runs, so a slow command shows what
/// it is doing, and the result follows it.
///
/// The parsed call and the result live in the tools' own scratch, which is
/// dropped at the start of the next call. The caller interns what it keeps, so
/// the result only has to last until then, which keeps a long conversation from
/// holding every result. A caller that needs to keep one past the next call
/// must copy it.
pub fn run(tools: *Tools, call: llm.ToolCall) ![]const u8 {
    _ = tools.scratch.reset(.retain_capacity);
    const arena = tools.scratch.allocator();

    const parsed = parseCall(arena, call);
    try printHead(arena, parsed, tools.formats, tools.style, tools.log);
    try tools.log.flush();

    const result = switch (parsed) {
        .read => |args| try tools.read(args),
        .write => |args| try tools.write(args),
        .edit => |args| try tools.edit(args),
        .bash => |args| try tools.bash(args),
        .web_search => |args| try tools.webSearch(args),
        .unknown => |name| try fail(arena, "unknown tool '{s}'", .{name}),
        .malformed => |bad| try fail(
            arena,
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
    const arena = tools.scratch.allocator();
    const contents = tools.dir.readFileAlloc(
        tools.io,
        args.path,
        tools.gpa,
        .limited(16 << 20),
    ) catch |err| return fail(arena, "cannot read {s}: {s}", .{ args.path, @errorName(err) });
    defer tools.gpa.free(contents);

    // A trailing newline would otherwise read as a final empty line.
    const text = std.mem.trimEnd(u8, contents, "\n");
    if (text.len == 0) return arena.dupe(u8, "(empty file)");

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
        return std.fmt.allocPrint(arena, "offset {d} is past the end; {d} lines", .{ first, number });
    }
    if (shown == limit) {
        try out.writer.print("… {d} more lines\n", .{number - first + 1 - shown});
    }
    return finish(arena, out.written());
}

fn write(tools: *Tools, args: Call.Write) ![]const u8 {
    const arena = tools.scratch.allocator();
    if (std.fs.path.dirname(args.path)) |parent| {
        tools.dir.createDirPath(tools.io, parent) catch |err|
            return fail(arena, "cannot create {s}: {s}", .{ parent, @errorName(err) });
    }
    tools.dir.writeFile(tools.io, .{ .sub_path = args.path, .data = args.content }) catch |err|
        return fail(arena, "cannot write {s}: {s}", .{ args.path, @errorName(err) });
    return std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ args.content.len, args.path });
}

fn edit(tools: *Tools, args: Call.Edit) ![]const u8 {
    const arena = tools.scratch.allocator();
    if (args.old_string.len == 0) return fail(arena, "old_string must not be empty", .{});

    const contents = tools.dir.readFileAlloc(
        tools.io,
        args.path,
        tools.gpa,
        .limited(16 << 20),
    ) catch |err| return fail(arena, "cannot read {s}: {s}", .{ args.path, @errorName(err) });
    defer tools.gpa.free(contents);

    const change = try replaceInFile(
        tools.gpa,
        contents,
        args.old_string,
        args.new_string,
        args.replace_all,
    );
    switch (change) {
        .not_found => return fail(arena, "old_string not found in {s}", .{args.path}),
        .ambiguous => |count| return fail(
            arena,
            "old_string appears {d} times in {s}; add context or pass replace_all",
            .{ count, args.path },
        ),
        .applied => |applied| {
            defer tools.gpa.free(applied.text);
            tools.dir.writeFile(tools.io, .{
                .sub_path = args.path,
                .data = applied.text,
            }) catch |err| return fail(arena, "cannot write {s}: {s}", .{ args.path, @errorName(err) });
            return std.fmt.allocPrint(arena, "replaced {d} occurrence(s) in {s}", .{
                applied.count,
                args.path,
            });
        },
    }
}

fn bash(tools: *Tools, args: Call.Bash) ![]const u8 {
    const arena = tools.scratch.allocator();
    // The count the configuration holds is turned into the signed seconds
    // the clock takes. A value past what it can express is absurd but must
    // not overflow the cast, so it is clamped to the longest duration, which
    // is no limit in practice.
    const timeout_s = std.math.cast(i64, tools.bash_timeout_s) orelse std.math.maxInt(i64);
    const result = std.process.run(tools.gpa, tools.io, .{
        .argv = &.{ "bash", "-c", args.command },
        // The command runs where the session's tools do, so a resumed session
        // runs it in the directory the session was started in.
        .cwd = .{ .dir = tools.dir },
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        // A command that outlives the configured limit is killed, so a
        // runaway command cannot hang the agent forever.
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_s) } },
    }) catch |err| switch (err) {
        error.StreamTooLong => return fail(
            arena,
            "command produced more than {d} bytes of output",
            .{max_command_output},
        ),
        error.Timeout => return fail(
            arena,
            "command did not finish within {d}s and was killed",
            .{tools.bash_timeout_s},
        ),
        else => return fail(arena, "cannot run command: {s}", .{@errorName(err)}),
    };
    defer tools.gpa.free(result.stdout);
    defer tools.gpa.free(result.stderr);

    var out: std.Io.Writer.Allocating = .init(tools.gpa);
    defer out.deinit();
    try out.writer.print("exit code: {d}\n", .{formatting.exitCode(result.term)});
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try out.writer.writeAll("(no output)\n");
    }
    try out.writer.writeAll(result.stdout);
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) try out.writer.writeAll("\n");
        try out.writer.print("stderr:\n{s}", .{result.stderr});
    }
    return finish(arena, out.written());
}

/// Runs one web search and returns its results as text. No backend is
/// configured only when a resumed session carries the tool from a run that
/// had one; the model is told so rather than the call failing outright.
fn webSearch(tools: *Tools, args: Call.WebSearch) ![]const u8 {
    const arena = tools.scratch.allocator();
    const client = if (tools.search) |*client| client else return fail(arena, "web search is not configured", .{});
    return client.search(arena, args.query) catch |err|
        return fail(arena, "search failed: {s}", .{@errorName(err)});
}

/// A failure reported to the model as text, so that it can react to it. It is
/// written into the arena the call's result lives in, since that is where the
/// caller looks for the result of a call that went wrong.
fn fail(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "error: " ++ format, args);
}

/// A result as the model is given it, cut to `max_result_len` with a count of
/// what was left out.
fn finish(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= max_result_len) return arena.dupe(u8, text);
    return std.fmt.allocPrint(arena, "{s}\n… {d} more bytes", .{
        text[0..max_result_len],
        text.len - max_result_len,
    });
}

/// What replacing `old_string` in a file produced: the new contents and how many
/// places changed, or why no change could be made.
const Change = union(enum) {
    applied: struct {
        /// The file with the change made. Owned by the allocator the search ran
        /// with.
        text: []u8,
        /// How many places were changed.
        count: usize,
    },
    /// The text was not in the file, even ignoring whitespace.
    not_found,
    /// The text was in the file this many times, so which one to change is
    /// unclear.
    ambiguous: usize,
};

/// How `old_string` was found in the file. The rules are tried strictest first,
/// so text that matches exactly is changed where it is and only text that does
/// not is matched loosely: a loose rule never stands in for a real match, and
/// one that does match is never mistaken for another.
const Matching = enum {
    /// The text appears as it is written, byte for byte.
    exact,
    /// The text appears once trailing whitespace and the line ending are ignored
    /// on each line, which is what a model that retyped a copied line gets
    /// wrong.
    trailing_whitespace,
    /// The text also appears ignoring the indentation in front of each line,
    /// which is what a model that lost the file's indentation writes. The
    /// replacement is indented to match the file, so an edit does not flatten
    /// code the file had indented.
    indentation,
};

/// A byte range of the file.
const Span = struct { start: usize, end: usize };

/// Replaces `old_string` with `new_string` in `contents`, matching exactly when
/// it can and ignoring whitespace when it cannot. `replace_all` changes every
/// place the text appears; without it, text that appears more than once is
/// `ambiguous` rather than changed at a guess. The result is owned by `gpa`.
fn replaceInFile(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !Change {
    var rule: Matching = .exact;
    const spans = try findInFile(gpa, contents, old_string, &rule);
    defer gpa.free(spans);

    if (spans.len == 0) return .not_found;
    if (spans.len > 1 and !replace_all) return .{ .ambiguous = spans.len };

    // An exact match is already laid out the way the file is, so only a loosely
    // matched one is re-indented, to the indentation of the line it replaces.
    const replacement = if (rule == .exact)
        try gpa.dupe(u8, new_string)
    else
        try reindent(
            gpa,
            new_string,
            indentOf(firstLine(old_string)),
            indentOf(contents[spans[0].start..]),
        );
    defer gpa.free(replacement);

    const count = if (replace_all) spans.len else 1;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var at: usize = 0;
    for (spans[0..count]) |span| {
        try text.appendSlice(gpa, contents[at..span.start]);
        try text.appendSlice(gpa, replacement);
        at = span.end;
    }
    try text.appendSlice(gpa, contents[at..]);
    return .{ .applied = .{ .text = try text.toOwnedSlice(gpa), .count = count } };
}

/// Finds `old_string` in `contents`, exact first and then loosely, returning the
/// spans it covers in order and the rule that found them in `rule`. An empty
/// result means it was not found at all. The spans are owned by `gpa`.
fn findInFile(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    rule: *Matching,
) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    if (old_string.len == 0) return spans.toOwnedSlice(gpa);

    rule.* = .exact;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, contents, from, old_string)) |at| {
        try spans.append(gpa, .{ .start = at, .end = at + old_string.len });
        from = at + old_string.len;
    }
    if (spans.items.len > 0) return spans.toOwnedSlice(gpa);

    // Whole lines now: the text is lined up line by line, with the whitespace a
    // line carries left out of the comparison.
    for ([_]Matching{ .trailing_whitespace, .indentation }) |tier| {
        spans.clearRetainingCapacity();
        try findLines(gpa, contents, old_string, tier == .indentation, &spans);
        if (spans.items.len > 0) {
            rule.* = tier;
            return spans.toOwnedSlice(gpa);
        }
    }
    return spans.toOwnedSlice(gpa);
}

/// Finds `old_string` in `contents` as a run of whole lines, ignoring trailing
/// whitespace and, when `trim_leading`, the indentation in front of each line.
/// Every line of the text has to line up with a line of the file, so a match
/// spans as many lines as the text to find. The spans are appended to `spans`.
fn findLines(
    gpa: std.mem.Allocator,
    contents: []const u8,
    old_string: []const u8,
    trim_leading: bool,
    spans: *std.ArrayList(Span),
) !void {
    const file = try splitLines(gpa, contents);
    defer gpa.free(file);
    const find = try splitLines(gpa, old_string);
    defer gpa.free(find);
    if (find.len == 0 or find.len > file.len) return;

    // Whether the text ends on a newline says whether the line it stops on is
    // taken whole; without one, that line's own ending is left in the file.
    const ends_with_newline = old_string[old_string.len - 1] == '\n';

    var i: usize = 0;
    while (i + find.len <= file.len) : (i += 1) {
        var matches = true;
        for (find, 0..) |want, j| {
            const have = file[i + j];
            const want_text = normalized(old_string[want.start..want.content_end], trim_leading);
            const have_text = normalized(contents[have.start..have.content_end], trim_leading);
            if (!std.mem.eql(u8, want_text, have_text)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        const last = file[i + find.len - 1];
        try spans.append(gpa, .{
            .start = file[i].start,
            .end = if (ends_with_newline) last.end else last.content_end,
        });
    }
}

/// One line of a file, by the offsets it occupies: `start` is its first byte,
/// `content_end` the byte after its text, and `end` the byte after its line
/// ending, which is `content_end` on a last line that has none.
const FileLine = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

/// Splits `text` into the lines it holds, each with its offsets. Text that ends
/// on a newline does not gain an empty line after it.
fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]FileLine {
    var lines: std.ArrayList(FileLine) = .empty;
    errdefer lines.deinit(gpa);
    var at: usize = 0;
    while (at < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, at, '\n');
        const end = if (newline) |i| i + 1 else text.len;
        var content_end = if (newline) |i| i else text.len;
        // A carriage return before the newline is the line ending, not the line.
        if (content_end > at and text[content_end - 1] == '\r') content_end -= 1;
        try lines.append(gpa, .{ .start = at, .content_end = content_end, .end = end });
        at = end;
    }
    return lines.toOwnedSlice(gpa);
}

/// A line as it is compared: without the trailing whitespace it carries and,
/// when `trim_leading`, without its indentation either.
fn normalized(line: []const u8, trim_leading: bool) []const u8 {
    var text = std.mem.trimEnd(u8, line, " \t\r");
    if (trim_leading) text = std.mem.trimStart(u8, text, " \t");
    return text;
}

/// `text` with its lines shifted so that a block indented at `from` sits at `to`
/// instead. This is how a loosely matched replacement keeps the indentation of
/// the file it lands in: a line indented at least as far as `from` is moved with
/// it, and one that is not, such as a blank line, is left where it is. The
/// result is owned by `gpa`.
fn reindent(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    if (std.mem.eql(u8, from, to)) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (std.mem.trim(u8, line, " \t").len == 0 or !std.mem.startsWith(u8, line, from)) {
            try out.appendSlice(gpa, line);
            continue;
        }
        try out.appendSlice(gpa, to);
        try out.appendSlice(gpa, line[from.len..]);
    }
    return out.toOwnedSlice(gpa);
}

/// The whitespace in front of `line`, which is its indentation.
fn indentOf(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

/// The first line of `text`, up to its line ending.
fn firstLine(text: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..newline];
}

/// Parses a tool call into the arguments of the call it names. It never fails:
/// an unimplemented tool becomes `unknown` and arguments that do not fit become
/// `malformed`, so a caller can still name the call it could not run.
pub fn parseCall(arena: std.mem.Allocator, call: llm.ToolCall) Call {
    return parseCallNamed(arena, call.function.name, call.function.arguments);
}

/// Parses a call from the name of the tool and the arguments it was given, which
/// is the pair a session stores. This is what a transcript reads a call with, so
/// that replaying one does not have to build the `llm.ToolCall` it came from.
pub fn parseCallNamed(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) Call {
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
    if (std.mem.eql(u8, name, "web_search")) {
        return .{ .web_search = parse(Call.WebSearch, arena, arguments) catch |reason|
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
///
/// `scratch` is free for the block to build with, such as an edit's diff; it is
/// the caller's, dropped once the block is printed.
pub fn describe(
    scratch: std.mem.Allocator,
    call: Call,
    result: []const u8,
    formats: Formats,
    style: Style,
    out: *Io.Writer,
) !void {
    try printHead(scratch, call, formats, style, out);
    try printResult(call, result, style, out);
    try out.writeAll("\n");
}

/// The mark of each tool. A glyph stands on the one line billy writes whole
/// rather than in front of every row of output, which the terminal wraps on its
/// own and cannot be marked without folding it here.
const marks = struct {
    const read = Mark{ .glyph = "▸", .hue = .blue };
    const write = Mark{ .glyph = "◂", .hue = .green };
    const edit = Mark{ .glyph = "✎", .hue = .yellow };
    const bash = Mark{ .glyph = "❯", .hue = .cyan };
    const search = Mark{ .glyph = "⌕", .hue = .magenta };
    /// A call that could not be named: a tool billy does not implement, or
    /// arguments that could not be read.
    const unknown = Mark{ .glyph = "?", .hue = .red };
};

/// Prints the header block of a call: which tool it is and what it acts on. A
/// bash command is laid out by the bash formatter, so it reads the way it runs;
/// an edit is shown as the diff of the strings it works on; and a search shows
/// the query it ran.
fn printHead(scratch: std.mem.Allocator, call: Call, formats: Formats, style: Style, out: *Io.Writer) !void {
    switch (call) {
        .read => |args| try styling.header(marks.read, "read", args.path, style, out),
        .write => |args| try styling.header(marks.write, "write", args.path, style, out),
        .edit => |args| {
            try styling.header(marks.edit, "edit", args.path, style, out);
            try printDiff(scratch, args.old_string, args.new_string, formats.edit, style, out);
        },
        .bash => |args| {
            try styling.header(marks.bash, "bash", "", style, out);
            try printScript(args.command, formats.bash, out);
        },
        .web_search => |args| try styling.header(marks.search, "web_search", args.query, style, out),
        // Only the name is known, so that is all there is to show; the reason it
        // could not run reaches the user through the output.
        .unknown => |name| try styling.header(marks.unknown, name, "", style, out),
        .malformed => |bad| try styling.header(marks.unknown, bad.name, "", style, out),
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
    style: Style,
    out: *Io.Writer,
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

/// Prints a block header: the glyph of the tool in its colour, its name in bold
/// and what it acts on, when there is one, dimmed: `▸ read a.zig`.
/// The mark in front of the labels that break a block into sections, such as
/// `▾ stdout`. It points down at the lines under it, where the glyph of a tool
/// points at the call it names.
const label_mark = "▾";

/// The mark in front of an exit status: a check when the command succeeded and a
/// cross when it did not. It repeats what the colour says, so the line reads the
/// same where the colour does not, such as a colour-blind terminal or a log with
/// the escape codes stripped.
const exit_marks = struct {
    const ok = "✓";
    const failed = "✗";
};

/// How a section of a block is printed. The label line is bold, so it reads as
/// the heading of what follows, and the output under it is dim, so it stays
/// readable without competing with it.
const Ink = union(enum) {
    plain,
    dim,
    hue: Color,
};

/// Prints a label such as `▾ stdout` in bold, so it reads as the heading of the
/// lines under it rather than as the first of them.
fn printLabel(name: []const u8, style: Style, out: *Io.Writer) !void {
    try out.print("{s}{s} {s}{s}\n", .{ style.on("1"), label_mark, name, style.off() });
}

/// Prints `text` in the way `ink` asks for.
fn printInk(text: []const u8, ink: Ink, style: Style, out: *Io.Writer) !void {
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
fn printScript(command: []const u8, format: Format, out: *Io.Writer) !void {
    const script = std.mem.trimEnd(u8, command, "\n");
    if (!try formatting.apply(format, script, out)) try out.writeAll(script);
    try out.writeAll("\n");
}

/// Prints what a call produced under the `output` label. A write shows the content
/// it put in the file; an edit shows nothing, since its result would only repeat
/// the change shown above it. Anything that failed shows why instead, whatever
/// it was asked to do.
fn printResult(call: Call, result: []const u8, style: Style, out: *Io.Writer) !void {
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
fn printBash(result: []const u8, style: Style, out: *Io.Writer) !void {
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
fn printExit(status: []const u8, style: Style, out: *Io.Writer) !void {
    const prefix = "exit code: ";
    const code = if (std.mem.startsWith(u8, status, prefix)) status[prefix.len..] else status;
    const ok = std.mem.eql(u8, code, "0");
    const mark = if (ok) exit_marks.ok else exit_marks.failed;
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} exit {s}", .{ mark, code }) catch status;
    try style.boldColor(if (ok) .green else .red, line, out);
    try out.writeAll("\n");
}

/// A bash result split back into the status line billy wrote and what the
/// command printed on each stream. Null when the result does not open with a
/// status, which is how a result stored before one was written reads.
const BashResult = struct {
    status: []const u8,
    stdout: []const u8,
    stderr: []const u8,
};

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
fn printTruncated(text: []const u8, ink: Ink, style: Style, out: *Io.Writer) !void {
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
        .description = "Run a shell command with bash -c and return its output and exit code.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"command\":{\"type\":\"string\",\"description\":\"Command to run.\"}}," ++
            "\"required\":[\"command\"]}",
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

/// `specs` with the search tool appended, for a run that has a backend. The
/// order is what keeps the set growing by appending rather than reordering.
const specs_with_search = specs ++ [_]Session.Definition{search_spec};

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
    // An edit shows the diff of the strings it worked on, not its result.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-old text\n+new text\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"old text\",\"new_string\":\"new text\"}",
        "replaced 1 occurrence(s) in a.zig",
    );
    // The command of a bash call is printed whole.
    try expectDescribe(
        "❯ bash\nls -la\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"ls -la\"}",
        "exit code: 0\n(no output)\n",
    );
    // A web search shows the query it ran, and its results under the output
    // label like any other text a tool returned.
    try expectDescribe(
        "⌕ web_search zig lang\n▾ output\n1. Zig\nhttps://ziglang.org\n\n",
        "web_search",
        "{\"query\":\"zig lang\"}",
        "1. Zig\nhttps://ziglang.org",
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
    // A failed edit still shows the change it meant to make, then why it did not.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-x\n+y\n▾ output\n" ++
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
    try describe(arena, parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "", .{}, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A terminal that takes no escape code gets the same text without them.
    try describe(arena, parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "", .{}, .plain, &out.writer);
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
    try describe(arena, parseCall(arena, call), "exit code: 0\nbuilt\n", .{}, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;32m✓ exit 0\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mbuilt\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // One that did not, whose output the terminal still shows as it is.
    try describe(arena, parseCall(arena, call), "exit code: 2\nboom\n", .{}, .ansi, &out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;31m✗ exit 2\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mboom\x1b[0m\n\n",
        out.written(),
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
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .log = &log.writer,
        .bash_timeout_s = 120,
        .http = &http,
    });
    defer tool_set.deinit();
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
    for (cases) |case| {
        log.clearRetainingCapacity();
        const arguments = try std.fmt.allocPrint(arena, "{{\"command\":{f}}}", .{
            std.json.fmt(case.command, .{}),
        });
        _ = try tool_set.run(.{ .id = "1", .function = .{ .name = "bash", .arguments = arguments } });
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
    try describe(arena, parseCall(arena, call), "built\nnothing to do", .{}, .plain, &out.writer);
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
    try describe(arena, parseCall(arena, .{ .id = "1", .function = .{
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
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The format script reads the command and writes it back upper case, the
    // way `shfmt | bat -l bash` reads it and writes it back laid out.
    const format: Format = .{ .script = "tr a-z A-Z | cat", .io = std.testing.io, .gpa = gpa };
    try describe(arena, parseCall(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"ls -la\\n\"}",
    } }), "exit code: 0\n(no output)\n", .{ .bash = format }, .plain, &out.writer);

    // The command is shown as the formatter wrote it; its trailing newline does
    // not leave a blank line in the block.
    try std.testing.expectEqualStrings(
        "❯ bash\nLS -LA\n✓ exit 0\n\n",
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
        "❯ bash\nls -la\n✓ exit 0\n\n";

    // A formatter that cannot be run, one that fails and one that writes
    // nothing all leave the command the model wrote for the user to read.
    const scripts = [_][]const u8{ "billy-no-such-formatter", "exit 1", "true" };
    for (scripts) |script| {
        const format: Format = .{ .script = script, .io = std.testing.io, .gpa = gpa };
        try describe(arena, parseCall(arena, call), "exit code: 0\n(no output)\n", .{ .bash = format }, .plain, &out.writer);
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
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .log = &log.writer,
        .bash_timeout_s = 120,
        .http = &http,
    });
    defer tool_set.deinit();
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    const result = try tool_set.run(call);

    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(arena, parseCall(arena, call), result, .{}, .plain, &described.writer);

    // The live log is the description, so a replayed session reads the same.
    try std.testing.expectEqualStrings(
        "❯ bash\ntrue\n✓ exit 0\n\n",
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
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    // The format script writes the command back upper case, so what is shown is
    // plainly not what runs.
    const format: Format = .{ .script = "tr a-z A-Z", .io = std.testing.io, .gpa = gpa };
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .log = &log.writer,
        .formats = .{ .bash = format },
        .bash_timeout_s = 120,
        .http = &http,
    });
    defer tool_set.deinit();
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };
    const result = try tool_set.run(call);

    // The command that ran is the one the model wrote, so the result is its
    // output, and the user reads the command as the formatter laid it out.
    try std.testing.expectEqualStrings("exit code: 0\nhi\n", result);
    try std.testing.expectEqualStrings(
        "❯ bash\nECHO HI\n✓ exit 0\n▾ stdout\nhi\n\n",
        log.written(),
    );

    // A replayed session describes the stored call the same way.
    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(arena, parseCall(arena, call), result, .{ .bash = format }, .plain, &described.writer);
    try std.testing.expectEqualStrings(log.written(), described.written());
}

test "an edit diff is laid out by the edit format" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    try describe(arena, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\n-OLD\n+NEW\n\n",
        out.written(),
    );
}

test "an edit's two sides reach the format script as files" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    try describe(arena, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\nwas here now here\n\n",
        out.written(),
    );
}

test "an edit's sides are billy's own files in the temporary directory" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    try describe(arena, call, "", .{ .edit = format }, .plain, &out.writer);

    const written = out.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "✎ edit a.zig\n▾ diff\n/tmp/billy-edit-"));
    try std.testing.expect(std.mem.indexOf(u8, written, "-old /tmp/billy-edit-") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, written, "\n"), "-new"));
}

test "an edit whose format script fails falls back to billy's own diff" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const format: Format = .{ .script = "exit 1", .io = std.testing.io, .gpa = gpa };
    const call: Call = .{ .edit = .{ .path = "a.zig", .old_string = "b", .new_string = "x" } };
    try describe(arena, call, "replaced 1 occurrence(s) in a.zig", .{ .edit = format }, .plain, &out.writer);
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
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .log = &log.writer,
        .bash_timeout_s = 1,
        .http = &http,
    });
    defer tool_set.deinit();
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"sleep 30\"}",
    } };
    const result = try tool_set.run(call);

    try std.testing.expectEqualStrings(
        "error: command did not finish within 1s and was killed",
        result,
    );
}

test "parseCall splits known, unknown and malformed calls" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_call = parseCall(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\",\"offset\":5}",
    } });
    try std.testing.expectEqualStrings("a.zig", read_call.read.path);
    try std.testing.expectEqual(@as(?usize, 5), read_call.read.offset);

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
    try describe(arena_state.allocator(), parseCall(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), result, .{}, .plain, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Replaces `old_string` in `contents` and checks what the file became, so a
/// test reads as the edit it makes rather than as the plumbing around it.
fn expectReplace(expected: []const u8, contents: []const u8, old_string: []const u8, new_string: []const u8) !void {
    return expectReplaceAll(expected, contents, old_string, new_string, false);
}

fn expectReplaceAll(
    expected: []const u8,
    contents: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !void {
    const gpa = std.testing.allocator;
    const change = try replaceInFile(gpa, contents, old_string, new_string, replace_all);
    const applied = switch (change) {
        .applied => |applied| applied,
        else => return error.TestExpectedAnAppliedChange,
    };
    defer gpa.free(applied.text);
    try std.testing.expectEqualStrings(expected, applied.text);
}

test "an exact match is changed where it is" {
    // The line's own ending is not part of the text, so it is left in the file.
    try expectReplace("let x = 42;\nlet y = 2;\n", "let x = 1;\nlet y = 2;\n", "let x = 1;", "let x = 42;");
    // The ending is part of the text when the text carries it.
    try expectReplace("qux();\n", "foo();\n", "foo();\n", "qux();\n");
    // Text in the middle of a line, not only whole lines.
    try expectReplace("a = 2; b = 3;\n", "a = 1; b = 3;\n", "a = 1;", "a = 2;");
}

test "an exact match is preferred over a loose one" {
    // The first line matches exactly, so it is changed even though the second
    // matches only once whitespace is ignored, which would be two candidates.
    try expectReplace("x = 1\n  x = 1\n", "x = 0\n  x = 1\n", "x = 0", "x = 1");
}

test "text that appears more than once is ambiguous unless replace_all" {
    const gpa = std.testing.allocator;
    const contents = "a = 1;\na = 1;\n";

    switch (try replaceInFile(gpa, contents, "a = 1;", "a = 2;", false)) {
        .ambiguous => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.TestExpectedAnAmbiguousMatch,
    }
    try expectReplaceAll("a = 2;\na = 2;\n", contents, "a = 1;", "a = 2;", true);
}

test "text that is not in the file is not found" {
    const gpa = std.testing.allocator;
    switch (try replaceInFile(gpa, "abc\ndef\n", "xyz", "q", false)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
    // Nor when it is a different file than the one the lines were copied from.
    switch (try replaceInFile(gpa, "def\nabc\n", "abc\ndef\n", "q", false)) {
        .not_found => {},
        else => return error.TestExpectedNoMatch,
    }
}

test "trailing whitespace and the line ending are ignored when exact fails" {
    // Trailing spaces the model dropped from a copied line.
    try expectReplace("qux();\nbar();\n", "foo();   \nbar();\n", "foo();\n", "qux();\n");
    // A carriage return line ending where the text was written with a newline.
    // Only the matched line is changed, so the rest keeps its own ending.
    try expectReplace("qux();\nbar();\r\n", "foo();\r\nbar();\r\n", "foo();\n", "qux();\n");
    // Trailing spaces the model added that the file does not have, in text
    // written without a line ending, so the file keeps its own.
    try expectReplace("qux();\n", "foo();\n", "foo();   ", "qux();");
}

test "indentation is ignored when the file is indented differently" {
    // The text was written unindented but sits inside a block in the file. The
    // replacement is indented to sit where the text did, so the block keeps its
    // shape.
    try expectReplace(
        "    if (x) {\n        z();\n    }\n",
        "    if (x) {\n        y();\n    }\n",
        "if (x) {\n    y();\n}\n",
        "if (x) {\n    z();\n}\n",
    );
    // The same the other way: text indented more than the file it lands in.
    try expectReplace(
        "if (x) {\n    z();\n}\n",
        "if (x) {\n    y();\n}\n",
        "    if (x) {\n        y();\n    }\n",
        "    if (x) {\n        z();\n    }\n",
    );
}

test "a blank line in a loosely matched replacement carries no indentation" {
    try expectReplace(
        "    a();\n\n    b();\n",
        "    a();\n\n    b();\n",
        "a();\n\nb();\n",
        "a();\n\nb();\n",
    );
}

test "a replacement matched exactly is not re-indented" {
    // The text matches byte for byte, so the replacement is left as written even
    // though its own first line is indented differently.
    try expectReplace(
        "one();\n        three();\n",
        "one();\n    two();\n",
        "    two();\n",
        "        three();\n",
    );
}

/// A tool set over `dir` for the definition tests, with a search backend when
/// `with_search` is set.
fn definitionsToolSet(
    dir: Io.Dir,
    gpa: std.mem.Allocator,
    log: *Io.Writer,
    http: *std.http.Client,
    with_search: bool,
) !Tools {
    return Tools.init(.{
        .io = std.testing.io,
        .dir = dir,
        .gpa = gpa,
        .log = log,
        .bash_timeout_s = 120,
        .search = if (with_search) .{
            .provider = .tavily,
            .api_key = "key",
            .max_results = 3,
        } else null,
        .http = http,
    });
}

test "the definitions cover every tool the loop dispatches" {
    const gpa = std.testing.allocator;
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var tool_set = try definitionsToolSet(Io.Dir.cwd(), gpa, &log.writer, &http, false);
    defer tool_set.deinit();

    // The names are exactly the tools the loop can dispatch, in the order the
    // model receives them, so it is never offered one that does not run.
    const offered = tool_set.definitions();
    const expected = [_][]const u8{ "read", "write", "edit", "bash" };
    try std.testing.expectEqual(expected.len, offered.len);
    for (offered, expected) |definition, name| {
        try std.testing.expectEqualStrings(name, definition.name);
        // The schema is the JSON text it is sent as, which starts with an object.
        try std.testing.expect(std.mem.startsWith(u8, definition.parameters, "{"));
    }
}

test "web search is offered only when a backend is configured" {
    const gpa = std.testing.allocator;
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();

    // Without a backend the search tool is not offered at all, and the tools
    // every session has come first so the set only grows.
    var plain = try definitionsToolSet(Io.Dir.cwd(), gpa, &log.writer, &http, false);
    defer plain.deinit();
    const without = plain.definitions();
    try std.testing.expectEqual(specs.len, without.len);
    for (without) |definition| {
        try std.testing.expect(!std.mem.eql(u8, definition.name, "web_search"));
    }

    // With one it is appended, so a session that gains it keeps the tools it had.
    var searched = try definitionsToolSet(Io.Dir.cwd(), gpa, &log.writer, &http, true);
    defer searched.deinit();
    const with = searched.definitions();
    try std.testing.expectEqual(specs.len + 1, with.len);
    try std.testing.expectEqualStrings("web_search", with[with.len - 1].name);
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
        .log = &log.writer,
        .bash_timeout_s = 120,
        .http = &http,
    });
    defer tool_set.deinit();

    // A file written by the tool lands in that directory.
    _ = try tool_set.run(.{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"note.txt\",\"content\":\"hi\"}",
    } });
    const written = try tmp.dir.readFileAlloc(std.testing.io, "project/note.txt", arena, .limited(64));
    try std.testing.expectEqualStrings("hi", written);

    // And a command runs there too, so `pwd` reports that directory and not the
    // one billy was started in.
    log.clearRetainingCapacity();
    const result = try tool_set.run(.{ .id = "2", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } });
    try std.testing.expect(std.mem.indexOf(u8, result, "/project\n") != null);
}
