//! The string pool: every string in one arena, named by where it sits rather
//! than by a pointer.
//!
//! A name is a small index that survives the pool growing, which a pointer into
//! it would not, and the whole of a session's text is one allocation that frees
//! in one step.
//!
//! The pool does not look for a string it already holds. It used to, and the
//! price was a hash over every string: a session whose tool results are tens of
//! kilobytes each hashed megabytes of text to find that almost none of it
//! repeated -- nine megabytes to save a few kilobytes of roles and tool names,
//! which the roles are an enum for now anyway. Text is kept as it comes.
//!
//! Everything a pool holds is valid UTF-8. Text that is not is repaired as it is
//! added, so anything written from the pool can be carried as a JSON string.

const std = @import("std");

pub const Pool = @This();

/// A string's name in the pool: where its bytes start. The text runs from there
/// to the NUL that ends it, so no length is kept beside it.
pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

/// All string data, one NUL-terminated copy per string.
strings: std.ArrayList(u8) = .empty,

pub fn deinit(pool: *Pool, gpa: std.mem.Allocator) void {
    pool.strings.deinit(gpa);
}

/// Adds `text` to the pool and returns its index, or `.none` for null.
///
/// Text that is not valid UTF-8 is repaired, since Zig writes a byte slice that
/// is not as an array of numbers, which JSON rejects. `fmtUtf8` passes
/// well-formed text through unchanged and repairs anything ill-formed, so every
/// string the pool holds is one a JSON string can carry.
pub fn intern(pool: *Pool, gpa: std.mem.Allocator, text: ?[]const u8) !Index {
    const value = text orelse return .none;

    const start: u32 = @intCast(pool.strings.items.len);
    try pool.strings.print(gpa, "{f}", .{std.unicode.fmtUtf8(value)});
    errdefer pool.strings.shrinkRetainingCapacity(start);
    try pool.strings.append(gpa, 0);
    return @fromBackingInt(start);
}

/// The string `index` names as a NUL-terminated pointer, or null for `.none`.
///
/// A pointer into the pool survives no write to it, so this is for a caller
/// that reads a string many times while the pool is still.
pub fn ptr(pool: *const Pool, index: Index) ?[*:0]const u8 {
    if (index == .none) return null;
    const start = @backingInt(index);
    // Only the start of a string is a name: either the pool opens there, or the
    // byte before is the NUL that ends the string in front.
    std.debug.assert(start < pool.strings.items.len);
    std.debug.assert(start == 0 or pool.strings.items[start - 1] == 0);
    return @ptrCast(pool.strings.items.ptr + start);
}

/// The string `index` names, or null for `.none`. The pool ends every string
/// with a NUL, so the text is the span from the index to that terminator.
pub fn get(pool: *const Pool, index: Index) ?[]const u8 {
    return std.mem.span(pool.ptr(index) orelse return null);
}

test "each string is kept where it was written, and reads back from there" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "hello");
    const second = try pool.intern(gpa, "world");
    // A string already held is added again rather than looked for: the pool
    // keeps text, it does not remember which text it has.
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
    // Nothing was written for either, so the pool is still empty.
    try std.testing.expectEqual(@as(usize, 0), pool.strings.items.len);
}

test "text that is not valid UTF-8 is repaired on the way into the pool" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    // A byte no UTF-8 sequence starts with, which a JSON string could not carry.
    const broken = "bad \xff byte";
    const index = try pool.intern(gpa, broken);

    const repaired = pool.get(index).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(repaired));
    // The byte became the replacement character, which is three bytes, so the
    // text is the byte it was short by two.
    try std.testing.expectEqual(broken.len + 2, repaired.len);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "\u{FFFD}") != null);
}

test "a string read back is the whole string, not the rest of the pool" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "read");
    const second = try pool.intern(gpa, "read a file");

    // The first string ends at its NUL, not where the second one starts.
    try std.testing.expectEqualStrings("read", pool.get(first).?);
    try std.testing.expectEqualStrings("read a file", pool.get(second).?);
    // An empty string is a string like any other, and is not `.none`.
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
    // It is the pool's own byte, not a copy of it.
    try std.testing.expectEqual(pool.strings.items.ptr, @as([*]const u8, @ptrCast(pool.ptr(first).?)));
}
