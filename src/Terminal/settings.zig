//! Where the terminal's settings are kept, so that input can be read a line at a time rather than a
//! keystroke at a time, and put back afterwards.

const builtin = @import("builtin");
const std = @import("std");

/// The settings `fd` is on now.
pub fn get(fd: std.posix.fd_t) !std.posix.termios {
    if (builtin.os.tag != .linux) return std.posix.tcgetattr(fd);
    var term: std.posix.termios = undefined;
    if (std.os.linux.tcgetattr(fd, &term) != 0) return error.NotATerminal;
    return term;
}

/// Replaces the settings of `fd` with `term`, at once rather than when the output has been written.
pub fn set(fd: std.posix.fd_t, term: std.posix.termios) !void {
    if (builtin.os.tag != .linux) return std.posix.tcsetattr(fd, .NOW, term);
    if (std.os.linux.tcsetattr(fd, .NOW, &term) != 0) return error.NotATerminal;
}
