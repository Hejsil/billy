const std = @import("std");

const Billy = @import("billy").Billy;
const report = @import("billy").report;
const Server = @import("billy").Server;
const Terminal = @import("billy").Terminal;
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
    \\hand; for example, `billy config tools.bash.timeout_s '300'`. A string is
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

/// What the `sessions` subcommand is for, shown in its help.
const sessions_about =
    \\List the sessions billy has kept, the one written to most recently first,
    \\one to a line: the id to resume it by, and the title it was given. A
    \\session that has not been named yet is listed by its id alone.
;

/// The subcommands billy itself has, and what each is for, shown in billy's own
/// help.
const billy_commands =
    \\  login [<service>]         store an API key, or list the services
    \\  config <setting> <value>  set a configuration setting by its path
    \\  sessions                  list the sessions, newest first
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
    out: Terminal.Writer,
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
        sessions: Sessions,
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
        host: []const u8 = Server.default_host,
        /// The port to listen on. Zero asks the system for a free one.
        port: u16 = Server.default_port,
        /// Whether the user asked for this subcommand's usage.
        help: bool = false,
    };

    /// The `sessions` subcommand takes nothing but its own usage.
    const Sessions = struct {
        /// Whether the user asked for this subcommand's usage.
        help: bool = false,
    };
};

/// Runs what the command line asked for, and returns the code the process exits
/// with. A failure is answered where it happens, so what comes back here is
/// either nothing, or a failure nobody has put into words yet.
pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| fail(err);
}

/// Everything the command line asked for, answering with the code it exits with:
/// zero when it did what was asked.
fn run(init: std.process.Init) !u8 {
    // Anything that lives as long as the process, including the conversation,
    // is allocated here.
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    // Everything billy prints goes through one writer, which decorates its blocks
    // only when it is a terminal it is printing to. A subcommand that prints no
    // blocks writes the same text either way.
    const out = Terminal.Writer.detect(&stdout_file_writer);
    defer out.flush() catch {};

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const options = parseArgsSlice(argv[1..]) catch |err| switch (err) {
        error.InvalidArgument => {
            std.log.err("invalid arguments, try --help", .{});
            return report.Reported;
        },
    };
    // A usage is answered before anything is read, so it works even when billy's
    // own files cannot be: which of them asked is the command's own business, so
    // it is printed here rather than in each arm below.
    if (try printAskedHelp(options, out)) return 0;

    // Everything else needs billy's files, so they are read in once and each way
    // of running billy is a method on what came back.
    var billy = try Billy.open(init, out);
    defer billy.deinit();

    switch (options.command) {
        .none => try billy.run(out, options.resume_id),
        .serve => |serve| try billy.serve(serve.host, serve.port),
        .config => |config| try billy.configSet(out, config.path.?, config.value.?),
        .login => |login| try billy.login(out, login.service),
        .sessions => try billy.listSessions(out),
    }
    return 0;
}

/// Reports a failure that got as far as here, and gives the code the process
/// exits with. A failure a command has already put into words is only counted:
/// the user has read it, and repeating it is what makes a mistyped flag read as
/// a crash. Anything else is one nobody explained, so it is named here, with
/// where it came from.
fn fail(err: anyerror) u8 {
    if (err != report.Reported) {
        std.log.err("{s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    }
    return 1;
}

/// Prints the usage `options` asked for, and says whether it asked for one. A
/// subcommand's usage is its own, so `billy serve --help` prints that rather
/// than billy's.
fn printAskedHelp(options: Options, out: Terminal.Writer) !bool {
    if (options.help) {
        try printHelp(out, "billy [command] [options]", billy_about, billy_commands, run_options);
        return true;
    }
    switch (options.command) {
        .none => {},
        .login => |login| if (login.help) {
            try printHelp(out, "billy login [<service>]", login_about, null, command_options);
            return true;
        },
        .config => |config| if (config.help) {
            try printHelp(out, "billy config <setting> <value>", config_about, null, command_options);
            return true;
        },
        .serve => |serve| if (serve.help) {
            try printHelp(out, "billy serve [--port <port>] [--host <addr>]", serve_about, null, serve_options);
            return true;
        },
        .sessions => |sessions| if (sessions.help) {
            try printHelp(out, "billy sessions", sessions_about, null, command_options);
            return true;
        },
    }
    return false;
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
    if (std.mem.eql(u8, command, "sessions"))
        return .{ .sessions = try parseSessions(args) };
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

/// Reads the arguments of the `sessions` subcommand: nothing but its own usage.
fn parseSessions(args: *spaghet.Args) ParseError!Options.Sessions {
    var sessions: Options.Sessions = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            sessions.help = true;
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    return sessions;
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
    try expectHost(Server.default_host, try parseArgsSlice(&.{"serve"}));

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
        .{ .command = .{ .config = .{ .path = "tools.bash.timeout_s", .value = "300" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.timeout_s", "300" }),
    );
    // A value may look like an option or be empty; the path may not.
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.bash.timeout_s", .value = "--nope" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.timeout_s", "--nope" }),
    );
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.web_search.searxng.url", .value = "" } } },
        try parseArgsSlice(&.{ "config", "tools.web_search.searxng.url", "" }),
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

test "parseArgs reads the sessions subcommand on its own" {
    // It takes nothing, so the line is just the command.
    try expectOptions(.{ .command = .{ .sessions = .{} } }, try parseArgsSlice(&.{"sessions"}));

    // The subcommand has its own usage.
    try expectOptions(.{ .command = .{ .sessions = .{ .help = true } } }, try parseArgsSlice(&.{ "sessions", "-h" }));
    try expectOptions(.{ .command = .{ .sessions = .{ .help = true } } }, try parseArgsSlice(&.{ "sessions", "--help" }));

    // The subcommand owns the rest of the line, so an argument after it is not
    // one it takes, and a run option after it is not a run option.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "sessions", "extra" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "sessions", "--resume", "x" }));
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
        .sessions => |sessions| try std.testing.expectEqual(sessions.help, actual.command.sessions.help),
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
    .{
        .invocation = "billy sessions",
        .description = sessions_about,
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
        try printHelp(.{ .out = &out.writer }, message.invocation, message.description, message.commands, message.options);
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

test "a failure a command has reported exits non-zero and is not said again" {
    // This passes only because nothing is logged: the test runner counts an
    // error line against the test that caused it, which is the property wanted
    // here. The message was the command's, and the process says the rest with
    // its exit code, for anything scripted around billy to read.
    try std.testing.expectEqual(@as(u8, 1), fail(report.Reported));
}
