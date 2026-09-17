const std = @import("std");
const Io = std.Io;

const billy = @import("billy");

const usage =
    \\usage: billy [--resume <session>]
    \\
    \\  -r, --resume <session>  continue the session with this id
    \\  -h, --help              print this message
    \\
    \\The API key comes from DEEPSEEK_API_KEY or OPENAI_API_KEY. BILLY_BASE_URL
    \\and BILLY_MODEL override the endpoint and the model. Sessions are stored
    \\under $XDG_DATA_HOME/billy, or ~/.local/share/billy when that is unset.
    \\The configuration lives in $XDG_CONFIG_HOME/billy/config.json, or
    \\~/.config/billy/config.json when that is unset, and is created with the
    \\defaults on the first run.
    \\
;

const Options = struct {
    /// Session to continue; a new one is started when this is null.
    resume_id: ?[]const u8 = null,
    /// Whether the user asked for usage instead of a run.
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    // Anything that lives as long as the process, including the conversation,
    // is allocated here.
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const args = try std.process.Args.toSlice(init.minimal.args, arena);
    const options = parseArgs(args) catch |err| {
        std.log.err("invalid arguments, try --help", .{});
        return err;
    };
    if (options.help) {
        try out.writeAll(usage);
        return;
    }

    const api_key = init.environ_map.get("DEEPSEEK_API_KEY") orelse
        init.environ_map.get("OPENAI_API_KEY") orelse {
        std.log.err("set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };
    const base_url = init.environ_map.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";

    const config_dir = billy.config.defaultDir(arena, init.environ_map) catch |err| {
        std.log.err("cannot find where to store the configuration: {s}", .{@errorName(err)});
        return err;
    };
    var config_dir_handle = Io.Dir.cwd().createDirPathOpen(io, config_dir, .{}) catch |err| {
        std.log.err("cannot use {s} for the configuration: {s}", .{ config_dir, @errorName(err) });
        return err;
    };
    defer config_dir_handle.close(io);

    const settings = billy.config.Config.open(io, config_dir_handle, arena) catch |err| {
        std.log.err("cannot read the configuration in {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };
    if (settings.created) {
        try out.print("wrote the default configuration to {s}\n", .{
            try std.fs.path.join(arena, &.{ config_dir, billy.config.file_name }),
        });
    }

    const config: billy.agent.Config = .{
        .api_key = api_key,
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
            std.mem.trimEnd(u8, base_url, "/"),
        }),
        .model = init.environ_map.get("BILLY_MODEL") orelse "deepseek-flash",
        .max_turns = settings.config.max_turns,
    };

    const directory = billy.session.defaultDir(arena, init.environ_map) catch |err| {
        std.log.err("cannot find where to store sessions: {s}", .{@errorName(err)});
        return err;
    };
    var sessions_dir = Io.Dir.cwd().createDirPathOpen(io, directory, .{}) catch |err| {
        std.log.err("cannot use {s} for sessions: {s}", .{ directory, @errorName(err) });
        return err;
    };
    defer sessions_dir.close(io);

    var session = billy.session.Session.open(io, sessions_dir, arena, init.gpa, options.resume_id) catch |err| switch (err) {
        error.SessionNotFound => {
            std.log.err("no session '{s}' in {s}", .{ options.resume_id.?, directory });
            return err;
        },
        error.InvalidSessionId => {
            std.log.err("'{s}' cannot be used as a session name", .{options.resume_id.?});
            return err;
        },
        else => return err,
    };

    if (options.resume_id) |id| {
        try out.print("billy · {s} · resumed session {s} · Ctrl-D to exit\n", .{ config.model, id });
    } else {
        try out.print("billy · {s} · session {s} · Ctrl-D to exit\n", .{ config.model, session.id });
        try out.print("resume it later with: billy --resume {s}\n", .{session.id});
    }
    try billy.agent.run(io, arena, init.gpa, out, config, &session);
}

/// Reads the command line, whose first entry is the executable name.
fn parseArgs(args: []const [:0]const u8) error{ InvalidArgument, MissingValue }!Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.resume_id = args[i];
        } else if (std.mem.startsWith(u8, arg, "--resume=")) {
            options.resume_id = arg["--resume=".len..];
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

test "parseArgs" {
    try expectOptions(.{}, try parseArgs(&.{"billy"}));
    try expectOptions(.{ .help = true }, try parseArgs(&.{ "billy", "--help" }));
    try expectOptions(
        .{ .resume_id = "20250131-120000" },
        try parseArgs(&.{ "billy", "--resume", "20250131-120000" }),
    );
    try expectOptions(.{ .resume_id = "dev" }, try parseArgs(&.{ "billy", "-r", "dev" }));
    try expectOptions(.{ .resume_id = "dev" }, try parseArgs(&.{ "billy", "--resume=dev" }));
    try expectOptions(
        .{ .help = true, .resume_id = "both" },
        try parseArgs(&.{ "billy", "--help", "--resume=both" }),
    );
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "billy", "--resume" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "--nope" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "extra" }));
}

/// The slices in `Options` are compared by content rather than by pointer.
fn expectOptions(expected: Options, actual: Options) !void {
    try std.testing.expectEqual(expected.help, actual.help);
    if (expected.resume_id) |id| {
        try std.testing.expectEqualStrings(id, actual.resume_id.?);
    } else {
        try std.testing.expect(actual.resume_id == null);
    }
}
