const std = @import("std");

const Credentials = @import("../Credentials.zig");
const Tools = @import("../Tools.zig");

const Read = @This();

path: []const u8,
offset: usize = 1,
limit: usize = 2000,

pub fn run(read: Read, tools: Tools, out: *std.Io.Writer) !void {
    const contents = tools.dir.readFileAlloc(
        tools.io,
        read.path,
        tools.gpa,
        .limited(Tools.max_file_bytes),
    ) catch |err| return Tools.fail(out, "cannot read {s}: {t}", .{ read.path, err });
    defer tools.gpa.free(contents);

    // A trailing newline would otherwise read as a final empty line.
    const text = std.mem.trimEnd(u8, contents, "\n");
    if (text.len == 0) return out.writeAll("(empty file)");

    const total = std.mem.count(u8, text, "\n") + 1;
    const first = @max(read.offset, 1);
    if (first > total) {
        // The call asked for lines the file has not got, so it failed rather than answering: what
        // it is given says how long the file is, which is what it needs to ask again.
        return Tools.fail(out, "offset {d} is past the end; {d} lines", .{ read.offset, total });
    }
    const last = @min(total, first - 1 +| read.limit);

    const width = std.fmt.count("{d}", .{last});
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (number < first) continue;
        if (number > last) break;
        try out.splatByteAll(' ', width - std.fmt.count("{d}", .{number}));
        try out.print("{d}: {s}\n", .{ number, line });
    }

    if (last < total) try out.print("… {d} more lines\n", .{total - last});
}

const test_file = "f.txt";

fn expectRead(contents: []const u8, read: Read, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = test_file, .data = contents });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const tool_set = Tools.init(io, tmp.dir, gpa, undefined, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
    try read.run(tool_set, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a read cut by the limit says how many lines are left" {
    const contents =
        \\a
        \\b
        \\c
        \\d
        \\e
    ;
    try expectRead(contents, .{ .path = test_file, .limit = 2 },
        \\1: a
        \\2: b
        \\… 3 more lines
        \\
    );
    try expectRead(contents, .{ .path = test_file, .offset = 2, .limit = 2 },
        \\2: b
        \\3: c
        \\… 2 more lines
        \\
    );
}

test "a read that ends exactly at the limit says nothing more" {
    try expectRead(
        \\a
        \\b
    , .{ .path = test_file, .limit = 2 },
        \\1: a
        \\2: b
        \\
    );
}

test "line numbers are padded to the width of the largest one shown" {
    const contents =
        \\a
        \\b
        \\c
        \\d
        \\e
        \\f
        \\g
        \\h
        \\i
        \\j
        \\k
    ;
    try expectRead(contents, .{ .path = test_file, .offset = 8 },
        \\ 8: h
        \\ 9: i
        \\10: j
        \\11: k
        \\
    );
    try expectRead(contents, .{ .path = test_file, .offset = 8, .limit = 2 },
        \\8: h
        \\9: i
        \\… 2 more lines
        \\
    );
}

test "an offset past the end says how long the file is" {
    try expectRead("a\nb\n", .{ .path = test_file, .offset = 3 }, "error: offset 3 is past the end; 2 lines");
}

test "a file that cannot be read is the call's failure, not the run's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Nothing is returned: a read that could not open its file is written as the call's result,
    // beginning with the mark both readers branch on, so the terminal shows it as a failure and the
    // page draws it as one rather than either reading it as the contents of a file.
    const tool_set = Tools.init(io, tmp.dir, gpa, undefined, .{ .bash_timeout_s = 120, .keys = &Credentials.empty });
    const read: Read = .{ .path = "missing.txt" };
    try read.run(tool_set, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: cannot read missing.txt: "));
    try std.testing.expect(std.mem.find(u8, out.written(), "FileNotFound") != null);
}
