//! Laying text out for the display with an external command.
//!
//! A format is a shell script that reads the text on standard input and writes
//! the laid-out text on standard output, such as `shfmt | bat -l bash` for a
//! bash command or `glow -` for markdown. A block with two sides, such as an
//! edit, also writes them to files and passes their paths as the script's
//! arguments, so a two-file differ can name them `$1` and `$2`.
//!
//! The layout is presentation only: the command that runs, what a session stores
//! and what the model is sent keep the text that was written.

const std = @import("std");
const Io = std.Io;

/// Room above the text when the laid-out text is read back, so a formatter that
/// runs away cannot exhaust memory.
const slack = 1 << 20;
/// The most arguments a block passes to its format script, which is the two sides
/// of a diff. `bash` and `-c` and the script itself come before them.
const max_args = 2;

/// Where a block's two sides are written for the script to read. Billy's own
/// name in the temporary directory, so it does not collide with another
/// program's file, with a random part drawn fresh for each file and tried again
/// when the name is already taken, so two runs do not collide either.
const sides_dir = "/tmp";
const sides_prefix = "billy-edit-";
/// Random bytes in a name, written as twice as many hex digits.
const suffix_bytes = 8;
/// How many names to try before giving up on finding a free one.
const name_attempts = 8;
/// Longest path made: `/tmp/`, the prefix, the hex suffix, `-`, and the kind.
const max_path = sides_dir.len + 1 + sides_prefix.len + suffix_bytes * 2 + 1 + "old".len;

/// How text is laid out before it is shown. Null shows the text as written.
pub const Format = ?Formatter;

/// A formatter: a shell script that reads the text on standard input and writes
/// the laid-out text on standard output. That script is what a configuration
/// sets.
pub const Formatter = struct {
    /// The shell script, run with `bash -c`.
    script: []const u8,
    io: Io,
    /// Holds the laid-out text while it is printed.
    gpa: std.mem.Allocator,
};

/// Runs `text` through the formatter with no arguments and writes what it makes
/// of the text to `out`. Returns whether it could; false leaves `out` untouched,
/// so the caller can show the text as written. That is what no formatter gives,
/// and a formatter that cannot be run, rejects the text, writes nothing or writes
/// too much.
pub fn apply(format: Format, text: []const u8, out: *Io.Writer) !bool {
    return run(format, text, &.{}, out);
}

/// Runs `text` through the formatter with `args` after the script, so the script
/// can name them `$1`, `$2`. The text still goes in on standard input, so a
/// script that takes no arguments is unaffected. Everything else is as `apply`.
fn run(format: Format, text: []const u8, args: []const []const u8, out: *Io.Writer) !bool {
    const formatter = format orelse return false;
    std.debug.assert(args.len <= max_args);

    // `bash -c script name arg…`: the name is what the shell reports as `$0`, and
    // each argument after it becomes `$1`, `$2`. The stdin text is unaffected.
    var argv: [4 + max_args][]const u8 = undefined;
    argv[0] = "bash";
    argv[1] = "-c";
    argv[2] = formatter.script;
    argv[3] = "billy";
    for (args, 4..) |arg, i| argv[i] = arg;

    var child = std.process.spawn(formatter.io, .{
        .argv = argv[0 .. 4 + args.len],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;
    defer child.kill(formatter.io);

    // The text goes in on standard input, which is what the format script reads.
    // Closing the pipe is what tells it there is no more.
    var in_buffer: [4096]u8 = undefined;
    var script: Io.File.Writer = .init(child.stdin.?, formatter.io, &in_buffer);
    try script.interface.writeAll(text);
    try script.interface.flush();
    child.stdin.?.close(formatter.io);
    child.stdin = null;

    var out_buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(child.stdout.?, formatter.io, &out_buffer);
    const written = reader.interface.allocRemaining(
        formatter.gpa,
        .limited(text.len +| slack),
    ) catch return false;
    defer formatter.gpa.free(written);

    // A formatter that failed, or left nothing behind, is one the text should
    // not disappear for; it is shown as written instead.
    if (exitCode(child.wait(formatter.io) catch return false) != 0) return false;
    const laid_out = std.mem.trimEnd(u8, written, "\n");
    if (laid_out.len == 0) return false;

    try out.writeAll(laid_out);
    return true;
}

/// Runs the formatter for a block with two sides, such as an edit's diff. `text`
/// goes in on standard input as usual, and the two sides are written to billy's
/// own files and passed as the script's first two arguments, so a two-file
/// differ is handed the files it wants. The files are removed once the script has
/// run, whether or not it could be used.
pub fn runDiff(format: Format, text: []const u8, old: []const u8, new: []const u8, out: *Io.Writer) !bool {
    const formatter = format orelse return false;

    var dir = Io.Dir.openDirAbsolute(formatter.io, sides_dir, .{}) catch return false;
    defer dir.close(formatter.io);

    var old_buffer: [max_path]u8 = undefined;
    const old_path = writeSide(formatter.io, dir, old, "old", &old_buffer) orelse return false;
    defer dir.deleteFile(formatter.io, std.fs.path.basename(old_path)) catch {};

    var new_buffer: [max_path]u8 = undefined;
    const new_path = writeSide(formatter.io, dir, new, "new", &new_buffer) orelse return false;
    defer dir.deleteFile(formatter.io, std.fs.path.basename(new_path)) catch {};

    return run(format, text, &.{ old_path, new_path }, out);
}

/// Writes `data` to a fresh file in `dir`, whose name is the prefix, a random
/// suffix and `kind`. The file is created under a name no other holds, so a name
/// already taken is retried with a new suffix; the full path is written into
/// `buffer` and returned, or null when the name could not be made free or the
/// write failed.
fn writeSide(io: Io, dir: Io.Dir, data: []const u8, kind: []const u8, buffer: []u8) ?[]const u8 {
    var attempt: usize = 0;
    while (attempt < name_attempts) : (attempt += 1) {
        var suffix: [suffix_bytes]u8 = undefined;
        io.random(&suffix);
        const hex = std.fmt.bytesToHex(suffix, .lower);
        const path = std.fmt.bufPrint(
            buffer,
            sides_dir ++ "/" ++ sides_prefix ++ "{s}-{s}",
            .{ hex, kind },
        ) catch return null;

        // The create is exclusive: a name already taken is one to stay away from,
        // so it is retried rather than written over.
        const file = dir.createFile(io, std.fs.path.basename(path), .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return null,
        };

        var write_buffer: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &write_buffer);
        const wrote = blk: {
            writer.interface.writeAll(data) catch break :blk false;
            writer.interface.flush() catch break :blk false;
            break :blk true;
        };
        file.close(io);
        // A half-written file is not one the script should read, so it is removed
        // before giving up.
        if (!wrote) {
            dir.deleteFile(io, std.fs.path.basename(path)) catch {};
            return null;
        }
        return path;
    }
    return null;
}

/// The status a child process ended with, as the shell reports it: the exit code
/// it left, or 128 plus the signal that killed it.
pub fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(128 + @as(u32, @intFromEnum(signal))),
        .stopped => 128,
        .unknown => 255,
    };
}

test "each side is written to its own fresh file" {
    const gpa = std.testing.allocator;
    var dir = try Io.Dir.openDirAbsolute(std.testing.io, sides_dir, .{});
    defer dir.close(std.testing.io);

    var first_buffer: [max_path]u8 = undefined;
    const first = writeSide(std.testing.io, dir, "one", "old", &first_buffer) orelse return error.NoFile;
    defer dir.deleteFile(std.testing.io, std.fs.path.basename(first)) catch {};

    var second_buffer: [max_path]u8 = undefined;
    const second = writeSide(std.testing.io, dir, "two", "new", &second_buffer) orelse return error.NoFile;
    defer dir.deleteFile(std.testing.io, std.fs.path.basename(second)) catch {};

    // Billy's own name in the temporary directory, ended by the kind it holds.
    try std.testing.expect(std.mem.startsWith(u8, first, sides_dir ++ "/" ++ sides_prefix));
    try std.testing.expect(std.mem.endsWith(u8, first, "-old"));
    try std.testing.expect(std.mem.endsWith(u8, second, "-new"));
    // The suffix is random, so two files are not given the same name.
    try std.testing.expect(!std.mem.eql(u8, first, second));

    // Each file holds what it was given.
    const contents = try dir.readFileAlloc(std.testing.io, std.fs.path.basename(first), gpa, .limited(64));
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("one", contents);
}

