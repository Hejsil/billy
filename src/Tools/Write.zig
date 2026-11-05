const std = @import("std");

const Tools = @import("../Tools.zig");

const Write = @This();

path: []const u8,
content: []const u8,

pub fn run(write: Write, tools: Tools, out: *std.Io.Writer) !void {
    if (std.Io.Dir.path.dirname(write.path)) |parent| {
        tools.dir.createDirPath(tools.io, parent) catch |err|
            return Tools.fail(out, "cannot create {s}: {t}", .{ parent, err });
    }

    Tools.writeFile(tools.io, tools.dir, write.path, write.content) catch |err|
        return Tools.fail(out, "cannot write {s}: {t}", .{ write.path, err });
    try out.print("wrote {d} bytes to {s}", .{ write.content.len, write.path });
}
