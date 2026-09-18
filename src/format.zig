//! Laying text out for the display with an external command.
//!
//! A format is a shell script that reads the text on standard input and writes
//! the laid-out text on standard output, such as `shfmt | bat -l bash` for a
//! bash command or `glow -` for markdown. It is what a configuration sets.
//!
//! The layout is presentation only: the command that runs, what a session stores
//! and what the model is sent keep the text that was written.

const std = @import("std");
const Io = std.Io;

/// Room above the text when the laid-out text is read back, so a formatter that
/// runs away cannot exhaust memory.
const slack = 1 << 20;

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

/// Runs `text` through the formatter and writes what it makes of the text to
/// `out`. Returns whether it could; false leaves `out` untouched, so the caller
/// can show the text as written. That is what no formatter gives, and a
/// formatter that cannot be run, rejects the text, writes nothing or writes too
/// much.
pub fn apply(format: Format, text: []const u8, out: *Io.Writer) !bool {
    const formatter = format orelse return false;
    var child = std.process.spawn(formatter.io, .{
        .argv = &.{ "bash", "-c", formatter.script },
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
