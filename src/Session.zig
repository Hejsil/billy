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
/// Most a session id may be. A generated one is the 15 characters of
/// `YYYYMMDD-HHMMSS`; the room is for a `-N` suffix on a second run in the same
/// second, or a name typed on the command line. The buffer holds this many bytes
/// and is written from the front, so there is always a byte left to end the id.
const max_id_len = 64;
/// Layout of a session file, bumped when its shape changes.
const format_version = 1;
/// Longest session file read back, so a damaged file cannot exhaust memory.
const max_session_bytes = 64 << 20;

/// A tool definition as the API takes it, which is how a session file holds
/// one, so a file written before a session kept its own tools still reads. The
/// arguments schema is the parsed object in the file and becomes the JSON text
/// the session stores.
const StoredTool = struct {
    type: []const u8 = "function",
    function: Function,

    const Function = struct {
        name: []const u8 = "",
        description: []const u8 = "",
        parameters: std.json.Value = .null,
    };
};

/// A session file as it is written to and read from disk.
const Stored = struct {
    version: u32 = format_version,
    /// The conversation, oldest first.
    messages: []const llm.Message = &.{},
    /// The tool definitions the conversation was started with.
    tools: []const StoredTool = &.{},
    /// Tokens billed over the whole session, summed over every request.
    usage: llm.Usage = .{},
    /// Tokens in the conversation as of the last request, which is what the
    /// context window gauge shows.
    context_tokens: usize = 0,
    /// What the session has cost so far, in USD, summed request by request.
    cost: f64 = 0,
    /// The directory the session was started in. Empty for a session saved
    /// before it was recorded, which is read as the directory billy runs in.
    cwd: []const u8 = "",
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

/// A tool definition as a session stores it. Every string is an index into the
/// pool, and the arguments schema is the JSON text the request carries, so
/// nothing here is a parsed document: the set is one array that frees with the
/// pool and no per-tool walk to free it.
pub const Tool = struct {
    name: StringIndex,
    description: StringIndex,
    /// The JSON Schema of the arguments, as the JSON text it is sent as.
    parameters: StringIndex,
};

/// A tool definition as it comes from outside the session: the strings to be
/// interned, so a caller builds the set without knowing the pool.
pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    /// The JSON Schema of the arguments, as JSON text.
    parameters: []const u8,
};

io: Io,

/// Directory holding the session files. Owned by the caller.
dir: Io.Dir,

/// Owns the conversation and everything a resume read back, all freed by
/// `deinit`.
gpa: std.mem.Allocator,

/// The id, in a fixed buffer written once from the front. The buffer is
/// zero-filled, so what is written ends in NUL and the id is a NUL-terminated
/// string with no length kept beside it. A generated id is a timestamp; a resume
/// takes one from the command line.
id_buf: [max_id_len]u8 = [_]u8{0} ** max_id_len,

/// The id with the file extension: the name of the session file, in a fixed
/// buffer beside the id and zero-filled past the name for the same reason.
name_buf: [max_id_len + extension.len]u8 = [_]u8{0} ** (max_id_len + extension.len),

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
/// resume offers the model the same tools as the run it continues. The whole set
/// is one array `deinit` frees; every string in it is interned in the pool.
tools: []const Tool = &.{},

/// Tokens billed over the whole session, summed over every request, so the
/// cost of a resumed session includes what earlier runs spent.
usage: llm.Usage = .{},

/// Tokens in the conversation as of the last request.
context_tokens: usize = 0,

/// What the session has cost so far, in USD. Accumulated request by request
/// because the rate depends on the time of the request, which the token
/// totals alone could not recover.
cost: f64 = 0,

/// The directory the session was started in. A resumed session keeps it, so
/// billy works where the session did rather than wherever it is run from now;
/// a session saved before it was recorded has none, and the run's own directory
/// is used instead. Owned by `gpa`, even when it is the empty default.
cwd: []const u8 = "",

/// Opens the session called `resume_id`, or starts a new one when it is null.
///
/// `cwd` is the directory billy is running in. A new session records it; a
/// resumed one keeps the directory it was saved with, so a session continues
/// where it was started.
///
/// Fails with `error.SessionNotFound` when the session is missing, and with
/// `error.InvalidSessionId` when `resume_id` is not a usable name.
pub fn open(
    io: Io,
    dir: Io.Dir,
    gpa: std.mem.Allocator,
    resume_id: ?[]const u8,
    cwd: []const u8,
) !Session {
    var session: Session = .{ .io = io, .dir = dir, .gpa = gpa };
    // A resume that fails part way leaves what it had read behind, since the
    // caller only gets the session on the way out.
    errdefer session.deinit();

    // The id is written into its buffer; the file name is the id with the
    // extension, built from it once so every read and write goes through one
    // place. Both buffers are zero-filled, so both end in NUL.
    const session_id = if (resume_id) |given|
        try setCheckedId(&session.id_buf, given)
    else
        try unusedId(io, dir, &session.id_buf);
    _ = try std.fmt.bufPrint(&session.name_buf, "{s}{s}", .{ session_id, extension });

    // The session owns its directory rather than pointing into the caller's
    // memory, which it may outlive.
    session.cwd = try gpa.dupe(u8, cwd);

    if (resume_id != null) try session.load();
    return session;
}

pub fn deinit(session: *Session) void {
    session.strings.deinit(session.gpa);
    session.interned.deinit(session.gpa);
    session.tool_calls.deinit(session.gpa);
    session.messages.deinit(session.gpa);
    session.gpa.free(session.tools);
    session.gpa.free(session.cwd);
}

/// Names the session; also its file name without the extension. The buffer ends
/// in NUL, which is what says where the id does.
pub fn id(session: *const Session) []const u8 {
    return std.mem.sliceTo(&session.id_buf, 0);
}

/// Name of the session file inside `dir`.
pub fn name(session: *const Session) []const u8 {
    return std.mem.sliceTo(&session.name_buf, 0);
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
pub fn toolResult(session: *const Session, from: usize, call: []const u8) []const u8 {
    const messages = session.messages.items;
    if (from >= messages.len) return "";
    for (messages[from..]) |message| {
        if (!std.mem.eql(u8, session.string(message.role) orelse "", "tool")) continue;
        const call_id = session.string(message.tool_call_id) orelse continue;
        if (std.mem.eql(u8, call_id, call)) return session.string(message.content) orelse "";
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
pub fn ensureTools(session: *Session, definitions: []const Definition) !void {
    if (session.tools.len != 0) return;
    // The strings are interned into the pool, so the set costs one array and
    // frees with the pool. Nothing is copied per string and there is no parsed
    // document to keep alive: the arguments schema is stored as the JSON text it
    // is sent as.
    const tools = try session.gpa.alloc(Tool, definitions.len);
    for (definitions, tools) |definition, *tool| {
        tool.* = .{
            .name = try session.internString(definition.name),
            .description = try session.internString(definition.description),
            .parameters = try session.internString(definition.parameters),
        };
    }
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
    try json.write(session.toolSet());
    try json.objectField("usage");
    try json.write(session.usage);
    try json.objectField("context_tokens");
    try json.write(session.context_tokens);
    try json.objectField("cost");
    try json.write(session.cost);
    try json.objectField("cwd");
    try json.write(session.cwd);
    try json.endObject();

    var atomic = try session.dir.createFileAtomic(session.io, session.name(), .{ .replace = true });
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
        session.name(),
        session.gpa,
        .limited(max_session_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    // The file's own bytes are not needed once it has been parsed.
    defer session.gpa.free(text);

    // The parse is freed on the way out: what the session keeps, the tools and
    // the directory, is copied out of it first, so nothing points into it after
    // this returns. The conversation is interned into the pool, which is what a
    // session keeps its strings in.
    var parsed = std.json.parseFromSlice(Stored, session.gpa, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CorruptSession;
    defer parsed.deinit();
    const stored = parsed.value;

    if (stored.version > format_version)
        return error.UnsupportedSessionVersion;

    // The stored messages are kept as they are, system prompt included, so
    // resuming reuses exactly what the earlier run sent.
    for (stored.messages) |message| {
        try session.appendNoSave(message);
    }

    // The tools are interned like the conversation, so the set is one array and
    // the arguments schema becomes the JSON text the request sends it as.
    const tools = try session.gpa.alloc(Tool, stored.tools.len);
    for (stored.tools, tools) |stored_tool, *tool| {
        tool.* = .{
            .name = try session.internString(stored_tool.function.name),
            .description = try session.internString(stored_tool.function.description),
            .parameters = try session.internParameters(stored_tool.function.parameters),
        };
    }
    session.tools = tools;
    session.usage = stored.usage;
    session.context_tokens = stored.context_tokens;
    session.cost = stored.cost;
    // A session saved before the directory was recorded has none, and the
    // directory billy runs in now is kept.
    if (stored.cwd.len > 0) {
        const owned = try session.gpa.dupe(u8, stored.cwd);
        session.gpa.free(session.cwd);
        session.cwd = owned;
    }
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

/// The arguments schema of a tool as JSON text: already text when a file holds
/// it so, and written back out when an older file holds the parsed object, which
/// is what the request is sent.
fn internParameters(session: *Session, value: std.json.Value) !StringIndex {
    switch (value) {
        .string => |text| return session.internString(text),
        else => {
            const text = try std.json.Stringify.valueAlloc(session.gpa, value, .{});
            defer session.gpa.free(text);
            return session.internString(text);
        },
    }
}

/// The tools as JSON: the definitions written out, each with its arguments
/// schema as the JSON text it is held as. A request writes the tools it sends
/// through this, and the session file stores them the same way, so the two are
/// written by one piece of code.
pub const ToolSet = struct {
    session: *const Session,

    pub fn jsonStringify(self: ToolSet, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        for (session.tools) |tool| {
            try json.beginObject();
            // The API takes the kind of every tool billy offers as "function".
            try json.objectField("type");
            try json.write("function");
            try json.objectField("function");
            try json.beginObject();
            try json.objectField("name");
            try json.write(session.string(tool.name) orelse "");
            try json.objectField("description");
            try json.write(session.string(tool.description) orelse "");
            try json.objectField("parameters");
            // The schema is written as the JSON it is, not as a quoted string.
            try json.print("{s}", .{session.string(tool.parameters) orelse "{}"});
            try json.endObject();
            try json.endObject();
        }
        try json.endArray();
    }
};

/// The tools as a request carries them. The returned value borrows the session.
pub fn toolSet(session: *const Session) ToolSet {
    return .{ .session = session };
}

/// Formats a Unix timestamp as `YYYYMMDD-HHMMSS` in UTC, written into `buf` and
/// returned as the slice it filled, which is 15 characters.
fn formatId(buf: []u8, secs: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = seconds.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

/// An id based on the current UTC time, such as `20250131-120000`, whose session
/// file does not exist yet, written into `buf` and returned as a slice of it, so
/// that starting two runs in the same second cannot overwrite the first session.
fn unusedId(io: Io, dir: Io.Dir, buf: []u8) ![]const u8 {
    const base = try formatId(buf, @intCast(Io.Clock.now(.real, io).toSeconds()));
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        // A second run in the same second appends `-N` to the timestamp, growing
        // the id in place after the base.
        const candidate = if (attempt == 0) base else candidate: {
            const suffix = try std.fmt.bufPrint(buf[base.len..], "-{d}", .{attempt});
            break :candidate buf[0 .. base.len + suffix.len];
        };
        var file_buf: [max_id_len + extension.len]u8 = undefined;
        const file = try std.fmt.bufPrint(&file_buf, "{s}{s}", .{ candidate, extension });
        _ = dir.statFile(io, file, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => return err,
        };
    }
}

/// Copies an id given on the command line into `buf`, rejecting anything that
/// could name another file or directory or that does not fit. Returns the id as
/// a slice of `buf`; the buffer is zero-filled, so the copy ends in NUL.
fn setCheckedId(buf: []u8, given: []const u8) ![]const u8 {
    // One byte is kept for the NUL that ends the id in the buffer.
    if (given.len == 0 or given.len + 1 > buf.len) return error.InvalidSessionId;
    for (given) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return error.InvalidSessionId,
    };
    if (std.mem.allEqual(u8, given, '.')) return error.InvalidSessionId;
    @memcpy(buf[0..given.len], given);
    return buf[0..given.len];
}

test "formatId writes a UTC timestamp" {
    var buf: [max_id_len]u8 = undefined;

    try std.testing.expectEqualStrings("19700101-000000", try formatId(&buf, 0));
    try std.testing.expectEqualStrings("19700102-000000", try formatId(&buf, 86400));
    try std.testing.expectEqualStrings("20000229-000000", try formatId(&buf, 951782400)); // leap day
    try std.testing.expectEqualStrings("20231114-221320", try formatId(&buf, 1700000000));
    try std.testing.expectEqualStrings("20240301-000000", try formatId(&buf, 1709251200)); // day after a leap day
}

test "a generated id has the shape of a timestamp" {
    var buf: [max_id_len]u8 = undefined;
    const stamp = try formatId(&buf, 1700000000);

    try std.testing.expectEqual(15, stamp.len);
    try std.testing.expectEqual('-', stamp[8]);
    for (stamp, 0..) |byte, i| {
        if (i == 8) continue;
        try std.testing.expect(std.ascii.isDigit(byte));
    }
}

test "setCheckedId rejects names that could escape the session directory" {
    var buf: [max_id_len]u8 = undefined;

    try std.testing.expectEqualStrings("20250131-120000", try setCheckedId(&buf, "20250131-120000"));
    try std.testing.expectEqualStrings("dev", try setCheckedId(&buf, "dev"));

    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, ""));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, ".."));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, "../x"));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, "a/b"));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, "a b"));
    // A name that does not fit, with room for its NUL, is refused rather than
    // cut short: the longest that fits is one byte less than the buffer.
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, "x" ** (max_id_len + 1)));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, "x" ** max_id_len));
    _ = try setCheckedId(&buf, "x" ** (max_id_len - 1));
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

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
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

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer resumed.deinit();

    try std.testing.expectEqualStrings(session.id(), resumed.id());
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

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
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

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
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

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "one.json",
        .data = "{\"version\":1,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"old prompt\"}," ++
            "{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    // Resuming keeps the saved prompt even though a newer one is available.
    var resumed = try Session.open(std.testing.io, tmp.dir, arena, "one", "/work");
    defer resumed.deinit();

    try resumed.appendSystemPrompt("new prompt");
    try std.testing.expectEqual(2, resumed.messages.items.len);
    try std.testing.expectEqualStrings("system", resumed.string(resumed.messages.items[0].role).?);
    try std.testing.expectEqualStrings("old prompt", resumed.string(resumed.messages.items[0].content).?);
    try std.testing.expectEqualStrings("user", resumed.string(resumed.messages.items[1].role).?);
}

test "appendSystemPrompt only adds the prompt to an empty session" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
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

test "the tools are written out with the schema as the JSON it is" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tools = [_]Definition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = "{\"type\":\"object\",\"required\":[\"path\"]}",
    }};

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.ensureTools(&tools);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.write(session.toolSet());

    // The schema is the JSON it is, not the quoted string it is stored as, and
    // the tool carries the kind the API wants.
    try std.testing.expectEqualStrings(
        "[{\"type\":\"function\",\"function\":{" ++
            "\"name\":\"read\",\"description\":\"Read a file.\"," ++
            "\"parameters\":{\"type\":\"object\",\"required\":[\"path\"]}}}]",
        out.written(),
    );
}

test "ensureTools stores the tools and only sets them once" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tools = [_]Definition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = "{}",
    }};

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer session.deinit();
    try session.ensureTools(&tools);
    try std.testing.expectEqual(1, session.tools.len);
    try std.testing.expectEqualStrings("read", session.string(session.tools[0].name).?);

    // The stored tools survive a save and resume.
    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqualStrings("read", resumed.string(resumed.tools[0].name).?);
    try std.testing.expectEqualStrings("Read a file.", resumed.string(resumed.tools[0].description).?);

    // A session that already has tools keeps them.
    const replaced = [_]Definition{.{
        .name = "bash",
        .description = "Run a command.",
        .parameters = "{}",
    }};
    var reopened = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer reopened.deinit();
    try reopened.ensureTools(&replaced);
    try std.testing.expectEqual(1, reopened.tools.len);
    try std.testing.expectEqualStrings("read", reopened.string(reopened.tools[0].name).?);
}

test "ensureTools gives tools to a session saved without any" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sessions saved before the tools were stored have no tools field.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "legacy.json",
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    const tools = [_]Definition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = "{}",
    }};

    var session = try Session.open(std.testing.io, tmp.dir, arena, "legacy", "/work");
    defer session.deinit();

    try std.testing.expectEqual(0, session.tools.len);
    try session.ensureTools(&tools);
    try std.testing.expectEqual(1, session.tools.len);
    try std.testing.expectEqualStrings("read", session.string(session.tools[0].name).?);
}

test "the token totals survive a save and resume" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
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

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.SessionNotFound,
        Session.open(std.testing.io, tmp.dir, arena, "nope", "/work"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "{" });
    try std.testing.expectError(
        error.CorruptSession,
        Session.open(std.testing.io, tmp.dir, arena, "bad", "/work"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "future.json", .data = "{\"version\":99}" });
    try std.testing.expectError(
        error.UnsupportedSessionVersion,
        Session.open(std.testing.io, tmp.dir, arena, "future", "/work"),
    );
}

test "a new session does not reuse an id whose file exists" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer first.deinit();
    try first.append(.{ .role = "user", .content = "keep me" });

    var second = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer second.deinit();
    try second.append(.{ .role = "user", .content = "and me" });

    try std.testing.expect(!std.mem.eql(u8, first.id(), second.id()));

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, first.id(), "/work");
    defer resumed.deinit();

    try std.testing.expectEqualStrings("keep me", resumed.string(resumed.messages.items[0].content).?);
}

test "the working directory is stored and restored on resume" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session started in one directory.
    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/home/user/project");
    defer session.deinit();
    try std.testing.expectEqualStrings("/home/user/project", session.cwd);
    try session.append(.{ .role = "user", .content = "hello" });

    // Resumed from somewhere else, it keeps the directory it was started in.
    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/somewhere/else");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("/home/user/project", resumed.cwd);
}

test "a session saved before the directory was recorded uses the run's own" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written before the field existed, with no `cwd`.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "old" ++ extension,
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, "old", "/now/here");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("/now/here", resumed.cwd);
}

test "a resumed session frees everything it read back" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file big enough that holding its bytes for the run would show: writing
    // and resuming it here runs under the testing allocator, which reports any
    // allocation left behind, so this passing means the file it read and the
    // parse of it were both freed by `deinit`.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "{\"version\":1,\"cwd\":\"/work\",\"messages\":[");
    for (0..2000) |i| {
        if (i > 0) try big.append(gpa, ',');
        try big.appendSlice(gpa, "{\"role\":\"user\",\"content\":\"a line of the conversation\"}");
    }
    try big.appendSlice(gpa, "]}");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big" ++ extension, .data = big.items });

    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, "big", "/work");
    defer resumed.deinit();
    try std.testing.expectEqual(2000, resumed.messages.items.len);
    try std.testing.expectEqualStrings("/work", resumed.cwd);
}

test "the id and file name read back from their fixed buffers" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session with a short name typed on the command line, shorter than the
    // generated timestamp, so the NUL that ends it is what sets its length.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dev" ++ extension,
        .data = "{\"version\":1,\"messages\":[]}",
    });
    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, "dev", "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("dev", resumed.id());
    try std.testing.expectEqualStrings("dev" ++ extension, resumed.name());

    // A new session gets a generated timestamp id of its own.
    var fresh = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer fresh.deinit();
    try std.testing.expectEqual(15, fresh.id().len);
    // The file name is that id with the extension.
    try std.testing.expect(std.mem.endsWith(u8, fresh.name(), extension));
    try std.testing.expectEqualStrings(
        fresh.id(),
        fresh.name()[0 .. fresh.name().len - extension.len],
    );
}
