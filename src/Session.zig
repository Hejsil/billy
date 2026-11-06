//! Sessions: the conversation kept under the XDG data directory for a later run to pick up.

const std = @import("std");

const llm = @import("llm.zig");
const Pool = @import("Pool.zig");
const store = @import("store.zig");
const ulid = @import("ulid.zig");

const Session = @This();

const max_id_len = 64;

const interrupted_result = "Error: the tool call was interrupted before it produced a result.";

const Interned = struct {
    id: Pool.Index = .none,
    cwd: Pool.Index = .none,
    system_prompt: Pool.Index = .none,
    title: Pool.Index = .none,
    model: Pool.Index = .none,
};

const ToolCallIndex = extern struct {
    start: u32,
    len: u32,

    const empty = ToolCallIndex{ .start = 0, .len = 0 };

    fn resolve(tool_calls: ToolCallIndex, session: *const Session) []const ToolCall {
        return session.tool_calls.items[tool_calls.start..][0..tool_calls.len];
    }
};

const ToolCall = extern struct {
    id: Pool.Index,
    type: Pool.Index,
    function: Function,

    const Function = extern struct {
        name: Pool.Index,
        arguments: Pool.Index,
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

pub const Message = extern struct {
    role: llm.Role,
    content: Pool.Index = .none,
    tool_call_id: Pool.Index = .none,
    reasoning: Pool.Index = .none,
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

pub const Tool = extern struct {
    name: Pool.Index,
    description: Pool.Index,
    parameters: Pool.Index,
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
tools: std.ArrayList(Tool) = .empty,
context_tokens: u64 = 0,

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
    return try named(io, dir, gpa, named_id, start_cwd);
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
    // The id goes in first, so it is the pool's first string: the one place a file need not name.
    session.interned.id = try session.pool.intern(gpa, id_text);

    // The session owns its directory rather than pointing into memory it may outlive.
    session.interned.cwd = try session.pool.intern(gpa, start_cwd);
    return session;
}

pub fn deinit(session: *Session) void {
    session.pool.deinit(session.gpa);
    session.tool_calls.deinit(session.gpa);
    session.messages.deinit(session.gpa);
    session.compactions.deinit(session.gpa);
    session.tools.deinit(session.gpa);
}

pub fn id(session: *const Session) []const u8 {
    return session.pool.get(session.interned.id) orelse "";
}

pub fn cwd(session: *const Session) []const u8 {
    return session.pool.get(session.interned.cwd) orelse "";
}

/// The conversation as a request carries it: its `messages`, written straight out of the pool.
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

/// Where a request starts: the summary the last compaction produced, or zero if there was none.
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

/// The conversation as plain API messages, resolved out of the pool, the system prompt first.
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

/// Adds a message, and writes the session out once a request could be built from what is on disk.
pub fn append(session: *Session, message: llm.Message) !void {
    try session.appendMessage(message);
    // A turn adds the calls, then a result for each: between the two no request can be built, so
    // the file waits for where the conversation is whole.
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

/// Records `system_prompt` as what every request opens with, in place of any prompt it had.
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

/// The choice to send the session to: its own model, or `fallback` for one saved without it.
pub fn modelChoice(session: *const Session, fallback: []const u8) []const u8 {
    return session.model() orelse fallback;
}

pub fn ensureSystemPrompt(session: *Session, system_prompt: []const u8) !void {
    if (session.systemPrompt() != null) return;
    try session.setSystemPrompt(system_prompt);
}

pub fn setTools(session: *Session, definitions: []const Definition) !void {
    try session.tools.ensureTotalCapacity(session.gpa, definitions.len);
    session.tools.shrinkRetainingCapacity(0);

    for (definitions) |definition| {
        session.tools.appendAssumeCapacity(.{
            .name = try session.pool.intern(session.gpa, definition.name),
            .description = try session.pool.intern(session.gpa, definition.description),
            .parameters = try session.pool.intern(session.gpa, definition.parameters),
        });
    }
}

pub fn ensureTools(session: *Session, definitions: []const Definition) !void {
    if (session.tools.items.len != 0) return;
    try session.setTools(definitions);
}

/// Remembers how full the context window is: the size of the conversation last sent.
pub fn recordUsage(session: *Session, usage: llm.Usage) void {
    session.context_tokens = usage.total_tokens;
}

pub fn save(session: *const Session) !void {
    var atomic = try session.dir.createFileAtomic(session.io, session.id(), .{
        .replace = true,
    });
    defer atomic.deinit(session.io);

    var file_buf: [std.heap.page_size_min]u8 = undefined;
    var file_writer = atomic.file.writer(session.io, &file_buf);

    try session.write(&file_writer.interface);
    try file_writer.flush();
    try atomic.replace(session.io);
}

// ---------------------------------------------------------------- the file itself

const magic = "BILLYSSN";

/// This version of the format, which is the layout below: a file of another one is not read.
const format_version: u32 = 1;

/// What a file says of itself before the blocks it counts: how long each of them is, where the
/// strings a listing shows sit, and how long it is.
const Header = extern struct {
    magic: [magic.len]u8 = magic.*,
    version: u32 = format_version,
    header_len: u32 = @sizeOf(Header),
    context_tokens: u64 = 0,
    strings_len: u64 = 0,
    tools_len: u64 = 0,
    messages_len: u64 = 0,
    tool_calls_len: u64 = 0,
    compactions_len: u64 = 0,
    file_len: u64 = 0,
    title: Pool.Index = .none,
    system_prompt: Pool.Index = .none,
    model: Pool.Index = .none,
    cwd: Pool.Index = .none,
    /// Held at nothing: a header with a gap would write the gap, which is a stack's bytes, not ours.
    reserved: u64 = 0,

    fn bodyLen(header: Header) u64 {
        return header.strings_len +
            header.tools_len * @sizeOf(Tool) +
            header.messages_len * @sizeOf(Message) +
            header.tool_calls_len * @sizeOf(ToolCall) +
            header.compactions_len * @sizeOf(u32);
    }
};

const header_len = @sizeOf(Header);

// A file is the structs a session is held as: what fails here is what says to bump `format_version`.
comptime {
    store.fixedSize(Header, 96);
    store.fixedSize(Tool, 12);
    store.fixedSize(Message, 24);
    store.fixedSize(ToolCall, 16);
    store.fixedPacking(Header);
    store.fixedPacking(Tool);
    store.fixedPacking(Message);
    store.fixedPacking(ToolCall);
    store.fixedOffset(Header, "context_tokens", 16);
    store.fixedOffset(Header, "strings_len", 24);
    store.fixedOffset(Header, "file_len", 64);
    store.fixedOffset(Header, "title", 72);
    store.fixedOffset(Header, "cwd", 84);
    store.fixedOffset(Header, "reserved", 88);
    store.fixedOffset(Message, "role", 0);
    store.fixedOffset(Message, "tool_calls", 16);
}

/// Writes the session as the header and the blocks it counts, each the bytes it is held as.
pub fn write(session: *const Session, writer: *std.Io.Writer) !void {
    var header: Header = .{
        .context_tokens = session.context_tokens,
        .strings_len = session.pool.strings.items.len,
        .tools_len = session.tools.items.len,
        .messages_len = session.messages.items.len,
        .tool_calls_len = session.tool_calls.items.len,
        .compactions_len = session.compactions.items.len,
        .title = session.interned.title,
        .system_prompt = session.interned.system_prompt,
        .model = session.interned.model,
        .cwd = session.interned.cwd,
    };
    header.file_len = header_len + Header.bodyLen(header);

    var blocks = [_][]const u8{
        std.mem.asBytes(&header),
        session.pool.strings.items,
        std.mem.sliceAsBytes(session.tools.items),
        std.mem.sliceAsBytes(session.messages.items),
        std.mem.sliceAsBytes(session.tool_calls.items),
        std.mem.sliceAsBytes(session.compactions.items),
    };
    try writer.writeVecAll(&blocks);
}

/// Reads the session a file holds, block by block, into where the session keeps it.
fn load(session: *Session) !void {
    var name_buf: [max_id_len]u8 = undefined;
    const file_name = fileName(session.id(), &name_buf) orelse return error.InvalidSessionId;
    var file = session.dir.openFile(session.io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer file.close(session.io);

    var read_buf: [store.read_buffer]u8 = undefined;
    var file_reader = file.reader(session.io, &read_buf);
    const reader = &file_reader.interface;

    const header = try readHeader(reader, try file_reader.getSize());
    try session.pool.strings.resize(session.gpa, @intCast(header.strings_len));
    try session.tools.resize(session.gpa, @intCast(header.tools_len));
    try session.messages.resize(session.gpa, @intCast(header.messages_len));
    try session.tool_calls.resize(session.gpa, @intCast(header.tool_calls_len));
    try session.compactions.resize(session.gpa, @intCast(header.compactions_len));

    var blocks = [_][]u8{
        session.pool.strings.items,
        std.mem.sliceAsBytes(session.tools.items),
        std.mem.sliceAsBytes(session.messages.items),
        std.mem.sliceAsBytes(session.tool_calls.items),
        std.mem.sliceAsBytes(session.compactions.items),
    };
    reader.readVecAll(&blocks) catch |err| switch (err) {
        // The header counted this file's length already, so a short block is a file that changed.
        error.EndOfStream => return error.CorruptSession,
        else => |other| return other,
    };

    session.interned.title = header.title;
    session.interned.system_prompt = header.system_prompt;
    session.interned.model = header.model;
    session.interned.cwd = header.cwd;
    session.context_tokens = header.context_tokens;

    try session.checkIndices();
    session.dropCompactionsPastTheEnd();
    try session.repairTail();
}

fn readHeader(reader: *std.Io.Reader, file_len: u64) !Header {
    const bytes = reader.take(header_len) catch return error.CorruptSession;
    return readHeaderBytes(bytes, file_len);
}

/// The header a file opens with, refused when it is of another kind or of a later version.
fn readHeaderBytes(bytes: []const u8, file_len: u64) !Header {
    if (bytes.len < header_len) return error.CorruptSession;

    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..header_len]);
    if (!std.mem.eql(u8, &header.magic, magic)) return error.CorruptSession;
    if (header.header_len != header_len) return error.CorruptSession;
    if (header.version > format_version) return error.UnsupportedSessionVersion;
    // A file says how long it is, so one cut short, or whose counts do not add up, is refused first.
    if (header.file_len != file_len) return error.CorruptSession;
    if (header_len + Header.bodyLen(header) != file_len) return error.CorruptSession;
    return header;
}

/// Whether every message holds a role the API names, read through its backing integer.
fn checkRoles(messages: []const Message) !void {
    for (messages) |*message| {
        const stored: *const u32 = @ptrCast(&message.role);
        if (std.enums.fromInt(llm.Role, stored.*) == null) return error.CorruptSession;
    }
}

/// Whether every index a session holds names a string and every range names tool calls.
fn checkIndices(session: *Session) !void {
    const pool = &session.pool;
    var sound = pool.validateIndicesInStruct(Interned, session.interned);
    for (session.tools.items) |tool| sound = sound and pool.validateIndicesInStruct(Tool, tool);
    for (session.messages.items) |message| {
        sound = sound and pool.validateIndicesInStruct(Message, message);
        const calls = message.tool_calls;
        sound = sound and @as(u64, calls.start) + calls.len <= session.tool_calls.items.len;
    }
    for (session.tool_calls.items) |call| sound = sound and pool.validateIndicesInStruct(ToolCall, call);
    if (!sound) return error.CorruptSession;
    try checkRoles(session.messages.items);
}

/// A compaction names the message it summed up, and one past the last message names none.
fn dropCompactionsPastTheEnd(session: *Session) void {
    var kept: usize = 0;
    for (session.compactions.items) |index| {
        if (index >= session.messages.items.len) continue;
        session.compactions.items[kept] = index;
        kept += 1;
    }
    session.compactions.shrinkRetainingCapacity(kept);
}

fn repairTail(session: *Session) !void {
    const hole = session.unanswered() orelse return;
    const tail = hole.tail;
    const calls = hole.calls;
    const answered = hole.answered;

    // The calls with no result are answered after the results the file holds, in the order made.
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

    // A summary is held by index, and the answers push every message from `at` on, so it moves too.
    for (session.compactions.items) |*index| {
        if (index.* >= at) index.* += @intCast(missing);
    }
}

/// The calls of the last assistant message left without a result, and where it is: null if none.
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

/// The tools as JSON: each definition with its arguments schema as the text it is held as.
pub const ToolSet = struct {
    session: *const Session,

    pub fn jsonStringify(self: ToolSet, json: anytype) !void {
        const session = self.session;
        try json.beginArray();
        for (session.tools.items) |tool| {
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

/// The sessions in `dir`, the one most recently written to first, each with its title.
pub fn list(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]Named {
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);

    return listIn(iter_dir, io, gpa);
}

/// The id of the session last written to from `start_cwd`, or null if none was started there.
pub fn latest(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, start_cwd: []const u8) !?[]const u8 {
    const listed = try list(io, dir, gpa);
    defer freeList(listed, gpa);

    for (listed) |listed_session| {
        var name_buf: [max_id_len]u8 = undefined;
        const file_name = fileName(listed_session.id, &name_buf) orelse continue;
        var file = dir.openFile(io, file_name, .{}) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        const stored = cwdFrom(io, gpa, file, stat.size) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A file that cannot be read through is not the session to continue here.
            else => continue,
        };
        defer if (stored) |text| gpa.free(text);
        if (stored) |text| {
            if (std.mem.eql(u8, text, start_cwd)) return try gpa.dupe(u8, listed_session.id);
        }
    }
    return null;
}

/// One session as a listing shows it: the id that names it and its title, "" until it is named.
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

        const stored_title = readTitle(io, gpa, file, stat.size) catch continue;
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

/// The header of a file, read without what follows it, so a listing costs one small read a file.
fn readHeaderOf(io: std.Io, file: std.Io.File, file_len: u64) !Header {
    var bytes: [header_len]u8 = undefined;
    const read = try file.readPositionalAll(io, &bytes, 0);
    if (read < header_len) return error.CorruptSession;
    return readHeaderBytes(&bytes, file_len);
}

/// The string `index` names, read from the file without reading the rest of the pool.
fn readFieldAt(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File, header: Header, index: Pool.Index) !?[]u8 {
    if (index == .none) return null;
    const start = @backingInt(index);
    if (start >= header.strings_len) return error.CorruptSession;

    // A field comes out of a window the size of a buffer: one longer than that is no title or path.
    var read_buf: [store.read_buffer]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    try file_reader.seekTo(header_len + start);
    const text = file_reader.interface.takeSentinel(0) catch return error.CorruptSession;
    return try gpa.dupe(u8, text);
}

/// The title of the session in `file`, or "" for one that has not been named.
fn readTitle(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File, file_len: u64) ![]const u8 {
    const header = try readHeaderOf(io, file, file_len);
    return (try readFieldAt(io, gpa, file, header, header.title)) orelse try gpa.dupe(u8, "");
}

/// The directory the session in `file` was started in, or null when it does not say.
fn cwdFrom(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File, file_len: u64) !?[]u8 {
    const header = try readHeaderOf(io, file, file_len);
    return readFieldAt(io, gpa, file, header, header.cwd);
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
    if (session_id.len > buffer.len) return null;
    @memcpy(buffer[0..session_id.len], session_id);
    return buffer[0..session_id.len];
}

/// Deletes the session `id` from `dir`, so it is gone for good: billy keeps no trash.
pub fn delete(io: std.Io, dir: std.Io.Dir, session_id: []const u8) !void {
    var buffer: [max_id_len]u8 = undefined;
    const file = fileName(session_id, &buffer) orelse return error.InvalidSessionId;
    dir.deleteFile(io, file) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
}

fn idInName(file_name: []const u8) ?[]const u8 {
    if (!usableName(file_name)) return null;
    return file_name;
}

fn newTestSession(tmp: *std.testing.TmpDir) !Session {
    return try Session.open(std.testing.io, tmp.dir, std.testing.allocator, null, "/work");
}

fn reopenTestSession(tmp: *std.testing.TmpDir, session_id: []const u8) !Session {
    return try Session.open(std.testing.io, tmp.dir, std.testing.allocator, session_id, "/work");
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
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.id(), .{}));
}

test "a session can be started for an id that has no file yet" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.create(std.testing.io, tmp.dir, gpa, "made-by-hand", "/work");
    defer session.deinit();
    try std.testing.expectEqualStrings("made-by-hand", session.id());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.id(), .{}));

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
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, session.id(), .{}));

    try session.append(.{ .role = .user, .content = "hello" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.items.len);
    try std.testing.expect(resumed.systemPrompt() != null);
    try std.testing.expectEqualStrings("be terse", resumed.systemPrompt().?);
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.messages.items[0].role.name());
    try std.testing.expectEqualStrings("hello", resumed.contentOf(resumed.messages.items[0]).?);
}

test "a session written, read and written again is the same bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setTitle("stable");
    try session.setSystemPrompt("be terse");
    try session.setModel("deepseek/deepseek-flash");
    try session.ensureTools(&.{.{ .name = "read", .description = "Read a file.", .parameters = "{}" }});
    session.recordUsage(.{ .total_tokens = 7 });
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "the result" });
    try session.appendCompaction("summarise", "the summary");

    const first = try tmp.dir.readFileAlloc(std.testing.io, session.id(), gpa, .unlimited);
    defer gpa.free(first);

    // A file is what a session is held as, so reading one and writing it back is no change at all.
    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try resumed.save();

    const second = try tmp.dir.readFileAlloc(std.testing.io, session.id(), gpa, .unlimited);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "a session longer than the buffer it is read through is read back whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    // Written in one go, so both blocks are larger than the buffer the file is read through.
    for (0..4000) |_| try session.appendMessage(.{ .role = .user, .content = "a line of the conversation" });
    try session.save();

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(4000, resumed.messages.items.len);
    try std.testing.expectEqualStrings("a line of the conversation", resumed.contentOf(resumed.messages.items[3999]).?);
}

test "a session is written as its own bytes, and its header counts them" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.setTitle("a written session");
    try session.setSystemPrompt("be terse");
    try session.setModel("deepseek/deepseek-flash");
    try session.ensureTools(&.{.{ .name = "read", .description = "Read a file.", .parameters = "{}" }});
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "the result" });

    const written = try tmp.dir.readFileAlloc(std.testing.io, session.id(), gpa, .unlimited);
    defer gpa.free(written);

    // A file says what it is, what version it is and how long it is, so another kind, or a cut
    // short one, is refused before anything is taken out of it.
    const header = try readHeaderBytes(written[0..header_len], written.len);
    try std.testing.expectEqual(format_version, header.version);
    try std.testing.expectEqual(@as(u32, header_len), header.header_len);
    try std.testing.expectEqual(@as(u64, written.len), header.file_len);
    try std.testing.expectEqual(@as(u64, 1), header.tools_len);
    try std.testing.expectEqual(@as(u64, 3), header.messages_len);
    try std.testing.expectEqual(@as(u64, 1), header.tool_calls_len);
    try std.testing.expectEqual(@as(u64, 0), header.compactions_len);

    // The strings follow the header and the four blocks follow them, each the bytes it is held as.
    const strings = session.pool.strings.items;
    try std.testing.expectEqual(@as(u64, strings.len), header.strings_len);
    try std.testing.expectEqualStrings(strings, written[header_len..][0..strings.len]);
    const messages_at = header_len + strings.len + session.tools.items.len * @sizeOf(Tool);
    const messages = std.mem.sliceAsBytes(session.messages.items);
    try std.testing.expectEqualStrings(messages, written[messages_at..][0..messages.len]);
}

test "the file only takes a conversation a request can be built from" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();

    try session.append(.{ .role = .user, .content = "one" });

    // A call with no result is a conversation no request can be built from, so the file stays
    // at the last whole state rather than taking it.
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
    try writeSessionIn(tmp, gpa, session_id, "/work", written_ms);
}

fn writeSessionIn(
    tmp: *std.testing.TmpDir,
    gpa: std.mem.Allocator,
    session_id: []const u8,
    session_cwd: []const u8,
    written_ms: i64,
) !void {
    var session = try Session.create(std.testing.io, tmp.dir, gpa, session_id, session_cwd);
    defer session.deinit();
    try session.append(.{ .role = .user, .content = "hi" });
    try session.save();
    try tmp.dir.setTimestamps(std.testing.io, session_id, .{
        .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(
            @as(i96, written_ms) * std.time.ns_per_ms,
        ) },
    });
}

fn writeRawAt(
    tmp: *std.testing.TmpDir,
    gpa: std.mem.Allocator,
    session_id: []const u8,
    data: []const u8,
    written_ms: i64,
) !void {
    _ = gpa;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = session_id, .data = data });
    try tmp.dir.setTimestamps(std.testing.io, session_id, .{
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad name", .data = "x" });
    try tmp.dir.createDirPath(std.testing.io, "a-directory");

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

    const text = try tmp.dir.readFileAlloc(std.testing.io, session.id(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);

    // The header says where the directory sits in the pool, and the directory itself follows it.
    const header = try readHeaderBytes(text[0..header_len], text.len);
    const stored = try readFieldAt(std.testing.io, std.testing.allocator, try tmp.dir.openFile(std.testing.io, session.id(), .{}), header, header.cwd);
    defer if (stored) |dir| std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/work", stored.?);
}

test "the latest session for a directory is the one last written there" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeSessionIn(&tmp, gpa, "first", "/work", 1_000);
    try writeSessionIn(&tmp, gpa, "other", "/other", 2_000);
    try writeSessionIn(&tmp, gpa, "second", "/work", 3_000);

    const found = (try latest(std.testing.io, tmp.dir, gpa, "/work")).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings("second", found);

    try std.testing.expect(try latest(std.testing.io, tmp.dir, gpa, "/nowhere") == null);
    var truncated: [header_len - 1]u8 = @splat(0);
    try writeRawAt(&tmp, gpa, "old", &truncated, 4_000);
    _ = &truncated;
    const unchanged = (try latest(std.testing.io, tmp.dir, gpa, "/work")).?;
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("second", unchanged);
}

test "the ordering keeps each id with the time it was written at" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Six sessions whose id order and write order run opposite ways, so the sort has to carry the
    // times along with the ids rather than reorder one list on its own.
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

    // The unreadable file is written between the others, so a session follows it wherever it comes.
    try writeSessionAt(&tmp, gpa, "a", 1_000);
    try writeSessionAt(&tmp, gpa, "b", 2_000);
    try writeRawAt(&tmp, gpa, "broken", "not a session at all", 3_000);
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

    const long_title: [4096]u8 = @splat('y');
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

test "a title is read from the header of the file, and is not the whole of it" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var unnamed = try newTestSession(&tmp);
    defer unnamed.deinit();
    try unnamed.append(.{ .role = .user, .content = "hi" });
    // A session that has not been named has no title in its file at all.
    try std.testing.expect((try titleOfFile(&tmp, gpa, unnamed.id())) == null);

    var titled = try newTestSession(&tmp);
    defer titled.deinit();
    try titled.setTitle("a \"quoted\" \\ title");
    try titled.append(.{ .role = .user, .content = "hi" });
    const read = (try titleOfFile(&tmp, gpa, titled.id())).?;
    defer gpa.free(read);
    try std.testing.expectEqualStrings("a \"quoted\" \\ title", read);

    // A file that is not a session is not read as one.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-session", .data = "not a session at all" });
    try std.testing.expectError(error.CorruptSession, titleOfFile(&tmp, gpa, "not-a-session"));
}

fn titleOfFile(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator, session_id: []const u8) !?[]u8 {
    var file = try tmp.dir.openFile(std.testing.io, session_id, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    const header = try readHeaderOf(std.testing.io, file, stat.size);
    return try readFieldAt(std.testing.io, gpa, file, header, header.title);
}

test "a listing and the latest session are read from the header alone" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.create(std.testing.io, tmp.dir, gpa, "listed", "/work");
    defer session.deinit();
    try session.setTitle("a listed session");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.save();

    // A role no request could carry: opening refuses the file, so a listing that still shows its
    // title has read nothing past the header.
    const written = try tmp.dir.readFileAlloc(std.testing.io, "listed", gpa, .unlimited);
    defer gpa.free(written);
    var patched = try gpa.dupe(u8, written);
    defer gpa.free(patched);
    const messages_at = header_len + session.pool.strings.items.len + session.tools.items.len * @sizeOf(Tool);
    std.mem.writeInt(u32, patched[messages_at..][0..4], 99, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "listed", .data = patched });

    const listed = try Session.list(std.testing.io, tmp.dir, gpa);
    defer freeList(listed, gpa);
    try std.testing.expectEqual(1, listed.len);
    try std.testing.expectEqualStrings("listed", listed[0].id);
    try std.testing.expectEqualStrings("a listed session", listed[0].title);

    const resumed_here = (try Session.latest(std.testing.io, tmp.dir, gpa, "/work")).?;
    defer gpa.free(resumed_here);
    try std.testing.expectEqualStrings("listed", resumed_here);

    try std.testing.expectError(error.CorruptSession, reopenTestSession(&tmp, "listed"));
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

    // The summary the file recorded at index 3 moves to 4 with the message it names, so a request
    // still starts at the summary rather than at the prompt that asked for it.
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

    // The stored conversation has to write the bytes the resolved one does, or a resumed session
    // would send a request that misses its prompt cache.
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

    // The repaired text is what the session keeps, so a resume reads back what could be sent.
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", session.contentOf(session.messages.items[0]).?);
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
    try expected.writer.print("{s}\x00/work\x00", .{session.id()});
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

test "a compaction that names no message is dropped when the file is read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.append(.{ .role = .user, .content = "one" });
    try session.setSystemPrompt("s");
    try session.appendCompaction("ask", "the summary");
    try std.testing.expectEqual(1, session.compactions.items.len);

    // The last four bytes are the compaction's index: 99 names no message, so it is dropped.
    const written = try tmp.dir.readFileAlloc(std.testing.io, session.id(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    var patched = try std.testing.allocator.dupe(u8, written);
    defer std.testing.allocator.free(patched);
    std.mem.writeInt(u32, patched[patched.len - 4 ..][0..4], 99, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "far-off", .data = patched });

    var resumed = try reopenTestSession(&tmp, "far-off");
    defer resumed.deinit();
    try std.testing.expectEqual(0, resumed.compactions.items.len);
    try std.testing.expectEqual(0, resumed.sentFrom());
}

fn openOnce(gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
    var session = try Session.open(std.testing.io, dir, gpa, "tools", "/work");
    session.deinit();
}

test "a session that fails part way through reading its tools frees what it took" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.create(std.testing.io, tmp.dir, std.testing.allocator, "tools", "/work");
    defer session.deinit();
    try session.setTools(&.{
        .{ .name = "read", .description = "d", .parameters = "{\"type\":\"object\"}" },
        .{ .name = "write", .description = "d", .parameters = "{\"type\":\"object\"}" },
    });
    try session.append(.{ .role = .user, .content = "hi" });
    try session.save();

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
    try std.testing.expectEqual(1, session.tools.items.len);
    try std.testing.expectEqualStrings("read", session.pool.get(session.tools.items[0].name).?);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, session.id(), .{}),
    );
    try session.append(.{ .role = .user, .content = "hi" });

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(1, resumed.tools.items.len);
    try std.testing.expectEqualStrings("read", resumed.pool.get(resumed.tools.items[0].name).?);
    try std.testing.expectEqualStrings("Read a file.", resumed.pool.get(resumed.tools.items[0].description).?);

    const replaced = [_]Definition{.{
        .name = "bash",
        .description = "Run a command.",
        .parameters = "{}",
    }};
    var reopened = try reopenTestSession(&tmp, session.id());
    defer reopened.deinit();
    try reopened.ensureTools(&replaced);
    try std.testing.expectEqual(1, reopened.tools.items.len);
    try std.testing.expectEqualStrings("read", reopened.pool.get(reopened.tools.items[0].name).?);
}

test "a session saved without tools loads with none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try newTestSession(&tmp);
    defer session.deinit();
    try session.append(.{ .role = .user, .content = "hi" });
    try session.save();

    var resumed = try reopenTestSession(&tmp, session.id());
    defer resumed.deinit();
    try std.testing.expectEqual(0, resumed.tools.items.len);
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

    // The resumed session keeps the model it was started on, since the conversation belongs to
    // the model that produced it rather than to whatever the configuration says now.
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
    const file = try tmp.dir.readFileAlloc(std.testing.io, session.id(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file);
    try std.testing.expect(std.mem.find(u8, file, "\"model\"") == null);
}

test "opening an unknown or damaged session is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.SessionNotFound,
        Session.open(std.testing.io, tmp.dir, std.testing.allocator, "nobody", "/work"),
    );

    var damaged = try newTestSession(&tmp);
    defer damaged.deinit();
    try damaged.append(.{ .role = .user, .content = "hi" });
    try damaged.save();

    // A file cut short, and a file of a version this billy does not know.
    const written = try tmp.dir.readFileAlloc(std.testing.io, damaged.id(), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    var short_id: [max_id_len]u8 = undefined;
    @memcpy(short_id[0..].ptr[0..damaged.id().len], damaged.id());
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cut-short",
        .data = written[0 .. written.len - 1],
    });
    try std.testing.expectError(
        error.CorruptSession,
        Session.open(std.testing.io, tmp.dir, std.testing.allocator, "cut-short", "/work"),
    );

    var future = try std.testing.allocator.dupe(u8, written);
    defer std.testing.allocator.free(future);
    std.mem.writeInt(u32, future[@offsetOf(Header, "version")..][0..4], format_version + 1, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "future", .data = future });
    try std.testing.expectError(
        error.UnsupportedSessionVersion,
        Session.open(std.testing.io, tmp.dir, std.testing.allocator, "future", "/work"),
    );

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nothing-like-a-session", .data = "not a session" });
    try std.testing.expectError(
        error.CorruptSession,
        Session.open(std.testing.io, tmp.dir, std.testing.allocator, "nothing-like-a-session", "/work"),
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

test "a resumed session frees everything it read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Writing and resuming here runs under the testing gpa, which reports any allocation left
    // behind, so this passing means the bytes read and the session built were both freed.
    var session = try newTestSession(&tmp);
    var id_buf: [max_id_len]u8 = undefined;
    const written_id = try setCheckedId(&id_buf, session.id());
    for (0..200) |_| try session.append(.{ .role = .user, .content = "a line of the conversation" });
    session.deinit();

    var resumed = try reopenTestSession(&tmp, written_id);
    defer resumed.deinit();
    try std.testing.expectEqual(200, resumed.messages.items.len);
    try std.testing.expectEqualStrings("a line of the conversation", resumed.contentOf(resumed.messages.items[199]).?);
    try std.testing.expectEqualStrings("/work", resumed.cwd());
}

test "the id a session was opened by is the one it reads back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.create(std.testing.io, tmp.dir, gpa, "dev", "/work");
    defer session.deinit();
    try session.append(.{ .role = .user, .content = "hello" });

    // The id names the file, so a session reads back the one it was opened by, not another.
    var resumed = try reopenTestSession(&tmp, "dev");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("dev", resumed.id());
    try std.testing.expectEqual(1, resumed.messages.items.len);

    var fresh = try newTestSession(&tmp);
    defer fresh.deinit();
    try std.testing.expectEqual(ulid.length, fresh.id().len);
    try std.testing.expect(ulid.isId(fresh.id()));
}
