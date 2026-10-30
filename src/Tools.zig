//! The tools the agent can call, together with their JSON Schema descriptions.

const std = @import("std");

const Bash = @import("Tools/Bash.zig");
const Edit = @import("Tools/Edit.zig");
const Health = @import("Health.zig");
const llm = @import("llm.zig");
const Read = @import("Tools/Read.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const Write = @import("Tools/Write.zig");

pub const web = @import("Tools/web.zig");

const Tools = @This();

const max_result_len = 30_000;

pub const Call = union(enum) {
    read: Read,
    write: Write,
    edit: Edit,
    bash: Bash,
    web_search: web.Search,
    web_fetch: web.Fetch,
    unknown: []const u8,
    malformed: Malformed,

    pub const Malformed = struct {
        name: []const u8,
        reason: anyerror,
    };
};

io: std.Io,
dir: std.Io.Dir,
gpa: std.mem.Allocator,
http: *std.http.Client,
settings: Settings,

/// What a tool set runs with, beyond the plumbing of the run it belongs to: the limits it runs
/// under and the backends it asks.
pub const Settings = struct {
    bash_timeout_s: usize,
    search: ?web.Search.Config = null,
    fetch: ?web.Fetch.Config = null,
    health: ?*Health = null,
};

pub fn init(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, http: *std.http.Client, settings: Settings) Tools {
    return .{ .io = io, .dir = dir, .gpa = gpa, .http = http, .settings = settings };
}

pub fn hasWeb(tools: *const Tools) bool {
    return tools.settings.search != null or tools.settings.fetch != null;
}

pub fn definitions(tools: *const Tools) []const Session.Definition {
    return if (tools.hasWeb()) &specs_with_web else &specs;
}

pub fn callName(call: Call) []const u8 {
    return switch (call) {
        .unknown => |name| name,
        .malformed => |bad| bad.name,
        inline else => |_, tag| @tagName(tag),
    };
}

/// Writes the result of `call` to `result`, cut at `max_result_len` with a count of what was left
/// out, so no tool can fill the model's context.
pub fn run(tools: *Tools, call: Call, result: *std.Io.Writer) !void {
    var buffer: [result_buffer_len]u8 = undefined;
    var limited = Limited.init(result, &buffer, max_result_len);
    try tools.dispatch(call, &limited.writer);
    try limited.writer.flush();
    if (limited.dropped > 0) {
        try result.print("\n… {d} more bytes", .{limited.dropped});
    }
}

const result_buffer_len = 4096;

const Limited = struct {
    inner: *std.Io.Writer,
    remaining: usize,
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

        const header = w.buffer[0..w.end];
        w.end = 0;
        try self.hand(header);

        for (data[0 .. data.len - 1]) |bytes| try self.hand(bytes);

        try self.repeat(data[data.len - 1], splat);

        // Dropped bytes count as consumed, or the caller would offer them again.
        var offered: usize = data[data.len - 1].len * splat;
        for (data[0 .. data.len - 1]) |bytes| offered += bytes.len;
        return offered;
    }

    fn hand(self: *Limited, bytes: []const u8) std.Io.Writer.Error!void {
        const fits = @min(bytes.len, self.remaining);
        if (fits > 0) try self.inner.writeAll(bytes[0..fits]);
        self.remaining -= fits;
        self.dropped += bytes.len - fits;
    }

    fn repeat(self: *Limited, pattern: []const u8, splat: usize) std.Io.Writer.Error!void {
        const offered = pattern.len * splat;
        const fits = @min(offered, self.remaining);
        self.remaining -= fits;
        self.dropped += offered - fits;
        if (fits == 0 or pattern.len == 0) return;

        const whole = fits / pattern.len;
        if (whole > 0) {
            var repeated = [_][]const u8{pattern};
            try self.inner.writeSplatAll(&repeated, whole);
        }
        if (fits % pattern.len != 0) try self.inner.writeAll(pattern[0 .. fits % pattern.len]);
    }
};

pub fn fail(out: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    try out.print("error: " ++ format, args);
}

/// Writes `bytes` to `path` under `dir`, replacing the file in one step: the new contents are put
/// in place once they are all there, so a kill or a full disk part way through leaves the old file
/// whole rather than an empty one or half of the new.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const permissions: std.Io.File.Permissions = if (dir.statFile(io, path, .{})) |stat|
        stat.permissions
    else |_|
        .default_file;

    var atomic = try dir.createFileAtomic(io, path, .{
        .permissions = permissions,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buffer);
    try file.interface.writeAll(bytes);
    try file.flush();
    try atomic.replace(io);
}

fn dispatch(tools: *Tools, call: Call, out: *std.Io.Writer) !void {
    switch (call) {
        .edit => |edit| try edit.run(tools.gpa, tools.io, tools.dir, out),
        .read => |read| try read.run(tools.gpa, tools.io, tools.dir, out),
        .write => |write| try write.run(tools.io, tools.dir, out),
        .bash => |bash| {
            const timeout_s = std.math.cast(i64, tools.settings.bash_timeout_s) orelse std.math.maxInt(i64);
            const timeout = std.Io.Duration.fromSeconds(timeout_s);
            try bash.run(tools.gpa, tools.io, tools.dir, timeout, out);
        },
        .web_search => |search| try search.run(
            tools.gpa,
            tools.http,
            tools.settings.search,
            tools.settings.health,
            out,
        ),
        .web_fetch => |fetch| try fetch.run(
            tools.gpa,
            tools.http,
            tools.settings.fetch,
            tools.settings.health,
            out,
        ),
        .unknown => |name| try fail(out, "unknown tool '{s}'", .{name}),
        .malformed => |bad| try fail(
            out,
            "invalid arguments for {s}: {t}",
            .{ bad.name, bad.reason },
        ),
    }
}

/// Parses and runs one call as the agent does, and hands the parsed call back so a test can give
/// both to `describe`.
pub fn runCall(
    arena: std.mem.Allocator,
    tools: *Tools,
    call: llm.ToolCall,
    result: *std.Io.Writer,
) !Call {
    const parsed = parse(arena, call);
    try tools.run(parsed, result);
    return parsed;
}

pub fn parse(arena: std.mem.Allocator, call: llm.ToolCall) Call {
    return parseCallNamed(arena, call.function.name, call.function.arguments);
}

pub fn parseCallNamed(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) Call {
    const fields = @typeInfo(Call).@"union";
    inline for (fields.field_names, fields.field_types) |field_name, field_type| {
        if (comptime isNotATool(field_name)) continue;
        if (std.mem.eql(u8, name, field_name)) {
            const parsed = fromJson(field_type, arena, arguments) catch |reason|
                return .{ .malformed = .{ .name = name, .reason = reason } };
            return @unionInit(Call, field_name, parsed);
        }
    }
    return .{ .unknown = name };
}

fn fromJson(T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return try std.json.parseFromSliceLeaky(T, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

const marks = struct {
    const read = Terminal.Writer.Mark{ .glyph = "▸", .hue = .blue };
    const write = Terminal.Writer.Mark{ .glyph = "◂", .hue = .green };
    const edit = Terminal.Writer.Mark{ .glyph = "✎", .hue = .yellow };
    const bash = Terminal.Writer.Mark{ .glyph = "❯", .hue = .cyan };
    const search = Terminal.Writer.Mark{ .glyph = "⌕", .hue = .magenta };
    const fetch = Terminal.Writer.Mark{ .glyph = "⇣", .hue = .magenta };
    const unknown = Terminal.Writer.Mark{ .glyph = "?", .hue = .red };
};

pub const Heading = struct {
    glyph: []const u8,
    hue: Terminal.Writer.Color,
    name: []const u8,
    target: []const u8,

    pub fn of(call: Call) Heading {
        return switch (call) {
            .read => |args| .forTool(.read, args.path),
            .write => |args| .forTool(.write, args.path),
            .edit => |args| .forTool(.edit, args.path),
            .bash => |args| .forTool(.bash, headerLine(args.description orelse args.command)),
            .web_search => |args| .forTool(.web_search, args.query),
            .web_fetch => |args| .forTool(.web_fetch, args.url),
            .unknown => |name| .marked(marks.unknown, name, ""),
            .malformed => |bad| .marked(marks.unknown, bad.name, ""),
        };
    }

    fn forTool(comptime tag: std.meta.Tag(Call), target: []const u8) Heading {
        const tool = comptime tableForTag(tag);
        return .marked(tool.mark, @tagName(tag), target);
    }

    fn marked(mark: Terminal.Writer.Mark, name: []const u8, target: []const u8) Heading {
        return .{ .glyph = mark.glyph, .hue = mark.hue, .name = name, .target = target };
    }
};

pub fn headerLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

pub const exit_marks = struct {
    pub const ok = "✓";
    pub const failed = "✗";
};

pub const Exit = struct {
    code: []const u8,
    ok: bool,
};

const exit_prefix = "exit code: ";

pub const BashOutput = struct {
    exit: Exit,
    stdout: []const u8,
    stderr: []const u8,
};

pub fn bashOutput(result: []const u8) ?BashOutput {
    const newline = std.mem.findScalar(u8, result, '\n') orelse return null;
    const status = result[0..newline];
    if (!std.mem.startsWith(u8, status, exit_prefix)) return null;
    const code = status[exit_prefix.len..];
    const exit: Exit = .{ .code = code, .ok = std.mem.eql(u8, code, "0") };
    const body = result[newline + 1 ..];
    const trimmed = std.mem.trimEnd(u8, body, "\n");

    if (std.mem.eql(u8, trimmed, "(no output)")) {
        return .{ .exit = exit, .stdout = "", .stderr = "" };
    }
    const marker = "stderr:\n";
    if (std.mem.startsWith(u8, body, marker)) {
        return .{ .exit = exit, .stdout = "", .stderr = body[marker.len..] };
    }
    if (std.mem.find(u8, body, "\n" ++ marker)) |at| {
        return .{
            .exit = exit,
            .stdout = body[0..at],
            .stderr = body[at + marker.len + 1 ..],
        };
    }
    return .{ .exit = exit, .stdout = body, .stderr = "" };
}

const Tool = struct {
    tag: std.meta.Tag(Call),
    description: []const u8,
    parameters: []const u8,
    mark: Terminal.Writer.Mark,
    web: bool = false,
};

const table = [_]Tool{
    .{
        .tag = .read,
        .mark = marks.read,
        .description = "Read a file. Returns the lines with their line numbers.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to read.\"}," ++
            "\"offset\":{\"type\":\"integer\",\"description\":\"First line to read, 1-based. Defaults to 1.\"}," ++
            "\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of lines. Defaults to 2000.\"}}," ++
            "\"required\":[\"path\"]}",
    },
    .{
        .tag = .write,
        .mark = marks.write,
        .description = "Write a file, creating parent directories and replacing any existing content.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to write.\"}," ++
            "\"content\":{\"type\":\"string\",\"description\":\"Complete content of the file.\"}}," ++
            "\"required\":[\"path\",\"content\"]}",
    },
    .{
        .tag = .edit,
        .mark = marks.edit,
        .description = "Replace text in a file. The text is matched exactly when it can be and ignoring whitespace otherwise, so a copied line need not be perfect. Fails unless it is found exactly once, unless replace_all is true.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"path\":{\"type\":\"string\",\"description\":\"File to edit.\"}," ++
            "\"old_string\":{\"type\":\"string\",\"description\":\"Text to replace, one or more whole lines. Matched exactly, or ignoring whitespace when it does not match exactly.\"}," ++
            "\"new_string\":{\"type\":\"string\",\"description\":\"Replacement text.\"}," ++
            "\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every occurrence instead of requiring a unique match. Defaults to false.\"}}," ++
            "\"required\":[\"path\",\"old_string\",\"new_string\"]}",
    },
    .{
        .tag = .bash,
        .mark = marks.bash,
        .description = "Run a shell command with bash -c and return its output and exit code. " ++
            "Give a short description of what the command does, so the user can see the intent at a glance.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"command\":{\"type\":\"string\",\"description\":\"Command to run.\"}," ++
            "\"description\":{\"type\":\"string\",\"description\":\"A short, one-line description of what the command does, so the user can tell at a glance without reading the command, e.g. \\\"run the test suite\\\".\"}}," ++
            "\"required\":[\"command\",\"description\"]}",
    },
    .{
        .tag = .web_search,
        .mark = marks.search,
        .web = true,
        .description = "Search the web and return the top results: a title, a url and a snippet for each.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"query\":{\"type\":\"string\",\"description\":\"What to search for.\"}}," ++
            "\"required\":[\"query\"]}",
    },
    .{
        .tag = .web_fetch,
        .mark = marks.fetch,
        .web = true,
        .description = "Fetch a url and return its content. A page comes back as markdown; set raw for an API or a file, whose bytes are returned as they are.",
        .parameters = "{\"type\":\"object\",\"properties\":{" ++
            "\"url\":{\"type\":\"string\",\"description\":\"The url to fetch.\"}," ++
            "\"raw\":{\"type\":\"boolean\",\"description\":\"Read the url directly instead of extracting a page, for JSON or plain text, whose bytes would be changed by extraction. Defaults to false.\"}}," ++
            "\"required\":[\"url\"]}",
    },
};

fn isNotATool(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "unknown") or std.mem.eql(u8, name, "malformed");
}

fn hasRow(comptime name: []const u8) bool {
    for (table) |tool| {
        if (std.mem.eql(u8, @tagName(tool.tag), name)) return true;
    }
    return false;
}

fn tableForTag(comptime tag: std.meta.Tag(Call)) Tool {
    for (table) |tool| {
        if (tool.tag == tag) return tool;
    }
    @compileError("no table row for the tool '" ++ @tagName(tag) ++ "'");
}

comptime {
    // A tool in the union but not in the table would be parsed and run while never being offered.
    for (@typeInfo(Call).@"union".field_names) |name| {
        if (isNotATool(name)) continue;
        if (!hasRow(name)) @compileError("the tool '" ++ name ++ "' has no row in the tool table");
    }
    for (table) |tool| {
        if (isNotATool(@tagName(tool.tag)))
            @compileError("the non-tool arm '" ++ @tagName(tool.tag) ++ "' has a table row");
    }
}

fn specList(comptime web_tools: Web) [specsCount(web_tools)]Session.Definition {
    var list: [specsCount(web_tools)]Session.Definition = undefined;
    var n: usize = 0;
    for (table) |tool| {
        if (web_tools == .without_web and tool.web) continue;
        list[n] = .{
            .name = @tagName(tool.tag),
            .description = tool.description,
            .parameters = tool.parameters,
        };
        n += 1;
    }
    return list;
}

const Web = enum { with_web, without_web };

fn specsCount(comptime web_tools: Web) usize {
    var n: usize = 0;
    for (table) |tool| {
        if (web_tools == .without_web and tool.web) continue;
        n += 1;
    }
    return n;
}

const specs = specList(.without_web);
const specs_with_web = specList(.with_web);

test "a bash result splits into its status and its streams" {
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

    const quiet = bashOutput("exit code: 0\n(no output)\n").?;
    try std.testing.expectEqualStrings("", quiet.stdout);
    try std.testing.expectEqualStrings("", quiet.stderr);
}

test "a bash command that outlives the timeout is killed and reported" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // A one-second limit kills a command that would otherwise run far longer, and the model is told
    // so rather than left waiting for it to finish.
    var tool_set = Tools.init(io, std.Io.Dir.cwd(), gpa, &http_client, .{ .bash_timeout_s = 1 });
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

fn testTools(with_search: bool) Tools {
    // A web tool that actually makes a request needs a live client; the tests here only exercise
    // the ones that refuse before any request, so this is never reached.
    return Tools.init(std.testing.io, .cwd(), std.testing.allocator, undefined, .{
        .bash_timeout_s = 120,
        .search = if (with_search) .{
            .backends = &.{.{ .provider = .tavily, .api_key = "key" }},
            .max_results = 3,
        } else null,
    });
}

test "a failure is written the way a reader knows it is one" {
    // Every tool that fails goes through `fail`, so what it writes begins with the mark both
    // readers branch on: the terminal colours it as a failure and the page draws it as one.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try fail(&out.writer, "cannot do {s}", .{"the thing"});
    try std.testing.expectEqualStrings("error: cannot do the thing", out.written());
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: "));
}

test "a fetch that fails reaches the reader as a failure" {
    // The mark is not decoration: `printResult` and `html.block` both tell a failed call from one
    // that answered by looking for it, so a fetch that failed without it would be shown as a call
    // that succeeded and said "fetch failed: ...".
    const gpa = std.testing.allocator;
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();

    const call = parse(gpa, .{ .id = "1", .function = .{
        .name = "web_fetch",
        .arguments = "{\"url\":\"\"}",
    } });
    var tool_set = testTools(true);
    try tool_set.run(call, &result.writer);
    try std.testing.expectEqualStrings("error: no url to fetch", result.written());

    // And the reader is told it failed, rather than reading the text as an answer the call gave.
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    const writer: Terminal.Writer = .{ .style = .ansi, .out = &shown.writer };
    try Terminal.tool.printResult(call, result.written(), writer);
    try std.testing.expect(std.mem.find(u8, shown.written(), "output") != null);
}

test "the definitions cover every tool the loop dispatches" {
    const gpa = std.testing.allocator;
    var tool_set = testTools(false);

    // The names are exactly the tools the loop can dispatch, in the order the model receives them,
    // so it is never offered one that does not run.
    const offered = tool_set.definitions();
    const expected = [_][]const u8{ "read", "write", "edit", "bash" };
    try std.testing.expectEqual(expected.len, offered.len);
    for (offered, expected) |definition, name| {
        try std.testing.expectEqualStrings(name, definition.name);
        // The schema is the JSON text it is sent as, so it has to be JSON: it is built by hand, and
        // a mistyped escape would make every request carrying it invalid.
        const schema = try std.json.parseFromSlice(std.json.Value, gpa, definition.parameters, .{});
        defer schema.deinit();
        try std.testing.expect(schema.value == .object);
    }
}

test "the web tools are offered only when a backend is configured" {
    var plain = testTools(false);
    const without = plain.definitions();
    try std.testing.expectEqual(specs.len, without.len);
    for (without) |definition| {
        try std.testing.expect(!std.mem.eql(u8, definition.name, "web_search"));
        try std.testing.expect(!std.mem.eql(u8, definition.name, "web_fetch"));
    }

    var searched = testTools(true);
    const with = searched.definitions();
    try std.testing.expectEqual(specs_with_web.len, with.len);
    try std.testing.expectEqualStrings("web_search", with[with.len - 2].name);
    try std.testing.expectEqualStrings("web_fetch", with[with.len - 1].name);
}

test "the tools work in the directory they are given, wherever billy runs" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "project");
    var work = try tmp.dir.openDir(io, "project", .{});
    defer work.close(io);

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var tool_set = Tools.init(io, work, gpa, &http_client, .{ .bash_timeout_s = 120 });

    var sink: std.Io.Writer.Discarding = .init("");
    _ = try runCall(arena, &tool_set, .{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"note.txt\",\"content\":\"hi\"}",
    } }, &sink.writer);
    const written = try tmp.dir.readFileAlloc(io, "project/note.txt", arena, .limited(64));
    try std.testing.expectEqualStrings("hi", written);

    log.clearRetainingCapacity();
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    _ = try runCall(arena, &tool_set, .{ .id = "2", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }, &result.writer);
    try std.testing.expect(std.mem.find(u8, result.written(), "/project\n") != null);
}

test "a file a tool replaces keeps the permissions it had" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var tool_set = Tools.init(io, tmp.dir, gpa, &http_client, .{ .bash_timeout_s = 120 });

    // A file of the user's with a mode of its own, which is what a script is.
    try tmp.dir.writeFile(io, .{ .sub_path = "run.sh", .data = "#!/bin/sh\necho one\n" });
    const user_only: std.Io.File.Permissions = @fromBackingInt(@intCast(0o700));
    try tmp.dir.setFilePermissions(io, "run.sh", user_only, .{});

    var sink: std.Io.Writer.Discarding = .init("");
    _ = try runCall(arena, &tool_set, .{ .id = "1", .function = .{
        .name = "edit",
        .arguments = "{\"path\":\"run.sh\",\"old_string\":\"echo one\",\"new_string\":\"echo two\"}",
    } }, &sink.writer);

    const edited = try tmp.dir.readFileAlloc(io, "run.sh", arena, .limited(64));
    try std.testing.expectEqualStrings("#!/bin/sh\necho two\n", edited);
    var stat = try tmp.dir.statFile(io, "run.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);

    _ = try runCall(arena, &tool_set, .{ .id = "2", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"run.sh\",\"content\":\"#!/bin/sh\\necho three\\n\"}",
    } }, &sink.writer);

    const written = try tmp.dir.readFileAlloc(io, "run.sh", arena, .limited(64));
    try std.testing.expectEqualStrings("#!/bin/sh\necho three\n", written);
    stat = try tmp.dir.statFile(io, "run.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "the limiting writer gathers writes, then passes on what fits" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Small, so writes spill out of it and the limit is exercised across the gathers rather than
    // all in one go.
    var buffer: [4]u8 = undefined;

    var roomy = Limited.init(&out.writer, &buffer, 100);
    try roomy.writer.writeAll("he");
    try std.testing.expectEqualStrings("", out.written());
    try roomy.writer.writeAll("llo");
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(0, roomy.dropped);

    out.clearRetainingCapacity();
    var gathered = Limited.init(&out.writer, &buffer, 100);
    try gathered.writer.writeAll("ab");
    try std.testing.expectEqualStrings("", out.written());
    try gathered.writer.flush();
    try std.testing.expectEqualStrings("ab", out.written());
    try std.testing.expectEqual(0, gathered.dropped);
    try std.testing.expectEqual(98, gathered.remaining);

    out.clearRetainingCapacity();
    var exact = Limited.init(&out.writer, &buffer, 5);
    try exact.writer.writeAll("hello");
    try exact.writer.flush();
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(0, exact.dropped);

    out.clearRetainingCapacity();
    var tight = Limited.init(&out.writer, &buffer, 5);
    try tight.writer.writeAll("he");
    try tight.writer.writeAll("llo wor");
    try tight.writer.writeAll("ld");
    try tight.writer.flush();
    try std.testing.expectEqualStrings("hello", out.written());
    try std.testing.expectEqual(6, tight.dropped);

    out.clearRetainingCapacity();
    var splatted = Limited.init(&out.writer, &buffer, 4);
    var repeated = [_][]const u8{"ab"};
    try splatted.writer.writeSplatAll(&repeated, 3);
    try splatted.writer.flush();
    try std.testing.expectEqualStrings("abab", out.written());
    try std.testing.expectEqual(2, splatted.dropped);

    out.clearRetainingCapacity();
    var none = Limited.init(&out.writer, &buffer, 0);
    try none.writer.writeAll("gone");
    try none.writer.flush();
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqual(4, none.dropped);
}

test "a result longer than the cap is cut and says what it lost" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line = @as([99]u8, @splat('x')) ++ "\n";
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..1000) |_| try big.appendSlice(gpa, line);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big.items });

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var tool_set = Tools.init(io, tmp.dir, gpa, &http_client, .{ .bash_timeout_s = 120 });

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    _ = try runCall(arena, &tool_set, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"big.txt\"}",
    } }, &result.writer);

    const written = result.written();
    const marker = "\n… ";
    const cut = std.mem.find(u8, written, marker) orelse return error.NoTruncation;
    try std.testing.expectEqual(max_result_len, cut);
    const per_line = 4 + 2 + 99 + 1;
    const written_by_tool = 1000 * per_line;
    const lost = try std.fmt.parseInt(usize, written[cut + marker.len .. written.len - " more bytes".len], 10);
    try std.testing.expectEqual(written_by_tool - max_result_len, lost);
}
