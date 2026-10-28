//! Sessions: the conversation persisted under the XDG data directory so that a later run can pick
//! up where the previous one stopped.

const std = @import("std");

const llm = @import("llm.zig");
const Pool = @import("Pool.zig");
const ulid = @import("ulid.zig");

const Session = @This();

const extension = ".json";

const max_id_len = 64;

const interrupted_result = "Error: the tool call was interrupted before it produced a result.";

const StoredTool = struct {
    type: []const u8 = "function",
    function: Function,

    const Function = struct {
        name: []const u8 = "",
        description: []const u8 = "",
        parameters: std.json.Value = .null,
    };
};

const Stored = struct {
    version: u32 = 3,
    title: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    messages: []const llm.Message = &.{},
    compactions: []const u32 = &.{},
    tools: []const StoredTool = &.{},
    context_tokens: usize = 0,
    cwd: ?[]const u8 = null,

    const default = Stored{};
};

const StringIndex = Pool.Index;

const Interned = struct {
    id: StringIndex = .none,
    name: StringIndex = .none,
    cwd: StringIndex = .none,
    system_prompt: StringIndex = .none,
    title: StringIndex = .none,
    model: StringIndex = .none,
};

const ToolCallIndex = struct {
    start: u32,
    len: u32,

    const empty = ToolCallIndex{ .start = 0, .len = 0 };

    fn resolve(tool_calls: ToolCallIndex, session: *const Session) []const ToolCall {
        return session.tool_calls.items[tool_calls.start..][0..tool_calls.len];
    }
};

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

pub const Message = struct {
    role: llm.Role,
    content: StringIndex = .none,
    tool_call_id: StringIndex = .none,
    reasoning: StringIndex = .none,
    tool_calls: ToolCallIndex = .empty,

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

pub const StoredDefinition = struct {
    name: StringIndex,
    description: StringIndex,
    parameters: StringIndex,
};

pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

io: std.Io,

dir: std.Io.Dir,

gpa: std.mem.Allocator,

pool: Pool = .{},

interned: Interned = .{},

tool_calls: std.ArrayList(ToolCall) = .empty,

messages: std.ArrayList(Message) = .empty,

compactions: std.ArrayList(u32) = .empty,

tools: []const StoredDefinition = &.{},

context_tokens: usize = 0,

pub fn open(
    io: std.Io,
    dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    resume_id: ?[]const u8,
    start_cwd: []const u8,
) !Session {
    var session = try named(io, dir, gpa, resume_id, start_cwd);
    errdefer session.deinit();
    if (resume_id != null) try session.load();
    return session;
}

pub fn create(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, named_id: []const u8, start_cwd: []const u8) !Session {
    return named(io, dir, gpa, named_id, start_cwd);
}

fn named(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, named_id: ?[]const u8, start_cwd: []const u8) !Session {
    var session: Session = .{ .io = io, .dir = dir, .gpa = gpa };
    errdefer session.deinit();

    var id_buf: [max_id_len]u8 = @splat(0);
    const id_text = if (named_id) |given|
        try setCheckedId(&id_buf, given)
    else made: {
        ulid.generate(io, id_buf[0..ulid.length]);
        break :made id_buf[0..ulid.length];
    };
    session.interned.id = try session.pool.intern(gpa, id_text);

    var name_buf: [max_id_len + extension.len]u8 = undefined;
    const file_name = try std.mem.print(&name_buf, "{s}{s}", .{ id_text, extension });
    session.interned.name = try session.pool.intern(gpa, file_name);

    // The session owns its directory rather than pointing into the caller's memory, which it may
    // outlive.
    session.interned.cwd = try session.pool.intern(gpa, start_cwd);
    return session;
}

pub fn deinit(session: *Session) void {
    session.pool.deinit(session.gpa);
    session.tool_calls.deinit(session.gpa);
    session.messages.deinit(session.gpa);
    session.compactions.deinit(session.gpa);
    session.gpa.free(session.tools);
}

pub fn id(session: *const Session) []const u8 {
    return session.pool.get(session.interned.id) orelse "";
}

pub fn name(session: *const Session) []const u8 {
    return session.pool.get(session.interned.name) orelse "";
}

pub fn cwd(session: *const Session) []const u8 {
    return session.pool.get(session.interned.cwd) orelse "";
}

/// The conversation as a completion request carries it: the `messages` array of a request body,
/// written straight out of the pool.
pub const Conversation = struct {
    session: *const Session,
    extra: []const llm.Message = &.{},

    pub fn jsonStringify(self: Conversation, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        if (session.systemPrompt()) |prompt| {
            try json.beginObject();
            try json.objectField("role");
            try json.write("system");
            try json.objectField("content");
            try json.write(prompt);
            try json.endObject();
        }
        for (session.messages.items[session.sentFrom()..]) |message| {
            try session.writeMessage(json, message);
        }
        for (self.extra) |message| try json.write(message);
        try json.endArray();
    }
};

fn writeMessage(session: *const Session, json: anytype, message: Message) !void {
    try json.beginObject();
    try json.objectField("role");
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

    if (session.pool.get(message.reasoning)) |reasoning| {
        try json.objectField("reasoning_content");
        try json.write(reasoning);
    }

    try json.endObject();
}

/// The conversation as a request carries it, for passing to a client without resolving it first.
pub fn conversation(session: *const Session, extra: []const llm.Message) Conversation {
    return .{ .session = session, .extra = extra };
}

/// The first message a compaction leaves out of a request: the summary the last compaction
/// produced, or zero for a conversation that has never been compacted.
pub fn sentFrom(session: *const Session) usize {
    if (session.compactions.items.len == 0) return 0;
    return session.compactions.items[session.compactions.items.len - 1];
}

pub fn isCompaction(session: *const Session, index: usize) bool {
    if (index >= session.messages.items.len) return false;
    const target: u32 = @intCast(index);
    return std.mem.findScalar(u32, session.compactions.items, target) != null;
}

pub fn systemPrompt(session: *const Session) ?[]const u8 {
    return session.pool.get(session.interned.system_prompt);
}

pub fn title(session: *const Session) ?[]const u8 {
    return session.pool.get(session.interned.title);
}

pub fn setTitle(session: *Session, text: []const u8) !void {
    session.interned.title = try session.pool.intern(session.gpa, std.mem.trim(u8, text, " \t\r\n"));
}

pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub fn contentOf(session: *const Session, message: Message) ?[]const u8 {
    return session.pool.get(message.content);
}

pub fn callAt(session: *const Session, message: Message, index: usize) Call {
    const call = message.tool_calls.resolve(session)[index];
    return .{
        .id = session.pool.get(call.id) orelse "",
        .name = session.pool.get(call.function.name) orelse "",
        .arguments = session.pool.get(call.function.arguments) orelse "",
    };
}

pub fn toolResult(session: *const Session, from: usize, call: []const u8) []const u8 {
    const messages = session.messages.items;
    if (from >= messages.len)
        return "";

    for (messages[from..]) |message| {
        if (message.role != .tool) break;
        const call_id = session.pool.get(message.tool_call_id) orelse continue;
        if (std.mem.eql(u8, call_id, call))
            return session.pool.get(message.content) orelse "";
    }

    return "";
}

/// The conversation as plain API messages, every string resolved out of the pool: the system
/// prompt, when there is one, and then the whole conversation.
pub fn resolvedMessages(session: *const Session, allocator: std.mem.Allocator) ![]const llm.Message {
    const lead: usize = if (session.systemPrompt() != null) 1 else 0;
    const messages = try allocator.alloc(llm.Message, lead + session.messages.items.len);
    var out: usize = 0;
    if (session.systemPrompt()) |prompt| {
        messages[0] = .{ .role = .system, .content = prompt };
        out = 1;
    }
    for (session.messages.items) |message| {
        messages[out] = try message.resolve(session, allocator);
        out += 1;
    }
    return messages;
}

/// Adds a message to the conversation, and writes the session out once it is a
/// conversation again: a request can be built from what is on disk, which is what
/// makes the file worth having.
pub fn append(session: *Session, message: llm.Message) !void {
    try session.appendMessage(message);
    // A turn adds the assistant message with the calls it asks for, and then a
    // result for each: between the two the conversation asks for what it has no
    // answer to, which no request can be built from. Writing that state out would
    // leave a file that is only good for `repairTail`, so the file is written
    // where the conversation is whole instead.
    if (session.unanswered() == null) try session.save();
}

/// Adds a compaction to the conversation: the prompt that asked for it and the summary it produced.
pub fn appendCompaction(session: *Session, prompt: []const u8, summary: []const u8) !void {
    try session.appendMessage(.{ .role = .user, .content = prompt });
    const summary_index: u32 = @intCast(session.messages.items.len);
    try session.appendMessage(.{ .role = .user, .content = summary });
    try session.compactions.append(session.gpa, summary_index);
    try session.save();
}

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

/// Records `system_prompt` as what every request opens with, replacing any prompt the session
/// already had.
pub fn setSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    session.interned.system_prompt = try session.pool.intern(session.gpa, system_prompt);
}

pub fn setModel(session: *Session, choice: []const u8) !void {
    session.interned.model = try session.pool.intern(session.gpa, choice);
}

pub fn setCwd(session: *Session, directory: []const u8) !void {
    session.interned.cwd = try session.pool.intern(session.gpa, directory);
}

pub fn model(session: *const Session) ?[]const u8 {
    return session.pool.get(session.interned.model);
}

/// The choice to send the session to: its own model, or `fallback` for a session saved before one
/// was recorded -- the choice billy is configured with, which is where it was being sent anyway.
pub fn modelChoice(session: *const Session, fallback: []const u8) []const u8 {
    return session.model() orelse fallback;
}

pub fn ensureSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    if (session.systemPrompt() != null) return;
    try session.setSystemPrompt(system_prompt);
}

pub fn setTools(session: *Session, definitions: []const Definition) !void {
    const tools = try session.gpa.alloc(StoredDefinition, definitions.len);
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

pub fn ensureTools(session: *Session, definitions: []const Definition) !void {
    if (session.tools.len != 0) return;
    try session.setTools(definitions);
}

/// Remembers how full the context window is: the size of the conversation the last request was
/// sent.
pub fn recordUsage(session: *Session, usage: llm.Usage) void {
    session.context_tokens = usage.total_tokens;
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

    if (session.title()) |stored_title| {
        try json.objectField("title");
        try json.write(stored_title);
    }

    // The directory the session was started in is written here, with the title, because it is the
    // other field something asks a session file for without reading it: `latest` walks the files
    // looking for the one started in this directory, and a field at the end costs every
    // conversation in the store to answer a question about one of them.
    try json.objectField("cwd");
    try json.write(session.cwd());

    if (session.systemPrompt()) |prompt| {
        try json.objectField("system_prompt");
        try json.write(prompt);
    }

    if (session.model()) |recorded| {
        try json.objectField("model");
        try json.write(recorded);
    }

    try json.objectField("messages");
    try json.beginArray();
    for (session.messages.items) |message|
        try session.writeMessage(&json, message);
    try json.endArray();

    try json.objectField("compactions");
    try json.write(session.compactions.items);

    try json.objectField("tools");
    try json.write(session.toolSet());

    try json.objectField("context_tokens");
    try json.write(session.context_tokens);

    try json.endObject();
}

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

    if (stored.model) |stored_model| {
        // An empty field is a file written without one rather than a session sent to no model, so
        // it is left unset and read as the fallback.
        if (stored_model.len > 0) try session.setModel(stored_model);
    }
    session.context_tokens = stored.context_tokens;
    if (stored.cwd) |stored_cwd|
        session.interned.cwd = try session.pool.intern(session.gpa, stored_cwd);
}

fn loadPromptAndMessages(
    session: *Session,
    system_prompt: ?[]const u8,
    messages: []const llm.Message,
) !usize {
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

fn loadCompactions(session: *Session, stored: []const u32, lead: usize) !void {
    if (session.messages.items.len == 0) return;

    const last: u32 = @intCast(session.messages.items.len - 1);
    try session.compactions.ensureTotalCapacity(session.gpa, stored.len);
    for (stored) |stored_index| {
        const index = std.math.sub(u32, stored_index, @intCast(lead)) catch 0;
        // An index past the end names no message to stand in for.
        if (index > last) continue;
        session.compactions.appendAssumeCapacity(index);
    }
    std.mem.sort(u32, session.compactions.items, {}, std.sort.asc(u32));

    var kept: usize = 0;
    for (session.compactions.items) |index| {
        if (kept > 0 and session.compactions.items[kept - 1] == index) continue;
        session.compactions.items[kept] = index;
        kept += 1;
    }
    session.compactions.shrinkRetainingCapacity(kept);
}

fn loadTools(session: *Session, stored: []const StoredTool) !void {
    const tools = try session.gpa.alloc(StoredDefinition, stored.len);
    errdefer session.gpa.free(tools);
    for (stored, tools) |stored_tool, *tool| {
        tool.* = .{
            .name = try session.pool.intern(session.gpa, stored_tool.function.name),
            .description = try session.pool.intern(session.gpa, stored_tool.function.description),
            .parameters = try session.internParameters(stored_tool.function.parameters),
        };
    }
    session.tools = tools;
}

fn repairTail(session: *Session) !void {
    const hole = session.unanswered() orelse return;
    const tail = hole.tail;
    const calls = hole.calls;
    const answered = hole.answered;

    // The calls with no result are answered right after the results the file holds, in the order
    // the calls were made, so the assistant message is followed by one result per call.
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

    // A compaction records where its summary sits by index, and the answers push every message from
    // `at` on along, so a summary at or past `at` moves with them.
    for (session.compactions.items) |*index| {
        if (index.* >= at) index.* += @intCast(missing);
    }
}

/// The calls of the last assistant message that have no result yet, and where
/// that message is: null when every call it made has been answered, which is the
/// one state a request can be built from.
fn unanswered(session: *const Session) ?Hole {
    const tail = session.lastCall() orelse return null;
    const calls = session.messages.items[tail].tool_calls.len;

    var answered: usize = 0;
    for (session.messages.items[tail + 1 ..]) |message| {
        if (message.role != .tool) break;
        answered += 1;
    }
    if (answered >= calls) return null;
    return .{ .tail = tail, .calls = calls, .answered = answered };
}

const Hole = struct { tail: usize, calls: usize, answered: usize };

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

/// The tools as JSON: the definitions written out, each with its arguments schema as the JSON text
/// it is held as.
pub const ToolSet = struct {
    session: *const Session,

    pub fn jsonStringify(self: ToolSet, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        for (session.tools) |tool| {
            try json.beginObject();
            try json.objectField("type");
            try json.write("function");
            try json.objectField("function");
            try json.beginObject();
            try json.objectField("name");
            try json.write(session.pool.get(tool.name) orelse "");
            try json.objectField("description");
            try json.write(session.pool.get(tool.description) orelse "");
            try json.objectField("parameters");
            try json.print("{s}", .{session.pool.get(tool.parameters) orelse "{}"});
            try json.endObject();
            try json.endObject();
        }
        try json.endArray();
    }
};

pub fn toolSet(session: *const Session) ToolSet {
    return .{ .session = session };
}

fn setCheckedId(buf: []u8, given: []const u8) ![]const u8 {
    if (given.len + 1 > buf.len) return error.InvalidSessionId;
    if (!usableName(given)) return error.InvalidSessionId;
    @memcpy(buf[0..given.len], given);
    return buf[0..given.len];
}

fn usableName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return !std.mem.allEqual(u8, text, '.');
}

/// The ids of the sessions in the directory `dir`, the one most recently written to first, each
/// with its title.
pub fn list(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]Named {
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);

    return listIn(iter_dir, io, gpa);
}

/// The id of the session in `dir` that was last written to from `start_cwd`, or null when no
/// session was started there.
pub fn latest(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, start_cwd: []const u8) !?[]const u8 {
    const listed = try list(io, dir, gpa);
    defer freeList(listed, gpa);

    for (listed) |listed_session| {
        var name_buf: [max_id_len + extension.len]u8 = undefined;
        const file_name = fileName(listed_session.id, &name_buf) orelse continue;
        var file = dir.openFile(io, file_name, .{}) catch continue;
        defer file.close(io);

        const stored = cwdFrom(io, gpa, file) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A file that cannot be read through is not the session to continue here, and is still
            // one to resume by its id.
            else => continue,
        };
        defer if (stored) |text| gpa.free(text);
        if (stored) |text| {
            if (std.mem.eql(u8, text, start_cwd)) return try gpa.dupe(u8, listed_session.id);
        }
    }
    return null;
}

/// One session as a listing shows it: the id that names it, and its title, which is "" for a
/// session that has not been named.
pub const Named = struct {
    id: []const u8,
    title: []const u8,
};

fn freeList(names: []Named, gpa: std.mem.Allocator) void {
    for (names) |made| {
        gpa.free(made.id);
        gpa.free(made.title);
    }
    gpa.free(names);
}

fn listIn(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) ![]Named {
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
        if (entry.kind != .file) continue;
        const stem = idInName(entry.name) orelse continue;

        var file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;

        const stored_title = readTitle(io, gpa, file) catch |err| switch (err) {
            error.SyntaxError => continue,
            else => return err,
        };
        errdefer gpa.free(stored_title);

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

const title_read_buffer_len = 1024;

fn cwdFrom(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !?[]const u8 {
    var reader_buf: [std.heap.page_size_min]u8 = undefined;
    var reader = file.reader(io, &reader_buf);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var j_reader = std.json.Reader.init(gpa, &reader.interface);
    defer j_reader.deinit();

    if (try j_reader.next() != .object_begin) return null;
    while (true) {
        const key = try j_reader.nextAlloc(arena, .alloc_if_needed);
        const field = switch (key) {
            .object_end => return null,
            .string => |text| text,
            .allocated_string => |text| text,
            else => return null,
        };
        if (std.mem.eql(u8, field, "cwd")) {
            return switch (try j_reader.nextAlloc(gpa, .alloc_always)) {
                // `alloc_always` puts the text in memory of the caller's, which the reader's buffer
                // cannot move under it.
                .allocated_string => |text| text,
                else => null,
            };
        }
        try j_reader.skipValue();
    }
}

fn readTitle(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) ![]const u8 {
    var reader_buf: [std.heap.page_size_min]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    return (try titleFrom(&reader.interface, gpa)) orelse "";
}

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

const Ordering = struct {
    names: []Named,
    written: []i64,

    pub fn lessThan(self: Ordering, a: usize, b: usize) bool {
        if (self.written[a] != self.written[b]) return self.written[a] > self.written[b];
        return std.mem.order(u8, self.names[a].id, self.names[b].id) == .gt;
    }

    pub fn swap(self: Ordering, a: usize, b: usize) void {
        std.mem.swap(Named, &self.names[a], &self.names[b]);
        std.mem.swap(i64, &self.written[a], &self.written[b]);
    }
};

fn fileName(session_id: []const u8, buffer: []u8) ?[]const u8 {
    if (!usableName(session_id)) return null;
    return std.mem.print(buffer, "{s}{s}", .{ session_id, extension }) catch null;
}

/// Deletes the session `id` from `dir`, so it is gone for good: billy keeps no trash.
pub fn delete(io: std.Io, dir: std.Io.Dir, session_id: []const u8) !void {
    var buffer: [max_id_len + extension.len]u8 = undefined;
    const file = fileName(session_id, &buffer) orelse return error.InvalidSessionId;
    dir.deleteFile(io, file) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
}

fn idInName(file_name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, file_name, extension)) return null;
    const stem = file_name[0 .. file_name.len - extension.len];
    if (!usableName(stem)) return null;
    return stem;
}

fn newTestSession(tmp: *std.testing.TmpDir) !Session {
    return Session.open(std.testing.io, tmp.dir, std.testing.allocator, null, "/work");
}

fn reopenTestSession(tmp: *std.testing.TmpDir, session_id: []const u8) !Session {
    return Session.open(std.testing.io, tmp.dir, std.testing.allocator, session_id, "/work");
}

fn expectConvo(expected: []const llm.Message, actual: []const llm.Message) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.role, got.role);
        try std.testing.expectEqualStrings(want.content orelse "", got.content orelse "");
        try std.testing.expectEqualStrings(want.reasoning_content orelse "", got.reasoning_content orelse "");
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

fn freeResolved(gpa: std.mem.Allocator, messages: []const llm.Message) void {
    for (messages) |message| {
        if (message.tool_calls) |calls| gpa.free(calls);
    }
    gpa.free(messages);
}

fn expectSessionConvo(session: *const Session, expected: []const llm.Message) !void {
    const gpa = std.testing.allocator;
    const resolved = try session.resolvedMessages(gpa);
    defer freeResolved(gpa, resolved);
    try expectConvo(expected, resolved);
}

fn expectResume(messages: []const llm.Message) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try resumed.expectSessionConvo(messages);
}

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
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));
}

test "a session can be started for an id that has no file yet" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.create(std.testing.io, tmp.dir, gpa, "made-by-hand", "/work");
    defer session.deinit();
    try std.testing.expectEqualStrings("made-by-hand", session.id());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));

    try session.append(.{ .role = .user, .content = "hello" });
    var resumed = try reopenTestSession(&tmp, "made-by-hand");
    defer resumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), resumed.messages.items.len);
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[0]).?);

    try std.testing.expectError(
        error.InvalidSessionId,
        Session.create(std.testing.io, tmp.dir, gpa, "../escape", "/work"),
    );
}

test "a session is deleted for good, and only that session" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    try std.testing.expectError(error.SessionNotFound, reopenTestSession(&tmp, gone_id));
    try std.testing.expectError(error.SessionNotFound, Session.delete(std.testing.io, tmp.dir, gone_id));

    var still = try reopenTestSession(&tmp, kept_id);
    defer still.deinit();
    try std.testing.expectEqualStrings("keep me", still.contentOf(still.messages.items[0]).?);

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

    try session.setSystemPrompt("be terse");
    try session.ensureTools(&tools);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.name(), .{}));

    try session.append(.{ .role = .user, .content = "hello" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expect(resumed.systemPrompt() != null);
    try std.testing.expectEqualStrings("be terse", resumed.systemPrompt().?);
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.messages.items[0].role.name());
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[0]).?);
}

test "the file only takes a conversation a request can be built from" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "one" });

    // A call with no result is a conversation no request can be built from, so what
    // is on disk stays at the last whole state rather than taking it.
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    var waiting = try reopenTestSession(&tmp, session.id());
    defer waiting.deinit();
    try waiting.expectSessionConvo(&.{.{ .role = .user, .content = "one" }});

    // The result answers it, and the three are written together.
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "the result" });
    var answered = try reopenTestSession(&tmp, session.id());
    defer answered.deinit();
    try answered.expectSessionConvo(&.{
        .{ .role = .user, .content = "one" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "the result" },
    });
}

test "ids made one after another differ" {
    var first: [ulid.length]u8 = undefined;
    var second: [ulid.length]u8 = undefined;
    ulid.generate(std.testing.io, &first);
    ulid.generate(std.testing.io, &second);

    try std.testing.expect(ulid.isId(&first));
    try std.testing.expect(ulid.isId(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

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
    const file_name = try gpa.print("{s}{s}", .{ session_id, extension });
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

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

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

test "the directory a session was started in is written at the front" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setTitle("a name");
    try session.append(.{ .role = .user, .content = "hi" });

    const text = try tmp.dir.readFileAlloc(std.testing.io, session.name(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"version\":3,\"title\":\"a name\",\"cwd\":\"/work\","));
}

test "the latest session for a directory is the one last written there" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const here =
        \\{"version":3,"messages":[{"role":"user","content":"hello \"there\""}],"cwd":"/work"}
    ;
    const elsewhere =
        \\{"version":3,"messages":[],"cwd":"/other"}
    ;
    try writeFileAt(&tmp, gpa, "first", here, 1_000);
    try writeFileAt(&tmp, gpa, "other", elsewhere, 2_000);
    try writeFileAt(&tmp, gpa, "second", here, 3_000);

    const found = (try latest(std.testing.io, tmp.dir, gpa, "/work")).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings("second", found);

    try std.testing.expect(try latest(std.testing.io, tmp.dir, gpa, "/nowhere") == null);
    try writeFileAt(&tmp, gpa, "old", "{\"version\":1}", 4_000);
    const unchanged = (try latest(std.testing.io, tmp.dir, gpa, "/work")).?;
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("second", unchanged);
}

test "the ordering keeps each id with the time it was written at" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Six sessions whose id order and write order run opposite ways, so the sort has to move the
    // times along with the ids rather than reorder one list on its own: the id that was made first
    // is the one written last, and so is the one that comes first in the listing.
    const count = 6;
    var buffers: [count][max_id_len]u8 = undefined;
    for (0..count) |i| {
        const made = buffers[i][0..ulid.length];
        ulid.encode(made, 1_700_000_000_000 + @as(u48, @intCast(i)), @splat(0));
        try writeSessionAt(&tmp, gpa, made, @intCast(1_000 + (count - 1 - i) * 1_000));
    }

    const ids = try listIn(tmp.dir, std.testing.io, std.testing.allocator);
    defer freeList(ids, std.testing.allocator);

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

    // The unreadable file is written between the others, so wherever the directory yields it, some
    // session follows it.
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

test "a title is trimmed when it is set, and kept whole however long" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.setTitle("  Fix the parser\n");
    try std.testing.expectEqualStrings("Fix the parser", session.title().?);

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

    // The title sits right after the version, and the reader stops there rather than reading the
    // rest of the file.
    try expectTitle(gpa, "Fix it", "{\"version\":3,\"title\":\"Fix it\",\"system_prompt\":\"x\"}");
    try expectTitle(gpa, "a \"quoted\" \\ title", "{\"version\":3,\"title\":\"a \\\"quoted\\\" \\\\ title\"}");
    try expectTitle(gpa, "ends with a backslash \\", "{\"version\":3,\"title\":\"ends with a backslash \\\\\",\"messages\":[]}");
    try expectTitle(gpa, "\"", "{\"version\":3,\"title\":\"\\\"\"}");
    try expectTitle(gpa, "", "{\"version\":3,\"title\":\"\",\"messages\":[]}");

    try std.testing.expect((try titleOf(gpa, "{\"version\":3,\"system_prompt\":\"be terse\",\"messages\":[]}")) == null);
    try std.testing.expect((try titleOf(gpa, "{\"version\":3,\"messages\":[]}")) == null);
    try std.testing.expectError(error.SyntaxError, titleOf(gpa, "not json at all"));

    const long_title: [4096]u8 = @splat('y');
    try expectTitle(gpa, &long_title, "{\"version\":3,\"title\":\"" ++ &long_title ++ "\"}");
}

fn titleOf(gpa: std.mem.Allocator, front: []const u8) !?[]u8 {
    var reader: std.Io.Reader = .fixed(front);
    return titleFrom(&reader, gpa);
}

fn expectTitle(gpa: std.mem.Allocator, expected: []const u8, front: []const u8) !void {
    const got = (try titleOf(gpa, front)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "setCheckedId rejects names that could escape the session directory" {
    var buf: [max_id_len]u8 = undefined;

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
    // A name that does not fit, with room for its NUL, is refused rather than cut short: the
    // longest that fits is one byte less than the buffer.
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, &@as([max_id_len + 1]u8, @splat('x'))));
    try std.testing.expectError(error.InvalidSessionId, setCheckedId(&buf, &@as([max_id_len]u8, @splat('x'))));
    _ = try setCheckedId(&buf, &@as([max_id_len - 1]u8, @splat('x')));
}

test "a session survives a save and resume" {
    try expectResume(&.{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .reasoning_content = "I should read the file.", .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
        .{ .role = .assistant, .content = "it is one line", .reasoning_content = "The file is short." },
    });
}

test "a resume answers a tool call a killed run left open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "bash", .arguments = "{}" },
    }} });
    // Written whatever state the conversation is in, which is what an older billy
    // left when a run was killed between a call and its result.
    try session.save();

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try resumed.expectSessionConvo(&.{
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
    try session.append(.{ .role = .user, .content = "still there?" });
    // As an older billy left it: one call answered, one lost, and a line typed after.
    try session.save();

    // The result the file held stays with its call, and the call it lost is answered in the place
    // it was made rather than after the user message.
    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try resumed.expectSessionConvo(&.{
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

    try session.append(.{ .role = .user, .content = "go" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.appendCompaction("summarize this", "the summary");

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();

    // user, the assistant message, its answer, then the prompt and the summary: the summary the
    // file recorded at index 3 moves to 4 with the message it names, so a request still starts at
    // the summary rather than at the prompt.
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

    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{
        .role = .assistant,
        .reasoning_content = "Reading the file.",
        .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }},
    });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" });

    const expected = "[{\"role\":\"system\",\"content\":\"be terse\"}," ++
        "{\"role\":\"user\",\"content\":\"hello\"}," ++
        "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}]," ++
        "\"reasoning_content\":\"Reading the file.\"}," ++
        "{\"role\":\"tool\",\"content\":\"1\\tconst x = 1;\\n\",\"tool_call_id\":\"call_1\"}]";
    try session.expectRequestJson(&.{}, expected);

    // Writing the stored conversation has to give the bytes the resolved one does, field for field
    // and in the same order, or a resumed session would send a request that misses its prompt
    // cache.
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

    const extra = [_]llm.Message{.{ .role = .user, .content = "give it a title" }};
    try session.expectRequestJson(&extra, "[{\"role\":\"system\",\"content\":\"be terse\"}," ++
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

    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "a\x80b\xffc" });

    try session.expectRequestJson(&.{}, "[{\"role\":\"tool\",\"content\":\"a\u{FFFD}b\u{FFFD}c\",\"tool_call_id\":\"call_1\"}]");

    // The repaired text is what the session keeps, so a resume reads it back the same rather than
    // the bytes that could not be sent.
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", session.contentOf(session.messages.items[0]).?);
}

test "a message a session read back with bytes that are not UTF-8 is repaired" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bytes.json",
        .data = "{\"version\":2,\"messages\":[{\"role\":\"tool\"," ++
            "\"content\":[97,255,98],\"tool_call_id\":\"call_1\"}]}",
    });

    var session = try reopenTestSession(&tmp, "bytes");
    defer session.deinit();

    try std.testing.expectEqualStrings("a\u{FFFD}b", session.contentOf(session.messages.items[0]).?);

    // Saving it back writes the content as a string, so the bytes are gone for good and the file is
    // one a later resume reads as text.
    try session.save();
    const text = try tmp.dir.readFileAlloc(std.testing.io, "bytes.json", gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, "[97,255,98]") == null);
    try std.testing.expect(std.mem.find(u8, text, "\"content\":\"a\u{FFFD}b\"") != null);
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

    const user = session.messages.items[0];
    try std.testing.expectEqualStrings("user", user.role.name());
    try std.testing.expectEqualStrings("hello", session.contentOf(user).?);
    try std.testing.expectEqual(0, user.tool_calls.len);

    const assistant = session.messages.items[1];
    try std.testing.expectEqualStrings("assistant", assistant.role.name());
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

    try std.testing.expectEqualStrings("the result", session.toolResult(1, "call_1"));
    try std.testing.expectEqualStrings("", session.toolResult(2, "call_1"));
    try std.testing.expectEqualStrings("an earlier result", session.toolResult(2, "old"));
    try std.testing.expectEqualStrings("", session.toolResult(1, "nothing"));
    try std.testing.expectEqualStrings("", session.toolResult(99, "call_1"));
}

test "a result is not taken from a later turn that reuses the call id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_0",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.append(.{ .role = .user, .content = "next" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_0",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_0", .content = "second result" });

    try std.testing.expectEqualStrings("", session.toolResult(1, "call_0"));
    try std.testing.expectEqualStrings("second result", session.toolResult(3, "call_0"));
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

    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try expected.writer.print("{s}\x00{s}\x00/work\x00", .{ session.id(), session.name() });
    try expected.writer.writeAll(
        "hello\x00hello\x00call_1\x00function\x00read\x00{}\x00" ++
            "call_1\x00function\x00read\x00[]\x00",
    );
    try std.testing.expectEqualStrings(expected.written(), session.pool.strings.items);
    try std.testing.expectEqualStrings("hello", session.contentOf(session.messages.items[0]).?);
    try std.testing.expectEqualStrings("hello", session.contentOf(session.messages.items[1]).?);
    const calls = session.messages.items[2].tool_calls.resolve(&session);
    try std.testing.expectEqualStrings("{}", session.pool.get(calls[0].function.arguments).?);
    try std.testing.expectEqualStrings("[]", session.pool.get(calls[1].function.arguments).?);
}

test "a version 2 file's system prompt is lifted into its own field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "one.json",
        .data = "{\"version\":2,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"old prompt\"}," ++
            "{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var resumed = try reopenTestSession(&tmp, "one");
    defer resumed.deinit();

    try std.testing.expectEqualStrings("old prompt", resumed.systemPrompt().?);
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.messages.items[0].role.name());
    try std.testing.expectEqualStrings("hi", resumed.contentOf(resumed.messages.items[0]).?);

    try resumed.ensureSystemPrompt("new prompt");
    try std.testing.expectEqualStrings("old prompt", resumed.systemPrompt().?);
}

test "a compaction is appended and a request starts at its summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .content = "first answer" });
    try std.testing.expectEqual(0, session.sentFrom());

    try session.appendCompaction("summarize this", "what happened so far");
    try std.testing.expectEqual(4, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.messages.items[2].role.name());
    try std.testing.expectEqualStrings("summarize this", session.contentOf(session.messages.items[2]).?);
    try std.testing.expectEqualStrings("user", session.messages.items[3].role.name());
    try std.testing.expectEqualStrings("what happened so far", session.contentOf(session.messages.items[3]).?);

    try std.testing.expectEqual(3, session.sentFrom());
    try std.testing.expect(session.isCompaction(3));
    try std.testing.expect(!session.isCompaction(2));
    try std.testing.expect(!session.isCompaction(1));
    try std.testing.expect(!session.isCompaction(99));

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

    try std.testing.expectEqualStrings("be terse", resumed.systemPrompt().?);
    try std.testing.expectEqual(4, resumed.messages.items.len);
    try std.testing.expectEqual(2, resumed.sentFrom());
    try std.testing.expectEqualStrings("the summary", resumed.pool.get(resumed.messages.items[2].content).?);
    try std.testing.expectEqualStrings("next", resumed.pool.get(resumed.messages.items[3].content).?);
}

test "the compaction list is sorted, deduplicated and dropped where it names nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    try std.testing.expectEqualStrings("s", session.systemPrompt().?);
    // 99 is past the end and dropped, not moved onto the last message, where it would have read as
    // a summary of "two"; the two 2s name one compaction.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, session.compactions.items);
    try std.testing.expectEqual(1, session.sentFrom());
    try std.testing.expect(session.isCompaction(1));
    try std.testing.expect(!session.isCompaction(2));
}

test "compactions in a file with no messages are dropped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "empty.json",
        .data = "{\"version\":3,\"messages\":[],\"compactions\":[0,5]}",
    });

    var session = try reopenTestSession(&tmp, "empty");
    defer session.deinit();
    try std.testing.expectEqual(0, session.messages.items.len);
    try std.testing.expectEqual(0, session.compactions.items.len);
    try std.testing.expectEqual(0, session.sentFrom());
}

fn openOnce(gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
    var session = try Session.open(std.testing.io, dir, gpa, "tools", "/work");
    session.deinit();
}

test "a session that fails part way through reading its tools frees what it took" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tools.json",
        .data = "{\"version\":3,\"tools\":[" ++
            "{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"}}}," ++
            "{\"type\":\"function\",\"function\":{\"name\":\"write\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"}}}]," ++
            "\"messages\":[]}",
    });

    try std.testing.checkAllAllocationFailures(std.testing.allocator, openOnce, .{tmp.dir});
}

test "the messages a request carries start at the latest compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "old" });
    try session.appendCompaction("p1", "summary one");
    try session.append(.{ .role = .user, .content = "middle" });
    try session.appendCompaction("p2", "summary two");
    try session.append(.{ .role = .user, .content = "latest" });

    try session.expectRequestJson(&.{}, "[{\"role\":\"system\",\"content\":\"s\"}," ++
        "{\"role\":\"user\",\"content\":\"summary two\"}," ++
        "{\"role\":\"user\",\"content\":\"latest\"}]");
}

test "the system prompt is kept apart from the conversation and is not replaced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.setSystemPrompt("current prompt");
    try std.testing.expect(session.systemPrompt() != null);
    try std.testing.expectEqualStrings("current prompt", session.systemPrompt().?);
    try std.testing.expectEqual(0, session.messages.items.len);

    try session.append(.{ .role = .user, .content = "hi" });
    try session.ensureSystemPrompt("a different prompt");
    try std.testing.expectEqualStrings("current prompt", session.systemPrompt().?);
    try std.testing.expectEqual(1, session.messages.items.len);

    try session.setSystemPrompt("a different prompt");
    try std.testing.expectEqualStrings("a different prompt", session.systemPrompt().?);
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

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, session.name(), .{}),
    );
    try session.append(.{ .role = .user, .content = "hi" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.len);
    try std.testing.expectEqualStrings("read", resumed.pool.get(resumed.tools[0].name).?);
    try std.testing.expectEqualStrings("Read a file.", resumed.pool.get(resumed.tools[0].description).?);

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

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "legacy.json",
        .data = "{\"version\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    });

    var session = try reopenTestSession(&tmp, "legacy");
    defer session.deinit();
    try std.testing.expectEqual(0, session.tools.len);
}

test "the context size survives a save and resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    session.recordUsage(.{ .prompt_tokens = 100, .completion_tokens = 10, .total_tokens = 110 });
    try session.append(.{ .role = .user, .content = "hi" });
    session.recordUsage(.{ .prompt_tokens = 200, .completion_tokens = 20, .total_tokens = 220 });
    try session.append(.{ .role = .assistant, .content = "hello" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();

    try std.testing.expectEqual(220, resumed.context_tokens);
}

test "the provider and model a session was started on are saved and resumed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try std.testing.expect(session.model() == null);
    try session.setModel("opencode-go/glm-5.3-flash");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .content = "hi" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();

    // The resumed session keeps the provider and model it was started on rather than following
    // whatever the configuration now says, since the conversation belongs to the model that
    // produced it.
    try std.testing.expect(resumed.model() != null);
    try std.testing.expectEqualStrings("opencode-go/glm-5.3-flash", resumed.modelChoice("deepseek/deepseek-flash"));
}

test "a session with no recorded model is read as the configured one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", session.modelChoice("deepseek/deepseek-flash"));

    try session.append(.{ .role = .user, .content = "hi" });
    const file = try tmp.dir.readFileAlloc(std.testing.io, session.name(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file);
    try std.testing.expect(std.mem.find(u8, file, "\"model\"") == null);
}

test "a session file written with an empty model reads as the configured one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_id = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = session_id ++ ".json",
        .data = "{\"version\":3,\"title\":null,\"system_prompt\":null,\"mode\":\"general\"," ++
            "\"model\":\"\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]," ++
            "\"compactions\":[],\"tools\":[],\"context_tokens\":0,\"cwd\":\"/work\"}",
    });

    var resumed = try reopenTestSession(&tmp, session_id);
    defer resumed.deinit();
    try std.testing.expect(resumed.model() == null);
    try std.testing.expectEqualStrings(
        "opencode-go/glm-5.3-flash",
        resumed.modelChoice("opencode-go/glm-5.3-flash"),
    );
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

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/home/user/project");
    defer session.deinit();
    try std.testing.expectEqualStrings("/home/user/project", session.cwd());
    try session.append(.{ .role = .user, .content = "hello" });

    var resumed = try Session.open(std.testing.io, tmp.dir, gpa, session.id(), "/somewhere/else");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("/home/user/project", resumed.cwd());
}

test "a session saved before the directory was recorded uses the run's own" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    // A file big enough that holding its bytes for the run would show: writing and resuming it here
    // runs under the testing gpa, which reports any allocation left behind, so this passing means
    // the file it read and the parse of it were both freed by `deinit`.
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

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dev" ++ extension,
        .data = "{\"version\":1,\"messages\":[]}",
    });
    var resumed = try reopenTestSession(&tmp, "dev");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("dev", resumed.id());
    try std.testing.expectEqualStrings("dev" ++ extension, resumed.name());

    var fresh = try newTestSession(&tmp);
    defer fresh.deinit();
    try std.testing.expectEqual(ulid.length, fresh.id().len);
    try std.testing.expect(ulid.isId(fresh.id()));
    try std.testing.expect(std.mem.endsWith(u8, fresh.name(), extension));
    try std.testing.expectEqualStrings(
        fresh.id(),
        fresh.name()[0 .. fresh.name().len - extension.len],
    );
}
