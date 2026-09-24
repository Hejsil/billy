//! Sessions: the conversation persisted under the XDG data directory so that a
//! later run can pick up where the previous one stopped.
//!
//! Every session is one JSON file named after its id. The file is rewritten
//! after each message, so killing the process loses at most the message being
//! written. The system prompt and the tool definitions are stored with the
//! conversation and reused when the session is resumed, so a resume resends the
//! exact request of the run it continues and hits the prompt cache. A changed
//! prompt or tool therefore takes effect in new sessions only.
//!
//! A kill that lands while a tool runs can leave the last turn of a session
//! without the results of its tool calls, which the API rejects on the next
//! request. A resume completes that turn before anything else reads it, so a
//! session a kill left half written is still one that can continue.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const ulid = @import("ulid.zig");

const Session = @This();

/// Directory under the XDG data directory that holds billy's files.
const app_dir = "billy";

/// Subdirectory of the data directory that holds the sessions, so the session
/// files sit apart from the credentials billy keeps in the directory itself.
const sessions_dir = "sessions";

/// Extension of a session file.
const extension = ".json";

/// Most a session id may be. A generated one is the 26 characters of a ULID; the
/// room is for a name typed on the command line. The buffer holds this many bytes
/// and is written from the front, so there is always a byte left to end the id.
const max_id_len = 64;

/// Longest session file read back, so a damaged file cannot exhaust memory.
const max_session_bytes = 64 << 20;

/// The result given a tool call a kill left open. It restores a conversation the
/// API will take, and tells the model the call did not finish so it can try
/// again.
const interrupted_result = "Error: the tool call was interrupted before it produced a result.";

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
    /// Layout of a session file, bumped when its shape changes.
    version: u32 = 2,
    /// The conversation, oldest first.
    messages: []const llm.Message = &.{},
    /// Indices into `messages`, sorted, of the summaries a compaction produced.
    /// A request starts at the last of them, so everything before it, which the
    /// summary stands in for, is left out. The prompt that asked for the
    /// compaction is the message just before its summary; it is stored so the
    /// two read as a question and its answer, and shows in the transcript as one
    /// line along with the summary.
    compactions: []const usize = &.{},
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

    const default = Stored{};
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
/// string with no length kept beside it. A generated id is a ULID; a resume
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

/// Indices into `messages`, sorted and without repeats, of the summaries a
/// compaction produced. Keeping them as a list rather than a flag on every
/// message costs four bytes per compaction instead of a byte on every message,
/// and is what a request and a transcript read to know where the conversation
/// now starts.
compactions: std.ArrayList(u32) = .empty,

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
    // place. Both buffers are zero-filled, so both end in NUL, which is what
    // says where an id ends.
    if (resume_id) |given| {
        _ = try setCheckedId(&session.id_buf, given);
    } else {
        ulid.generate(io, session.id_buf[0..ulid.length]);
    }
    _ = try std.fmt.bufPrint(&session.name_buf, "{s}{s}", .{ session.id(), extension });

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
    session.compactions.deinit(session.gpa);
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
/// A request carries the system prompt and then only what follows the summary of
/// the latest compaction. A compacted session keeps its whole history, for the
/// transcript and a resume, but the messages a compaction stands in for are not
/// sent to the model.
///
/// The field order and the fields left out are the ones `llm.Message` produces,
/// so the body is the same either way.
pub const Conversation = struct {
    session: *const Session,

    pub fn jsonStringify(self: Conversation, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        for (session.messages.items[0..session.leadCount()]) |message| {
            try writeMessage(session, json, message);
        }
        for (session.messages.items[session.sendStart()..]) |message| {
            try writeMessage(session, json, message);
        }
        try json.endArray();
    }
};

/// Writes one message as the `messages` array of a request holds it, with every
/// string read out of the pool.
fn writeMessage(session: *const Session, json: anytype, message: Message) !void {
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

/// The conversation as a request carries it, for passing to a client without
/// resolving it first. The returned value borrows the session.
pub fn conversation(session: *const Session) Conversation {
    return .{ .session = session };
}

/// The first message a compaction leaves out of a request: the summary the last
/// compaction produced, or zero for a conversation that has never been
/// compacted. The list is sorted, so the last index is the latest compaction.
///
/// The session keeps the messages a request skips, so a transcript still shows
/// the whole history and a resume reads all of it back; only what is sent to the
/// model is cut down.
pub fn sentFrom(session: *const Session) usize {
    if (session.compactions.items.len == 0) return 0;
    return session.compactions.items[session.compactions.items.len - 1];
}

/// Whether the message at `index` is a summary a compaction produced. A request
/// starts at the latest such message, and a transcript shows it as the single
/// line that stands in for the compaction. False for an index past the
/// conversation, so a caller can ask about the message after the last one.
pub fn isCompaction(session: *const Session, index: usize) bool {
    if (index >= session.messages.items.len) return false;
    // The list holds one index per compaction, so a scan of it is short.
    const target: u32 = @intCast(index);
    return std.mem.indexOfScalar(u32, session.compactions.items, target) != null;
}

/// How many messages lead every request: the system prompt, which is sent even
/// when a compaction skips past it. Zero for a session that has none.
pub fn leadCount(session: *const Session) usize {
    var count: usize = 0;
    while (count < session.messages.items.len and
        std.mem.eql(u8, session.roleOf(session.messages.items[count]), "system")) count += 1;
    return count;
}

/// Where the messages a request carries after the system prompt begin: the
/// summary of the latest compaction, or the first message after the system
/// prompt when there is none.
pub fn sendStart(session: *const Session) usize {
    return @max(session.sentFrom(), session.leadCount());
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

/// The messages a request carries, resolved out of the pool: the system prompt
/// and then everything from the latest compaction on, the same set `conversation`
/// writes. `allocator` owns the result, as `resolvedMessages` does. A compaction
/// request is sent this way, so it summarizes exactly what the model has been
/// given.
pub fn resolveSend(session: *const Session, allocator: std.mem.Allocator) ![]const llm.Message {
    const lead = session.leadCount();
    const start = session.sendStart();
    const messages = try allocator.alloc(llm.Message, lead + session.messages.items.len - start);
    var out: usize = 0;
    for (session.messages.items[0..lead]) |message| {
        messages[out] = try message.resolve(session, allocator);
        out += 1;
    }
    for (session.messages.items[start..]) |message| {
        messages[out] = try message.resolve(session, allocator);
        out += 1;
    }
    return messages;
}

/// Adds a message to the conversation and writes the session out, so the
/// next run sees it even if this one is killed.
///
/// This is what brings a new session into being: opening one only reserves its
/// id, and the id, the system prompt, the tools and the conversation all reach
/// the file together with the first message added.
pub fn append(session: *Session, message: llm.Message) !void {
    try session.appendMessage(message);
    try session.save();
}

/// Adds a compaction to the conversation: the prompt that asked for it and the
/// summary it produced. The index of the summary is recorded in `compactions`,
/// so a request from then on starts at it and carries neither the prompt nor
/// anything the summary stands in for, while the session keeps every message it
/// always had.
///
/// The prompt is stored so the pair reads as a question and its answer, and so
/// the transcript can show the two as one line; it is never sent to the model.
/// The summary is a user message, so the model reads it as context handed to it
/// rather than as something it said. The messages and the index are written out
/// together, so the session file is never left holding half of a compaction.
pub fn appendCompaction(session: *Session, prompt: []const u8, summary: []const u8) !void {
    try session.appendMessage(.{ .role = "user", .content = prompt });
    const summary_index: u32 = @intCast(session.messages.items.len);
    try session.appendMessage(.{ .role = "user", .content = summary });
    try session.compactions.append(session.gpa, summary_index);
    try session.save();
}

/// Appends one message to the conversation without writing the session out.
/// The parts are interned into the pool.
fn appendMessage(session: *Session, message: llm.Message) !void {
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
///
/// The prompt is held in memory and reaches the file with the session's first
/// message, like the tools. A new session is therefore not written out until it
/// is first asked something, so a run that is started and left alone leaves no
/// session file behind.
pub fn appendSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    if (session.messages.items.len != 0) return;
    try session.appendMessage(.{ .role = "system", .content = system_prompt });
}

/// Records the tool definitions to send with every request, unless the session
/// already has some. A resumed session carries the tools it was saved with,
/// which are kept so the request matches the earlier run and hits the prompt
/// cache; a new session, or one saved before the tools were stored, gets the
/// current definitions instead.
///
/// Like the system prompt, the set is held in memory and written out with the
/// session's first message.
pub fn ensureTools(session: *Session, definitions: []const Definition) !void {
    if (session.tools.len != 0) return;
    // The strings are interned into the pool, so the set costs one array and
    // frees with the pool. Nothing is copied per string and there is no parsed
    // document to keep alive: the arguments schema is stored as the JSON text it
    // is sent as.
    const tools = try session.gpa.alloc(Tool, definitions.len);
    errdefer session.gpa.free(tools);
    for (definitions, tools) |definition, *tool| {
        tool.* = .{
            .name = try session.internString(definition.name),
            .description = try session.internString(definition.description),
            .parameters = try session.internString(definition.parameters),
        };
    }
    session.tools = tools;
}

/// Adds a request's tokens and cost to the session totals and remembers how
/// full the context window is. The totals reach the file with the next save,
/// which follows every message.
///
/// `cost` is priced by the caller, which knows the rates that applied when
/// the request was made; the session only accumulates it, so a session that
/// spans a rate change is billed at the rates it actually ran under.
pub fn recordUsage(session: *Session, usage: llm.Usage, cost: f64) void {
    session.recordCost(usage, cost);
    session.context_tokens = usage.total_tokens;
}

/// Adds a request's tokens and cost to the session totals without moving the
/// context gauge. This is for a request whose conversation is not the one the
/// session now holds, such as the summary a compaction was made from: the
/// request was billed, but its size says nothing about how full the context
/// window is going forward.
pub fn recordCost(session: *Session, usage: llm.Usage, cost: f64) void {
    session.usage = session.usage.plus(usage);
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
    try json.write(Stored.default.version);
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
    // The indices of the compaction summaries, sorted, so a resume knows where
    // the conversation a request carries begins.
    try json.objectField("compactions");
    try json.write(session.compactions.items);
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

    if (stored.version > Stored.default.version)
        return error.UnsupportedSessionVersion;

    // The stored messages are kept as they are, system prompt included, so
    // resuming reuses exactly what the earlier run sent.
    for (stored.messages) |message| {
        try session.appendMessage(message);
    }

    // The compaction indices are read back against the messages just loaded, so
    // the sorted list a request and a transcript read is sound even if the file
    // was written by hand: one past the end is dropped rather than trusted, the
    // list is sorted, and a repeat is collapsed to the one copy of it.
    for (stored.compactions) |index| {
        if (index >= session.messages.items.len) continue;
        try session.compactions.append(session.gpa, std.math.cast(u32, index) orelse continue);
    }
    const compactions = session.compactions.items;
    std.mem.sort(u32, compactions, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (compactions) |index| {
        if (kept > 0 and compactions[kept - 1] == index) continue;
        compactions[kept] = index;
        kept += 1;
    }
    session.compactions.shrinkRetainingCapacity(kept);

    // A run killed while a tool ran can leave the last turn without the results
    // of its calls, which the API rejects on the next request. The turn is
    // completed before anything reads the conversation.
    try session.repairTail();

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

/// Completes the last turn of a conversation a kill left half written.
///
/// A run killed while a tool ran can stop after the assistant message that asked
/// for the calls was written and before the results were, so the last turn of a
/// resumed session can hold calls with no message answering them, which the API
/// rejects: every turn before it finished and is left alone, and only the calls
/// the kill left open are answered here, each by a message saying the call was
/// interrupted so the model can carry on.
fn repairTail(session: *Session) !void {
    // The last message that asks for tools is where a kill leaves off. A
    // conversation with none, or whose last such message is answered in full, is
    // one the earlier run finished.
    const tail = session.lastCall() orelse return;
    const calls = session.callCount(session.messages.items[tail]);

    // The results that follow the message, which is where they were written.
    var answered: usize = 0;
    while (answered < calls and tail + 1 + answered < session.messages.items.len and
        std.mem.eql(u8, session.roleOf(session.messages.items[tail + 1 + answered]), "tool"))
        answered += 1;
    if (answered >= calls) return;

    // The calls with no result are answered right after the results the file
    // holds, in the order the calls were made, so the assistant message is
    // followed by one result per call.
    //
    // The id that names each result is the one the call already carries, taken
    // as its index into the pool rather than as the text it names: interning
    // the other strings grows the pool, which would leave a copy of that text
    // dangling, while an index survives the pool moving.
    const at = tail + 1 + answered;
    const missing = calls - answered;
    var k: usize = answered;
    while (k < calls) : (k += 1) {
        const call_id = session.messages.items[tail].tool_calls.resolve(session)[k].id;
        const result: Message = .{
            .role = try session.internString("tool"),
            .content = try session.internString(interrupted_result),
            .tool_call_id = call_id,
        };
        try session.messages.insert(session.gpa, at + (k - answered), result);
    }

    // A compaction records where its summary sits by index, and the answers push
    // every message from `at` on along, so a summary at or past `at` moves with
    // them. Only a file written by hand holds a summary behind an unfinished
    // turn; it is moved so that such a file still reads soundly.
    for (session.compactions.items) |*index| {
        if (index.* >= at) index.* += @intCast(missing);
    }
}

/// The index of the last message that asks for tools, or null when the
/// conversation asks for none.
fn lastCall(session: *const Session) ?usize {
    var i = session.messages.items.len;
    while (i > 0) {
        i -= 1;
        const message = session.messages.items[i];
        if (std.mem.eql(u8, session.roleOf(message), "assistant") and session.callCount(message) > 0)
            return i;
    }
    return null;
}

/// Interns `text` into the pool and returns its index, or `.none` for null.
///
/// The pool holds text, and text is what a request and the session file carry
/// as a JSON string. A tool's output, what the user typed and a file read back
/// are arbitrary bytes, though, and Zig writes a byte slice that is not valid
/// UTF-8 as an array of numbers, which the API rejects. The text is therefore
/// written through `fmtUtf8`, which passes well-formed text through unchanged
/// and repairs anything ill-formed, so every string the pool holds, and
/// everything written from it, is text a request and a session file can carry.
fn internString(session: *Session, text: ?[]const u8) !StringIndex {
    const value = text orelse return .none;

    // The candidate is put in the pool before it is looked up, since a key has
    // to name a string the pool already holds. A duplicate is rolled back as
    // soon as the lookup finds the copy that was there already. The text is
    // written straight into the pool, so nothing else is allocated for it.
    const start: u32 = @intCast(session.strings.items.len);
    try session.strings.print(session.gpa, "{f}", .{std.unicode.fmtUtf8(value)});
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
pub fn dataDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        // The specification says a relative path must be ignored.
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(gpa, &.{ xdg, app_dir });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", app_dir });
}

/// The directory holding the sessions: the `sessions` subdirectory of `dataDir`,
/// so that the session files sit apart from what else billy keeps.
pub fn defaultDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const data_dir = try dataDir(gpa, environ);
    defer gpa.free(data_dir);

    return std.fs.path.join(gpa, &.{ data_dir, sessions_dir });
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

test "a new session is given a ULID, and nothing is written yet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, std.testing.allocator, null, "/work");
    defer session.deinit();

    try std.testing.expect(ulid.isId(session.id()));
    // Opening a new session records an id and nothing else, so the first write
    // is the first message. Nothing is named after the id until then.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));
}

test "a new session is written out by its first message" {
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

    // Setting a session up -- its prompt and its tools -- is held in memory, so
    // a run that is started and left alone leaves nothing behind. This is what
    // keeps an untouched `billy` from littering the sessions directory.
    try session.appendSystemPrompt("be terse");
    try session.ensureTools(&tools);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));

    // The first message is what brings the session into being, and everything
    // set up before it lands in the file with it.
    try session.append(.{ .role = "user", .content = "hello" });

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqual(2, resumed.messages.items.len);
    try std.testing.expectEqualStrings("system", resumed.roleOf(resumed.messages.items[0]));
    try std.testing.expectEqualStrings("be terse", resumed.contentOf(resumed.messages.items[0]).?);
    try std.testing.expectEqualStrings("user", resumed.roleOf(resumed.messages.items[1]));
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[1]).?);
}

test "ids made one after another differ" {
    var first: [ulid.length]u8 = undefined;
    var second: [ulid.length]u8 = undefined;
    ulid.generate(std.testing.io, &first);
    ulid.generate(std.testing.io, &second);

    // Two sessions made one after the other never share an id. The clock alone
    // cannot promise that, which is what the random bits are for; that the
    // timestamp makes them sort is `ulid.zig`'s to prove.
    try std.testing.expect(ulid.isId(&first));
    try std.testing.expect(ulid.isId(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "setCheckedId rejects names that could escape the session directory" {
    var buf: [max_id_len]u8 = undefined;

    // A name typed on the command line, and an id this module would make.
    try std.testing.expectEqualStrings("dev", try setCheckedId(&buf, "dev"));
    try std.testing.expectEqualStrings("20250131-120000", try setCheckedId(&buf, "20250131-120000"));
    try std.testing.expectEqualStrings(
        "01HF7YAT000000000000000000",
        try setCheckedId(&buf, "01HF7YAT000000000000000000"),
    );

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

test "a resume answers a tool call a killed run left open" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
    defer session.deinit();

    try session.append(.{ .role = "user", .content = "hello" });
    // The assistant asked for a tool, and the run was killed before its result
    // was written, so the session ends on the call with no message answering it.
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "bash", .arguments = "{}" },
    }} });

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, session.id(), "/work");
    defer resumed.deinit();

    // The call now has an answer, so the request the session builds is one the
    // API takes: the assistant message is followed by the result of its call.
    const messages = try resumed.resolvedMessages(allocator);
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("assistant", messages[1].role);
    try std.testing.expectEqualStrings("tool", messages[2].role);
    try std.testing.expectEqualStrings("call_1", messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings(interrupted_result, messages[2].content.?);
}

test "a resume answers every call a kill left open, in the order made" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
    defer session.deinit();

    try session.append(.{ .role = "user", .content = "go" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{}" } },
    } });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "the first result" });
    // Killed before the second result, and the user typed on afterwards, so the
    // message that follows the run is not a result at all.
    try session.append(.{ .role = "user", .content = "still there?" });

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, session.id(), "/work");
    defer resumed.deinit();

    // user, the assistant message, its two results, then the user message: the
    // result the file held stays with its call, and the call it lost is answered
    // in the place it was made rather than after the user message.
    const messages = try resumed.resolvedMessages(allocator);
    try std.testing.expectEqual(@as(usize, 5), messages.len);
    try std.testing.expectEqualStrings("tool", messages[2].role);
    try std.testing.expectEqualStrings("call_1", messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("the first result", messages[2].content.?);
    try std.testing.expectEqualStrings("tool", messages[3].role);
    try std.testing.expectEqualStrings("call_2", messages[3].tool_call_id.?);
    try std.testing.expectEqualStrings(interrupted_result, messages[3].content.?);
    try std.testing.expectEqualStrings("user", messages[4].role);
    try std.testing.expectEqualStrings("still there?", messages[4].content.?);
}

test "a resume leaves a finished conversation alone" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
    defer session.deinit();

    // A run that finished leaves every call answered and its compaction in
    // place, which is what the repair must not disturb.
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "go" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{}" } },
    } });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "one" });
    try session.append(.{ .role = "tool", .tool_call_id = "call_2", .content = "two" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = "assistant", .content = "done" });

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, session.id(), "/work");
    defer resumed.deinit();

    try std.testing.expectEqual(session.messages.items.len, resumed.messages.items.len);
    try std.testing.expectEqual(session.sentFrom(), resumed.sentFrom());
    try std.testing.expect(resumed.isCompaction(resumed.sentFrom()));
}

test "a repair moves a compaction that sits behind the turn it completes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, allocator, null, "/work");
    defer session.deinit();

    // A file that holds a compaction right behind a call with no result, as one
    // written by hand can: the answer the repair inserts lands in front of both
    // the prompt and the summary.
    try session.append(.{ .role = "user", .content = "go" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.appendCompaction("summarize this", "the summary");

    var resumed = try Session.open(std.testing.io, tmp.dir, allocator, session.id(), "/work");
    defer resumed.deinit();

    // user, the assistant message, its answer, then the prompt and the summary:
    // the summary the file recorded at index 3 moves to 4 with the message it
    // names, so a request still starts at the summary rather than at the prompt.
    try std.testing.expectEqual(@as(usize, 5), resumed.messages.items.len);
    try std.testing.expectEqual(@as(usize, 4), resumed.sentFrom());
    try std.testing.expect(resumed.isCompaction(resumed.sentFrom()));
    try std.testing.expectEqualStrings("the summary", resumed.contentOf(resumed.messages.items[4]).?);
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

test "a string that is not valid UTF-8 is repaired on the way into the pool" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer session.deinit();

    // A command's output and a file read back are arbitrary bytes, so a result
    // holds a stray continuation byte and a cut-off sequence, neither of which
    // is UTF-8.
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "a\x80b\xffc" });

    // The pool holds text, so a request writes the content as a string. Left as
    // bytes, Zig would write it as an array of numbers the API rejects.
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try json.write(session.conversation());
    try std.testing.expectEqualStrings(
        "[{\"role\":\"tool\",\"content\":\"a\u{FFFD}b\u{FFFD}c\",\"tool_call_id\":\"call_1\"}]",
        out.written(),
    );

    // The repaired text is what the session keeps, so a resume reads it back
    // the same rather than the bytes that could not be sent.
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", session.contentOf(session.messages.items[0]).?);
}

test "a message a session read back with bytes that are not UTF-8 is repaired" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session file written before a result was repaired holds the content as
    // the array of numbers Zig writes for bytes that are not UTF-8, which is
    // how the bytes "a\xffb" were stored.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bytes.json",
        .data = "{\"version\":2,\"messages\":[{\"role\":\"tool\"," ++
            "\"content\":[97,255,98],\"tool_call_id\":\"call_1\"}]}",
    });

    var session = try Session.open(std.testing.io, tmp.dir, arena, "bytes", "/work");
    defer session.deinit();

    try std.testing.expectEqualStrings("a\u{FFFD}b", session.contentOf(session.messages.items[0]).?);

    // Saving it back writes the content as a string, so the bytes are gone for
    // good and the file is one a later resume reads as text.
    try session.save();
    const text = try tmp.dir.readFileAlloc(std.testing.io, "bytes.json", arena, .limited(1 << 16));
    defer arena.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[97,255,98]") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"content\":\"a\u{FFFD}b\"") != null);
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

test "a compaction is appended and a request starts at its summary" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer session.deinit();

    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "one" });
    try session.append(.{ .role = "assistant", .content = "first answer" });
    // Nothing compacted yet, so a request carries the whole conversation.
    try std.testing.expectEqual(0, session.sentFrom());

    // A compaction adds the prompt and the summary to the end, keeping every
    // message it stands in for. The summary is a user message, so the model
    // reads it as context given to it.
    try session.appendCompaction("summarize this", "what happened so far");
    try std.testing.expectEqual(5, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[3]));
    try std.testing.expectEqualStrings("summarize this", session.contentOf(session.messages.items[3]).?);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[4]));
    try std.testing.expectEqualStrings("what happened so far", session.contentOf(session.messages.items[4]).?);

    // A request now starts at the summary, skipping the prompt and everything
    // the summary stands in for.
    try std.testing.expectEqual(4, session.sentFrom());
    try std.testing.expect(session.isCompaction(4));
    // The prompt that asked for the compaction is not itself a summary.
    try std.testing.expect(!session.isCompaction(3));
    try std.testing.expect(!session.isCompaction(2));
    // An index past the conversation is never a compaction.
    try std.testing.expect(!session.isCompaction(99));

    // The messages after the compaction are sent in full.
    try session.append(.{ .role = "user", .content = "next" });
    try std.testing.expectEqual(4, session.sentFrom());
}

test "a compaction survives a save and resume" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, arena, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "one" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = "user", .content = "next" });

    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer resumed.deinit();

    // Everything comes back, and the request still starts at the summary.
    try std.testing.expectEqual(5, resumed.messages.items.len);
    try std.testing.expectEqual(3, resumed.sentFrom());
    try std.testing.expectEqualStrings("the summary", resumed.string(resumed.messages.items[3].content).?);
    try std.testing.expectEqualStrings("next", resumed.string(resumed.messages.items[4].content).?);
}

test "the compaction list is sorted and cleaned when a session is read" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written by hand, with the indices out of order, a repeat, and one
    // past the end of the conversation.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "odd.json",
        .data = "{\"version\":2,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"s\"}," ++
            "{\"role\":\"user\",\"content\":\"one\"}," ++
            "{\"role\":\"user\",\"content\":\"summary\"}," ++
            "{\"role\":\"user\",\"content\":\"two\"}]," ++
            "\"compactions\":[2,0,2,99]}",
    });

    var session = try Session.open(std.testing.io, tmp.dir, arena, "odd", "/work");
    defer session.deinit();

    // Indices past the end are dropped, the rest are sorted, and the repeat is
    // collapsed, so the list is the one sorted copy the rest of the session
    // expects.
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, session.compactions.items);
    // The latest is therefore the summary, and a request starts there.
    try std.testing.expectEqual(2, session.sentFrom());
    try std.testing.expect(session.isCompaction(2));
}

test "the messages a request carries start at the latest compaction" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "s" });
    try session.append(.{ .role = "user", .content = "old" });
    // Two compactions: a request starts at the later summary, not the earlier.
    try session.appendCompaction("p1", "summary one");
    try session.append(.{ .role = "user", .content = "middle" });
    try session.appendCompaction("p2", "summary two");
    try session.append(.{ .role = "user", .content = "latest" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try json.write(session.conversation());

    // The system prompt, then the latest summary and the prompt after it: the
    // first compaction and everything before it is left out.
    try std.testing.expectEqualStrings(
        "[{\"role\":\"system\",\"content\":\"s\"}," ++
            "{\"role\":\"user\",\"content\":\"summary two\"}," ++
            "{\"role\":\"user\",\"content\":\"latest\"}]",
        out.written(),
    );
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

    // The tools are held in memory until the session's first message, which is
    // what writes the session out.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, session.name(), .{}),
    );
    try session.append(.{ .role = "user", .content = "hi" });

    // The stored tools survive a save and resume.
    var resumed = try Session.open(std.testing.io, tmp.dir, arena, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqualStrings("read", resumed.string(resumed.tools[0].name).?);
    try std.testing.expectEqualStrings("Read a file.", resumed.string(resumed.tools[0].description).?);

    // A session that already has tools keeps them, rather than taking a new set.
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

test "a session saved without tools loads with none" {
    const arena = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sessions saved before the tools were stored have no tools field.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "legacy.json",
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var session = try Session.open(std.testing.io, tmp.dir, arena, "legacy", "/work");
    defer session.deinit();
    try std.testing.expectEqual(0, session.tools.len);
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

    // A session with a short name typed on the command line, shorter than a
    // generated id, so the NUL that ends it is what sets its length.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dev" ++ extension,
        .data = "{\"version\":1,\"messages\":[]}",
    });
    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, "dev", "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("dev", resumed.id());
    try std.testing.expectEqualStrings("dev" ++ extension, resumed.name());

    // A new session gets a generated ULID of its own.
    var fresh = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer fresh.deinit();
    try std.testing.expectEqual(ulid.length, fresh.id().len);
    try std.testing.expect(ulid.isId(fresh.id()));
    // The file name is that id with the extension.
    try std.testing.expect(std.mem.endsWith(u8, fresh.name(), extension));
    try std.testing.expectEqualStrings(
        fresh.id(),
        fresh.name()[0 .. fresh.name().len - extension.len],
    );
}
