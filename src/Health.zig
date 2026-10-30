//! Which backends are worth trying, and until when.

const std = @import("std");

const Health = @This();

pub const max_wait_ms: i64 = 60 * 60 * 1000;
const base_wait_ms: i64 = 30 * 1000;

pub const file_name = "health.json";
const format_version = 1;

const Wait = struct {
    until_ms: i64 = 0,
    failures: u32 = 0,
};

const Stored = struct {
    version: u32 = format_version,
    entries: std.json.ArrayHashMap(Wait) = .{},
};

fn usable(name: []const u8) bool {
    return std.unicode.utf8ValidateSlice(name) and
        std.mem.findScalar(u8, name, 0) == null;
}

const Name = enum(u32) { _ };

const Names = struct {
    health: *const Health,

    pub fn hash(names: Names, name: anytype) u32 {
        return @truncate(std.hash.Wyhash.hash(0, names.text(name)));
    }

    pub fn eql(names: Names, a: anytype, b: Name, b_index: usize) bool {
        _ = b_index;
        return std.mem.eql(u8, names.text(a), names.text(b));
    }

    fn text(names: Names, name: anytype) []const u8 {
        if (@TypeOf(name) == Name) return names.health.nameText(name);
        return name;
    }
};

io: std.Io,
gpa: std.mem.Allocator,
dir: std.Io.Dir,
mutex: std.Io.Mutex = .init,
strings: std.ArrayList(u8) = .empty,
entries: std.array_hash_map.Custom(Name, Wait, Names, store_hash) = .empty,

const store_hash = true;

pub fn load(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !Health {
    var health: Health = .{ .io = io, .gpa = gpa, .dir = dir };
    errdefer health.deinit();
    try health.read();
    return health;
}

pub fn deinit(self: *Health) void {
    self.strings.deinit(self.gpa);
    self.entries.deinit(self.gpa);
}

fn read(self: *Health) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No file is the ordinary case of a first run, and a file that cannot be read or understood is
    // one left by something else: neither is worth reporting, since the waits are only advice.
    const stored_text = self.dir.readFileAlloc(self.io, file_name, arena, .unlimited) catch return;
    const stored = std.json.parseFromSlice(Stored, arena, stored_text, .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (stored.value.version > format_version) return;

    const now = std.Io.Clock.real.now(self.io).toMilliseconds();
    var read_entries = stored.value.entries.map.iterator();
    while (read_entries.next()) |entry| {
        // A name that cannot be held is left out rather than making the rest of the file
        // unreadable.
        if (!usable(entry.key_ptr.*)) continue;
        const wait = try self.add(entry.key_ptr.*);
        // A wait further off than the cap is one the clock has moved under, so it is brought back
        // to the cap rather than leaving the backend unused for good.
        wait.* = .{
            .until_ms = @min(entry.value_ptr.until_ms, now + max_wait_ms),
            .failures = entry.value_ptr.failures,
        };
    }
}

pub fn skips(self: *Health, name: []const u8, now_ms: i64) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.lookup(name) orelse return false;
    return wait.until_ms > now_ms;
}

pub fn record(self: *Health, name: []const u8, retry_after_ms: ?i64, now_ms: i64) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.add(name) catch |err| return lost("set aside", name, err);
    wait.failures += 1;
    wait.until_ms = now_ms + @min(retry_after_ms orelse waitFor(wait.failures), max_wait_ms);
    self.write() catch |err| lost("keep the wait for", name, err);
}

pub fn clear(self: *Health, name: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.lookup(name) orelse return;
    if (wait.failures == 0 and wait.until_ms == 0) return;
    wait.* = .{};
    self.write() catch |err| lost("clear", name, err);
}

fn lost(what: []const u8, name: []const u8, err: anyerror) void {
    std.log.warn("cannot {s} {s}: {t}", .{ what, name, err });
}

pub fn isSetAside(health: ?*Health, name: []const u8, now_ms: i64) bool {
    return (health orelse return false).skips(name, now_ms);
}

pub fn recordFailure(health: ?*Health, name: []const u8, retry_after_ms: ?i64, now_ms: i64) void {
    (health orelse return).record(name, retry_after_ms, now_ms);
}

pub fn recordAnswer(health: ?*Health, name: []const u8) void {
    (health orelse return).clear(name);
}

fn lookup(self: *Health, name: []const u8) ?*Wait {
    return self.entries.getPtrAdapted(name, Names{ .health = self });
}

fn add(self: *Health, name: []const u8) !*Wait {
    const names = Names{ .health = self };
    if (self.entries.getPtrAdapted(name, names)) |wait| return wait;

    try self.entries.ensureUnusedCapacityContext(self.gpa, 1, names);

    const start: u32 = @intCast(self.strings.items.len);
    try self.strings.appendSlice(self.gpa, name);
    errdefer self.strings.shrinkRetainingCapacity(start);
    try self.strings.append(self.gpa, 0);

    const entry = self.entries.getOrPutAssumeCapacityAdapted(name, names);
    std.debug.assert(!entry.found_existing);
    entry.key_ptr.* = @fromBackingInt(@intCast(start));
    entry.value_ptr.* = .{};
    return entry.value_ptr;
}

fn nameText(self: *const Health, offset: Name) []const u8 {
    const start = @backingInt(offset);
    return std.mem.span(self.strings.items[start .. self.strings.items.len - 1 :0].ptr);
}

fn waitFor(failures: u32) i64 {
    const shift: u6 = @intCast(@min(failures - 1, 20));
    return @min(base_wait_ms << shift, max_wait_ms);
}

fn write(self: *Health) !void {
    var atomic = try self.dir.createFileAtomic(self.io, file_name, .{ .replace = true });
    defer atomic.deinit(self.io);

    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, self.io, &buffer);

    var json: std.json.Stringify = .{
        .writer = &file.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("version");
    try json.write(format_version);
    try json.objectField("entries");
    try json.beginObject();
    for (self.entries.keys(), self.entries.values()) |name, wait| {
        if (wait.failures == 0) continue;
        try json.objectField(self.nameText(name));
        try json.write(wait);
    }
    try json.endObject();
    try json.endObject();

    try file.flush();
    try atomic.replace(self.io);
}

pub fn retryAfterMs(head: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "retry-after")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        return std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    }
    return null;
}

test "retryAfterMs reads the seconds form and ignores the rest" {
    try std.testing.expectEqual(
        @as(?u64, 2000),
        retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 2\r\nContent-Length: 0\r\n\r\n"),
    );
    try std.testing.expectEqual(@as(?u64, 5000), retryAfterMs("HTTP/1.1 503\r\nretry-after: 5\r\n\r\n"));
    try std.testing.expect(retryAfterMs("HTTP/1.1 200 OK\r\n\r\n") == null);
    try std.testing.expect(retryAfterMs("HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n") == null);
}

const Test = struct {
    health: Health,
    tmp: std.testing.TmpDir,

    pub fn init(data: ?[]const u8) !Test {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        if (data) |d| {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = d });
        }

        const health = try Health.load(std.testing.io, std.testing.allocator, tmp.dir);
        return Test{ .health = health, .tmp = tmp };
    }

    fn write(t: *Test, data: []const u8) !void {
        try t.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = data });
    }

    fn reload(t: *Test) !void {
        t.health.deinit();
        t.health = try Health.load(std.testing.io, std.testing.allocator, t.tmp.dir);
    }

    fn deinit(t: *Test) void {
        t.health.deinit();
        t.tmp.cleanup();
    }
};

test "a failed backend is skipped until its wait is over, and the wait is kept" {
    var t = try Test.init(null);
    defer t.deinit();

    try std.testing.expect(!t.health.skips("a", 1000));

    t.health.record("a", null, 1000);
    try std.testing.expect(t.health.skips("a", 1000));
    try std.testing.expect(t.health.skips("a", 1000 + base_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", 1000 + base_wait_ms));
    try std.testing.expect(!t.health.skips("b", 0));

    try t.reload();
    try std.testing.expect(t.health.skips("a", 1000 + base_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", 1000 + base_wait_ms));
    try std.testing.expect(!t.health.skips("b", 0));
}

test "a backend that answers is cleared, and the file with it" {
    var t = try Test.init(null);
    defer t.deinit();

    t.health.record("a", null, 1000);
    try std.testing.expect(t.health.skips("a", 1000));

    t.health.clear("a");
    try std.testing.expect(!t.health.skips("a", 1000));

    try t.reload();
    try std.testing.expect(!t.health.skips("a", 0));
}

test "a backend that asks to be waited for is set aside for what it asked" {
    var t = try Test.init(null);
    defer t.deinit();

    t.health.record("a", 5_000, 0);
    try std.testing.expect(t.health.skips("a", 4_999));
    try std.testing.expect(!t.health.skips("a", 5_000));

    // One longer than the cap is brought back to it, so a backend cannot set billy aside for longer
    // than the longest wait.
    t.health.record("a", max_wait_ms * 10, 0);
    try std.testing.expect(t.health.skips("a", max_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", max_wait_ms));
}

test "a wait further off than the cap is brought back to it on reading" {
    // A file with a wait far in the future, as a clock that jumped back would leave behind.
    var t = try Test.init("{\"version\":1,\"entries\":{\"a\":{\"until_ms\":99999999999999,\"failures\":3}}}");
    defer t.deinit();

    const now = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    try std.testing.expect(t.health.skips("a", now + max_wait_ms - 1000));
    try std.testing.expect(!t.health.skips("a", now + max_wait_ms + 1000));
}

test "a name that cannot be held is left out, and the rest of the file still reads" {
    // A name with a NUL in it cannot be held, since a NUL is what ends a name in the pool.
    var t = try Test.init(
        "{\"version\":1,\"entries\":{" ++
            "\"a\\u0000b\":{\"until_ms\":100000,\"failures\":1}," ++
            "\"b\":{\"until_ms\":100000,\"failures\":2}}}",
    );
    defer t.deinit();

    try std.testing.expect(t.health.skips("b", 0));
    try std.testing.expectEqual(@as(usize, 1), t.health.entries.count());
    try std.testing.expectEqualStrings("b\x00", t.health.strings.items);
}

test "a file that cannot be read or understood leaves the table empty" {
    var t = try Test.init(null);
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 0), t.health.entries.count());

    for ([_][]const u8{
        "{} not json",
        "{\"version\":9999,\"entries\":{\"a\":{\"until_ms\":1,\"failures\":1}}}",
        "{\"version\":1,\"entries\":{\"a\":1}}",
        "{\"version\":1,\"entries\":{\"a\":{\"until_ms\":\"soon\",\"failures\":1}}}",
    }) |broken| {
        try t.write(broken);
        try t.reload();
        try std.testing.expectEqual(@as(usize, 0), t.health.entries.count());
    }
}

test "a backend is set aside for longer with each failure, up to the cap" {
    try std.testing.expectEqual(base_wait_ms, waitFor(1));
    try std.testing.expectEqual(base_wait_ms * 2, waitFor(2));
    try std.testing.expectEqual(base_wait_ms * 4, waitFor(3));
    // It never grows past the cap, however many failures there are in a row.
    try std.testing.expectEqual(max_wait_ms, waitFor(100));
}

test "only a recorded name reaches the pool, and then only once" {
    var t = try Test.init(null);
    defer t.deinit();

    try std.testing.expect(!t.health.skips("nope", 0));
    try std.testing.expect(!t.health.skips("nope", 0));
    t.health.clear("nope");
    try std.testing.expectEqual(@as(usize, 0), t.health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.health.entries.count());

    t.health.record("tavily", null, 0);
    t.health.record("brave", null, 0);
    t.health.record("tavily", null, 0);
    try std.testing.expectEqual(@as(usize, "tavily\x00brave\x00".len), t.health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 2), t.health.entries.count());
    try std.testing.expect(t.health.skips("tavily", 0));
    try std.testing.expect(!t.health.skips("tavilyx", 0));
    try std.testing.expect(!t.health.skips("tavil", 0));
}

test "the file holds the waits of every backend that failed, by name" {
    var t = try Test.init(null);
    defer t.deinit();

    t.health.record("searxng", null, 0);
    t.health.record("brave", null, 0);
    t.health.clear("brave");
    t.health.record("tavily", 60_000, 0);

    var buffer: [1 << 12]u8 = undefined;
    const written = try t.tmp.dir.readFile(std.testing.io, file_name, &buffer);

    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "entries": {
        \\    "searxng": {
        \\      "until_ms": 30000,
        \\      "failures": 1
        \\    },
        \\    "tavily": {
        \\      "until_ms": 60000,
        \\      "failures": 1
        \\    }
        \\  }
        \\}
    , written);
}

test "the file holds the waits in the order they were recorded" {
    var t = try Test.init(null);
    defer t.deinit();

    // Written as the table holds them rather than sorted, since sorting is what a copy of the table
    // would be for.
    t.health.record("tavily", null, 0);
    t.health.record("brave", null, 0);

    var buffer: [1 << 12]u8 = undefined;
    const written = try t.tmp.dir.readFile(std.testing.io, file_name, &buffer);
    try std.testing.expect(std.mem.find(u8, written, "\"tavily\"").? <
        std.mem.find(u8, written, "\"brave\"").?);

    try t.reload();

    t.health.record("exa", null, 0);

    var after: [1 << 12]u8 = undefined;
    const rewritten = try t.tmp.dir.readFile(std.testing.io, file_name, &after);

    try std.testing.expect(std.mem.find(u8, rewritten, "\"tavily\"").? <
        std.mem.find(u8, rewritten, "\"brave\"").?);
    try std.testing.expect(std.mem.find(u8, rewritten, "\"brave\"").? <
        std.mem.find(u8, rewritten, "\"exa\"").?);
}

test "writing the waits allocates nothing" {
    var t = try Test.init(null);
    defer t.deinit();

    t.health.record("tavily", null, 0);
    t.health.record("brave", null, 0);

    // A table that cannot allocate still writes, and still clears: the waits are written out of
    // what is held, rather than into a copy of them first.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    t.health.gpa = failing.allocator();
    t.health.clear("brave");
    t.health.record("tavily", 60_000, 0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "the optional helpers do nothing without a table, and act on one" {
    try std.testing.expect(!isSetAside(null, "a", 0));
    recordFailure(null, "a", null, 0);
    recordAnswer(null, "a");

    var t = try Test.init(null);
    defer t.deinit();
    recordFailure(&t.health, "a", null, 1000);
    try std.testing.expect(isSetAside(&t.health, "a", 1000));
    recordAnswer(&t.health, "a");
    try std.testing.expect(!isSetAside(&t.health, "a", 1000));
}

test "a wait that cannot be written is still held, and fails nothing" {
    var t = try Test.init(null);
    defer t.deinit();

    // Something in the way of the file the waits are written to, so the write fails however the
    // disk is.
    try t.tmp.dir.createDirPath(std.testing.io, file_name);

    t.health.record("a", null, 1000);
    try std.testing.expect(t.health.skips("a", 1000));

    t.health.clear("a");
    try std.testing.expect(!t.health.skips("a", 1000));
}
