const std = @import("std");

const Tools = @import("../Tools.zig");

const Bash = @This();

command: []const u8,
description: ?[]const u8 = null,

pub fn run(bash: Bash, tools: Tools, out: *std.Io.Writer) !void {
    const timeout_s = std.math.cast(i64, tools.settings.bash_timeout_s) orelse std.math.maxInt(i64);
    const timeout = std.Io.Duration.fromSeconds(timeout_s);

    const max_command_output = 1 << 20;

    const result = std.process.run(tools.gpa, tools.io, .{
        .argv = &.{ "bash", "-c", bash.command },
        // The command runs where the session's tools do, which is the session's own directory
        // rather than the one billy was started in.
        .cwd = .{ .dir = tools.dir },
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        // A command that outlives the configured limit is killed, so a runaway command cannot hang
        // the agent forever.
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
        else => return Tools.fail(out, "cannot run command: {t}", .{err}),
    };
    defer tools.gpa.free(result.stdout);
    defer tools.gpa.free(result.stderr);

    try out.print("exit code: {d}\n", .{exitCode(result.term)});

    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try out.writeAll("(no output)\n");
    }

    try out.writeAll(result.stdout);
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) try out.writeAll("\n");
        try out.print("stderr:\n{s}", .{result.stderr});
    }
}

pub fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(128 + @as(u32, @backingInt(signal))),
        .stopped => 128,
        .unknown => 255,
    };
}

test "exit codes of signals follow the shell convention" {
    try std.testing.expectEqual(0, exitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(1, exitCode(.{ .exited = 1 }));
    try std.testing.expectEqual(130, exitCode(.{ .signal = .INT }));
    try std.testing.expectEqual(143, exitCode(.{ .signal = .TERM }));
}
