//! Which backends are worth trying, and until when.

const std = @import("std");

const Health = @This();

pub const max_wait_ms: i64 = 60 * 60 * 1000;
const base_wait_ms: i64 = 30 * 1000;

const Wait = struct {
    until_ms: i64 = 0,
    failures: u32 = 0,
};

io: std.Io,
gpa: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
waits: std.StringHashMapUnmanaged(Wait) = .empty,

pub fn deinit(self: *Health) void {
    var names = self.waits.keyIterator();
    while (names.next()) |name| self.gpa.free(name.*);
    self.waits.deinit(self.gpa);
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
    return self.waits.getPtr(name);
}

fn add(self: *Health, name: []const u8) !*Wait {
    if (self.waits.getPtr(name)) |wait| return wait;

    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    try self.waits.putNoClobber(self.gpa, owned, .{});
    return self.waits.getPtr(owned).?;
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

fn expectRetryAfter(header: []const u8, expected: ?u64) !void {
    try std.testing.expectEqual(expected, retryAfterMs(header));
}

test "retryAfterMs reads the seconds form and ignores the rest" {
    try expectRetryAfter(
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 2\r\nContent-Length: 0\r\n\r\n",
        2000,
    );
    try expectRetryAfter("HTTP/1.1 503\r\nretry-after: 5\r\n\r\n", 5000);
    try expectRetryAfter("HTTP/1.1 200 OK\r\n\r\n", null);
    try expectRetryAfter("HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n", null);
}

fn expectSkipped(health: *Health, name: []const u8, now_ms: i64) !void {
    try std.testing.expect(health.skips(name, now_ms));
}

fn expectNotSkipped(health: *Health, name: []const u8, now_ms: i64) !void {
    try std.testing.expect(!health.skips(name, now_ms));
}

fn expectWait(failures: u32, expected: i64) !void {
    try std.testing.expectEqual(expected, waitFor(failures));
}

test "a failed backend is skipped until its wait is over" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    try health.expectNotSkipped("a", 1000);

    health.record("a", null, 1000);
    try health.expectSkipped("a", 1000);
    try health.expectSkipped("a", 1000 + base_wait_ms - 1);
    try health.expectNotSkipped("a", 1000 + base_wait_ms);
    try health.expectNotSkipped("b", 0);
}
test "a backend that answers is cleared" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    health.record("a", null, 1000);
    try health.expectSkipped("a", 1000);

    health.clear("a");
    try health.expectNotSkipped("a", 1000);
}
test "a backend that asks to be waited for is set aside for what it asked" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    health.record("a", 5_000, 0);
    try health.expectSkipped("a", 4_999);
    try health.expectNotSkipped("a", 5_000);

    // One longer than the cap is brought back to it, so a backend cannot set billy aside for longer
    // than the longest wait.
    health.record("a", max_wait_ms * 10, 0);
    try health.expectSkipped("a", max_wait_ms - 1);
    try health.expectNotSkipped("a", max_wait_ms);
}
test "a backend is set aside for longer with each failure, up to the cap" {
    try expectWait(1, base_wait_ms);
    try expectWait(2, base_wait_ms * 2);
    try expectWait(3, base_wait_ms * 4);
    // It never grows past the cap, however many failures there are in a row.
    try expectWait(100, max_wait_ms);
}
test "only a recorded name is kept, and then only once" {
    const gpa = std.testing.allocator;
    var health = Health{ .io = std.testing.io, .gpa = gpa };
    defer health.deinit();

    try std.testing.expect(!health.skips("nope", 0));
    try std.testing.expect(!health.skips("nope", 0));
    health.clear("nope");
    try std.testing.expectEqual(@as(usize, 0), health.waits.count());

    health.record("tavily", null, 0);
    health.record("brave", null, 0);
    health.record("tavily", null, 0);
    try std.testing.expectEqual(@as(usize, 2), health.waits.count());
    try health.expectSkipped("tavily", 0);
    try health.expectNotSkipped("tavilyx", 0);
    try health.expectNotSkipped("tavil", 0);
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
