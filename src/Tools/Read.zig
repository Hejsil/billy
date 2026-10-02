const std = @import("std");

const Read = @This();

path: []const u8,
/// First line to read, 1-based.
offset: usize = 1,
/// Maximum number of lines.
limit: usize = 2000,

pub fn run(read: Read, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    const contents = dir.readFileAlloc(
        io,
        read.path,
        gpa,
        .limited(16 << 20),
    ) catch |err| return out.print("cannot read {s}: {s}", .{ read.path, @errorName(err) });
    defer gpa.free(contents);

    // A trailing newline would otherwise read as a final empty line.
    const text = std.mem.trimEnd(u8, contents, "\n");
    if (text.len == 0) return out.writeAll("(empty file)");

    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    var shown: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (number < read.offset) continue;
        if (shown == read.limit) break;
        shown += 1;
        try out.print("{d:>6}\t{s}\n", .{ number, line });
    }

    if (shown == 0) {
        return out.print("offset {d} is past the end; {d} lines", .{ read.offset, number });
    }

    if (shown == read.limit)
        try out.print("… {d} more lines\n", .{number - read.offset + 1 - shown});
}
