//! The numbers and paths a header shows: the terminal's line and the page's are the same, so they
//! are written from the same place.

const std = @import("std");

pub fn printTokens(out: *std.Io.Writer, count: usize) !void {
    if (count < 1000) return try out.print("{d}", .{count});
    if (count < 999_500) return try printScaled(out, count, 1000, 'k');
    return try printScaled(out, count, 1_000_000, 'M');
}

fn printScaled(out: *std.Io.Writer, count: usize, unit: usize, suffix: u8) !void {
    try out.print("{d:.0}{c}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(unit)),
        suffix,
    });
}

pub fn printPercent(out: *std.Io.Writer, used: usize, total: usize) !void {
    if (total == 0) return out.writeAll("0%");
    const percent = used * 100 / total;
    if (percent == 0 and used > 0) return out.writeAll("<1%");
    try out.print("{d}%", .{percent});
}

/// The working directory as shown in the header: shortened to `~` when it is inside the home
/// directory, so a long path stays readable, and otherwise returned as it is.
pub fn displayPath(buffer: []u8, cwd: []const u8, home: ?[]const u8) []const u8 {
    const dir = home orelse return cwd;
    const under_home = dir.len > 0 and std.mem.startsWith(u8, cwd, dir);
    if (!under_home) return cwd;

    const rest = cwd[dir.len..];
    if (rest.len == 0) return "~";
    // A sibling whose name opens the same way is not inside the home directory, so only a path
    // that goes on with a separator is shortened.
    if (rest[0] != '/') return cwd;
    return std.mem.print(buffer, "~{s}", .{rest}) catch cwd;
}

fn expectTokens(expected: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try printTokens(&out.writer, count);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "token counts are whole" {
    try expectTokens("0", 0);
    try expectTokens("999", 999);
    try expectTokens("1k", 1000);
    try expectTokens("13k", 12_500);
    try expectTokens("128k", 128_000);
    try expectTokens("1M", 1_000_000);
    try expectTokens("999k", 999_499);
    try expectTokens("1M", 999_500);
    try expectTokens("1M", 999_999);
}

test "a path under the home directory is shortened, and one beside it is not" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("~/src", displayPath(&buffer, "/home/user/src", "/home/user"));
    try std.testing.expectEqualStrings("~", displayPath(&buffer, "/home/user", "/home/user"));
    try std.testing.expectEqualStrings("/home/user2", displayPath(&buffer, "/home/user2", "/home/user"));
    try std.testing.expectEqualStrings("/tmp", displayPath(&buffer, "/tmp", null));
}
