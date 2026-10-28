//! The string pool: every string in one arena, named by where it sits rather than by a pointer.

const std = @import("std");

pub const Pool = @This();

/// A string's name in the pool: where its bytes start.
pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

strings: std.ArrayList(u8) = .empty,

pub fn deinit(pool: *Pool, gpa: std.mem.Allocator) void {
    pool.strings.deinit(gpa);
}

/// Adds `text` to the pool and returns its index, or `.none` for null.
pub fn intern(pool: *Pool, gpa: std.mem.Allocator, text: ?[]const u8) !Index {
    const value = text orelse return .none;

    const start: u32 = @intCast(pool.strings.items.len);
    errdefer pool.strings.shrinkRetainingCapacity(start);
    // A NUL is never inside a multi-byte sequence, so repairing each side of it on its own repairs
    // the whole.
    var parts = std.mem.splitScalar(u8, value, 0);
    var first = true;
    while (parts.next()) |part| {
        if (!first) try pool.strings.appendSlice(gpa, "\u{FFFD}");
        first = false;
        try pool.strings.print(gpa, "{f}", .{std.unicode.fmtUtf8(part)});
    }
    try pool.strings.append(gpa, 0);
    return @fromBackingInt(start);
}

/// The string `index` names as a NUL-terminated pointer, or null for `.none`.
pub fn ptr(pool: *const Pool, index: Index) ?[*:0]const u8 {
    if (index == .none) return null;
    const start = @backingInt(index);
    std.debug.assert(start < pool.strings.items.len);
    std.debug.assert(start == 0 or pool.strings.items[start - 1] == 0);
    return @ptrCast(pool.strings.items.ptr + start);
}

/// The string `index` names, or null for `.none`.
pub fn get(pool: *const Pool, index: Index) ?[]const u8 {
    return std.mem.span(pool.ptr(index) orelse return null);
}

test "each string is kept where it was written, and reads back from there" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "hello");
    const second = try pool.intern(gpa, "world");
    // A string already held is added again rather than looked for: the pool keeps text, it does not
    // remember which text it has.
    const again = try pool.intern(gpa, "hello");

    try std.testing.expect(again != first);
    try std.testing.expectEqualStrings("hello\x00world\x00hello\x00", pool.strings.items);
    try std.testing.expectEqualStrings("hello", pool.get(first).?);
    try std.testing.expectEqualStrings("world", pool.get(second).?);
    try std.testing.expectEqualStrings("hello", pool.get(again).?);
}

test "a null and an absent string name nothing" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    try std.testing.expectEqual(Index.none, try pool.intern(gpa, null));
    try std.testing.expectEqual(@as(?[]const u8, null), pool.get(.none));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), pool.ptr(.none));
    try std.testing.expectEqual(@as(usize, 0), pool.strings.items.len);
}

test "text that is not valid UTF-8 is repaired on the way into the pool" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const broken = "bad \xff byte";
    const index = try pool.intern(gpa, broken);

    const repaired = pool.get(index).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(repaired));
    try std.testing.expectEqual(broken.len + 2, repaired.len);
    try std.testing.expect(std.mem.find(u8, repaired, "\u{FFFD}") != null);
}

test "a NUL in the text does not end the string early" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const middle = try pool.intern(gpa, "a\x00b");
    const edges = try pool.intern(gpa, "\x00x\x00");
    const after = try pool.intern(gpa, "next");

    try std.testing.expectEqualStrings("a\u{FFFD}b", pool.get(middle).?);
    try std.testing.expectEqualStrings("\u{FFFD}x\u{FFFD}", pool.get(edges).?);
    try std.testing.expectEqualStrings("next", pool.get(after).?);
}

test "a string read back is the whole string, not the rest of the pool" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "read");
    const second = try pool.intern(gpa, "read a file");

    try std.testing.expectEqualStrings("read", pool.get(first).?);
    try std.testing.expectEqualStrings("read a file", pool.get(second).?);
    const empty = try pool.intern(gpa, "");
    try std.testing.expect(empty != .none);
    try std.testing.expectEqualStrings("", pool.get(empty).?);
}

test "a pointer into the pool reads the string it names" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "one");
    const second = try pool.intern(gpa, "two");

    try std.testing.expectEqualStrings("one", std.mem.span(pool.ptr(first).?));
    try std.testing.expectEqualStrings("two", std.mem.span(pool.ptr(second).?));
    try std.testing.expectEqual(pool.strings.items.ptr, @as([*]const u8, @ptrCast(pool.ptr(first).?)));
}
