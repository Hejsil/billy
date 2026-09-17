//! Sessions: the conversation persisted under the XDG data directory so that a
//! later run can pick up where the previous one stopped.
//!
//! Every session is one JSON file named after its id. The file is rewritten
//! after each message, so killing the process loses at most the message being
//! written. The system prompt is deliberately not stored: it is added again on
//! every start, so it can change without making saved sessions unusable.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");

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
};

pub const Session = struct {
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
    /// The conversation, oldest first. A system prompt is kept here while the
    /// process runs but is never written to disk.
    messages: std.ArrayList(llm.Message) = .empty,

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
            if (std.mem.eql(u8, message.role, "system")) continue;
            try json.write(message);
        }
        try json.endArray();
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
        // A stored system prompt is ignored: the current one is added again at
        // the start of the run.
        for (stored.messages) |message| {
            if (std.mem.eql(u8, message.role, "system")) continue;
            try session.messages.append(session.arena, message);
        }
    }
};

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
    // The system prompt is not stored, so it is not read back.
    try std.testing.expectEqual(session.messages.items.len - 1, resumed.messages.items.len);
    for (session.messages.items[1..], resumed.messages.items) |before, after| {
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

test "a stored system prompt is dropped when resuming" {
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

    const resumed = try Session.open(std.testing.io, tmp.dir, allocator, arena, "one");
    try std.testing.expectEqual(1, resumed.messages.items.len);
    try std.testing.expectEqualStrings("user", resumed.messages.items[0].role);
    try std.testing.expectEqualStrings("hi", resumed.messages.items[0].content.?);
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
