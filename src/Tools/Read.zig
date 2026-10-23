const std = @import("std");
const Tools = @import("../Tools.zig");

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
    ) catch |err| return Tools.fail(out, "cannot read {s}: {s}", .{ read.path, @errorName(err) });
    defer gpa.free(contents);

    // A trailing newline would otherwise read as a final empty line.
    const text = std.mem.trimEnd(u8, contents, "\n");
    if (text.len == 0) return out.writeAll("(empty file)");

    const total = std.mem.count(u8, text, "\n") + 1;
    // `offset` is 1-based, and 0 is read as the first line.
    const first = @max(read.offset, 1);
    if (first > total) {
        // The call asked for lines the file has not got, so it failed rather
        // than answering: what it is given says how long the file is, which is
        // what it needs to ask again.
        return Tools.fail(out, "offset {d} is past the end; {d} lines", .{ read.offset, total });
    }
    const last = @min(total, first - 1 +| read.limit);

    // The numbers line up on the largest one printed, so the width is known first.
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
    try read.run(gpa, io, tmp.dir, &out.writer);
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
    // Counted from the offset, not from the top of the file.
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
    // The last line shown is 11, so the single digits are padded to two.
    try expectRead(contents, .{ .path = test_file, .offset = 8 },
        \\ 8: h
        \\ 9: i
        \\10: j
        \\11: k
        \\
    );
    // Stopping before 10 keeps the width at one.
    try expectRead(contents, .{ .path = test_file, .offset = 8, .limit = 2 },
        \\8: h
        \\9: i
        \\… 2 more lines
        \\
    );
}

test "an offset past the end says how long the file is" {
    // The call asked for a line the file has not got, so it is the call that
    // failed, not the read: the mark says so, and what follows still tells it
    // how long the file is.
    try expectRead("a\nb\n", .{ .path = test_file, .offset = 3 }, "error: offset 3 is past the end; 2 lines");
}

test "a file that cannot be read is the call's failure, not the run's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Nothing is returned: a read that could not open its file is written as
    // the call's result, beginning with the mark both readers branch on, so the
    // terminal shows it as a failure and the page draws it as one rather than
    // either reading it as the contents of a file.
    try (Read{ .path = "missing.txt" }).run(gpa, io, tmp.dir, &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "error: cannot read missing.txt: "));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "FileNotFound") != null);
}
