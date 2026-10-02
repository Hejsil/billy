const std = @import("std");

const Write = @This();

path: []const u8,
content: []const u8,

pub fn run(write: Write, io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    if (std.fs.path.dirname(write.path)) |parent| {
        dir.createDirPath(io, parent) catch |err|
            return out.print("error: cannot create {s}: {s}", .{ parent, @errorName(err) });
    }

    dir.writeFile(io, .{ .sub_path = write.path, .data = write.content }) catch |err|
        return out.print("error: cannot write {s}: {s}", .{ write.path, @errorName(err) });
    try out.print("wrote {d} bytes to {s}", .{ write.content.len, write.path });
}
