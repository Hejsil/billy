//! How wide text is on a terminal.

const std = @import("std");

/// Columns `text` takes: one per character. A double-width character counts as one
/// too, so a line of them is laid out a little wide. Malformed text counts a column
/// per byte.
pub fn columns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

test "a column is a character, and malformed text counts bytes" {
    try std.testing.expectEqual(0, columns(""));
    try std.testing.expectEqual(4, columns("a\u{e9}\u{20ac}b"));
    try std.testing.expectEqual(2, columns("\xff\xff"));
}
