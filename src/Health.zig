//! Which backends are worth trying, and until when.
//!
//! A backend that has just failed is set aside for a while, so the next query
//! does not hammer a backend that is down, rate-limited or out of credit. The
//! wait grows with each consecutive failure, and a backend that answers is
//! cleared. The waits are keyed by the backend's name, so this knows nothing of
//! the backends that use it, and kept in a file, so a restart does not forget
//! them and try a backend that is still down.
//!
//! This is advice, not a limit: the worst a wrong wait costs is a backend left
//! unused for an hour, so a file that cannot be read is left behind without a
//! word, and an empty table. A file that cannot be written is another matter: it
//! is reported, so a billy whose waits are not being kept says so.

const std = @import("std");

const Health = @This();

/// Longest a backend is ever set aside. A backend is never locked out for more
/// than this, so a clock that jumped forward and back cannot leave one unused
/// for good; it also bounds what the file can say.
pub const max_wait_ms: i64 = 60 * 60 * 1000;
/// How long a backend is set aside after its first failure. Each consecutive
/// failure doubles it, up to `max_wait_ms`.
const base_wait_ms: i64 = 30 * 1000;

/// Name of the file the waits are kept in, in the billy data directory.
pub const file_name = "health.json";
/// Layout of that file, bumped when its shape changes.
const format_version = 1;
/// Longest file read back, so a damaged one cannot exhaust memory.
const max_file_bytes = 1 << 16;

/// One backend's wait: what the file holds under a backend's name, and what the
/// table holds for it.
const Wait = struct {
    /// When the backend may be tried again, ms since the epoch.
    until_ms: i64 = 0,
    /// Failures in a row, which sets the length of the next wait.
    failures: u32 = 0,
};

/// The file, as `read` parses it: the waits, one per backend name. `write`
/// writes the same fields out of the table directly, without building one of
/// these, so the two have to be kept in step by hand.
const Stored = struct {
    version: u32 = format_version,
    entries: std.json.ArrayHashMap(Wait) = .{},
};

/// Whether a name read from the file can be held: text, since the file is JSON,
/// and with no NUL in it, which is what ends a name in the pool.
fn usable(name: []const u8) bool {
    return std.unicode.utf8ValidateSlice(name) and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

/// Where a name is in `strings`, as the map's key. A key of its own rather than
/// a slice, since the pool moves as it grows, and inexhaustive since it only
/// ever holds an offset into that pool.
const Name = enum(u32) { _ };

/// Equality and hashing for names, over the text rather than the key: what a key
/// names is where its text sits in the pool.
///
/// This takes either a key or the text itself, which is what lets a name billy
/// holds no wait for be looked up: the text is hashed and compared where it is,
/// and no copy of it is made.
const Names = struct {
    health: *const Health,

    pub fn hash(names: Names, name: anytype) u32 {
        return @truncate(std.hash.Wyhash.hash(0, names.text(name)));
    }

    pub fn eql(names: Names, a: anytype, b: Name, b_index: usize) bool {
        _ = b_index;
        return std.mem.eql(u8, names.text(a), names.text(b));
    }

    /// The text of `name`, whether it is a key into the pool or text that has no
    /// key yet.
    fn text(names: Names, name: anytype) []const u8 {
        if (@TypeOf(name) == Name) return names.health.nameText(name);
        return name;
    }
};

io: std.Io,
/// Owns the pool and the waits, which `deinit` frees.
gpa: std.mem.Allocator,
/// The directory the waits are read from and written to. Borrowed: the caller
/// owns it and outlives this.
dir: std.Io.Dir,
/// Guards the pool and the waits, since the web server asks several searches at
/// once and they share this table.
mutex: std.Io.Mutex = .init,
/// The names the waits are held for, one NUL-terminated copy each, in the order
/// they were first recorded. Two equal names share one offset.
strings: std.ArrayList(u8) = .empty,
/// The waits, by the offset of their name in `strings`, in the order they were
/// recorded: the file is written in that order, so nothing has to be sorted or
/// copied to write it.
entries: std.ArrayHashMapUnmanaged(Name, Wait, Names, true) = .empty,

/// Reads the waits left by an earlier run.
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

/// Reads the waits left by an earlier run, into the table. The file is read and
/// parsed in an arena of this call, so what the parse holds lives only as long
/// as it is needed: what is kept is copied into the pool, which outlives it.
fn read(self: *Health) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No file is the ordinary case of a first run, and a file that cannot be
    // read or understood is one left by something else: neither is worth
    // reporting, since the waits are only advice.
    const stored_text = self.dir.readFileAlloc(self.io, file_name, arena, .limited(max_file_bytes)) catch return;
    const stored = std.json.parseFromSlice(Stored, arena, stored_text, .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (stored.value.version > format_version) return;

    const now = std.Io.Clock.real.now(self.io).toMilliseconds();
    var read_entries = stored.value.entries.map.iterator();
    while (read_entries.next()) |entry| {
        // A name that cannot be held is left out rather than making the rest of
        // the file unreadable.
        if (!usable(entry.key_ptr.*)) continue;
        const wait = try self.add(entry.key_ptr.*);
        // A wait further off than the cap is one the clock has moved under, so
        // it is brought back to the cap rather than leaving the backend unused
        // for good.
        wait.* = .{
            .until_ms = @min(entry.value_ptr.until_ms, now + max_wait_ms),
            .failures = entry.value_ptr.failures,
        };
    }
}

/// Whether `name` is set aside and should be skipped at `now_ms`. A name billy
/// holds no wait for is not, and costs nothing to ask about.
pub fn skips(self: *Health, name: []const u8, now_ms: i64) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.lookup(name) orelse return false;
    return wait.until_ms > now_ms;
}

/// Records that `name` failed, setting it aside until `now_ms` plus a wait: the
/// one the backend itself asked for when it sent one, and otherwise one that
/// doubles with each consecutive failure.
pub fn record(self: *Health, name: []const u8, retry_after_ms: ?i64, now_ms: i64) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = try self.add(name);
    wait.failures += 1;
    wait.until_ms = now_ms + @min(retry_after_ms orelse waitFor(wait.failures), max_wait_ms);
    try self.write();
}

/// Clears `name`, since it answered. Only a backend that had failed causes a
/// write, so a run in which nothing fails writes nothing.
pub fn clear(self: *Health, name: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.lookup(name) orelse return;
    if (wait.failures == 0 and wait.until_ms == 0) return;
    wait.* = .{};
    try self.write();
}

/// The wait held for `name`, or null when there is none. The name is looked up
/// as the text it is, so a name nothing is held for is not added to the pool.
fn lookup(self: *Health, name: []const u8) ?*Wait {
    return self.entries.getPtrAdapted(name, Names{ .health = self });
}

/// The wait held for `name`, adding one when there is none. This is the only
/// thing here that allocates, and then only for a name billy holds no wait for.
fn add(self: *Health, name: []const u8) !*Wait {
    const names = Names{ .health = self };
    // A name that is already held is found before anything is reserved for it,
    // so recording a backend that has failed before allocates nothing.
    if (self.entries.getPtrAdapted(name, names)) |wait| return wait;

    // Room for the wait is made before the name is written into the pool, so a
    // failed allocation leaves the table as it was.
    try self.entries.ensureUnusedCapacityContext(self.gpa, 1, names);

    const start: u32 = @intCast(self.strings.items.len);
    try self.strings.appendSlice(self.gpa, name);
    errdefer self.strings.shrinkRetainingCapacity(start);
    try self.strings.append(self.gpa, 0);

    const entry = self.entries.getOrPutAssumeCapacityAdapted(name, names);
    // The name was not there, since it was looked for above.
    std.debug.assert(!entry.found_existing);
    entry.key_ptr.* = @fromBackingInt(@intCast(start));
    entry.value_ptr.* = .{};
    return entry.value_ptr;
}

/// The text of the name at `offset`: from there to the NUL that ends it, which
/// every name in the pool carries.
fn nameText(self: *const Health, offset: Name) []const u8 {
    const start = @backingInt(offset);
    return std.mem.span(self.strings.items[start .. self.strings.items.len - 1 :0].ptr);
}

/// How long a backend is set aside after `failures` failures in a row.
fn waitFor(failures: u32) i64 {
    const shift: u6 = @intCast(@min(failures - 1, 20));
    return @min(base_wait_ms << shift, max_wait_ms);
}

/// Writes the waits of every backend that has failed, in the order they were
/// recorded. A wait of a backend that answered is dropped, so the file holds
/// only what is still set aside.
///
/// Nothing is allocated: the table is written as it is held, under the field
/// names `read` parses `Stored` by, rather than into a copy of it.
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

/// The seconds a response's `Retry-After` header asks to be waited, in
/// milliseconds, or null when it sent none or one that is not a whole number of
/// seconds. The HTTP-date form is left alone: it is rare, and a caller's own
/// backoff covers it.
pub fn retryAfterMs(head: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
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
    // The header name is matched however it is spelled.
    try std.testing.expectEqual(@as(?u64, 5000), retryAfterMs("HTTP/1.1 503\r\nretry-after: 5\r\n\r\n"));
    // No header, and the HTTP-date form, are left to the caller's backoff.
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

    try t.health.record("a", null, 1000);
    // Set aside from the moment it failed until the wait is up, and no longer.
    try std.testing.expect(t.health.skips("a", 1000));
    try std.testing.expect(t.health.skips("a", 1000 + base_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", 1000 + base_wait_ms));
    // A backend that did not fail is left alone.
    try std.testing.expect(!t.health.skips("b", 0));

    // A new table, as a restart makes, reads the wait back from the file.
    try t.reload();
    try std.testing.expect(t.health.skips("a", 1000 + base_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", 1000 + base_wait_ms));
    try std.testing.expect(!t.health.skips("b", 0));
}

test "a backend that answers is cleared, and the file with it" {
    var t = try Test.init(null);
    defer t.deinit();

    try t.health.record("a", null, 1000);
    try std.testing.expect(t.health.skips("a", 1000));

    try t.health.clear("a");
    try std.testing.expect(!t.health.skips("a", 1000));

    // Nothing is left on disk for it either.
    try t.reload();
    try std.testing.expect(!t.health.skips("a", 0));
}

test "a backend that asks to be waited for is set aside for what it asked" {
    var t = try Test.init(null);
    defer t.deinit();

    // The backend's own wait is used, not the backoff.
    try t.health.record("a", 5_000, 0);
    try std.testing.expect(t.health.skips("a", 4_999));
    try std.testing.expect(!t.health.skips("a", 5_000));

    // One longer than the cap is brought back to it, so a backend cannot set
    // billy aside for longer than the longest wait.
    try t.health.record("a", max_wait_ms * 10, 0);
    try std.testing.expect(t.health.skips("a", max_wait_ms - 1));
    try std.testing.expect(!t.health.skips("a", max_wait_ms));
}

test "a wait further off than the cap is brought back to it on reading" {
    // A file with a wait far in the future, as a clock that jumped back would
    // leave behind. It is capped rather than locking the backend out for good.
    var t = try Test.init("{\"version\":1,\"entries\":{\"a\":{\"until_ms\":99999999999999,\"failures\":3}}}");
    defer t.deinit();

    const now = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    try std.testing.expect(t.health.skips("a", now + max_wait_ms - 1000));
    try std.testing.expect(!t.health.skips("a", now + max_wait_ms + 1000));
}

test "a name that cannot be held is left out, and the rest of the file still reads" {
    // A name with a NUL in it cannot be held, since a NUL is what ends a name in
    // the pool. It is dropped rather than making the whole file unreadable.
    var t = try Test.init(
        "{\"version\":1,\"entries\":{" ++
            "\"a\\u0000b\":{\"until_ms\":100000,\"failures\":1}," ++
            "\"b\":{\"until_ms\":100000,\"failures\":2}}}",
    );
    defer t.deinit();

    try std.testing.expect(t.health.skips("b", 0));
    try std.testing.expectEqual(@as(usize, 1), t.health.entries.count());
    // The name the file held, and nothing of the one that was dropped.
    try std.testing.expectEqualStrings("b\x00", t.health.strings.items);
}

test "a file that cannot be read or understood leaves the table empty" {
    // No file at all, which is the first run of a fresh installation.
    var t = try Test.init(null);
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 0), t.health.entries.count());

    // A file of something else, and one of a newer layout, are both left alone.
    for ([_][]const u8{
        "{} not json",
        "{\"version\":9999,\"entries\":{\"a\":{\"until_ms\":1,\"failures\":1}}}",
        // A number where the wait is an object, and one too large for its type.
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

    // Asking about a name nothing is held for leaves nothing behind, however
    // often it is asked, and neither does clearing one.
    try std.testing.expect(!t.health.skips("nope", 0));
    try std.testing.expect(!t.health.skips("nope", 0));
    try t.health.clear("nope");
    try std.testing.expectEqual(@as(usize, 0), t.health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.health.entries.count());

    // Two names cost one copy each, and a repeated name costs none.
    try t.health.record("tavily", null, 0);
    try t.health.record("brave", null, 0);
    try t.health.record("tavily", null, 0);
    try std.testing.expectEqual(@as(usize, "tavily\x00brave\x00".len), t.health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 2), t.health.entries.count());
    // A name that is in the pool is still found by the text it is held as, and
    // one that is not is not.
    try std.testing.expect(t.health.skips("tavily", 0));
    try std.testing.expect(!t.health.skips("tavilyx", 0));
    try std.testing.expect(!t.health.skips("tavil", 0));
}

test "the file holds the waits of every backend that failed, by name" {
    var t = try Test.init(null);
    defer t.deinit();

    try t.health.record("searxng", null, 0);
    try t.health.record("brave", null, 0);
    try t.health.clear("brave");
    try t.health.record("tavily", 60_000, 0);

    var buffer: [1 << 12]u8 = undefined;
    const written = try t.tmp.dir.readFile(std.testing.io, file_name, &buffer);

    // One entry per backend that failed, and none for one that answered. This
    // is the whole file, so a field the parser does not know is caught here.
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

    // Written as the table holds them rather than sorted, since sorting is what
    // a copy of the table would be for. The names do not read in this order.
    try t.health.record("tavily", null, 0);
    try t.health.record("brave", null, 0);

    var buffer: [1 << 12]u8 = undefined;
    const written = try t.tmp.dir.readFile(std.testing.io, file_name, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"tavily\"").? <
        std.mem.indexOf(u8, written, "\"brave\"").?);

    // Reading it back keeps that order, so a file billy did not write last is
    // not reshuffled by the next write.
    try t.reload();

    try t.health.record("exa", null, 0);

    var after: [1 << 12]u8 = undefined;
    const rewritten = try t.tmp.dir.readFile(std.testing.io, file_name, &after);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"tavily\"").? <
        std.mem.indexOf(u8, rewritten, "\"brave\"").?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"brave\"").? <
        std.mem.indexOf(u8, rewritten, "\"exa\"").?);
}

test "writing the waits allocates nothing" {
    var t = try Test.init(null);
    defer t.deinit();

    try t.health.record("tavily", null, 0);
    try t.health.record("brave", null, 0);

    // A table that cannot allocate still writes, and still clears: the waits are
    // written out of what is held, rather than into a copy of them first.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    t.health.gpa = failing.allocator();
    try t.health.clear("brave");
    try t.health.record("tavily", 60_000, 0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
