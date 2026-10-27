const std = @import("std");
const Tools = @import("../Tools.zig");

const Write = @This();

path: []const u8,
content: []const u8,

pub fn run(write: Write, io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    if (std.Io.Dir.path.dirname(write.path)) |parent| {
        dir.createDirPath(io, parent) catch |err|
            return Tools.fail(out, "cannot create {s}: {s}", .{ parent, @errorName(err) });
    }

    Tools.writeFile(io, dir, write.path, write.content) catch |err|
        return Tools.fail(out, "cannot write {s}: {s}", .{ write.path, @errorName(err) });
    try out.print("wrote {d} bytes to {s}", .{ write.content.len, write.path });
}
