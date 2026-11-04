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
    if (home) |dir| {
        if (dir.len > 0 and std.mem.startsWith(u8, cwd, dir)) {
            const rest = cwd[dir.len..];
            if (rest.len == 0) return "~";
            if (rest[0] == '/') return std.mem.print(buffer, "~{s}", .{rest}) catch cwd;
        }
    }
    return cwd;
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
