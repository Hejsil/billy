//! The tools the agent can call, together with their JSON Schema descriptions.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const search = @import("search.zig");
const formatting = @import("format.zig");
const styling = @import("style.zig");

/// Laying a bash command out for the display.
pub const Format = formatting.Format;
/// How billy decorates the lines it prints itself.
pub const Style = styling.Style;
/// A foreground colour for those lines.
pub const Color = styling.Color;

/// The mark a block header opens with.
const Mark = styling.Mark;

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

pub const Tools = struct {
    io: Io,
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
    /// The web search client, or null when no backend is configured. A null
    /// leaves `web_search` out of `definitions`, so the model is never offered
    /// a tool that could not run.
    search: ?search.Client,
    definitions: []const llm.Tool,

    /// `arena` holds the definitions, which are sent with every request and so
    /// live as long as the run. Nothing else the tools allocate outlives the
    /// call that made it, so the rest is asked for per call.
    ///
    /// `search_config` is the backend the configuration asked for, with its key
    /// resolved, or null to leave web search out.
    pub fn init(
        io: Io,
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        log: *Io.Writer,
        format: Format,
        style: Style,
        search_config: ?search.Config,
    ) !Tools {
        return .{
            .io = io,
            .gpa = gpa,
            .log = log,
            .format = format,
            .style = style,
            .search = if (search_config) |config| .{
                .io = io,
                .gpa = gpa,
                .provider = config.provider,
                .api_key = config.api_key,
                .max_results = config.max_results,
            } else null,
            .definitions = try definitions(arena, search_config != null),
        };
    }

    /// Runs one tool call and returns its result. Tool failures are reported to
    /// the model as text so that it can react to them.
    ///
    /// What the user sees comes from `printHead` and `printResult`, which the
    /// transcript reuses, so a replayed session shows exactly what a live one
    /// did. The head goes out before the tool runs, so a slow command shows what
    /// it is doing, and the result follows it.
    ///
    /// `arena` holds the parsed call and the result. The result is what the
    /// caller is given, so it has to outlive the call, but no longer than that:
    /// the session interns what it keeps, so an arena dropped with the request
    /// is enough and keeps a long conversation from holding every result.
    pub fn run(tools: *Tools, arena: std.mem.Allocator, call: llm.ToolCall) ![]const u8 {
        const parsed = parseCall(arena, call);
        try printHead(parsed, tools.format, tools.style, tools.log);
        try tools.log.flush();

        const result = switch (parsed) {
            .read => |args| try tools.read(arena, args),
            .write => |args| try tools.write(arena, args),
            .edit => |args| try tools.edit(arena, args),
            .bash => |args| try tools.bash(arena, args),
            .web_search => |args| try tools.webSearch(arena, args),
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

    fn read(tools: *Tools, arena: std.mem.Allocator, args: Call.Read) ![]const u8 {
        const contents = std.Io.Dir.cwd().readFileAlloc(
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

    fn write(tools: *Tools, arena: std.mem.Allocator, args: Call.Write) ![]const u8 {
        if (std.fs.path.dirname(args.path)) |parent| {
            std.Io.Dir.cwd().createDirPath(tools.io, parent) catch |err|
                return fail(arena, "cannot create {s}: {s}", .{ parent, @errorName(err) });
        }
        std.Io.Dir.cwd().writeFile(tools.io, .{ .sub_path = args.path, .data = args.content }) catch |err|
            return fail(arena, "cannot write {s}: {s}", .{ args.path, @errorName(err) });
        return std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ args.content.len, args.path });
    }

    fn edit(tools: *Tools, arena: std.mem.Allocator, args: Call.Edit) ![]const u8 {
        if (args.old_string.len == 0) return fail(arena, "old_string must not be empty", .{});

        const contents = std.Io.Dir.cwd().readFileAlloc(
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
                std.Io.Dir.cwd().writeFile(tools.io, .{
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

    fn bash(tools: *Tools, arena: std.mem.Allocator, args: Call.Bash) ![]const u8 {
        const result = std.process.run(tools.gpa, tools.io, .{
            .argv = &.{ "bash", "-c", args.command },
            .stdout_limit = .limited(max_command_output),
            .stderr_limit = .limited(max_command_output),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(command_timeout_s) } },
        }) catch |err| switch (err) {
            error.StreamTooLong => return fail(
                arena,
                "command produced more than {d} bytes of output",
                .{max_command_output},
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
    fn webSearch(tools: *Tools, arena: std.mem.Allocator, args: Call.WebSearch) ![]const u8 {
        const client = if (tools.search) |*client| client else return fail(arena, "web search is not configured", .{});
        return client.search(arena, args.query) catch |err|
            return fail(arena, "search failed: {s}", .{@errorName(err)});
    }
};

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
pub fn describe(call: Call, result: []const u8, format: Format, style: Style, out: *Io.Writer) !void {
    try printHead(call, format, style, out);
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
/// bash command is laid out by `format`, so it reads the way it runs; the
/// strings an edit works on are truncated, since they are there for context
/// rather than to be read in full.
fn printHead(call: Call, format: Format, style: Style, out: *Io.Writer) !void {
    switch (call) {
        .read => |args| try styling.header(marks.read, "read", args.path, style, out),
        .write => |args| try styling.header(marks.write, "write", args.path, style, out),
        .edit => |args| {
            try styling.header(marks.edit, "edit", args.path, style, out);
            try printLabel("find", style, out);
            try printTruncated(args.old_string, .plain, style, out);
            try printLabel("replace", style, out);
            try printTruncated(args.new_string, .plain, style, out);
        },
        .bash => |args| {
            try styling.header(marks.bash, "bash", "", style, out);
            try printScript(args.command, format, out);
        },
        .web_search => |args| try styling.header(marks.search, "web_search", args.query, style, out),
        // Only the name is known, so that is all there is to show; the reason it
        // could not run reaches the user through the output.
        .unknown => |name| try styling.header(marks.unknown, name, "", style, out),
        .malformed => |bad| try styling.header(marks.unknown, bad.name, "", style, out),
    }
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
/// the strings shown above it. Anything that failed shows why instead, whatever
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
        // An edit's result would only repeat the strings shown above it.
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

const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

/// The tools every session is offered, in the order the model receives them.
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
        .description = "Replace text in a file. The text is matched exactly when it can be and ignoring whitespace otherwise, so a copied line need not be perfect. Fails unless it is found exactly once, unless replace_all is true.",
        .parameters =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {"type": "string", "description": "File to edit."},
        \\    "old_string": {"type": "string", "description": "Text to replace, one or more whole lines. Matched exactly, or ignoring whitespace when it does not match exactly."},
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

/// The tool that is offered only when a search backend is configured, since it
/// can do nothing without one. It comes last, after the tools every session
/// has, so a session that gains it appends to the set rather than reordering it.
const search_spec = Spec{
    .name = "web_search",
    .description = "Search the web and return the top results: a title, a url and a snippet for each.",
    .parameters =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {"type": "string", "description": "What to search for."}
    \\  },
    \\  "required": ["query"]
    \\}
    ,
};

/// The tool definitions sent with every request. `web_search` is included only
/// when `include_search` is set, so a run with no backend never offers the model
/// a tool that could not run.
fn definitions(arena: std.mem.Allocator, include_search: bool) ![]const llm.Tool {
    var tools: std.ArrayList(llm.Tool) = .empty;
    for (specs) |spec| try tools.append(arena, try buildTool(arena, spec));
    if (include_search) try tools.append(arena, try buildTool(arena, search_spec));
    return tools.toOwnedSlice(arena);
}

/// Builds one tool definition from its spec, the parameters parsed into the
/// JSON the request carries.
fn buildTool(arena: std.mem.Allocator, spec: Spec) !llm.Tool {
    return .{ .function = .{
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
    // An edit shows the strings it worked on instead of its result.
    try expectDescribe(
        "✎ edit a.zig\n▾ find\nold text\n▾ replace\nnew text\n\n",
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
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n\n",
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
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;32m✓ exit 0\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mbuilt\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // One that did not, whose output the terminal still shows as it is.
    try describe(parseCall(arena, call), "exit code: 2\nboom\n", null, .ansi, &out.writer);
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

    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer, null, .plain, null);
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
        _ = try tool_set.run(arena, .{ .id = "1", .function = .{ .name = "bash", .arguments = arguments } });
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
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n" ++
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
    try describe(parseCall(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"ls -la\\n\"}",
    } }), "exit code: 0\n(no output)\n", format, .plain, &out.writer);

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

    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer, null, .plain, null);
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    const result = try tool_set.run(arena, call);

    var described: std.Io.Writer.Allocating = .init(gpa);
    defer described.deinit();
    try describe(parseCall(arena, call), result, null, .plain, &described.writer);

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

    // The format script writes the command back upper case, so what is shown is
    // plainly not what runs.
    const format: Format = .{ .script = "tr a-z A-Z", .io = std.testing.io, .gpa = gpa };
    var tool_set = try Tools.init(std.testing.io, arena, gpa, &log.writer, format, .plain, null);
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };
    const result = try tool_set.run(arena, call);

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

test "definitions cover every tool the loop dispatches" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const defs = try definitions(arena_state.allocator(), false);
    try std.testing.expectEqual(specs.len, defs.len);
    for (defs) |tool| {
        try std.testing.expect(tool.function.parameters == .object);
    }
}

test "web search is offered only when a backend is configured" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();

    // Without a backend the tool is not offered at all, and the tools every
    // session has come first so the set only grows.
    const without = try definitions(arena_state.allocator(), false);
    try std.testing.expectEqual(specs.len, without.len);
    for (without) |tool| {
        try std.testing.expect(!std.mem.eql(u8, tool.function.name, "web_search"));
    }

    // With one it is appended, so a session that gains it keeps the tools it had.
    const with = try definitions(arena_state.allocator(), true);
    try std.testing.expectEqual(specs.len + 1, with.len);
    try std.testing.expectEqualStrings("web_search", with[with.len - 1].function.name);
}
