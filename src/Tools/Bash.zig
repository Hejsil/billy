const std = @import("std");
const Tools = @import("../Tools.zig");
const format = @import("../format.zig");

const Bash = @This();

command: []const u8,
/// A short, one-line description of what the command does, written by the
/// model. It is shown in the call's header, so a collapsed call says what
/// it is for rather than only what it ran. Null when the model gave none,
/// which is every stored call from before the tool asked for one.
description: ?[]const u8 = null,

pub fn run(
    bash: Bash,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    timeout: std.Io.Duration,
    out: *std.Io.Writer,
) !void {
    // Longest output captured from one command.
    const max_command_output = 1 << 20;

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "bash", "-c", bash.command },
        // The command runs where the session's tools do, so a resumed session
        // runs it in the directory the session was started in.
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        // A command that outlives the configured limit is killed, so a
        // runaway command cannot hang the agent forever.
        .timeout = .{ .duration = .{ .clock = .awake, .raw = timeout } },
    }) catch |err| switch (err) {
        error.StreamTooLong => return Tools.fail(
            out,
            "command produced more than {d} bytes of output",
            .{max_command_output},
        ),
        error.Timeout => return Tools.fail(
            out,
            "command did not finish within {d}s and was killed",
            .{timeout.toSeconds()},
        ),
        else => return Tools.fail(out, "cannot run command: {s}", .{@errorName(err)}),
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try out.print("exit code: {d}\n", .{format.exitCode(result.term)});

    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try out.writeAll("(no output)\n");
    }

    try out.writeAll(result.stdout);
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) try out.writeAll("\n");
        try out.print("stderr:\n{s}", .{result.stderr});
    }
}
