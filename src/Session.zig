//! Sessions: the conversation persisted under the XDG data directory so that a
//! later run can pick up where the previous one stopped.
//!
//! Every session is one JSON file named after its id. The file is rewritten
//! after each message, so killing the process loses at most the message being
//! written. The system prompt and the tool definitions are stored with the
//! conversation and reused when the session is resumed, so a resume resends the
//! exact request of the run it continues and hits the prompt cache. A changed
//! prompt or tool therefore takes effect in new sessions only.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");

const Session = @This();

/// Directory under the XDG data directory that holds the sessions.
const app_dir = "billy";
/// Extension of a session file.
const extension = ".json";
/// Layout of a session file, bumped when its shape changes.
const format_version = 1;
/// Longest session file read back, so a damaged file cannot exhaust memory.
const max_session_bytes = 64 << 20;

/// A session file as it is written to and read from disk.
const Stored = struct {
    version: u32 = format_version,
    /// The conversation, oldest first.
    messages: []const llm.Message = &.{},
    /// The tool definitions the conversation was started with.
    tools: []const llm.Tool = &.{},
    /// Tokens billed over the whole session, summed over every request.
    usage: llm.Usage = .{},
    /// Tokens in the conversation as of the last request, which is what the
    /// context window gauge shows.
    context_tokens: usize = 0,
    /// What the session has cost so far, in USD, summed request by request.
    cost: f64 = 0,
};

io: Io,
/// Directory holding the session files. Owned by the caller.
dir: Io.Dir,
/// Owns the id, the name and the messages.
arena: std.mem.Allocator,
/// For temporary buffers, freed on the way out.
gpa: std.mem.Allocator,
/// Names the session; also its file name without the extension.
id: []const u8,
/// Name of the session file inside `dir`.
name: []const u8,
/// The conversation, oldest first, starting with the system prompt.
messages: std.ArrayList(llm.Message) = .empty,
/// The tool definitions sent with every request. Stored in the session so a
/// resume offers the model the same tools as the run it continues.
tools: []const llm.Tool = &.{},
/// Tokens billed over the whole session, summed over every request, so the
/// cost of a resumed session includes what earlier runs spent.
usage: llm.Usage = .{},
/// Tokens in the conversation as of the last request.
context_tokens: usize = 0,
/// What the session has cost so far, in USD. Accumulated request by request
/// because the rate depends on the time of the request, which the token
/// totals alone could not recover.
cost: f64 = 0,

/// Opens the session called `resume_id`, or starts a new one when it is null.
///
/// Fails with `error.SessionNotFound` when the session is missing, and with
/// `error.InvalidSessionId` when `resume_id` is not a usable name.
pub fn open(
    io: Io,
    dir: Io.Dir,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    resume_id: ?[]const u8,
) !Session {
    const id = if (resume_id) |name|
        try checkedId(arena, name)
    else
        try unusedId(io, dir, arena);
    var session: Session = .{
        .io = io,
        .dir = dir,
        .arena = arena,
        .gpa = gpa,
        .id = id,
        .name = try std.fmt.allocPrint(arena, "{s}{s}", .{ id, extension }),
    };
    if (resume_id != null) try session.load();
    return session;
}

/// Adds a message to the conversation and writes the session out, so the
/// next run sees it even if this one is killed.
pub fn append(session: *Session, message: llm.Message) !void {
    try session.messages.append(session.arena, message);
    try session.save();
}

/// Appends `system_prompt` to an empty conversation, leaving one that has any
/// messages alone. Calling it before the first turn puts the prompt first; a
/// resumed session already carries the prompt it was saved with, which is
/// kept so the messages sent match the earlier run byte for byte and hit the
/// prompt cache.
pub fn appendSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    if (session.messages.items.len != 0) return;
    try session.append(.{ .role = "system", .content = system_prompt });
}

/// Records the tool definitions to send with every request, unless the
/// session already has some. A resumed session carries the tools it was
/// saved with, which are kept so the request matches the earlier run and
/// hits the prompt cache; a new session, or one saved before the tools were
/// stored, gets the current definitions instead.
pub fn ensureTools(session: *Session, tools: []const llm.Tool) !void {
    if (session.tools.len != 0) return;
    session.tools = tools;
    try session.save();
}

/// Adds a request's tokens and cost to the session totals and remembers how
/// full the context window is. The totals reach the file with the next save,
/// which follows every message.
///
/// `cost` is priced by the caller, which knows the rates that applied when
/// the request was made; the session only accumulates it, so a session that
/// spans a rate change is billed at the rates it actually ran under.
pub fn recordUsage(session: *Session, usage: llm.Usage, cost: f64) void {
    session.usage = session.usage.plus(usage);
    session.context_tokens = usage.total_tokens;
    session.cost += cost;
}

/// Writes the conversation to the session file. The previous contents are
/// replaced in one step, leaving them intact if writing fails part way.
pub fn save(session: *Session) !void {
    var text: std.Io.Writer.Allocating = .init(session.gpa);
    defer text.deinit();

    var json: std.json.Stringify = .{
        .writer = &text.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.beginObject();
    try json.objectField("version");
    try json.write(format_version);
    try json.objectField("messages");
    try json.beginArray();
    for (session.messages.items) |message| try json.write(message);
    try json.endArray();
    try json.objectField("tools");
    try json.write(session.tools);
    try json.objectField("usage");
    try json.write(session.usage);
    try json.objectField("context_tokens");
    try json.write(session.context_tokens);
    try json.objectField("cost");
    try json.write(session.cost);
    try json.endObject();

    var atomic = try session.dir.createFileAtomic(session.io, session.name, .{ .replace = true });
    defer atomic.deinit(session.io);
    var buffer: [4096]u8 = undefined;
    var file: Io.File.Writer = .init(atomic.file, session.io, &buffer);
    try file.interface.writeAll(text.written());
    try file.flush();
    try atomic.replace(session.io);
}

/// Reads the conversation of an existing session into `messages`.
fn load(session: *Session) !void {
    const text = session.dir.readFileAlloc(
        session.io,
        session.name,
        session.arena,
        .limited(max_session_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    const stored = std.json.parseFromSliceLeaky(Stored, session.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CorruptSession;
    if (stored.version > format_version) return error.UnsupportedSessionVersion;
    // The stored messages are kept as they are, system prompt included, so
    // resuming reuses exactly what the earlier run sent.
    for (stored.messages) |message| {
        try session.messages.append(session.arena, message);
    }
    session.tools = stored.tools;
    session.usage = stored.usage;
    session.context_tokens = stored.context_tokens;
    session.cost = stored.cost;
}

/// The directory holding the sessions: `$XDG_DATA_HOME/billy`, or
/// `$HOME/.local/share/billy` when that is unset, as the XDG base directory
/// specification prescribes.
pub fn defaultDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        // The specification says a relative path must be ignored.
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(arena, &.{ xdg, app_dir });
        }
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, ".local", "share", app_dir });
}

/// An id based on the current UTC time, such as `20250131-120000`, so that ids
/// sort in the order their sessions were started.
fn newId(io: Io, arena: std.mem.Allocator) ![]const u8 {
    return formatId(arena, @intCast(Io.Clock.now(.real, io).toSeconds()));
}

/// Formats a Unix timestamp as `YYYYMMDD-HHMMSS` in UTC.
fn formatId(arena: std.mem.Allocator, secs: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = seconds.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

/// A new id whose session file does not exist yet, so that starting two runs in
/// the same second cannot overwrite the first session.
fn unusedId(io: Io, dir: Io.Dir, arena: std.mem.Allocator) ![]const u8 {
    const base = try newId(io, arena);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const id = if (attempt == 0)
            base
        else
            try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, attempt });
        const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ id, extension });
        _ = dir.statFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return id,
            else => return err,
        };
    }
}

/// Copies an id given on the command line, rejecting anything that could name
/// another file or directory.
fn checkedId(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    if (id.len == 0) return error.InvalidSessionId;
    for (id) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return error.InvalidSessionId,
    };
    if (std.mem.allEqual(u8, id, '.')) return error.InvalidSessionId;
    return arena.dupe(u8, id);
}

test "formatId writes a UTC timestamp" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectEqualStrings("19700101-000000", try formatId(allocator, 0));
    try std.testing.expectEqualStrings("19700102-000000", try formatId(allocator, 86400));
    try std.testing.expectEqualStrings("20000229-000000", try formatId(allocator, 951782400)); // leap day
    try std.testing.expectEqualStrings("20231114-221320", try formatId(allocator, 1700000000));
    try std.testing.expectEqualStrings("20240301-000000", try formatId(allocator, 1709251200)); // day after a leap day
}

test "newId has the shape of a timestamp" {
    const id = try newId(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expectEqual(15, id.len);
    try std.testing.expectEqual('-', id[8]);
    for (id, 0..) |byte, i| {
        if (i == 8) continue;
        try std.testing.expect(std.ascii.isDigit(byte));
    }
}

test "checkedId rejects names that could escape the session directory" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();

    const id = try checkedId(arena_state.allocator(), "20250131-120000");
    try std.testing.expectEqualStrings("20250131-120000", id);
    try std.testing.expectEqualStrings("dev", try checkedId(arena_state.allocator(), "dev"));

    try std.testing.expectError(error.InvalidSessionId, checkedId(arena_state.allocator(), ""));
    try std.testing.expectError(error.InvalidSessionId, checkedId(arena_state.allocator(), ".."));
    try std.testing.expectError(error.InvalidSessionId, checkedId(arena_state.allocator(), "../x"));
    try std.testing.expectError(error.InvalidSessionId, checkedId(arena_state.allocator(), "a/b"));
    try std.testing.expectError(error.InvalidSessionId, checkedId(arena_state.allocator(), "a b"));
}

test "defaultDir follows the XDG base directory specification" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    defer environ.deinit();

    try std.testing.expectError(error.HomeNotSet, defaultDir(allocator, &environ));

    try environ.put("HOME", "/home/user");
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", try defaultDir(allocator, &environ));

    try environ.put("XDG_DATA_HOME", "/data");
    try std.testing.expectEqualStrings("/data/billy", try defaultDir(allocator, &environ));

    // An empty or relative XDG_DATA_HOME is ignored.
    try environ.put("XDG_DATA_HOME", "");
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", try defaultDir(allocator, &environ));
    try environ.put("XDG_DATA_HOME", "relative");
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", try defaultDir(allocator, &environ));
}

test "a session survives a save and resume" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "hello" });
    try session.append(.{
        .role = "assistant",
        .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }},
    });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" });

    const resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    try std.testing.expectEqualStrings(session.id, resumed.id);
    // The system prompt is stored too, so everything comes back.
    try std.testing.expectEqual(session.messages.items.len, resumed.messages.items.len);
    try std.testing.expectEqualStrings("be terse", resumed.messages.items[0].content.?);
    for (session.messages.items, resumed.messages.items) |before, after| {
        try std.testing.expectEqualStrings(before.role, after.role);
        try std.testing.expectEqualStrings(before.content orelse "", after.content orelse "");
        try std.testing.expectEqualStrings(before.tool_call_id orelse "", after.tool_call_id orelse "");
        if (before.tool_calls) |calls| {
            try std.testing.expectEqualStrings(calls[0].id, after.tool_calls.?[0].id);
            try std.testing.expectEqualStrings(calls[0].function.name, after.tool_calls.?[0].function.name);
            try std.testing.expectEqualStrings(calls[0].function.arguments, after.tool_calls.?[0].function.arguments);
        }
    }
}

test "a stored system prompt is kept when resuming" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "one.json",
        .data = "{\"version\":1,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"old prompt\"}," ++
            "{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    // Resuming keeps the saved prompt even though a newer one is available.
    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, "one");
    try resumed.appendSystemPrompt("new prompt");
    try std.testing.expectEqual(2, resumed.messages.items.len);
    try std.testing.expectEqualStrings("system", resumed.messages.items[0].role);
    try std.testing.expectEqualStrings("old prompt", resumed.messages.items[0].content.?);
    try std.testing.expectEqualStrings("user", resumed.messages.items[1].role);
}

test "appendSystemPrompt only adds the prompt to an empty session" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    try session.appendSystemPrompt("current prompt");
    try std.testing.expectEqual(1, session.messages.items.len);
    try std.testing.expectEqualStrings("system", session.messages.items[0].role);
    try std.testing.expectEqualStrings("current prompt", session.messages.items[0].content.?);

    // A conversation that already has messages is never touched, even when it
    // has no system prompt of its own.
    try session.append(.{ .role = "user", .content = "hi" });
    try session.appendSystemPrompt("a different prompt");
    try std.testing.expectEqual(2, session.messages.items.len);
    try std.testing.expectEqualStrings("system", session.messages.items[0].role);
    try std.testing.expectEqualStrings("current prompt", session.messages.items[0].content.?);
    try std.testing.expectEqualStrings("user", session.messages.items[1].role);
}

test "ensureTools stores the tools and only sets them once" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tools = [_]llm.Tool{.{ .function = .{
        .name = "read",
        .description = "Read a file.",
        .parameters = .null,
    } }};

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    try session.ensureTools(&tools);
    try std.testing.expectEqual(1, session.tools.len);
    try std.testing.expectEqualStrings("read", session.tools[0].function.name);

    // The stored tools survive a save and resume.
    const resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqualStrings("read", resumed.tools[0].function.name);
    try std.testing.expectEqualStrings("Read a file.", resumed.tools[0].function.description);

    // A session that already has tools keeps them.
    const replaced = [_]llm.Tool{.{ .function = .{
        .name = "bash",
        .description = "Run a command.",
        .parameters = .null,
    } }};
    var reopened = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    try reopened.ensureTools(&replaced);
    try std.testing.expectEqual(1, reopened.tools.len);
    try std.testing.expectEqualStrings("read", reopened.tools[0].function.name);
}

test "ensureTools gives tools to a session saved without any" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sessions saved before the tools were stored have no tools field.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "legacy.json",
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    const tools = [_]llm.Tool{.{ .function = .{
        .name = "read",
        .description = "Read a file.",
        .parameters = .null,
    } }};

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, "legacy");
    try std.testing.expectEqual(0, session.tools.len);
    try session.ensureTools(&tools);
    try std.testing.expectEqual(1, session.tools.len);
    try std.testing.expectEqualStrings("read", session.tools[0].function.name);
}

test "the token totals survive a save and resume" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    session.recordUsage(.{
        .prompt_tokens = 100,
        .completion_tokens = 10,
        .total_tokens = 110,
        .cache_hit_tokens = 90,
        .cache_miss_tokens = 10,
    }, 0.0001);
    try session.append(.{ .role = "user", .content = "hi" });
    // A second request adds to the totals rather than replacing them.
    session.recordUsage(.{
        .prompt_tokens = 200,
        .completion_tokens = 20,
        .total_tokens = 220,
        .cache_hit_tokens = 180,
        .cache_miss_tokens = 20,
    }, 0.0002);
    try session.append(.{ .role = "assistant", .content = "hello" });

    const resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    try std.testing.expectEqual(300, resumed.usage.prompt_tokens);
    try std.testing.expectEqual(30, resumed.usage.completion_tokens);
    try std.testing.expectEqual(270, resumed.usage.cache_hit_tokens);
    try std.testing.expectEqual(30, resumed.usage.cache_miss_tokens);
    // The context gauge keeps the size of the last request's conversation.
    try std.testing.expectEqual(220, resumed.context_tokens);
    // The cost accumulates across requests too.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0003), resumed.cost, 1e-12);
}

test "opening an unknown or damaged session is reported" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.SessionNotFound,
        Session.open(std.testing.io, tmp.dir, allocator, arena, "nope"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "{" });
    try std.testing.expectError(
        error.CorruptSession,
        Session.open(std.testing.io, tmp.dir, allocator, arena, "bad"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "future.json", .data = "{\"version\":99}" });
    try std.testing.expectError(
        error.UnsupportedSessionVersion,
        Session.open(std.testing.io, tmp.dir, allocator, arena, "future"),
    );
}

test "a new session does not reuse an id whose file exists" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    try first.append(.{ .role = "user", .content = "keep me" });

    var second = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    try second.append(.{ .role = "user", .content = "and me" });

    try std.testing.expect(!std.mem.eql(u8, first.id, second.id));
    const resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, first.id);
    try std.testing.expectEqualStrings("keep me", resumed.messages.items[0].content.?);
}
