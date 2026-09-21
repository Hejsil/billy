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

/// Directory under the XDG data directory that holds billy's files.
const app_dir = "billy";
/// Subdirectory of the data directory that holds the sessions, so the session
/// files sit apart from the credentials billy keeps in the directory itself.
const sessions_dir = "sessions";
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

const StringIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

/// Equality and hashing for interned strings. A string is named by its index
/// into the pool rather than by a pointer, so that growing the pool cannot
/// invalidate a key, and the pool itself stays the only copy of the text.
const Interned = struct {
    session: *const Session,

    pub fn hash(context: Interned, index: StringIndex) u64 {
        return std.hash.Wyhash.hash(0, context.session.string(index) orelse "");
    }

    pub fn eql(context: Interned, a: StringIndex, b: StringIndex) bool {
        return std.mem.eql(
            u8,
            context.session.string(a) orelse "",
            context.session.string(b) orelse "",
        );
    }
};

const ToolCallIndex = struct {
    start: u32,
    len: u32,

    const empty = ToolCallIndex{ .start = 0, .len = 0 };

    fn resolve(tool_calls: ToolCallIndex, session: *const Session) []const ToolCall {
        return session.tool_calls.items[tool_calls.start..][0..tool_calls.len];
    }
};

/// An llm.ToolCall as stored in a session.
const ToolCall = struct {
    id: StringIndex,
    type: StringIndex,
    function: Function,

    const Function = struct {
        name: StringIndex,
        arguments: StringIndex,
    };

    fn resolve(tool_call: ToolCall, session: *const Session) llm.ToolCall {
        return .{
            .id = session.string(tool_call.id) orelse "",
            .type = session.string(tool_call.type) orelse "",
            .function = .{
                .name = session.string(tool_call.function.name) orelse "",
                .arguments = session.string(tool_call.function.arguments) orelse "",
            },
        };
    }
};

/// An llm.Message as stored in a session.
pub const Message = struct {
    role: StringIndex,
    content: StringIndex = .none,
    tool_call_id: StringIndex = .none,
    tool_calls: ToolCallIndex = .empty,

    /// The message as the API client takes it, with every string resolved out of
    /// the pool. `allocator` owns the tool calls, which have to be pieced back
    /// together into a slice of their own.
    pub fn resolve(message: Message, session: *const Session, allocator: std.mem.Allocator) !llm.Message {
        const stored = message.tool_calls.resolve(session);
        var calls: ?[]const llm.ToolCall = null;
        if (stored.len > 0) {
            const resolved = try allocator.alloc(llm.ToolCall, stored.len);
            for (stored, resolved) |tool_call, *out| out.* = tool_call.resolve(session);
            calls = resolved;
        }
        return .{
            .role = session.string(message.role) orelse "",
            .content = session.string(message.content),
            .tool_call_id = session.string(message.tool_call_id),
            .tool_calls = calls,
        };
    }
};

io: Io,

/// Directory holding the session files. Owned by the caller.
dir: Io.Dir,

/// Owns the id, the name, and what was read back from the file, which holds the
/// tools a resume sends. The conversation is in `strings`, `tool_calls` and
/// `messages`, which `gpa` owns and `deinit` frees.
arena: std.mem.Allocator,

/// For temporary buffers, freed on the way out.
gpa: std.mem.Allocator,

/// Names the session; also its file name without the extension.
id: []const u8,

/// Name of the session file inside `dir`.
name: []const u8,

/// All string data, one NUL-terminated copy per distinct string. Two equal
/// strings share an index, so a conversation that repeats its roles, its tool
/// names and what a repeated call returned pays for each of them once.
strings: std.ArrayList(u8) = .empty,

/// The strings the pool holds, so that one already there is not appended again.
/// Keyed by index rather than by pointer, since the pool moves as it grows.
interned: std.HashMapUnmanaged(StringIndex, void, Interned, std.hash_map.default_max_load_percentage) = .empty,

tool_calls: std.ArrayList(ToolCall) = .empty,

/// The conversation, oldest first, starting with the system prompt.
messages: std.ArrayList(Message) = .empty,

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
    // A resume that fails part way leaves the strings it had read behind, since
    // the caller only gets the session on the way out.
    errdefer session.deinit();
    if (resume_id != null)
        try session.load();
    return session;
}

pub fn deinit(session: *Session) void {
    session.strings.deinit(session.gpa);
    session.interned.deinit(session.gpa);
    session.tool_calls.deinit(session.gpa);
    session.messages.deinit(session.gpa);
}

/// The conversation as a completion request carries it: the `messages` array of
/// a request body, written straight out of the pool.
///
/// A request takes one of these instead of a resolved copy of the conversation,
/// so that sending what a session holds allocates nothing at all: the messages
/// are written straight onto the connection, and the strings are read where they
/// were stored rather than pointed at from a second array of slices.
///
/// The field order and the fields left out are the ones `llm.Message` produces,
/// so the body is the same either way.
pub const Conversation = struct {
    session: *const Session,

    pub fn jsonStringify(self: Conversation, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        for (session.messages.items) |message| {
            try json.beginObject();
            try json.objectField("role");
            try json.write(session.string(message.role) orelse "");

            if (session.string(message.content)) |content| {
                try json.objectField("content");
                try json.write(content);
            }

            const calls = message.tool_calls.resolve(session);
            if (calls.len > 0) {
                try json.objectField("tool_calls");
                try json.beginArray();
                for (calls) |call| {
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(session.string(call.id) orelse "");
                    try json.objectField("type");
                    try json.write(session.string(call.type) orelse "");
                    try json.objectField("function");
                    try json.beginObject();
                    try json.objectField("name");
                    try json.write(session.string(call.function.name) orelse "");
                    try json.objectField("arguments");
                    try json.write(session.string(call.function.arguments) orelse "");
                    try json.endObject();
                    try json.endObject();
                }
                try json.endArray();
            }

            if (session.string(message.tool_call_id)) |tool_call_id| {
                try json.objectField("tool_call_id");
                try json.write(tool_call_id);
            }
            try json.endObject();
        }
        try json.endArray();
    }
};

/// The conversation as a request carries it, for passing to a client without
/// resolving it first. The returned value borrows the session.
pub fn conversation(session: *const Session) Conversation {
    return .{ .session = session };
}

/// A tool call as the transcript reads it: the id that names the result which
/// answers it, and the tool plus the arguments to run the call back through the
/// parser. Every one is a window into the pool, so reading a call allocates
/// nothing.
pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// The role of a message, read from where it is stored.
pub fn roleOf(session: *const Session, message: Message) []const u8 {
    return session.string(message.role) orelse "";
}

/// The content of a message, or null when it has none.
pub fn contentOf(session: *const Session, message: Message) ?[]const u8 {
    return session.string(message.content);
}

/// How many tool calls a message asked for.
pub fn callCount(session: *const Session, message: Message) usize {
    return message.tool_calls.resolve(session).len;
}

/// One tool call of a message, by position within it.
pub fn callAt(session: *const Session, message: Message, index: usize) Call {
    const call = message.tool_calls.resolve(session)[index];
    return .{
        .id = session.string(call.id) orelse "",
        .name = session.string(call.function.name) orelse "",
        .arguments = session.string(call.function.arguments) orelse "",
    };
}

/// The content of the tool message that answers `id`, looking from message
/// `from` onwards, which is where the result of a call sits: the message just
/// after the one that asked for it. Empty when the session does not hold it, so
/// a file written without one still replays.
///
/// Every string compared is a window into the pool, so finding a result costs
/// nothing to allocate.
pub fn toolResult(session: *const Session, from: usize, id: []const u8) []const u8 {
    const messages = session.messages.items;
    if (from >= messages.len) return "";
    for (messages[from..]) |message| {
        if (!std.mem.eql(u8, session.string(message.role) orelse "", "tool")) continue;
        const call_id = session.string(message.tool_call_id) orelse continue;
        if (std.mem.eql(u8, call_id, id)) return session.string(message.content) orelse "";
    }
    return "";
}

/// The conversation as plain API messages, every string resolved out of the
/// pool. `allocator` owns the result, since resolving a message has to piece its
/// tool calls back together into a slice of its own.
///
/// Nothing that shows or sends a conversation needs this: a request is built
/// from `conversation`, and the transcript reads the session a message at a
/// time. It is for a caller that wants the conversation as messages, which is
/// what comparing two of them takes.
pub fn resolvedMessages(session: *const Session, allocator: std.mem.Allocator) ![]const llm.Message {
    const messages = try allocator.alloc(llm.Message, session.messages.items.len);
    for (session.messages.items, messages) |message, *out| {
        out.* = try message.resolve(session, allocator);
    }
    return messages;
}

/// Adds a message to the conversation and writes the session out, so the
/// next run sees it even if this one is killed.
pub fn append(session: *Session, message: llm.Message) !void {
    try session.appendNoSave(message);
    try session.save();
}

pub fn appendNoSave(session: *Session, message: llm.Message) !void {
    const tool_calls = message.tool_calls orelse &.{};
    const interned_tool_calls = ToolCallIndex{
        .start = @intCast(session.tool_calls.items.len),
        .len = @intCast(tool_calls.len),
    };

    for (tool_calls) |tool_call| {
        try session.tool_calls.append(session.gpa, .{
            .id = try session.internString(tool_call.id),
            .type = try session.internString(tool_call.type),
            .function = .{
                .name = try session.internString(tool_call.function.name),
                .arguments = try session.internString(tool_call.function.arguments),
            },
        });
    }

    try session.messages.append(session.gpa, .{
        .role = try session.internString(message.role),
        .content = try session.internString(message.content),
        .tool_call_id = try session.internString(message.tool_call_id),
        .tool_calls = interned_tool_calls,
    });
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
    for (session.messages.items) |message| {
        try json.beginObject();
        if (session.string(message.role)) |role| {
            try json.objectField("role");
            try json.write(role);
        }
        if (session.string(message.content)) |content| {
            try json.objectField("content");
            try json.write(content);
        }
        if (session.string(message.tool_call_id)) |tool_call_id| {
            try json.objectField("tool_call_id");
            try json.write(tool_call_id);
        }

        const tool_calls = message.tool_calls.resolve(session);
        if (tool_calls.len != 0) {
            try json.objectField("tool_calls");
            try json.beginArray();
            for (tool_calls) |tool_call| {
                try json.write(tool_call.resolve(session));
            }
            try json.endArray();
        }
        try json.endObject();
    }
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

    var file: Io.File.Writer = atomic.file.writer(session.io, "");
    try file.interface.writeAll(text.written());
    try file.end();

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

    if (stored.version > format_version)
        return error.UnsupportedSessionVersion;

    // The stored messages are kept as they are, system prompt included, so
    // resuming reuses exactly what the earlier run sent.
    for (stored.messages) |message| {
        try session.appendNoSave(message);
    }

    session.tools = stored.tools;
    session.usage = stored.usage;
    session.context_tokens = stored.context_tokens;
    session.cost = stored.cost;
}

fn internString(session: *Session, text: ?[]const u8) !StringIndex {
    const value = text orelse return .none;

    // The candidate is put in the pool before it is looked up, since a key has
    // to name a string the pool already holds. A duplicate is rolled back as
    // soon as the lookup finds the copy that was there already.
    const start: u32 = @intCast(session.strings.items.len);
    try session.strings.appendSlice(session.gpa, value);
    try session.strings.append(session.gpa, 0);
    const candidate: StringIndex = @enumFromInt(start);

    const context = Interned{ .session = session };
    const entry = try session.interned.getOrPutContext(session.gpa, candidate, context);
    if (!entry.found_existing) return candidate;

    session.strings.shrinkRetainingCapacity(start);
    return entry.key_ptr.*;
}

fn string(session: *const Session, index: StringIndex) ?[]const u8 {
    const ptr = session.stringPtr(index) orelse return null;
    return std.mem.span(ptr);
}

fn stringPtr(session: *const Session, index: StringIndex) ?[*:0]const u8 {
    if (index == .none) return null;
    const start = @intFromEnum(index);
    return session.strings.items[start .. session.strings.items.len - 1 :0].ptr;
}

/// The directory billy keeps its own files in: `$XDG_DATA_HOME/billy`, or
/// `$HOME/.local/share/billy` when that is unset, as the XDG base directory
/// specification prescribes. The credentials live in the directory itself, and
/// the sessions in a subdirectory of it, so a listing of billy's data directory
/// shows what billy keeps rather than a wall of session files.
pub fn dataDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        // The specification says a relative path must be ignored.
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(arena, &.{ xdg, app_dir });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, ".local", "share", app_dir });
}

/// The directory holding the sessions: the `sessions` subdirectory of `dataDir`,
/// so that the session files sit apart from what else billy keeps.
pub fn defaultDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return std.fs.path.join(arena, &.{ try dataDir(arena, environ), sessions_dir });
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
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", try defaultDir(allocator, &environ));
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", try dataDir(allocator, &environ));

    try environ.put("XDG_DATA_HOME", "/data");
    try std.testing.expectEqualStrings("/data/billy/sessions", try defaultDir(allocator, &environ));
    try std.testing.expectEqualStrings("/data/billy", try dataDir(allocator, &environ));

    // An empty or relative XDG_DATA_HOME is ignored.
    try environ.put("XDG_DATA_HOME", "");
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", try defaultDir(allocator, &environ));
    try environ.put("XDG_DATA_HOME", "relative");
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", try defaultDir(allocator, &environ));
}

test "a session survives a save and resume" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    defer session.deinit();

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

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    defer resumed.deinit();

    try std.testing.expectEqualStrings(session.id, resumed.id);
    // The system prompt is stored too, so everything comes back.
    try std.testing.expectEqual(session.messages.items.len, resumed.messages.items.len);

    // Resolving both sides is what makes them comparable: the indices a session
    // stores are its own, and two sessions with the same conversation number
    // their strings differently.
    const before = try session.resolvedMessages(allocator);
    const after = try resumed.resolvedMessages(allocator);
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| {
        try std.testing.expectEqualStrings(expected.role, actual.role);
        try std.testing.expectEqualStrings(expected.content orelse "", actual.content orelse "");
        try std.testing.expectEqualStrings(expected.tool_call_id orelse "", actual.tool_call_id orelse "");

        const expected_calls = expected.tool_calls orelse &.{};
        const actual_calls = actual.tool_calls orelse &.{};
        try std.testing.expectEqual(expected_calls.len, actual_calls.len);
        for (expected_calls, actual_calls) |expected_call, actual_call| {
            try std.testing.expectEqualStrings(expected_call.id, actual_call.id);
            try std.testing.expectEqualStrings(expected_call.type, actual_call.type);
            try std.testing.expectEqualStrings(expected_call.function.name, actual_call.function.name);
            try std.testing.expectEqualStrings(expected_call.function.arguments, actual_call.function.arguments);
        }
    }
}

test "a conversation writes the messages a request would have carried" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, allocator, null);
    defer session.deinit();

    // A message of every shape: an optional left out, one filled in, and a call
    // alongside the result that answers it.
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "hello" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
    }} });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" });

    // Writing the stored conversation has to give the bytes the resolved one
    // does, field for field and in the same order, or a resumed session would
    // send a request that misses its prompt cache.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const resolved = try session.resolvedMessages(scratch_state.allocator());

    const via_messages = try std.json.Stringify.valueAlloc(
        gpa,
        resolved,
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(via_messages);

    const via_conversation = try std.json.Stringify.valueAlloc(
        gpa,
        session.conversation(),
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(via_conversation);

    try std.testing.expectEqualStrings(via_messages, via_conversation);
    try std.testing.expectEqualStrings(
        "[{\"role\":\"system\",\"content\":\"be terse\"}," ++
            "{\"role\":\"user\",\"content\":\"hello\"}," ++
            "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," ++
            "\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}]}," ++
            "{\"role\":\"tool\",\"content\":\"1\\tconst x = 1;\\n\",\"tool_call_id\":\"call_1\"}]",
        via_conversation,
    );
}

test "a stored message reads back as its parts" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, allocator, null);
    defer session.deinit();

    try session.append(.{ .role = "user", .content = "hello" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .id = "call_2", .function = .{ .name = "bash", .arguments = "{}" } },
    } });

    // What the transcript reads a message through, without building a message.
    const user = session.messages.items[0];
    try std.testing.expectEqualStrings("user", session.roleOf(user));
    try std.testing.expectEqualStrings("hello", session.contentOf(user).?);
    try std.testing.expectEqual(0, session.callCount(user));

    // A message with no content reports none, rather than an empty string.
    const assistant = session.messages.items[1];
    try std.testing.expectEqualStrings("assistant", session.roleOf(assistant));
    try std.testing.expect(session.contentOf(assistant) == null);
    try std.testing.expectEqual(2, session.callCount(assistant));

    const first = session.callAt(assistant, 0);
    try std.testing.expectEqualStrings("call_1", first.id);
    try std.testing.expectEqualStrings("read", first.name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", first.arguments);

    const second = session.callAt(assistant, 1);
    try std.testing.expectEqualStrings("call_2", second.id);
    try std.testing.expectEqualStrings("bash", second.name);
    try std.testing.expectEqualStrings("{}", second.arguments);
}

test "a tool result is found only from where the search starts" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, allocator, null);
    defer session.deinit();

    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "the result" });
    try session.append(.{ .role = "tool", .tool_call_id = "old", .content = "an earlier result" });

    // The replay searches from the message after the call, which is where its
    // result sits.
    try std.testing.expectEqualStrings("the result", session.toolResult(1, "call_1"));
    // A result behind the point the search starts from is not the answer to
    // anything ahead of it.
    try std.testing.expectEqualStrings("", session.toolResult(2, "call_1"));
    try std.testing.expectEqualStrings("an earlier result", session.toolResult(2, "old"));
    // A result the session does not hold, and a search past the end of it.
    try std.testing.expectEqualStrings("", session.toolResult(1, "nothing"));
    try std.testing.expectEqualStrings("", session.toolResult(99, "call_1"));
}

test "an equal string is interned once and shared" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    defer session.deinit();

    try session.append(.{ .role = "user", .content = "hello" });
    try session.append(.{ .role = "assistant", .content = "hello" });
    try session.append(.{
        .role = "assistant",
        .tool_calls = &.{
            .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
            // The same call read twice: its id and its name are already in the
            // pool, and only the arguments that differ are added.
            .{ .id = "call_1", .function = .{ .name = "read", .arguments = "[]" } },
        },
    });

    // Each distinct string once, in the order it was first seen.
    try std.testing.expectEqualStrings(
        "user\x00hello\x00assistant\x00call_1\x00function\x00read\x00{}\x00[]\x00",
        session.strings.items,
    );
    // The two equal contents, and the repeated parts of the two tool calls,
    // name the one copy of each.
    try std.testing.expectEqual(session.messages.items[0].content, session.messages.items[1].content);
    const calls = session.messages.items[2].tool_calls.resolve(&session);
    try std.testing.expectEqual(calls[0].id, calls[1].id);
    try std.testing.expectEqual(calls[0].function.name, calls[1].function.name);
    try std.testing.expect(calls[0].function.arguments != calls[1].function.arguments);
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
    defer resumed.deinit();

    try resumed.appendSystemPrompt("new prompt");
    try std.testing.expectEqual(2, resumed.messages.items.len);
    try std.testing.expectEqualStrings("system", resumed.string(resumed.messages.items[0].role).?);
    try std.testing.expectEqualStrings("old prompt", resumed.string(resumed.messages.items[0].content).?);
    try std.testing.expectEqualStrings("user", resumed.string(resumed.messages.items[1].role).?);
}

test "appendSystemPrompt only adds the prompt to an empty session" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    defer session.deinit();

    try session.appendSystemPrompt("current prompt");
    try std.testing.expectEqual(1, session.messages.items.len);
    try std.testing.expectEqualStrings("system", session.string(session.messages.items[0].role).?);
    try std.testing.expectEqualStrings("current prompt", session.string(session.messages.items[0].content).?);

    // A conversation that already has messages is never touched, even when it
    // has no system prompt of its own.
    try session.append(.{ .role = "user", .content = "hi" });
    try session.appendSystemPrompt("a different prompt");
    try std.testing.expectEqual(2, session.messages.items.len);
    try std.testing.expectEqualStrings("system", session.string(session.messages.items[0].role).?);
    try std.testing.expectEqualStrings("current prompt", session.string(session.messages.items[0].content).?);
    try std.testing.expectEqualStrings("user", session.string(session.messages.items[1].role).?);
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
    defer session.deinit();

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
    defer session.deinit();

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

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, session.id);
    defer resumed.deinit();

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
    defer first.deinit();
    try first.append(.{ .role = "user", .content = "keep me" });

    var second = try Session.open(std.testing.io, tmp.dir, allocator, arena, null);
    defer second.deinit();
    try second.append(.{ .role = "user", .content = "and me" });

    try std.testing.expect(!std.mem.eql(u8, first.id, second.id));

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, first.id);
    defer resumed.deinit();

    try std.testing.expectEqualStrings("keep me", resumed.string(resumed.messages.items[0].content).?);
}
