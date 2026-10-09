//! Sessions: the conversation persisted under the XDG data directory so that a
//! later run can pick up where the previous one stopped.
//!
//! Every session is one JSON file named after its id. The file is rewritten
//! after each message, so killing the process loses at most the message being
//! written. The system prompt and the tool definitions are kept with the
//! session, apart from the conversation, and reused when it is resumed, so a
//! resume resends the exact request of the run it continues and hits the prompt
//! cache. They are refreshed when the conversation is compacted, which is the
//! one time replacing the front of a request costs no cache that was not already
//! being thrown away; see `Agent.refresh`.
//!
//! A session also carries a title, a short name for it that a frontend lists it
//! by. It is written first in the file, so a listing reads it without reading the
//! conversation, and it is optional, so a session saved before titles were kept
//! simply has none (`list`).
//!
//! A kill that lands while a tool runs can leave the last turn of a session
//! without the results of its tool calls, which the API rejects on the next
//! request. A resume completes that turn before anything else reads it, so a
//! session a kill left half written is still one that can continue.

const std = @import("std");
const llm = @import("llm.zig");
const ulid = @import("ulid.zig");
const xdg = @import("xdg.zig");
const agent = @import("Agent.zig");
const Pool = @import("Pool.zig");

const Session = @This();

/// Subdirectory of the data directory that holds the sessions, so the session
/// files sit apart from the credentials billy keeps in the directory itself.
const sessions_dir = "sessions";

/// Extension of a session file.
const extension = ".json";

/// Most a session id may be. A generated one is the 26 characters of a ULID; the
/// room is for a name typed on the command line. The buffer holds this many bytes
/// and is written from the front, so there is always a byte left to end the id.
const max_id_len = 64;

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
    /// Layout of a session file, bumped when its shape changes. Version 3 keeps
    /// the system prompt in `system_prompt` rather than as the first message;
    /// version 1 and 2 files hold it in `messages` and are migrated on load.
    version: u32 = 3,
    /// A short name for the session, for a frontend to show in a list. Null for
    /// a session that has not been named, which is one that has not been asked
    /// anything yet, and one saved before titles were kept. It is written first,
    /// right after `version`, so a listing can read it from the front of the file
    /// without reading the conversation (`list`).
    title: ?[]const u8 = null,
    /// The system prompt sent at the front of every request, or null for a
    /// session that has none. It is kept apart from `messages`, which is the
    /// conversation alone, so that the prompt and the tools can be replaced at a
    /// compaction without rewriting the conversation the model has seen.
    system_prompt: ?[]const u8 = null,
    /// The mode the session runs in, which fixes its prompt and its tools. A file
    /// saved before modes existed has none, and reads back as general.
    mode: agent.Mode = .general,
    /// The conversation, oldest first.
    messages: []const llm.Message = &.{},
    /// Indices into `messages`, sorted, of the summaries a compaction produced.
    /// A request starts at the last of them, so everything before it, which the
    /// summary stands in for, is left out. The prompt that asked for the
    /// compaction is the message just before its summary; it is stored so the
    /// two read as a question and its answer, and shows in the transcript as one
    /// line along with the summary.
    compactions: []const u32 = &.{},
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
    cwd: ?[]const u8 = null,

    const default = Stored{};
};

const StringIndex = Pool.Index;

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
            .id = session.pool.get(tool_call.id) orelse "",
            .type = session.pool.get(tool_call.type) orelse "",
            .function = .{
                .name = session.pool.get(tool_call.function.name) orelse "",
                .arguments = session.pool.get(tool_call.function.arguments) orelse "",
            },
        };
    }
};

/// An llm.Message as stored in a session.
pub const Message = struct {
    role: llm.Role,
    content: StringIndex = .none,
    tool_call_id: StringIndex = .none,
    /// What the model thought before this message, for a provider that reports
    /// it and wants it sent back. `.none` for a model that reports none.
    reasoning: StringIndex = .none,
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
            .role = message.role,
            .content = session.pool.get(message.content),
            .tool_call_id = session.pool.get(message.tool_call_id),
            .reasoning_content = session.pool.get(message.reasoning),
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

io: std.Io,

/// Directory holding the session files. Owned by the caller.
dir: std.Io.Dir,

/// Owns the conversation and everything a resume read back, all freed by
/// `deinit`.
gpa: std.mem.Allocator,

/// The id, in a fixed buffer written once from the front. The buffer is
/// zero-filled, so what is written ends in NUL and the id is a NUL-terminated
/// string with no length kept beside it. A generated id is a ULID; a resume
/// takes one from the command line.
id_buf: [max_id_len]u8 = @splat(0),

/// The id with the file extension: the name of the session file, in a fixed
/// buffer beside the id and zero-filled past the name for the same reason.
name_buf: [max_id_len + extension.len]u8 = @splat(0),

/// All string data, one NUL-terminated copy per distinct string. Two equal
/// strings share an index, so a conversation that repeats its roles, its tool
/// names and what a repeated call returned pays for each of them once.
pool: Pool = .{},

tool_calls: std.ArrayList(ToolCall) = .empty,

/// The conversation, oldest first. The system prompt is not part of it: it is
/// sent at the front of every request, from `system_prompt`, and kept out of the
/// conversation so the two can be replaced apart from each other.
messages: std.ArrayList(Message) = .empty,

/// The system prompt sent at the front of every request, interned in the pool
/// like every other string. `.none` for a session that has none.
system_prompt: StringIndex = .none,

/// A short name for the session, for a frontend to show in a list, interned in
/// the pool like every other string. `.none` until the session is named, which
/// happens on the first turn.
title_index: StringIndex = .none,

/// What the session may do and what its prompt says. Kept so a resume keeps the
/// mode it started in rather than the default.
mode: agent.Mode = .general,

/// Indices into `messages` of the summaries a compaction produced
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
/// is used instead.
interned_cwd: StringIndex = .none,

/// Opens the session called `resume_id`, or starts a new one when it is null.
///
/// `cwd` is the directory billy is running in. A new session records it; a
/// resumed one keeps the directory it was saved with, so a session continues
/// where it was started.
///
/// Fails with `error.SessionNotFound` when the session is missing, and with
/// `error.InvalidSessionId` when `resume_id` is not a usable name.
pub fn open(
    io: std.Io,
    dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    resume_id: ?[]const u8,
    arg_cwd: []const u8,
) !Session {
    // A resume that fails part way leaves what it had read behind, since the
    // caller only gets the session on the way out.
    var session = try named(io, dir, gpa, resume_id, arg_cwd);
    errdefer session.deinit();
    if (resume_id != null) try session.load();
    return session;
}

/// Starts a session named `id`, which is not read from disk even if a file of
/// that name is there.
///
/// This is for an id handed out before the session exists: the id is what names
/// it, and nothing is read because there is nothing to read. Nothing is written
/// either, so the session comes into being with its first message; a run that
/// is started and left alone leaves no file behind.
pub fn create(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, named_id: []const u8, arg_cwd: []const u8) !Session {
    return named(io, dir, gpa, named_id, arg_cwd);
}

/// A session named `named_id`, or one given a fresh id when it is null, with
/// nothing read from disk and nothing written.
fn named(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, named_id: ?[]const u8, arg_cwd: []const u8) !Session {
    var session: Session = .{ .io = io, .dir = dir, .gpa = gpa };
    errdefer session.deinit();

    // The id is written into its buffer; the file name is the id with the
    // extension, built from it once so every read and write goes through one
    // place. Both buffers are zero-filled, so both end in NUL, which is what
    // says where an id ends.
    if (named_id) |given| {
        _ = try setCheckedId(&session.id_buf, given);
    } else {
        ulid.generate(io, session.id_buf[0..ulid.length]);
    }
    _ = try std.fmt.bufPrint(&session.name_buf, "{s}{s}", .{ session.id(), extension });

    // The session owns its directory rather than pointing into the caller's
    // memory, which it may outlive.
    session.interned_cwd = try session.pool.intern(session.gpa, arg_cwd);
    return session;
}

pub fn deinit(session: *Session) void {
    session.pool.deinit(session.gpa);
    session.tool_calls.deinit(session.gpa);
    session.messages.deinit(session.gpa);
    session.compactions.deinit(session.gpa);
    session.gpa.free(session.tools);
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

pub fn cwd(session: *const Session) []const u8 {
    return session.pool.get(session.interned_cwd) orelse "";
}

/// The conversation as a completion request carries it: the `messages` array of
/// a request body, written straight out of the pool.
///
/// A request takes one of these rather than a resolved copy, so sending what a
/// session holds allocates nothing: the strings are read where they were stored.
/// It carries the system prompt and then only what follows the latest summary,
/// so the messages a compaction stands in for are not sent. The field order and
/// the fields left out are `llm.Message`'s, so the body is the same either way.
pub const Conversation = struct {
    session: *const Session,
    /// Messages written after the conversation, for a request that carries one
    /// turn more than the session holds: the prompt that asks for a summary, or
    /// for a title. They are read straight out of the caller's own memory, so
    /// adding one message to a request costs no more than sending the
    /// conversation itself; a copy of the conversation is never built. They are
    /// not part of the session and are not kept anywhere.
    extra: []const llm.Message = &.{},

    pub fn jsonStringify(self: Conversation, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        // The system prompt leads every request, and is the one message that is
        // not part of the conversation.
        if (session.pool.get(session.system_prompt)) |prompt| {
            try json.beginObject();
            try json.objectField("role");
            try json.write("system");
            try json.objectField("content");
            try json.write(prompt);
            try json.endObject();
        }
        for (session.messages.items[session.sentFrom()..]) |message| {
            try writeMessage(session, json, message);
        }
        // The extra messages come last, as the newest of the request. Each is an
        // `llm.Message`, written the way the client writes a resolved
        // conversation, so the bytes are the ones the resolved path would write
        // -- which is what keeps a request carrying an extra message
        // cache-compatible with one that does not.
        for (self.extra) |message| try json.write(message);
        try json.endArray();
    }
};

/// Writes one message as the `messages` array of a request holds it, with every
/// string read out of the pool.
///
/// The field order is `llm.Message`'s, so a request built from the session is
/// the bytes the resolved conversation would send. The session file uses the
/// same function, so the stored form and the sent form cannot drift, and a
/// message never carries both a call and its own id, so the single order serves
/// both.
fn writeMessage(session: *const Session, json: anytype, message: Message) !void {
    try json.beginObject();
    try json.objectField("role");
    // The name the API knows the role by, so a file reads as it always did.
    try json.write(message.role.name());

    if (session.pool.get(message.content)) |content| {
        try json.objectField("content");
        try json.write(content);
    }

    const calls = message.tool_calls.resolve(session);
    if (calls.len > 0) {
        try json.objectField("tool_calls");
        try json.beginArray();
        for (calls) |call| try json.write(call.resolve(session));
        try json.endArray();
    }

    if (session.pool.get(message.tool_call_id)) |tool_call_id| {
        try json.objectField("tool_call_id");
        try json.write(tool_call_id);
    }

    // Sent back so a provider that concatenates its own reasoning into the
    // context on the next request has it to send. Written last, after every
    // other field, so a message that carries none is byte for byte the message
    // it was before this field existed and a cached prefix still matches.
    if (session.pool.get(message.reasoning)) |reasoning| {
        try json.objectField("reasoning_content");
        try json.write(reasoning);
    }
    try json.endObject();
}

/// The conversation as a request carries it, for passing to a client without
/// resolving it first. `extra` is written after the conversation, for a request
/// that asks the model one thing more than the session holds; see
/// `Conversation.extra`. The returned value borrows the session and `extra`.
pub fn conversation(session: *const Session, extra: []const llm.Message) Conversation {
    return .{ .session = session, .extra = extra };
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

/// Whether the session has a system prompt of its own, which every request
/// carries at its front. False for a session saved before the prompt was kept
/// apart from the conversation and for one opened but not yet prepared.
pub fn hasSystemPrompt(session: *const Session) bool {
    return session.system_prompt != .none;
}

/// The system prompt sent at the front of every request, or null when the
/// session has none.
pub fn systemPrompt(session: *const Session) ?[]const u8 {
    return session.pool.get(session.system_prompt);
}

/// The session's title, a short name for it, or null when it has none.
pub fn title(session: *const Session) ?[]const u8 {
    return session.pool.get(session.title_index);
}

/// Names the session, replacing any title it had. The whitespace around it is
/// trimmed and the title itself is kept as written. It is held in the pool and
/// reaches the file with the next save.
pub fn setTitle(session: *Session, text: []const u8) !void {
    session.title_index = try session.pool.intern(session.gpa, std.mem.trim(u8, text, " \t\r\n"));
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

/// The role of a message, which is the name the API knows it by.
pub fn roleOf(session: *const Session, message: Message) []const u8 {
    _ = session;
    return message.role.name();
}

/// The content of a message, or null when it has none.
pub fn contentOf(session: *const Session, message: Message) ?[]const u8 {
    return session.pool.get(message.content);
}

/// One tool call of a message, by position within it.
pub fn callAt(session: *const Session, message: Message, index: usize) Call {
    const call = message.tool_calls.resolve(session)[index];
    return .{
        .id = session.pool.get(call.id) orelse "",
        .name = session.pool.get(call.function.name) orelse "",
        .arguments = session.pool.get(call.function.arguments) orelse "",
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
    if (from >= messages.len)
        return "";

    for (messages[from..]) |message| {
        const call_id = session.pool.get(message.tool_call_id) orelse continue;
        if (std.mem.eql(u8, call_id, call))
            return session.pool.get(message.content) orelse "";
    }

    return "";
}

/// The conversation as plain API messages, every string resolved out of the
/// pool: the system prompt, when there is one, and then the whole conversation.
/// `allocator` owns the result, since resolving a message has to piece its tool
/// calls back together into a slice of its own.
///
/// Nothing that shows or sends a conversation needs this: a request is built
/// from `conversation`, and the transcript reads the session a message at a
/// time. It is for a caller that wants the conversation as messages, which is
/// what comparing two of them takes.
pub fn resolvedMessages(session: *const Session, allocator: std.mem.Allocator) ![]const llm.Message {
    const lead: usize = if (session.hasSystemPrompt()) 1 else 0;
    const messages = try allocator.alloc(llm.Message, lead + session.messages.items.len);
    var out: usize = 0;
    if (session.pool.get(session.system_prompt)) |prompt| {
        messages[0] = .{ .role = .system, .content = prompt };
        out = 1;
    }
    for (session.messages.items) |message| {
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
/// summary it produced. The summary's index is recorded in `compactions`, so a
/// request from then on starts at it while the session keeps every message it
/// always had. The prompt is kept so the transcript can show the pair as one
/// line; the summary is a user message, so the model reads it as context handed
/// to it rather than as something it said. Both are written out together, so the
/// file is never left holding half of a compaction.
pub fn appendCompaction(session: *Session, prompt: []const u8, summary: []const u8) !void {
    try session.appendMessage(.{ .role = .user, .content = prompt });
    const summary_index: u32 = @intCast(session.messages.items.len);
    try session.appendMessage(.{ .role = .user, .content = summary });
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
            .id = try session.pool.intern(session.gpa, tool_call.id),
            .type = try session.pool.intern(session.gpa, tool_call.type),
            .function = .{
                .name = try session.pool.intern(session.gpa, tool_call.function.name),
                .arguments = try session.pool.intern(session.gpa, tool_call.function.arguments),
            },
        });
    }

    try session.messages.append(session.gpa, .{
        .role = message.role,
        .content = try session.pool.intern(session.gpa, message.content),
        .tool_call_id = try session.pool.intern(session.gpa, message.tool_call_id),
        .reasoning = try session.pool.intern(session.gpa, message.reasoning_content),
        .tool_calls = interned_tool_calls,
    });
}

/// Records `system_prompt` as what every request opens with, replacing any prompt
/// the session already had.
///
/// This is what a compaction uses to refresh the front of a request; `prepare`
/// uses `ensureSystemPrompt` so that a resumed session keeps the prompt it was
/// saved with and hits its prompt cache. The prompt is held in the pool and
/// reaches the file with the next save, like the tools.
pub fn setSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    session.system_prompt = try session.pool.intern(session.gpa, system_prompt);
}

/// Records the mode the session runs in. Set once, when the session starts; the
/// prompt and tools stored with it follow from the mode.
pub fn setMode(session: *Session, mode: agent.Mode) void {
    session.mode = mode;
}

/// Records `system_prompt` unless the session already has one. A resumed session
/// carries the prompt it was saved with, which is kept so the request it sends
/// matches the earlier run byte for byte; a new session gets the current one.
pub fn ensureSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    if (session.hasSystemPrompt()) return;
    try session.setSystemPrompt(system_prompt);
}

/// Records the tool definitions to send with every request, replacing any the
/// session already had.
///
/// Like the prompt, this is what a compaction uses to refresh the tools, and
/// what a new session is given; `ensureTools` is the guarded form a resume uses.
pub fn setTools(session: *Session, definitions: []const Definition) !void {
    // The strings are interned into the pool, so the set costs one array and
    // frees with the pool. Nothing is copied per string and there is no parsed
    // document to keep alive: the arguments schema is stored as the JSON text it
    // is sent as.
    const tools = try session.gpa.alloc(Tool, definitions.len);
    errdefer session.gpa.free(tools);
    for (definitions, tools) |definition, *tool| {
        tool.* = .{
            .name = try session.pool.intern(session.gpa, definition.name),
            .description = try session.pool.intern(session.gpa, definition.description),
            .parameters = try session.pool.intern(session.gpa, definition.parameters),
        };
    }
    session.gpa.free(session.tools);
    session.tools = tools;
}

/// Records the tool definitions unless the session already has some. A resumed
/// session carries the tools it was saved with, which are kept so the request
/// matches the earlier run and hits the prompt cache; a new session, or one saved
/// before the tools were stored, gets the current definitions instead.
///
/// Like the system prompt, the set is held in memory and written out with the
/// session's first message.
pub fn ensureTools(session: *Session, definitions: []const Definition) !void {
    if (session.tools.len != 0) return;
    try session.setTools(definitions);
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

pub fn save(session: *const Session) !void {
    var atomic = try session.dir.createFileAtomic(session.io, session.name(), .{
        .replace = true,
    });
    defer atomic.deinit(session.io);

    var file_buf: [std.heap.page_size_min]u8 = undefined;
    var file_writer = atomic.file.writer(session.io, &file_buf);

    try session.write(&file_writer.interface);
    try file_writer.end();
    try atomic.replace(session.io);
}

pub fn write(session: *const Session, writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try json.beginObject();

    try json.objectField("version");
    try json.write(Stored.default.version);

    if (session.pool.get(session.title_index)) |stored_title| {
        try json.objectField("title");
        try json.write(stored_title);
    }

    if (session.pool.get(session.system_prompt)) |prompt| {
        try json.objectField("system_prompt");
        try json.write(prompt);
    }

    try json.objectField("mode");
    try json.write(session.mode);

    try json.objectField("messages");
    try json.beginArray();
    for (session.messages.items) |message|
        try writeMessage(session, &json, message);
    try json.endArray();

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
    try json.write(session.cwd());

    try json.endObject();
}

/// Reads an existing session's file into `session`.
fn load(session: *Session) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const text = session.dir.readFileAlloc(
        session.io,
        session.name(),
        arena,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };

    const stored = std.json.parseFromSliceLeaky(Stored, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptSession;

    if (stored.version > Stored.default.version)
        return error.UnsupportedSessionVersion;

    const lead = try session.loadPromptAndMessages(stored.system_prompt, stored.messages);
    try session.loadCompactions(stored.compactions, lead);
    try session.loadTools(stored.tools);
    try session.repairTail();

    if (stored.title) |stored_title|
        try session.setTitle(stored_title);

    session.mode = stored.mode;
    session.usage = stored.usage;
    session.context_tokens = stored.context_tokens;
    session.cost = stored.cost;
    if (stored.cwd) |stored_cwd|
        session.interned_cwd = try session.pool.intern(session.gpa, stored_cwd);
}

fn loadPromptAndMessages(
    session: *Session,
    system_prompt: ?[]const u8,
    messages: []const llm.Message,
) !usize {
    // The system prompt is its own field in a version 3 file. An older file
    // instead holds it as the first message, sometimes as a leading run of them;
    // that run is lifted out into the prompt and left out of the conversation, so
    // a request built from the session opens the way it did before. The first of
    // the run is the prompt, which is the one billy ever wrote.
    var lead: usize = 0;
    if (system_prompt) |prompt| {
        try session.setSystemPrompt(prompt);
    } else {
        while (lead < messages.len and messages[lead].role == .system) lead += 1;
        if (lead > 0)
            try session.setSystemPrompt(messages[0].content orelse "");
    }
    for (messages[lead..]) |message| {
        try session.appendMessage(message);
    }

    return lead;
}

/// Reads the compaction indices back against the conversation just loaded, so
/// the sorted list a request and a transcript read is sound even if the file was
/// written by hand: one past the end is dropped rather than trusted and the list
/// is sorted. A migrated file's indices name the messages as they were stored, so
/// each is shifted by the `lead` lifted out of the front of them.
fn loadCompactions(session: *Session, stored: []const u32, lead: usize) !void {
    try session.compactions.appendSlice(session.gpa, stored);
    std.mem.sort(u32, session.compactions.items, {}, std.sort.asc(u32));

    for (session.compactions.items) |*index| {
        index.* = std.math.sub(u32, index.*, @intCast(lead)) catch 0;
        index.* = @min(index.*, @as(u32, @intCast(session.messages.items.len - 1)));
    }
}

/// Interns the stored tool definitions, so the set is one array and the
/// arguments schema becomes the JSON text the request sends it as.
fn loadTools(session: *Session, stored: []const StoredTool) !void {
    const tools = try session.gpa.alloc(Tool, stored.len);
    for (stored, tools) |stored_tool, *tool| {
        tool.* = .{
            .name = try session.pool.intern(session.gpa, stored_tool.function.name),
            .description = try session.pool.intern(session.gpa, stored_tool.function.description),
            .parameters = try session.internParameters(stored_tool.function.parameters),
        };
    }
    session.tools = tools;
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
    const calls = session.messages.items[tail].tool_calls.len;

    // The results that follow the message, which is where they were written.
    var answered: usize = 0;
    for (session.messages.items[tail + 1 ..]) |message| {
        if (message.role != .tool)
            break;
        answered += 1;
    }
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
            .role = .tool,
            .content = try session.pool.intern(session.gpa, interrupted_result),
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
        if (message.role == .assistant and message.tool_calls.len > 0)
            return i;
    }
    return null;
}

/// The directory billy keeps its own files in: `$XDG_DATA_HOME/billy`, or
/// `$HOME/.local/share/billy` when that is unset, as the XDG base directory
/// specification prescribes. The credentials live in the directory itself, and
/// the sessions in a subdirectory of it, so a listing of billy's data directory
/// shows what billy keeps rather than a wall of session files.
pub fn dataDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return xdg.dir(gpa, environ, "XDG_DATA_HOME", &.{ ".local", "share" });
}

/// The directory holding the sessions: the `sessions` subdirectory of `dataDir`,
/// so that the session files sit apart from what else billy keeps.
pub fn defaultDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const data_dir = try dataDir(gpa, environ);
    defer gpa.free(data_dir);

    return std.fs.path.join(gpa, &.{ data_dir, sessions_dir });
}

/// The data directory, made if it is not there yet. Building the path and making
/// it is one intention, so the two error reports are written here rather than at
/// every caller that needs the directory.
pub fn openDataDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !std.Io.Dir {
    return xdg.openDirBuilt(io, dataDir(gpa, environ), "billy's files");
}

/// The sessions directory, made if it is not there yet, on the same terms as
/// `openDataDir`.
pub fn openDefaultDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !std.Io.Dir {
    return xdg.openDirBuilt(io, defaultDir(gpa, environ), "sessions");
}

/// The arguments schema of a tool as JSON text: already text when a file holds
/// it so, and written back out when an older file holds the parsed object, which
/// is what the request is sent.
fn internParameters(session: *Session, value: std.json.Value) !StringIndex {
    switch (value) {
        .string => |text| return session.pool.intern(session.gpa, text),
        else => {
            const text = try std.json.Stringify.valueAlloc(session.gpa, value, .{});
            defer session.gpa.free(text);
            return session.pool.intern(session.gpa, text);
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
            try json.write(session.pool.get(tool.name) orelse "");
            try json.objectField("description");
            try json.write(session.pool.get(tool.description) orelse "");
            try json.objectField("parameters");
            // The schema is written as the JSON it is, not as a quoted string.
            try json.print("{s}", .{session.pool.get(tool.parameters) orelse "{}"});
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
    if (given.len + 1 > buf.len) return error.InvalidSessionId;
    if (!usableName(given)) return error.InvalidSessionId;
    @memcpy(buf[0..given.len], given);
    return buf[0..given.len];
}

/// Whether `text` could be the id of a session. An id is the characters a file
/// name shares with one, and is neither empty nor all dots, which are the names
/// that walk the directory rather than name a file in it.
fn usableName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return !std.mem.allEqual(u8, text, '.');
}

/// The ids of the sessions in the directory `dir`, the one most recently written
/// to first, each with its title. Only files that could be a session are listed.
/// The ids and titles are `gpa`'s, and the caller frees each and then the list.
///
/// The order is the time each file was last written, asked of the filesystem
/// rather than read out of the id: an id carries the time it was *made*, and one
/// made before ids became ULIDs does not sort against them.
///
/// The directory is opened here, one handle per listing. A read holds its place
/// in the handle it was opened on, so two listings sharing one would read over
/// each other; the server asks from several connections at once, and this is what
/// makes each of those impossible to get wrong.
pub fn list(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]Named {
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);

    return listIn(iter_dir, io, gpa);
}

/// One session as a listing shows it: the id that names it, and its title, which
/// is "" for a session that has not been named.
pub const Named = struct {
    id: []const u8,
    title: []const u8,
};

/// The ids of the sessions in `dir`, which must be a handle this listing has to
/// itself. See `list`, which opens one.
fn listIn(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) ![]Named {
    // The names and the times they were written are two lists kept in step: the
    // times are only there to order the names by, so sorting has to move both.
    var names: std.ArrayList(Named) = .empty;
    errdefer {
        for (names.items) |made| {
            gpa.free(made.id);
            gpa.free(made.title);
        }
        names.deinit(gpa);
    }
    var written: std.ArrayList(i64) = .empty;
    defer written.deinit(gpa);

    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        // A session is a regular file, so a directory or a symlink in the way is
        // not one to read.
        if (entry.kind != .file) continue;
        const stem = idInName(entry.name) orelse continue;

        // A file that cannot be asked about is one to leave out rather than one
        // to fail the listing over.
        const stat = dir.statFile(io, entry.name, .{}) catch continue;

        // The title is read from the front of the file, which keeps a listing
        // cheap however large the conversations are. A file that is not a session
        // is left out before anything is allocated for it, so `continue` leaks
        // nothing and the two lists stay the same length.
        const stored_title = readTitle(io, gpa, dir, entry.name) catch |err| switch (err) {
            error.SyntaxError => continue,
            else => return err,
        };
        errdefer gpa.free(stored_title);

        // The name is a window into the iterator, which the next entry moves on,
        // so the id is copied out before it can go.
        const owned_id = try gpa.dupe(u8, stem);
        errdefer gpa.free(owned_id);

        try written.append(gpa, stat.mtime.toMilliseconds());
        try names.append(gpa, .{ .id = owned_id, .title = stored_title });
    }

    std.mem.sortUnstableContext(0, names.items.len, Ordering{
        .names = names.items,
        .written = written.items,
    });
    return names.toOwnedSlice(gpa);
}

/// The first buffer a session file's title is read into. It is big enough for an
/// ordinary title, so the quote that closes one is found in the first read; a
/// longer title grows the buffer rather than being refused.
const title_read_buffer_len = 1024;

/// The title stored in the session file `file_name`, or "" when it has none.
///
/// Only the front of the file is read, and only as far as the title: the fields
/// it opens with are stepped over a token at a time, so a listing reads a few
/// dozen bytes rather than the whole conversation, however large the file is.
fn readTitle(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var file = dir.openFile(io, file_name, .{}) catch return gpa.dupe(u8, "");
    defer file.close(io);

    var reader_buf: [std.heap.page_size_min]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    return (try titleFrom(&reader.interface, gpa)) orelse "";
}

/// Reads the title out of the front of a session file, or null when it has none.
///
/// It leans on the order `save` writes: the title is the second field, right
/// after the version. So only those two are looked at, and a file that does not
/// name the session -- one saved before titles, or hand-written -- is recognized
/// and left alone after a few bytes rather than scanned to its end.
fn titleFrom(reader: *std.Io.Reader, gpa: std.mem.Allocator) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var j_reader = std.json.Reader.init(gpa, reader);
    defer j_reader.deinit();

    const object_begin = try j_reader.next();
    if (object_begin != .object_begin) return null;

    const version_key = try j_reader.nextAlloc(arena, .alloc_always);
    if (version_key != .allocated_string) return null;
    if (!std.mem.eql(u8, version_key.allocated_string, "version")) return null;

    const version_value = try j_reader.nextAlloc(arena, .alloc_always);
    if (version_value != .allocated_number) return null;

    const title_key = try j_reader.nextAlloc(arena, .alloc_always);
    if (title_key != .allocated_string) return null;
    if (!std.mem.eql(u8, title_key.allocated_string, "title")) return null;

    const title_value = try j_reader.nextAlloc(arena, .alloc_always);
    if (title_value != .allocated_string) return null;

    return try gpa.dupe(u8, title_value.allocated_string);
}

/// Orders sessions by when their files were written, newest first, carrying the
/// times along with them. The two lists are one list of pairs that the sorting
/// cannot see, so a swap has to move both.
const Ordering = struct {
    names: []Named,
    written: []i64,

    pub fn lessThan(self: Ordering, a: usize, b: usize) bool {
        // Newest first, and two written in the same millisecond by their ids,
        // which is the order they were made in, so the order is total and a
        // listing does not shuffle between calls.
        if (self.written[a] != self.written[b]) return self.written[a] > self.written[b];
        return std.mem.order(u8, self.names[a].id, self.names[b].id) == .gt;
    }

    pub fn swap(self: Ordering, a: usize, b: usize) void {
        std.mem.swap(Named, &self.names[a], &self.names[b]);
        std.mem.swap(i64, &self.written[a], &self.written[b]);
    }
};

/// The name of the session file for `session_id`, written into `buffer`, or null
/// when it could not name a session.
fn fileName(session_id: []const u8, buffer: []u8) ?[]const u8 {
    if (!usableName(session_id)) return null;
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ session_id, extension }) catch null;
}

/// Deletes the session `id` from `dir`, so it is gone for good: billy keeps no
/// trash. A session that has no file is `error.SessionNotFound`, and an id that
/// could not name one is `error.InvalidSessionId`.
pub fn delete(io: std.Io, dir: std.Io.Dir, session_id: []const u8) !void {
    var buffer: [max_id_len + extension.len]u8 = undefined;
    const file = fileName(session_id, &buffer) orelse return error.InvalidSessionId;
    dir.deleteFile(io, file) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
}

/// The id in `file_name`, which is the name with the extension taken off, or null
/// when the name is not that of a session file.
fn idInName(file_name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, file_name, extension)) return null;
    const stem = file_name[0 .. file_name.len - extension.len];
    if (!usableName(stem)) return null;
    return stem;
}

/// A session opened fresh in `tmp`, for a test to build a conversation in. The
/// caller owns it and frees it with `deinit`.
fn newTestSession(tmp: *std.testing.TmpDir) !Session {
    return Session.open(std.testing.io, tmp.dir, std.testing.allocator, null, "/work");
}

/// The session `id` read back from `tmp`, which is what reopening it does. The
/// caller owns it and frees it with `deinit`.
fn reopenTestSession(tmp: *std.testing.TmpDir, session_id: []const u8) !Session {
    return Session.open(std.testing.io, tmp.dir, std.testing.allocator, session_id, "/work");
}

/// Checks two conversations hold the same messages, field for field: the role,
/// the content, the call a result answers, and every tool call. The text is
/// compared by content, since two sessions number their strings differently; a
/// role is the enum itself, so it is compared as one.
fn expectConvo(expected: []const llm.Message, actual: []const llm.Message) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.role, got.role);
        try std.testing.expectEqualStrings(want.content orelse "", got.content orelse "");
        try std.testing.expectEqualStrings(want.tool_call_id orelse "", got.tool_call_id orelse "");

        const want_calls = want.tool_calls orelse &.{};
        const got_calls = got.tool_calls orelse &.{};
        try std.testing.expectEqual(want_calls.len, got_calls.len);
        for (want_calls, got_calls) |want_call, got_call| {
            try std.testing.expectEqualStrings(want_call.id, got_call.id);
            try std.testing.expectEqualStrings(want_call.type, got_call.type);
            try std.testing.expectEqualStrings(want_call.function.name, got_call.function.name);
            try std.testing.expectEqualStrings(want_call.function.arguments, got_call.function.arguments);
        }
    }
}

/// Frees the messages `resolvedMessages` returns: it allocates the slice and each
/// message's tool calls, so both are given back, one message at a time.
fn freeResolved(gpa: std.mem.Allocator, messages: []const llm.Message) void {
    for (messages) |message| {
        if (message.tool_calls) |calls| gpa.free(calls);
    }
    gpa.free(messages);
}

/// Checks the conversation `session` resolves to against `expected`, freeing what
/// resolving it allocates. This is what a test uses instead of comparing two
/// sessions' own indices, which number their strings differently.
fn expectSessionConvo(session: *const Session, expected: []const llm.Message) !void {
    const gpa = std.testing.allocator;
    const resolved = try session.resolvedMessages(gpa);
    defer freeResolved(gpa, resolved);
    try expectConvo(expected, resolved);
}

/// Writes `messages` as a session's conversation, resumes the session, and
/// checks the conversation comes back exactly as it went in: the save/load
/// round trip, for a conversation of any shape. The session is opened with the
/// testing allocator, not an arena, so a resume that does not free what it read
/// is reported rather than hidden.
fn expectResume(messages: []const llm.Message) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try expectSessionConvo(&resumed, messages);
}

/// Checks the JSON a request carries for `session` against `expected`: the
/// `messages` array of a request body, with `extra` written after it or none.
fn expectRequestJson(session: *const Session, extra: []const llm.Message, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(session.conversation(extra), .{ .emit_null_optional_fields = false }, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a new session is given a ULID, and nothing is written yet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try std.testing.expect(ulid.isId(session.id()));
    // Opening a new session records an id and nothing else, so the first write
    // is the first message. Nothing is named after the id until then.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));
}

test "a session can be started for an id that has no file yet" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An id handed out before the session exists: the id is what names it, and
    // nothing is read, since there is nothing to read.
    var session = try Session.create(std.testing.io, tmp.dir, gpa, "made-by-hand", "/work");
    defer session.deinit();
    try std.testing.expectEqualStrings("made-by-hand", session.id());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));

    // The first message is what writes it, exactly as for a generated id.
    try session.append(.{ .role = .user, .content = "hello" });
    var resumed = try reopenTestSession(&tmp, "made-by-hand");
    defer resumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), resumed.messages.items.len);
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[0]).?);

    // An id that could not name a session is refused rather than written.
    try std.testing.expectError(
        error.InvalidSessionId,
        Session.create(std.testing.io, tmp.dir, gpa, "../escape", "/work"),
    );
}

test "a session is deleted for good, and only that session" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two sessions, so the delete can be seen to remove one and leave the other.
    var kept = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer kept.deinit();
    try kept.append(.{ .role = .user, .content = "keep me" });
    const kept_id = try gpa.dupe(u8, kept.id());
    defer gpa.free(kept_id);

    var gone = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer gone.deinit();
    try gone.append(.{ .role = .user, .content = "delete me" });
    const gone_id = try gpa.dupe(u8, gone.id());
    defer gpa.free(gone_id);

    try Session.delete(std.testing.io, tmp.dir, gone_id);

    // The one deleted is gone, and cannot be deleted again.
    try std.testing.expectError(error.SessionNotFound, reopenTestSession(&tmp, gone_id));
    try std.testing.expectError(error.SessionNotFound, Session.delete(std.testing.io, tmp.dir, gone_id));

    // The other is untouched.
    var still = try reopenTestSession(&tmp, kept_id);
    defer still.deinit();
    try std.testing.expectEqualStrings("keep me", still.contentOf(still.messages.items[0]).?);

    // An id that could not name a session is refused rather than looked for.
    try std.testing.expectError(error.InvalidSessionId, Session.delete(std.testing.io, tmp.dir, "../escape"));
}

test "a new session is written out by its first message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tools = [_]Definition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = "{}",
    }};

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // Setting a session up -- its prompt and its tools -- is held in memory, so
    // a run that is started and left alone leaves nothing behind. This is what
    // keeps an untouched `billy` from littering the sessions directory.
    try session.setSystemPrompt("be terse");
    try session.ensureTools(&tools);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));

    // The first message is what brings the session into being, and everything
    // set up before it lands in the file with it.
    try session.append(.{ .role = .user, .content = "hello" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    // The prompt is its own field, apart from the conversation, which is the
    // message alone.
    try std.testing.expect(resumed.hasSystemPrompt());
    try std.testing.expectEqualStrings("be terse", resumed.pool.get(resumed.system_prompt).?);
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.roleOf(resumed.messages.items[0]));
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[0]).?);
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

/// Frees what `list` returned: the ids it copied out, and the list itself.
fn freeList(names: []Named, gpa: std.mem.Allocator) void {
    for (names) |made| {
        gpa.free(made.id);
        gpa.free(made.title);
    }
    gpa.free(names);
}

/// Writes an empty session file named for `id`, last written `written_ms`
/// milliseconds after the epoch, so a listing can be checked for the order it
/// puts the files in. The file's content does not matter to a listing.
fn writeSessionAt(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator, session_id: []const u8, written_ms: i64) !void {
    try writeFileAt(tmp, gpa, session_id, "{}", written_ms);
}

fn writeFileAt(
    tmp: *std.testing.TmpDir,
    gpa: std.mem.Allocator,
    session_id: []const u8,
    data: []const u8,
    written_ms: i64,
) !void {
    const file_name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ session_id, extension });
    defer gpa.free(file_name);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = data });
    try tmp.dir.setTimestamps(std.testing.io, file_name, .{
        .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(
            @as(i96, written_ms) * std.time.ns_per_ms,
        ) },
    });
}

test "the sessions in a directory are listed by when they were written" {
    const gpa = std.testing.allocator;

    // Opened for iteration, since that is what listing a directory does.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // An older id and a newer one, and a name that is not a ULID at all. The
    // order below is none of these: it is the time each file was written, which
    // is what makes the listing newest-first whatever the ids are.
    var older_buf: [max_id_len]u8 = undefined;
    ulid.encode(older_buf[0..ulid.length], 1_700_000_000_000, @splat(0));
    var newer_buf: [max_id_len]u8 = undefined;
    ulid.encode(newer_buf[0..ulid.length], 1_700_000_001_000, @splat(0));

    const oldest = older_buf[0..ulid.length];
    const newest_id = newer_buf[0..ulid.length];
    const files = [_]struct { id: []const u8, written_ms: i64 }{
        .{ .id = oldest, .written_ms = 1_000 }, // oldest by id, oldest by time
        .{ .id = "dev", .written_ms = 3_000 }, // newest by time, named by hand
        .{ .id = newest_id, .written_ms = 2_000 }, // newest by id, in the middle
    };
    for (files) |file| try writeSessionAt(&tmp, gpa, file.id, file.written_ms);

    // Files that are not sessions are passed over: another extension, a name that
    // could not be an id, and a directory.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad name" ++ extension, .data = "x" });
    try tmp.dir.createDirPath(std.testing.io, "a-directory" ++ extension);

    const ids = try listIn(tmp.dir, std.testing.io, std.testing.allocator);
    defer freeList(ids, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try std.testing.expectEqualStrings("dev", ids[0].id);
    try std.testing.expectEqualStrings(newest_id, ids[1].id);
    try std.testing.expectEqualStrings(oldest, ids[2].id);
}

test "the ordering keeps each id with the time it was written at" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Six sessions whose id order and write order run opposite ways, so the sort
    // has to move the times along with the ids rather than reorder one list on
    // its own: the id that was made first is the one written last, and so is the
    // one that comes first in the listing.
    const count = 6;
    var buffers: [count][max_id_len]u8 = undefined;
    for (0..count) |i| {
        const made = buffers[i][0..ulid.length];
        ulid.encode(made, 1_700_000_000_000 + @as(u48, @intCast(i)), @splat(0));
        try writeSessionAt(&tmp, gpa, made, @intCast(1_000 + (count - 1 - i) * 1_000));
    }

    const ids = try listIn(tmp.dir, std.testing.io, std.testing.allocator);
    defer freeList(ids, std.testing.allocator);

    // The write times descend as the ids ascend, so the listing is the ids in
    // the order they were made in, each still with the time it was written at.
    try std.testing.expectEqual(@as(usize, count), ids.len);
    for (ids, 0..) |listed, position| {
        try std.testing.expectEqualStrings(buffers[position][0..ulid.length], listed.id);
    }
}

test "sessions written at the same moment are ordered by their ids" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var older_buf: [max_id_len]u8 = undefined;
    ulid.encode(older_buf[0..ulid.length], 1_700_000_000_000, @splat(0));
    var newer_buf: [max_id_len]u8 = undefined;
    ulid.encode(newer_buf[0..ulid.length], 1_700_000_001_000, @splat(0));

    // The same write time on both, so the newer id comes first and the order does
    // not depend on how the directory happened to be read.
    for ([_][]const u8{ older_buf[0..ulid.length], newer_buf[0..ulid.length] }) |made| {
        try writeSessionAt(&tmp, gpa, made, 1_000);
    }

    const ids = try listIn(tmp.dir, std.testing.io, std.testing.allocator);
    defer freeList(ids, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings(newer_buf[0..ulid.length], ids[0].id);
    try std.testing.expectEqualStrings(older_buf[0..ulid.length], ids[1].id);
}

test "a file that is not a session is left out without disturbing the order" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // The unreadable file is written between the others, so wherever the
    // directory yields it, some session follows it. What it leaves behind, were
    // it counted, would shift the times of the ones after it, and the testing
    // allocator reports anything it allocated and did not free.
    try writeSessionAt(&tmp, gpa, "a", 1_000);
    try writeSessionAt(&tmp, gpa, "b", 2_000);
    try writeFileAt(&tmp, gpa, "broken", "not json at all", 3_000);
    try writeSessionAt(&tmp, gpa, "c", 4_000);
    try writeSessionAt(&tmp, gpa, "d", 5_000);

    const listed = try listIn(tmp.dir, std.testing.io, gpa);
    defer freeList(listed, gpa);
    try std.testing.expectEqual(@as(usize, 4), listed.len);
    const expected = [_][]const u8{ "d", "c", "b", "a" };
    for (listed, expected) |entry, want| try std.testing.expectEqualStrings(want, entry.id);
}

test "an empty sessions directory lists nothing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const ids = try listIn(tmp.dir, std.testing.io, std.testing.allocator);
    defer freeList(ids, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "a listing carries each session's title" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // One session named with a long title, one with a short title, and one that
    // has not been named. The long one is longer than the first read buffer, so
    // it is read back only because the reader grows.
    const long_title: [title_read_buffer_len + 1]u8 = @splat('y');
    try std.testing.expect(long_title.len > title_read_buffer_len);
    var long = try newTestSession(&tmp);
    defer long.deinit();
    try long.setTitle(&long_title);
    try long.append(.{ .role = .user, .content = "hi" });

    var titled = try newTestSession(&tmp);
    defer titled.deinit();
    try titled.setTitle("Fix the parser");
    try titled.append(.{ .role = .user, .content = "hi" });

    var unnamed = try newTestSession(&tmp);
    defer unnamed.deinit();
    try unnamed.append(.{ .role = .user, .content = "hi" });

    const listed = try listIn(tmp.dir, std.testing.io, gpa);
    defer freeList(listed, gpa);
    try std.testing.expectEqual(@as(usize, 3), listed.len);

    // Each entry carries the title the file holds, or "" for the session that
    // has none.
    for (listed) |entry| {
        if (std.mem.eql(u8, entry.id, long.id())) {
            try std.testing.expectEqualStrings(&long_title, entry.title);
        } else if (std.mem.eql(u8, entry.id, titled.id())) {
            try std.testing.expectEqualStrings("Fix the parser", entry.title);
        } else {
            try std.testing.expectEqualStrings(unnamed.id(), entry.id);
            try std.testing.expectEqualStrings("", entry.title);
        }
    }
}

test "a title is trimmed and cut to the most a title may be when it is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try newTestSession(&tmp);
    defer session.deinit();

    // The whitespace a paste brings is not part of the title.
    try session.setTitle("  Fix the parser\n");
    try std.testing.expectEqualStrings("Fix the parser", session.title().?);

    // A title of any length is kept whole: there is no limit.
    // The euro sign is three bytes in UTF-8, so this is not one byte repeated.
    const many_euros = comptime blk: {
        var out: [3 * 500]u8 = undefined;
        for (0..500) |i| @memcpy(out[i * 3 ..][0..3], "\u{20AC}");
        break :blk out;
    };
    try session.setTitle(&many_euros);
    try std.testing.expectEqualStrings(&many_euros, session.title().?);
}

test "the title is read from the front of a session file, unescaped" {
    const gpa = std.testing.allocator;

    // The title sits right after the version, and the reader stops there rather
    // than reading the rest of the file.
    try expectTitle(gpa, "Fix it", "{\"version\":3,\"title\":\"Fix it\",\"system_prompt\":\"x\"}");
    // The escapes the writer produces are undone.
    try expectTitle(gpa, "a \"quoted\" \\ title", "{\"version\":3,\"title\":\"a \\\"quoted\\\" \\\\ title\"}");
    // A title that ends in an escaped backslash, which the quote after it does
    // not close.
    try expectTitle(gpa, "ends with a backslash \\", "{\"version\":3,\"title\":\"ends with a backslash \\\\\",\"messages\":[]}");
    // A title that is a single escaped quote.
    try expectTitle(gpa, "\"", "{\"version\":3,\"title\":\"\\\"\"}");
    // An empty title is read as empty, not as "no title".
    try expectTitle(gpa, "", "{\"version\":3,\"title\":\"\",\"messages\":[]}");

    // A session with no title -- one saved before titles, or hand-written -- is
    // recognized by the field after the version and left alone.
    try std.testing.expect((try titleOf(gpa, "{\"version\":3,\"system_prompt\":\"be terse\",\"messages\":[]}")) == null);
    try std.testing.expect((try titleOf(gpa, "{\"version\":3,\"messages\":[]}")) == null);
    // Something that is not a session at all.
    try std.testing.expectError(error.SyntaxError, titleOf(gpa, "not json at all"));

    // A title of any length is read, however long: there is no limit.
    const long_title: [4096]u8 = @splat('y');
    try expectTitle(gpa, &long_title, "{\"version\":3,\"title\":\"" ++ &long_title ++ "\"}");
}

/// Reads the title out of `front`, which stands in for the start of a session
/// file. The reader is fixed over `front`, so the whole of it is available.
fn titleOf(gpa: std.mem.Allocator, front: []const u8) !?[]u8 {
    var reader: std.Io.Reader = .fixed(front);
    return titleFrom(&reader, gpa);
}

/// Checks what `titleFrom` reads, freeing what it allocates.
fn expectTitle(gpa: std.mem.Allocator, expected: []const u8, front: []const u8) !void {
    const got = (try titleOf(gpa, front)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(expected, got);
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
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, &@as([max_id_len + 1]u8, @splat('x'))));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, &@as([max_id_len]u8, @splat('x'))));
    _ = try setCheckedId(&buf, &@as([max_id_len - 1]u8, @splat('x')));
}

test "defaultDir is the sessions directory under the data directory" {
    const gpa = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");

    // The rules themselves are `xdg.dir`'s; this only pins the base and the
    // subdirectory the sessions sit in.
    const data = try dataDir(gpa, &environ);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", data);

    const sessions = try defaultDir(gpa, &environ);
    defer gpa.free(sessions);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", sessions);
}

test "a session survives a save and resume" {
    // A message of every shape: a prompt, an assistant message that asks for a
    // tool, and the result that answers it.
    try expectResume(&.{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
    });
}

test "a resume answers a tool call a killed run left open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // The assistant asked for a tool, and the run was killed before its result
    // was written, so the session ends on the call with no message answering it.
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "bash", .arguments = "{}" },
    }} });

    // The call now has an answer, so the request the session builds is one the
    // API takes: the assistant message is followed by the result of its call,
    // and the call did not finish.
    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try expectSessionConvo(&resumed, &.{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "bash", .arguments = "{}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = interrupted_result },
    });
}

test "a resume answers every call a kill left open, in the order made" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "go" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{}" } },
    } });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "the first result" });
    // Killed before the second result, and the user typed on afterwards, so the
    // message that follows the run is not a result at all.
    try session.append(.{ .role = .user, .content = "still there?" });

    // The result the file held stays with its call, and the call it lost is
    // answered in the place it was made rather than after the user message.
    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try expectSessionConvo(&resumed, &.{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
            .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{}" } },
        } },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "the first result" },
        .{ .role = .tool, .tool_call_id = "call_2", .content = interrupted_result },
        .{ .role = .user, .content = "still there?" },
    });
}

test "a resume leaves a finished conversation alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // A run that finished leaves every call answered and its compaction in
    // place, which is what the repair must not disturb.
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "go" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{}" } },
    } });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "one" });
    try session.append(.{ .role = .tool, .tool_call_id = "call_2", .content = "two" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = .assistant, .content = "done" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();

    try std.testing.expectEqual(session.messages.items.len, resumed.messages.items.len);
    try std.testing.expectEqual(session.sentFrom(), resumed.sentFrom());
    try std.testing.expect(resumed.isCompaction(resumed.sentFrom()));
}

test "a repair moves a compaction that sits behind the turn it completes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // A file that holds a compaction right behind a call with no result, as one
    // written by hand can: the answer the repair inserts lands in front of both
    // the prompt and the summary.
    try session.append(.{ .role = .user, .content = "go" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.appendCompaction("summarize this", "the summary");

    var resumed = try reopenTestSession(&tmp, session.id());
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // A message of every shape: an optional left out, one filled in, and a call
    // alongside the result that answers it. The system prompt is its own field,
    // which the request opens with.
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" });

    const expected = "[{\"role\":\"system\",\"content\":\"be terse\"}," ++
        "{\"role\":\"user\",\"content\":\"hello\"}," ++
        "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}]}," ++
        "{\"role\":\"tool\",\"content\":\"1\\tconst x = 1;\\n\",\"tool_call_id\":\"call_1\"}]";
    try expectRequestJson(&session, &.{}, expected);

    // Writing the stored conversation has to give the bytes the resolved one
    // does, field for field and in the same order, or a resumed session would
    // send a request that misses its prompt cache.
    const resolved = try session.resolvedMessages(gpa);
    defer freeResolved(gpa, resolved);
    const via_messages = try std.json.Stringify.valueAlloc(gpa, resolved, .{ .emit_null_optional_fields = false });
    defer gpa.free(via_messages);
    try std.testing.expectEqualStrings(expected, via_messages);
}

test "an extra message is written after the conversation, and is not part of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .content = "hi" });
    const before = session.messages.items.len;

    // A request that carries one message more than the session holds, such as the
    // prompt that asks for a title: the extra is written last, as the newest
    // message, and the session is left exactly as it was.
    const extra = [_]llm.Message{.{ .role = .user, .content = "give it a title" }};
    try expectRequestJson(&session, &extra, "[{\"role\":\"system\",\"content\":\"be terse\"}," ++
        "{\"role\":\"user\",\"content\":\"hello\"}," ++
        "{\"role\":\"assistant\",\"content\":\"hi\"}," ++
        "{\"role\":\"user\",\"content\":\"give it a title\"}]");
    try std.testing.expectEqual(before, session.messages.items.len);
}

test "a string that is not valid UTF-8 is repaired on the way into the pool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // A command's output and a file read back are arbitrary bytes, so a result
    // holds a stray continuation byte and a cut-off sequence, neither of which
    // is UTF-8.
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "a\x80b\xffc" });

    // The pool holds text, so a request writes the content as a string. Left as
    // bytes, Zig would write it as an array of numbers the API rejects.
    try expectRequestJson(&session, &.{}, "[{\"role\":\"tool\",\"content\":\"a\u{FFFD}b\u{FFFD}c\",\"tool_call_id\":\"call_1\"}]");

    // The repaired text is what the session keeps, so a resume reads it back
    // the same rather than the bytes that could not be sent.
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", session.contentOf(session.messages.items[0]).?);
}

test "a message a session read back with bytes that are not UTF-8 is repaired" {
    const gpa = std.testing.allocator;
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

    var session = try reopenTestSession(&tmp, "bytes");
    defer session.deinit();

    try std.testing.expectEqualStrings("a\u{FFFD}b", session.contentOf(session.messages.items[0]).?);

    // Saving it back writes the content as a string, so the bytes are gone for
    // good and the file is one a later resume reads as text.
    try session.save();
    const text = try tmp.dir.readFileAlloc(std.testing.io, "bytes.json", gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[97,255,98]") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"content\":\"a\u{FFFD}b\"") != null);
}

test "a stored message reads back as its parts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .id = "call_2", .function = .{ .name = "bash", .arguments = "{}" } },
    } });

    // What the transcript reads a message through, without building a message.
    const user = session.messages.items[0];
    try std.testing.expectEqualStrings("user", session.roleOf(user));
    try std.testing.expectEqualStrings("hello", session.contentOf(user).?);
    try std.testing.expectEqual(0, user.tool_calls.len);

    // A message with no content reports none, rather than an empty string.
    const assistant = session.messages.items[1];
    try std.testing.expectEqualStrings("assistant", session.roleOf(assistant));
    try std.testing.expect(session.contentOf(assistant) == null);
    try std.testing.expectEqual(2, assistant.tool_calls.len);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "the result" });
    try session.append(.{ .role = .tool, .tool_call_id = "old", .content = "an earlier result" });

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

test "every string is kept as it was written, and reads back as its own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .content = "hello" });
    try session.append(.{
        .role = .assistant,
        .tool_calls = &.{
            .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{}" } },
            .{ .id = "call_1", .function = .{ .name = "read", .arguments = "[]" } },
        },
    });

    // Every string as it came, in the order it was added, with a role among
    // them: a role is the enum, so no copy of "user" or "assistant" is kept.
    try std.testing.expectEqualStrings(
        "/work\x00hello\x00hello\x00call_1\x00function\x00read\x00{}\x00" ++
            "call_1\x00function\x00read\x00[]\x00",
        session.pool.strings.items,
    );
    // Two equal contents are two entries in the pool, and each message reads
    // back the text that was written for it.
    try std.testing.expectEqualStrings("hello", session.contentOf(session.messages.items[0]).?);
    try std.testing.expectEqualStrings("hello", session.contentOf(session.messages.items[1]).?);
    const calls = session.messages.items[2].tool_calls.resolve(&session);
    try std.testing.expectEqualStrings("{}", session.pool.get(calls[0].function.arguments).?);
    try std.testing.expectEqualStrings("[]", session.pool.get(calls[1].function.arguments).?);
}

test "a version 2 file's system prompt is lifted into its own field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file from before the prompt was kept apart from the conversation holds it
    // as the first message.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "one.json",
        .data = "{\"version\":2,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"old prompt\"}," ++
            "{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var resumed = try reopenTestSession(&tmp, "one");
    defer resumed.deinit();

    // The prompt comes back as its own field and is no longer a message, so the
    // conversation is the user message alone.
    try std.testing.expectEqualStrings("old prompt", resumed.pool.get(resumed.system_prompt).?);
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.roleOf(resumed.messages.items[0]));
    try std.testing.expectEqualStrings("hi", resumed.contentOf(resumed.messages.items[0]).?);

    // A resume keeps it rather than taking a newer one.
    try resumed.ensureSystemPrompt("new prompt");
    try std.testing.expectEqualStrings("old prompt", resumed.pool.get(resumed.system_prompt).?);
}

test "a compaction is appended and a request starts at its summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .content = "first answer" });
    // Nothing compacted yet, so a request carries the whole conversation.
    try std.testing.expectEqual(0, session.sentFrom());

    // A compaction adds the prompt and the summary to the end, keeping every
    // message it stands in for. The summary is a user message, so the model
    // reads it as context given to it.
    try session.appendCompaction("summarize this", "what happened so far");
    try std.testing.expectEqual(4, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[2]));
    try std.testing.expectEqualStrings("summarize this", session.contentOf(session.messages.items[2]).?);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[3]));
    try std.testing.expectEqualStrings("what happened so far", session.contentOf(session.messages.items[3]).?);

    // A request now starts at the summary, skipping everything the summary stands
    // in for. The prompt is not a message, so it is not part of the count.
    try std.testing.expectEqual(3, session.sentFrom());
    try std.testing.expect(session.isCompaction(3));
    // The prompt that asked for the compaction is not itself a summary.
    try std.testing.expect(!session.isCompaction(2));
    try std.testing.expect(!session.isCompaction(1));
    // An index past the conversation is never a compaction.
    try std.testing.expect(!session.isCompaction(99));

    // The messages after the compaction are sent in full.
    try session.append(.{ .role = .user, .content = "next" });
    try std.testing.expectEqual(3, session.sentFrom());
}

test "a compaction survives a save and resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "one" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = .user, .content = "next" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();

    // Everything comes back, and the request still starts at the summary.
    try std.testing.expectEqualStrings("be terse", resumed.pool.get(resumed.system_prompt).?);
    try std.testing.expectEqual(4, resumed.messages.items.len);
    try std.testing.expectEqual(2, resumed.sentFrom());
    try std.testing.expectEqualStrings("the summary", resumed.pool.get(resumed.messages.items[2].content).?);
    try std.testing.expectEqualStrings("next", resumed.pool.get(resumed.messages.items[3].content).?);
}

test "the compaction list is sorted and clamped when a session is read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written by hand, with the indices out of order, a repeat, one past
    // the end of the conversation, and one naming the prompt a version 2 file
    // held as the first message.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "odd.json",
        .data = "{\"version\":2,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"s\"}," ++
            "{\"role\":\"user\",\"content\":\"one\"}," ++
            "{\"role\":\"user\",\"content\":\"summary\"}," ++
            "{\"role\":\"user\",\"content\":\"two\"}]," ++
            "\"compactions\":[2,0,2,99]}",
    });

    var session = try reopenTestSession(&tmp, "odd");
    defer session.deinit();

    try std.testing.expectEqualStrings("s", session.pool.get(session.system_prompt).?);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2 }, session.compactions.items);
    try std.testing.expectEqual(2, session.sentFrom());
    try std.testing.expect(session.isCompaction(1));
}

test "the messages a request carries start at the latest compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "old" });
    // Two compactions: a request starts at the later summary, not the earlier.
    try session.appendCompaction("p1", "summary one");
    try session.append(.{ .role = .user, .content = "middle" });
    try session.appendCompaction("p2", "summary two");
    try session.append(.{ .role = .user, .content = "latest" });

    // The system prompt, then the latest summary and the prompt after it: the
    // first compaction and everything before it is left out.
    try expectRequestJson(&session, &.{}, "[{\"role\":\"system\",\"content\":\"s\"}," ++
        "{\"role\":\"user\",\"content\":\"summary two\"}," ++
        "{\"role\":\"user\",\"content\":\"latest\"}]");
}

test "the system prompt is kept apart from the conversation and is not replaced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    // Setting the prompt does not put a message in the conversation: it is its own
    // field, sent at the front of every request.
    try session.setSystemPrompt("current prompt");
    try std.testing.expect(session.hasSystemPrompt());
    try std.testing.expectEqualStrings("current prompt", session.pool.get(session.system_prompt).?);
    try std.testing.expectEqual(0, session.messages.items.len);

    // A session that already has one keeps it, which is what a resume relies on.
    try session.append(.{ .role = .user, .content = "hi" });
    try session.ensureSystemPrompt("a different prompt");
    try std.testing.expectEqualStrings("current prompt", session.pool.get(session.system_prompt).?);
    try std.testing.expectEqual(1, session.messages.items.len);

    // Setting it outright replaces it, which is what a compaction does.
    try session.setSystemPrompt("a different prompt");
    try std.testing.expectEqualStrings("a different prompt", session.pool.get(session.system_prompt).?);
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

    var session = try newTestSession(&tmp);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tools = [_]Definition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = "{}",
    }};

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.ensureTools(&tools);
    try std.testing.expectEqual(1, session.tools.len);
    try std.testing.expectEqualStrings("read", session.pool.get(session.tools[0].name).?);

    // The tools are held in memory until the session's first message, which is
    // what writes the session out.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, session.name(), .{}),
    );
    try session.append(.{ .role = .user, .content = "hi" });

    // The stored tools survive a save and resume.
    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqualStrings("read", resumed.pool.get(resumed.tools[0].name).?);
    try std.testing.expectEqualStrings("Read a file.", resumed.pool.get(resumed.tools[0].description).?);

    // A session that already has tools keeps them, rather than taking a new set.
    const replaced = [_]Definition{.{
        .name = "bash",
        .description = "Run a command.",
        .parameters = "{}",
    }};
    var reopened = try reopenTestSession(&tmp, session.id());
    defer reopened.deinit();
    try reopened.ensureTools(&replaced);
    try std.testing.expectEqual(1, reopened.tools.len);
    try std.testing.expectEqualStrings("read", reopened.pool.get(reopened.tools[0].name).?);
}

test "a session saved without tools loads with none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sessions saved before the tools were stored have no tools field.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "legacy.json",
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var session = try reopenTestSession(&tmp, "legacy");
    defer session.deinit();
    try std.testing.expectEqual(0, session.tools.len);
}

test "the token totals survive a save and resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    session.recordUsage(.{
        .prompt_tokens = 100,
        .completion_tokens = 10,
        .total_tokens = 110,
        .cache_hit_tokens = 90,
        .cache_miss_tokens = 10,
    }, 0.0001);
    try session.append(.{ .role = .user, .content = "hi" });
    // A second request adds to the totals rather than replacing them.
    session.recordUsage(.{
        .prompt_tokens = 200,
        .completion_tokens = 20,
        .total_tokens = 220,
        .cache_hit_tokens = 180,
        .cache_miss_tokens = 20,
    }, 0.0002);
    try session.append(.{ .role = .assistant, .content = "hello" });

    var resumed = try reopenTestSession(&tmp, session.id());
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.SessionNotFound,
        reopenTestSession(&tmp, "nope"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "{" });
    try std.testing.expectError(
        error.CorruptSession,
        reopenTestSession(&tmp, "bad"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "future.json", .data = "{\"version\":99}" });
    try std.testing.expectError(
        error.UnsupportedSessionVersion,
        reopenTestSession(&tmp, "future"),
    );
}

test "a new session does not reuse an id whose file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try newTestSession(&tmp);
    defer first.deinit();
    try first.append(.{ .role = .user, .content = "keep me" });

    var second = try newTestSession(&tmp);
    defer second.deinit();
    try second.append(.{ .role = .user, .content = "and me" });

    try std.testing.expect(!std.mem.eql(u8, first.id(), second.id()));

    var resumed = try reopenTestSession(&tmp, first.id());
    defer resumed.deinit();

    try std.testing.expectEqualStrings("keep me", resumed.pool.get(resumed.messages.items[0].content).?);
}

test "the working directory is stored and restored on resume" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session started in one directory.
    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/home/user/project");
    defer session.deinit();
    try std.testing.expectEqualStrings("/home/user/project", session.cwd());
    try session.append(.{ .role = .user, .content = "hello" });

    // Resumed from somewhere else, it keeps the directory it was started in.
    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, session.id(), "/somewhere/else");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("/home/user/project", resumed.cwd());
}

test "a session saved before the directory was recorded uses the run's own" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written before the field existed, with no `cwd`.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "old" ++ extension,
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, "old", "/now/here");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("/now/here", resumed.cwd());
}

test "a resumed session frees everything it read back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file big enough that holding its bytes for the run would show: writing
    // and resuming it here runs under the testing gpa, which reports any
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

    var resumed = try reopenTestSession(&tmp, "big");
    defer resumed.deinit();
    try std.testing.expectEqual(2000, resumed.messages.items.len);
    try std.testing.expectEqualStrings("/work", resumed.cwd());
}

test "the id and file name read back from their fixed buffers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session with a short name typed on the command line, shorter than a
    // generated id, so the NUL that ends it is what sets its length.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dev" ++ extension,
        .data = "{\"version\":1,\"messages\":[]}",
    });
    var resumed = try reopenTestSession(&tmp, "dev");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("dev", resumed.id());
    try std.testing.expectEqualStrings("dev" ++ extension, resumed.name());

    // A new session gets a generated ULID of its own.
    var fresh = try newTestSession(&tmp);
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
