//! Which backends are worth trying, and until when.

const std = @import("std");

const Health = @This();

pub const max_wait_ms: i64 = 60 * 60 * 1000;
const base_wait_ms: i64 = 30 * 1000;

const Wait = struct {
    until_ms: i64 = 0,
    failures: u32 = 0,
};

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
mutex: std.Io.Mutex = .init,
strings: std.ArrayList(u8) = .empty,
entries: std.array_hash_map.Custom(Name, Wait, Names, store_hash) = .empty,

const store_hash = true;

pub fn deinit(self: *Health) void {
    self.strings.deinit(self.gpa);
    self.entries.deinit(self.gpa);
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

    const wait = self.add(name) catch |err| {
        std.log.warn("cannot set aside {s}: {t}", .{ name, err });
        return;
    };
    wait.failures += 1;
    wait.until_ms = now_ms + @min(retry_after_ms orelse waitFor(wait.failures), max_wait_ms);
}

pub fn clear(self: *Health, name: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const wait = self.lookup(name) orelse return;
    if (wait.failures == 0 and wait.until_ms == 0) return;
    wait.* = .{};
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

test "a failed backend is skipped until its wait is over" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    try std.testing.expect(!health.skips("a", 1000));

    health.record("a", null, 1000);
    try std.testing.expect(health.skips("a", 1000));
    try std.testing.expect(health.skips("a", 1000 + base_wait_ms - 1));
    try std.testing.expect(!health.skips("a", 1000 + base_wait_ms));
    try std.testing.expect(!health.skips("b", 0));
}

test "a backend that answers is cleared" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    health.record("a", null, 1000);
    try std.testing.expect(health.skips("a", 1000));

    health.clear("a");
    try std.testing.expect(!health.skips("a", 1000));
}

test "a backend that asks to be waited for is set aside for what it asked" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    health.record("a", 5_000, 0);
    try std.testing.expect(health.skips("a", 4_999));
    try std.testing.expect(!health.skips("a", 5_000));

    // One longer than the cap is brought back to it, so a backend cannot set billy aside for longer
    // than the longest wait.
    health.record("a", max_wait_ms * 10, 0);
    try std.testing.expect(health.skips("a", max_wait_ms - 1));
    try std.testing.expect(!health.skips("a", max_wait_ms));
}

test "a backend is set aside for longer with each failure, up to the cap" {
    try std.testing.expectEqual(base_wait_ms, waitFor(1));
    try std.testing.expectEqual(base_wait_ms * 2, waitFor(2));
    try std.testing.expectEqual(base_wait_ms * 4, waitFor(3));
    // It never grows past the cap, however many failures there are in a row.
    try std.testing.expectEqual(max_wait_ms, waitFor(100));
}

test "only a recorded name reaches the pool, and then only once" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    try std.testing.expect(!health.skips("nope", 0));
    try std.testing.expect(!health.skips("nope", 0));
    health.clear("nope");
    try std.testing.expectEqual(@as(usize, 0), health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), health.entries.count());

    health.record("tavily", null, 0);
    health.record("brave", null, 0);
    health.record("tavily", null, 0);
    try std.testing.expectEqual(@as(usize, "tavily\x00brave\x00".len), health.strings.items.len);
    try std.testing.expectEqual(@as(usize, 2), health.entries.count());
    try std.testing.expect(health.skips("tavily", 0));
    try std.testing.expect(!health.skips("tavilyx", 0));
    try std.testing.expect(!health.skips("tavil", 0));
}

test "the optional helpers do nothing without a table, and act on one" {
    try std.testing.expect(!isSetAside(null, "a", 0));
    recordFailure(null, "a", null, 0);
    recordAnswer(null, "a");

    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();
    recordFailure(&health, "a", null, 1000);
    try std.testing.expect(isSetAside(&health, "a", 1000));
    recordAnswer(&health, "a");
    try std.testing.expect(!isSetAside(&health, "a", 1000));
}
