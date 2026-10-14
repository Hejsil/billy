const std = @import("std");

const billy = @import("billy");
const spaghet = @import("spaghet");

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

/// What the `serve` subcommand is for, shown in its help.
const serve_about =
    \\Run billy as a server with a web frontend instead of in the terminal.
    \\It listens on this machine only unless another address is asked for, and
    \\has no authentication: anything that can reach it can run commands as you,
    \\so only listen where that is meant.
;

/// The subcommands billy itself has, and what each is for, shown in billy's own
/// help.
const billy_commands =
    \\  login [<service>]         store an API key, or list the services
    \\  config <setting> <value>  set a configuration setting by its path
    \\  serve                     run the web frontend
;

/// The options billy itself takes.
const run_options =
    \\  -r, --resume <session>  continue the session with this id
    \\  -h, --help              print this message
;

/// The options a subcommand takes, when it takes none but the usage itself.
const command_options =
    \\  -h, --help  print this message
;

/// The options the `serve` subcommand takes.
const serve_options =
    \\  -p, --port <port>  the port to listen on, by default 8787
    \\      --host <addr>  the address to listen on, by default 127.0.0.1;
    \\                     "localhost" and an address such as 0.0.0.0 or
    \\                     192.168.1.5 are taken; names are not resolved
    \\  -h, --help         print this message
;

/// Prints a help message: how the command is invoked, what it is for, the
/// subcommands it has, and the options it takes. Every message has those parts
/// in that order, so billy's own help and a subcommand's read alike.
///
/// `commands` is what the command itself can be asked for, or null when it has
/// none, as `login` and `config` do: a subcommand lists only the subcommands it
/// has, and a command that has none says nothing of them.
fn printHelp(
    out: *std.Io.Writer,
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

    command: Command = .none,

    const Command = union(enum) {
        none,
        login: Login,
        config: Config,
        serve: Serve,
    };

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

    const Serve = struct {
        /// The address to listen on. Loopback unless asked otherwise, since the
        /// server has no authentication and its routes run commands as the user.
        host: []const u8 = billy.Server.default_host,
        /// The port to listen on. Zero asks the system for a free one.
        port: u16 = billy.Server.default_port,
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
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const options = parseArgsSlice(argv[1..]) catch |err| {
        std.log.err("invalid arguments, try --help", .{});
        return err;
    };
    if (options.help) {
        try printHelp(out, "billy [command] [options]", billy_about, billy_commands, run_options);
        return;
    }

    switch (options.command) {
        .none => {
            var setup = try billy.Setup.open(init, out);
            defer setup.deinit(io);

            return runSession(init, out, &setup, options.resume_id);
        },
        .serve => |serve| {
            if (serve.help)
                return printHelp(out, "billy serve [--port <port>] [--host <addr>]", serve_about, null, serve_options);

            var setup = try billy.Setup.open(init, out);
            defer setup.deinit(io);

            const server = billy.Server{
                .io = io,
                .gpa = init.gpa,
                .session_dir = setup.sessions,
                .setup = &setup,
            };
            return server.serve(serve.host, serve.port);
        },
        .config => |config| {
            if (config.help)
                return printHelp(out, "billy config <setting> <value>", config_about, null, command_options);
            var dirs = try billy.Dirs.open(io, arena, init.environ_map);
            defer dirs.deinit(io);

            return billy.Config.run(
                io,
                out,
                init.gpa,
                dirs.config,
                config.path.?,
                config.value.?,
            );
        },
        .login => |login| {
            if (login.help)
                return printHelp(out, "billy login [<service>]", login_about, null, command_options);
            return runLogin(init, out, login.service);
        },
    }
}

/// Reads a key for a service, or lists the services, so a run need not have the
/// key exported.
///
/// The configuration is read for the names of the providers it defines, which
/// are the only names beside billy's own that a key can be stored for. Nothing
/// else of it is used.
fn runLogin(init: std.process.Init, out: *std.Io.Writer, service: ?[]const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    var dirs = try billy.Dirs.open(io, arena, environ);
    defer dirs.deinit(io);

    var opened = try billy.Config.open(io, dirs.config, init.gpa);
    defer opened.config.deinit();

    var provider_names: std.ArrayList([]const u8) = .empty;
    for (opened.config.stored.providers.entries) |entry| {
        try provider_names.append(arena, entry.name);
    }

    var credentials = billy.credentials.load(io, dirs.data, arena) catch |err| {
        std.log.err("cannot read the credentials: {s}", .{@errorName(err)});
        return err;
    };
    try billy.credentials.run(
        io,
        out,
        arena,
        dirs.data,
        &credentials,
        provider_names.items,
        service,
    );
}

/// Runs one session in the terminal, resuming `resume_id` or starting a new one.
fn runSession(
    init: std.process.Init,
    out: *std.Io.Writer,
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
            std.log.err("no session '{s}'", .{resume_id.?});
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
    const config = setup.agentConfig(session.cwd(), billy.Terminal.Style.detect(io, .stdout()));

    if (resume_id != null) {
        // Replay the conversation as a transcript, so the context does not
        // have to be remembered from the previous run. Only the last few blocks
        // are shown, so resuming a long one is quick.
        try billy.agent.printTranscript(
            io,
            init.gpa,
            out,
            &session,
            config.display,
            setup.config.stored.resume_blocks,
        );
    }
    // Where the session is sent is resolved into a buffer of its own, so the
    // run frees every string it made for it when the session is over: the URL
    // and the model are built per session, and nothing else holds them.
    var target_state = std.heap.ArenaAllocator.init(init.gpa);
    defer target_state.deinit();
    const target = try setup.sessionTarget(target_state.allocator(), &session);
    try billy.agent.run(io, init.gpa, out, config, &session, target);
}

const ParseError = error{InvalidArgument};

/// Parses `slice`, which is the arguments of one command line with the program
/// name left off, the way `main` parses the ones it is given.
fn parseArgsSlice(slice: []const []const u8) ParseError!Options {
    var args = spaghet.Args.initSlice(slice);
    return parseArgs(&args);
}

/// Reads billy's arguments: what to run, and the options of whichever part of
/// it was asked for.
fn parseArgs(args: *spaghet.Args) ParseError!Options {
    var options: Options = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            options.help = true;
        if (args.option(&.{ "-r", "--resume" })) |id|
            options.resume_id = id;
        if (args.positional()) |command|
            options.command = try parseCommand(args, command);
    }
    return options;
}

/// Reads the subcommand `command`, which is the first argument of the line.
fn parseCommand(args: *spaghet.Args, command: []const u8) ParseError!Options.Command {
    if (std.mem.eql(u8, command, "login"))
        return .{ .login = try parseLogin(args) };
    if (std.mem.eql(u8, command, "config"))
        return .{ .config = try parseConfig(args) };
    if (std.mem.eql(u8, command, "serve"))
        return .{ .serve = try parseServe(args) };
    return error.InvalidArgument;
}

/// Reads the arguments of the `login` subcommand: nothing, or the service to
/// store a key for, and its own usage.
fn parseLogin(args: *spaghet.Args) ParseError!Options.Login {
    var login: Options.Login = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            login.help = true;
        if (login.service == null)
            login.service = args.positional();
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    return login;
}

/// Reads the arguments of the `config` subcommand: a setting and the value to
/// give it, and its own usage. Neither is optional: a setting with nothing to
/// set it to names no change to make.
fn parseConfig(args: *spaghet.Args) ParseError!Options.Config {
    var setting: Options.Config = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            setting.help = true;
        if (setting.path == null)
            setting.path = args.positional();
        if (setting.value == null)
            setting.value = args.positional();
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    if (!setting.help and (setting.path == null or setting.value == null)) {
        return error.InvalidArgument;
    }
    return setting;
}

/// Reads the arguments of the `serve` subcommand: where it listens, and its own
/// usage.
fn parseServe(args: *spaghet.Args) ParseError!Options.Serve {
    var serve: Options.Serve = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            serve.help = true;
        if (args.option(&.{ "-p", "--port" })) |port|
            serve.port = std.fmt.parseInt(u16, port, 10) catch return error.InvalidArgument;
        if (args.option(&.{"--host"})) |host|
            serve.host = host;
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    return serve;
}

test "parseArgs" {
    try expectOptions(.{}, try parseArgsSlice(&.{}));
    try expectOptions(.{ .help = true }, try parseArgsSlice(&.{"--help"}));
    try expectOptions(
        .{ .resume_id = "20250131-120000" },
        try parseArgsSlice(&.{ "--resume", "20250131-120000" }),
    );
    try expectOptions(.{ .resume_id = "dev" }, try parseArgsSlice(&.{ "-r", "dev" }));
    try expectOptions(.{ .resume_id = "dev" }, try parseArgsSlice(&.{"--resume=dev"}));
    try expectOptions(
        .{ .help = true, .resume_id = "both" },
        try parseArgsSlice(&.{ "--help", "--resume=both" }),
    );
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"--resume"}));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"--nope"}));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"extra"}));
}

test "parseArgs reads the login subcommand on its own" {
    try expectOptions(.{ .command = .{ .login = .{} } }, try parseArgsSlice(&.{"login"}));
    try expectOptions(
        .{ .command = .{ .login = .{ .service = "tavily" } } },
        try parseArgsSlice(&.{ "login", "tavily" }),
    );
    // The subcommand has its own usage, so `-h` after it is not read as a run
    // option.
    try expectOptions(
        .{ .command = .{ .login = .{ .help = true } } },
        try parseArgsSlice(&.{ "login", "-h" }),
    );
    try expectOptions(
        .{ .command = .{ .login = .{ .help = true } } },
        try parseArgsSlice(&.{ "login", "--help" }),
    );
    // The subcommand owns the rest of the line, so a run option after it is not
    // a run option, a second service is not an argument it takes, and a service
    // beside the usage is not read.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "login", "tavily", "extra" }));
}

test "parseArgs reads the serve subcommand on its own" {
    // No port: the default, and no help.
    try expectOptions(.{ .command = .{ .serve = .{} } }, try parseArgsSlice(&.{"serve"}));

    // The port is read, however it is written.
    try expectServe(9000, try parseArgsSlice(&.{ "serve", "--port", "9000" }));
    try expectServe(9000, try parseArgsSlice(&.{ "serve", "-p", "9000" }));
    try expectServe(9000, try parseArgsSlice(&.{ "serve", "--port=9000" }));
    try expectServe(0, try parseArgsSlice(&.{ "serve", "--port", "0" }));

    // The address is read too, and both may be given in either order.
    try expectHost("0.0.0.0", try parseArgsSlice(&.{ "serve", "--host", "0.0.0.0" }));
    try expectHost("192.168.1.5", try parseArgsSlice(&.{ "serve", "--host=192.168.1.5" }));
    try expectHost("::1", try parseArgsSlice(&.{ "serve", "--host", "::1", "--port", "9" }));
    try expectHost("::1", try parseArgsSlice(&.{ "serve", "--port", "9", "--host", "::1" }));
    // An address that is not given a value is refused, like a port.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--host" }));
    // The default is to listen where only this machine can reach.
    try expectHost(billy.Server.default_host, try parseArgsSlice(&.{"serve"}));

    // The subcommand has its own usage.
    try expectOptions(.{ .command = .{ .serve = .{ .help = true } } }, try parseArgsSlice(&.{ "serve", "-h" }));
    try expectOptions(.{ .command = .{ .serve = .{ .help = true } } }, try parseArgsSlice(&.{ "serve", "--help" }));

    // A port that is missing, or not a number, or out of range, is refused.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port", "abc" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port", "70000" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port=-1" }));
    // The subcommand owns the rest of the line, so a run option after it is not
    // a run option.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--resume", "x" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "extra" }));
}

/// Checks the port a serve parse read, since `expectOptions` cannot compare it.
fn expectServe(expected: u16, actual: Options) !void {
    try std.testing.expectEqual(expected, actual.command.serve.port);
}

/// Checks the address a serve parse read.
fn expectHost(expected: []const u8, actual: Options) !void {
    try std.testing.expectEqualStrings(expected, actual.command.serve.host);
}

test "parseArgs reads the config subcommand on its own" {
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.bash.format", .value = "shfmt | bat -l bash" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.format", "shfmt | bat -l bash" }),
    );
    // A value may look like an option or be empty; the path may not.
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.bash.format", .value = "--nope" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.format", "--nope" }),
    );
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.edit.format", .value = "" } } },
        try parseArgsSlice(&.{ "config", "tools.edit.format", "" }),
    );
    // The subcommand has its own usage.
    try expectOptions(.{ .command = .{ .config = .{ .help = true } } }, try parseArgsSlice(&.{ "config", "-h" }));
    try expectOptions(.{ .command = .{ .config = .{ .help = true } } }, try parseArgsSlice(&.{ "config", "--help" }));
    // A setting without a value, a value without a setting, an option-shaped
    // setting, and trailing arguments are all refused.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"config"}));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "config", "max_turns" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "config", "max_turns", "1", "extra" }));
}

/// The slices in `Options` are compared by content rather than by pointer.
fn expectOptions(expected: Options, actual: Options) !void {
    try std.testing.expectEqual(expected.help, actual.help);
    if (expected.resume_id) |id| {
        try std.testing.expectEqualStrings(id, actual.resume_id.?);
    } else {
        try std.testing.expect(actual.resume_id == null);
    }

    switch (expected.command) {
        .none => try std.testing.expect(actual.command == .none),
        .login => |login| {
            const actual_login = actual.command.login;
            try std.testing.expectEqual(login.help, actual_login.help);
            if (login.service) |service| {
                try std.testing.expectEqualStrings(service, actual_login.service.?);
            } else {
                try std.testing.expect(actual_login.service == null);
            }
        },
        .serve => |serve| {
            const actual_serve = actual.command.serve;
            try std.testing.expectEqual(serve.help, actual_serve.help);
            try std.testing.expectEqual(serve.port, actual_serve.port);
            try std.testing.expectEqualStrings(serve.host, actual_serve.host);
        },
        .config => |config| {
            const actual_config = actual.command.config;
            try std.testing.expectEqual(config.help, actual_config.help);
            if (config.path) |path| {
                try std.testing.expectEqualStrings(path, actual_config.path.?);
            } else {
                try std.testing.expect(actual_config.path == null);
            }
            if (config.value) |value| {
                try std.testing.expectEqualStrings(value, actual_config.value.?);
            } else {
                try std.testing.expect(actual_config.value == null);
            }
        },
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
