const std = @import("std");
const Io = std.Io;

const billy = @import("billy");

/// What billy is, shown at the top of its own help.
const billy_about = "A small fast AI agent that works in your terminal.";

/// What the `login` subcommand is for, shown in its help.
const login_about =
    \\Store an API key for a service, so it need not be exported before every
    \\run. With no service, list the services billy needs a key for and where
    \\each key comes from.
;

/// What the `config` subcommand is for, shown in its help.
const config_about =
    \\Set one setting in the configuration file, named by its dotted path, and
    \\write it back, so a setting can be changed without opening the file by
    \\hand; for example, `billy config tools.bash.format 'shfmt'`. A string is
    \\taken as it is, a number from its digits, and `null` clears a setting that
    \\has no value.
;

/// The subcommands billy itself has, and what each is for, shown in billy's own
/// help.
const billy_commands =
    \\  login [<service>]         store an API key, or list the services
    \\  config <setting> <value>  set a configuration setting by its path
;

/// The options billy itself takes.
const run_options =
    \\  -r, --resume <session>  continue the session with this id
    \\  -h, --help              print this message
;

/// The options a subcommand takes. None takes an argument yet, so the only one
/// is the usage itself.
const command_options =
    \\  -h, --help  print this message
;

/// Prints a help message: how the command is invoked, what it is for, the
/// subcommands it has, and the options it takes. Every message has those parts
/// in that order, so billy's own help and a subcommand's read alike.
///
/// `commands` is what the command itself can be asked for, or null when it has
/// none, as `login` and `config` do: a subcommand lists only the subcommands it
/// has, and a command that has none says nothing of them.
fn printHelp(
    out: *Io.Writer,
    invocation: []const u8,
    description: []const u8,
    commands: ?[]const u8,
    options: []const u8,
) !void {
    try out.print("usage: {s}\n\n{s}\n", .{ invocation, description });
    if (commands) |list| try out.print("\nCommands:\n{s}\n", .{list});
    try out.print("\nOptions:\n{s}\n", .{options});
}

/// Whether `arg` asks for a usage message.
fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

const Options = struct {
    /// Session to continue; a new one is started when this is null.
    resume_id: ?[]const u8 = null,
    /// Whether the user asked for usage instead of a run.
    help: bool = false,
    /// Set when the `login` subcommand was asked for. The service is the one to
    /// store a key for, or null to list the services and the keys they have.
    login: ?Login = null,
    /// Set when the `config` subcommand was asked for: the setting to change,
    /// named by its dotted path, and the text to set it to.
    config: ?Config = null,

    const Login = struct {
        service: ?[]const u8 = null,
        /// Whether the user asked for this subcommand's usage.
        help: bool = false,
    };

    const Config = struct {
        /// The setting to change, named by its dotted path. Null when only the
        /// usage was asked for.
        path: ?[]const u8 = null,
        /// The text to set the setting to. Null when only the usage was asked
        /// for.
        value: ?[]const u8 = null,
        /// Whether the user asked for this subcommand's usage.
        help: bool = false,
    };
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
        try printHelp(out, "billy [command] [options]", billy_about, billy_commands, run_options);
        return;
    }

    // A subcommand asked for its usage is answered before billy's own files are
    // reached for, so its help works even when nothing else can be read. None of
    // them has subcommands of its own, so none lists any.
    if (options.login) |login| {
        if (login.help) return printHelp(out, "billy login [<service>]", login_about, null, command_options);
    }
    if (options.config) |setting| {
        if (setting.help) return printHelp(out, "billy config <setting> <value>", config_about, null, command_options);
    }

    // The config subcommand only touches the configuration file, so it runs
    // before billy's own files and credentials are reached for.
    if (options.config) |setting| {
        try billy.Config.run(
            io,
            out,
            arena,
            init.gpa,
            init.environ_map,
            setting.path.?,
            setting.value.?,
        );
        return;
    }

    // The login subcommand needs the credentials and nothing else, so it is
    // handled on its own rather than through the setup a run needs.
    if (options.login) |login| return runLogin(init, out, login.service);

    // Everything else needs the whole of what billy reads in: the configuration,
    // the credentials and the directories it keeps its files in.
    var setup = try billy.Setup.open(init, out);
    defer setup.deinit();

    return runSession(init, out, &setup, options.resume_id);
}

/// Reads a key for a service, or lists the services, so a run need not have the
/// key exported. Only the credentials are read, since nothing else is touched.
fn runLogin(init: std.process.Init, out: *Io.Writer, service: ?[]const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    const data_dir = billy.Session.dataDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store billy's files: {s}", .{@errorName(err)});
        return err;
    };
    var data_dir_handle = Io.Dir.cwd().createDirPathOpen(io, data_dir, .{}) catch |err| {
        std.log.err("cannot use {s} for billy's files: {s}", .{ data_dir, @errorName(err) });
        return err;
    };
    defer data_dir_handle.close(io);

    var credentials = billy.credentials.load(io, data_dir_handle, arena) catch |err| {
        std.log.err("cannot read the credentials in {s}: {s}", .{ data_dir, @errorName(err) });
        return err;
    };
    try billy.credentials.run(
        io,
        out,
        arena,
        data_dir_handle,
        data_dir,
        &credentials,
        environ,
        service,
    );
}

/// Runs one session in the terminal, resuming `resume_id` or starting a new one.
fn runSession(
    init: std.process.Init,
    out: *Io.Writer,
    setup: *billy.Setup,
    resume_id: ?[]const u8,
) !void {
    const io = init.io;

    // A resumed session keeps the directory it was saved with, so a session
    // continues where it was started rather than wherever it is picked up.
    var session = billy.Session.open(
        io,
        setup.sessions,
        init.gpa,
        resume_id,
        setup.cwd,
    ) catch |err| switch (err) {
        error.SessionNotFound => {
            std.log.err("no session '{s}' in {s}", .{ resume_id.?, setup.sessions_path });
            return err;
        },
        error.InvalidSessionId => {
            std.log.err("'{s}' cannot be used as a session name", .{resume_id.?});
            return err;
        },
        else => return err,
    };
    defer session.deinit();

    // The terminal lays its blocks out for the terminal it is on, which the
    // escape codes of a pipe or a redirection would only be noise in.
    const config = try setup.agentConfig(session.cwd, billy.style.Style.detect(io));

    if (resume_id != null) {
        // Replay the conversation as a transcript, so the context does not
        // have to be remembered from the previous run. Only the last few blocks
        // are shown, so resuming a long one is quick.
        try billy.agent.printTranscript(
            init.gpa,
            out,
            &session,
            config.display,
            setup.settings.resume_blocks,
        );
    }
    try billy.agent.run(io, init.gpa, out, config, &session);
}

/// Reads the command line, whose first entry is the executable name. The `login`
/// subcommand takes the rest of the line, so it is read on its own rather than
/// mixed with the run options.
fn parseArgs(args: []const [:0]const u8) error{ InvalidArgument, MissingValue }!Options {
    if (args.len > 1 and std.mem.eql(u8, args[1], "login")) {
        if (args.len == 2) return .{ .login = .{} };
        if (args.len == 3 and isHelp(args[2])) return .{ .login = .{ .help = true } };
        if (args.len == 3 and args[2].len > 0 and args[2][0] != '-') {
            return .{ .login = .{ .service = args[2] } };
        }
        return error.InvalidArgument;
    }

    // `config` takes exactly a setting and the value to give it, and owns the
    // rest of the line, so neither is read as a run option.
    if (args.len > 1 and std.mem.eql(u8, args[1], "config")) {
        if (args.len == 3 and isHelp(args[2])) return .{ .config = .{ .help = true } };
        if (args.len == 4 and args[2].len > 0 and args[2][0] != '-') {
            return .{ .config = .{ .path = args[2], .value = args[3] } };
        }
        return error.InvalidArgument;
    }

    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelp(arg)) {
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

test "parseArgs reads the login subcommand on its own" {
    try expectOptions(.{ .login = .{} }, try parseArgs(&.{ "billy", "login" }));
    try expectOptions(
        .{ .login = .{ .service = "tavily" } },
        try parseArgs(&.{ "billy", "login", "tavily" }),
    );
    // The subcommand has its own usage, so `-h` after it is not read as a run
    // option.
    try expectOptions(.{ .login = .{ .help = true } }, try parseArgs(&.{ "billy", "login", "-h" }));
    try expectOptions(.{ .login = .{ .help = true } }, try parseArgs(&.{ "billy", "login", "--help" }));
    // The subcommand owns the rest of the line, so a run option after it is not
    // a run option, a second service is not an argument it takes, and a service
    // beside the usage is not read.
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "--resume" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "tavily", "extra" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "" }));
}

test "parseArgs reads the config subcommand on its own" {
    try expectOptions(
        .{ .config = .{ .path = "tools.bash.format", .value = "shfmt | bat -l bash" } },
        try parseArgs(&.{ "billy", "config", "tools.bash.format", "shfmt | bat -l bash" }),
    );
    // A value may look like an option or be empty; the path may not.
    try expectOptions(
        .{ .config = .{ .path = "tools.bash.format", .value = "--nope" } },
        try parseArgs(&.{ "billy", "config", "tools.bash.format", "--nope" }),
    );
    try expectOptions(
        .{ .config = .{ .path = "markdown.format", .value = "" } },
        try parseArgs(&.{ "billy", "config", "markdown.format", "" }),
    );
    // The subcommand has its own usage.
    try expectOptions(.{ .config = .{ .help = true } }, try parseArgs(&.{ "billy", "config", "-h" }));
    try expectOptions(.{ .config = .{ .help = true } }, try parseArgs(&.{ "billy", "config", "--help" }));
    // A setting without a value, a value without a setting, an option-shaped
    // setting, and trailing arguments are all refused.
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "max_turns" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "--nope", "1" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "max_turns", "1", "extra" }));
}

/// The slices in `Options` are compared by content rather than by pointer.
fn expectOptions(expected: Options, actual: Options) !void {
    try std.testing.expectEqual(expected.help, actual.help);
    if (expected.resume_id) |id| {
        try std.testing.expectEqualStrings(id, actual.resume_id.?);
    } else {
        try std.testing.expect(actual.resume_id == null);
    }
    if (expected.login) |login| {
        const actual_login = actual.login.?;
        try std.testing.expectEqual(login.help, actual_login.help);
        if (login.service) |service| {
            try std.testing.expectEqualStrings(service, actual_login.service.?);
        } else {
            try std.testing.expect(actual_login.service == null);
        }
    } else {
        try std.testing.expect(actual.login == null);
    }
    if (expected.config) |setting| {
        const actual_setting = actual.config.?;
        try std.testing.expectEqual(setting.help, actual_setting.help);
        if (setting.path) |path| {
            try std.testing.expectEqualStrings(path, actual_setting.path.?);
        } else {
            try std.testing.expect(actual_setting.path == null);
        }
        if (setting.value) |value| {
            try std.testing.expectEqualStrings(value, actual_setting.value.?);
        } else {
            try std.testing.expect(actual_setting.value == null);
        }
    } else {
        try std.testing.expect(actual.config == null);
    }
}

/// A help message as `printHelp` writes it, for checking the shape all of them
/// share.
const help_messages = [_]struct {
    invocation: []const u8,
    description: []const u8,
    commands: ?[]const u8,
    options: []const u8,
}{
    .{
        .invocation = "billy [command] [options]",
        .description = billy_about,
        .commands = billy_commands,
        .options = run_options,
    },
    .{
        .invocation = "billy login [<service>]",
        .description = login_about,
        .commands = null,
        .options = command_options,
    },
    .{
        .invocation = "billy config <setting> <value>",
        .description = config_about,
        .commands = null,
        .options = command_options,
    },
};

test "every help message reads the same way" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (help_messages) |message| {
        out.clearRetainingCapacity();
        try printHelp(&out.writer, message.invocation, message.description, message.commands, message.options);
        const text = out.written();

        // The parts come in one order: how it is invoked, what it is, the
        // subcommands it has, and the options it takes. A command with no
        // subcommands leaves that part out entirely.
        const usage_at = std.mem.indexOf(u8, text, "usage: ").?;
        const description_at = std.mem.indexOf(u8, text, message.description).?;
        const options_at = std.mem.indexOf(u8, text, "Options:").?;
        try std.testing.expect(usage_at < description_at);
        try std.testing.expect(description_at < options_at);
        if (message.commands) |commands| {
            const commands_at = std.mem.indexOf(u8, text, "Commands:").?;
            try std.testing.expect(description_at < commands_at);
            try std.testing.expect(commands_at < options_at);
            // Each part is set off from the one before it by a blank line.
            try std.testing.expect(std.mem.indexOf(u8, text, "\n\nCommands:\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "\n\nOptions:\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, commands) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, text, "Commands:") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "\n\nOptions:\n") != null);
        }

        // The invocation and the options are the ones the command has, and the
        // options are the last part, with the message ending right after them.
        try std.testing.expect(std.mem.indexOf(u8, text, message.invocation) != null);
        try std.testing.expectEqualStrings(
            message.options,
            std.mem.trimEnd(u8, text[options_at + "Options:\n".len ..], "\n"),
        );
    }
}
