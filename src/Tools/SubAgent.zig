//! The agent tool: a sub agent is another billy, run for one answer and then gone.

const std = @import("std");

const Credentials = @import("../Credentials.zig");
const Tools = @import("../Tools.zig");

const SubAgent = @This();

prompt: []const u8,
/// The session to continue, as an earlier call returned it; a new one is started without it.
session: ?[]const u8 = null,

/// The most a sub agent may say, which the tool's own cap cuts further.
const max_answer_bytes = 1 << 20;

pub fn run(sub: SubAgent, tools: Tools, out: *std.Io.Writer) !void {
    if (!tools.settings.sub_agents)
        return Tools.fail(out, "no agent can be started from here", .{});

    const exe = std.process.executablePathAlloc(tools.io, tools.gpa) catch |err|
        return Tools.fail(out, "cannot find this billy: {t}", .{err});
    defer tools.gpa.free(exe);

    return sub.runWith(tools, out, exe);
}

/// Asks `exe` as a sub agent: the tool's work, with the billy it runs named by the caller.
fn runWith(sub: SubAgent, tools: Tools, out: *std.Io.Writer, exe: []const u8) !void {
    var argv: [7][]const u8 = undefined;
    const result = std.process.run(tools.gpa, tools.io, .{
        .argv = commandLine(&argv, exe, sub),
        // The sub agent works where this run does, under its own configuration.
        .cwd = .{ .dir = tools.dir },
        .stdout_limit = .limited(max_answer_bytes),
        .stderr_limit = .limited(max_answer_bytes),
    }) catch |err| switch (err) {
        error.StreamTooLong => return Tools.fail(out, "the agent said more than {d} bytes", .{max_answer_bytes}),
        else => |other| return Tools.fail(out, "cannot run the agent: {t}", .{other}),
    };
    defer tools.gpa.free(result.stdout);
    defer tools.gpa.free(result.stderr);

    const said = std.mem.trimEnd(u8, result.stdout, "\n");
    if (!answered(result.term)) {
        // A failed child marks its own words; anything else there is given the mark here.
        if (said.len > 0) {
            if (std.mem.startsWith(u8, said, "error: ")) return out.writeAll(said);
            return Tools.fail(out, "{s}", .{said});
        }
        // Nothing on the answer stream, so its log is the reason, less a mark it already carries.
        const logged = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (logged.len > 0) return Tools.fail(out, "{s}", .{std.mem.cutPrefix(u8, logged, "error: ") orelse logged});
        return Tools.fail(out, "the agent stopped without a word", .{});
    }
    return out.writeAll(said);
}

/// The command that asks a sub agent: this billy, one-shot, told which session to continue and
/// given the prompt after `--` so a prompt that begins with a dash is taken as one.
fn commandLine(
    argv: *[7][]const u8,
    exe: []const u8,
    sub: SubAgent,
) []const []const u8 {
    var count: usize = 0;
    argv[count] = exe;
    count += 1;
    argv[count] = "ask";
    count += 1;
    // A sub agent is not offered this tool itself, so a run can start one and no more.
    argv[count] = "--no-agents";
    count += 1;
    if (sub.session) |id| {
        argv[count] = "--session";
        argv[count + 1] = id;
        count += 2;
    }
    argv[count] = "--";
    count += 1;
    argv[count] = sub.prompt;
    count += 1;
    return argv[0..count];
}

fn answered(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn writeChild(dir: std.Io.Dir, io: std.Io, script: []const u8) !void {
    try Tools.writeFile(io, dir, "billy", script);
    const executable: std.Io.File.Permissions = @fromBackingInt(@intCast(0o700));
    try dir.setFilePermissions(io, "billy", executable, .{});
}

fn testTools(gpa: std.mem.Allocator, dir: std.Io.Dir, sub_agents: bool) Tools {
    return Tools.init(std.testing.io, dir, gpa, undefined, .{
        .bash_timeout_s = 120,
        .keys = &Credentials.empty,
        .sub_agents = sub_agents,
    });
}

test "the tool asks a billy of its own and keeps the session it names" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeChild(tmp.dir, io,
        \\#!/bin/sh
        \\printf '%s\n' "$@" > argv.txt
        \\echo 'session: 01K0000000000000000000000'
        \\echo
        \\echo 'the sub agent found it'
        \\
    );
    const exe = try tmp.dir.realPathFileAlloc(io, "billy", gpa);
    defer gpa.free(exe);

    const tool_set = testTools(gpa, tmp.dir, true);

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const call: SubAgent = .{ .prompt = "find it" };
    try call.runWith(tool_set, &result.writer, exe);

    // The child is asked one thing and told not to start agents of its own, and the prompt is
    // marked as one so a leading dash is not read as an option.
    const argv = try tmp.dir.readFileAlloc(io, "argv.txt", gpa, .limited(4096));
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("ask\n--no-agents\n--\nfind it\n", argv);

    // What the child said is the call's result as it stands, session and all, so the call can be
    // continued.
    try std.testing.expectEqualStrings(
        "session: 01K0000000000000000000000\n\nthe sub agent found it",
        result.written(),
    );

    result.clearRetainingCapacity();
    const again: SubAgent = .{ .prompt = "look again", .session = "01K0000000000000000000000" };
    try again.runWith(tool_set, &result.writer, exe);

    const second = try tmp.dir.readFileAlloc(io, "argv.txt", gpa, .limited(4096));
    defer gpa.free(second);
    try std.testing.expectEqualStrings(
        "ask\n--no-agents\n--session\n01K0000000000000000000000\n--\nlook again\n",
        second,
    );
}

test "a child that failed is the call's failure, in the words it failed in" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeChild(tmp.dir, io,
        \\#!/bin/sh
        \\echo 'error: no session 01K0000000000000000000000'
        \\exit 1
        \\
    );
    const exe = try tmp.dir.realPathFileAlloc(io, "billy", gpa);
    defer gpa.free(exe);

    const tool_set = testTools(gpa, tmp.dir, true);

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const call: SubAgent = .{ .prompt = "hi" };
    try call.runWith(tool_set, &result.writer, exe);
    try std.testing.expectEqualStrings(
        "error: no session 01K0000000000000000000000",
        result.written(),
    );
}

test "a child that said nothing and logged nothing is a failure of its own" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeChild(tmp.dir, io,
        \\#!/bin/sh
        \\exit 3
        \\
    );
    const exe = try tmp.dir.realPathFileAlloc(io, "billy", gpa);
    defer gpa.free(exe);

    const tool_set = testTools(gpa, tmp.dir, true);

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const call: SubAgent = .{ .prompt = "hi" };
    try call.runWith(tool_set, &result.writer, exe);
    try std.testing.expectEqualStrings("error: the agent stopped without a word", result.written());
}

test "what a child logged is the failure when it said nothing on its answer stream" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeChild(tmp.dir, io,
        \\#!/bin/sh
        \\echo 'error: cannot read the configuration: CorruptConfig' >&2
        \\exit 1
        \\
    );
    const exe = try tmp.dir.realPathFileAlloc(io, "billy", gpa);
    defer gpa.free(exe);

    const tool_set = testTools(gpa, tmp.dir, true);

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const call: SubAgent = .{ .prompt = "hi" };
    try call.runWith(tool_set, &result.writer, exe);
    try std.testing.expectEqualStrings(
        "error: cannot read the configuration: CorruptConfig",
        result.written(),
    );
}

test "a run that offers no sub agents is not given the tool, and cannot call it either" {
    const gpa = std.testing.allocator;

    var tool_set = testTools(gpa, std.Io.Dir.cwd(), false);
    for (tool_set.definitions()) |definition| {
        try std.testing.expect(!std.mem.eql(u8, definition.name, "agent"));
    }

    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    var parse_state = std.heap.ArenaAllocator.init(gpa);
    defer parse_state.deinit();
    try tool_set.run(
        Tools.parseCallNamed(parse_state.allocator(), "agent", "{\"prompt\":\"hi\"}"),
        &result.writer,
    );
    try std.testing.expectEqualStrings("error: no agent can be started from here", result.written());
}
