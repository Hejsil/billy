const std = @import("std");

const Billy = @import("billy").Billy;
const report = @import("billy").report;
const Server = @import("billy").Server;
const spaghet = @import("spaghet");
const Terminal = @import("billy").Terminal;

const billy_about = "A small fast AI agent that works in your terminal.";

const login_about =
    \\Store an API key for a service. With no service, list the services billy
    \\needs a key for and whether one is stored.
;

const config_about =
    \\Set one setting in the configuration file, named by its dotted path, and
    \\write it back, so a setting can be changed without opening the file by
    \\hand; for example, `billy config tools.bash.timeout_s '300'`. A string is
    \\taken as it is, a number from its digits, and `null` clears a setting that
    \\has no value.
;

const serve_about =
    \\Run billy as a server with a web frontend instead of in the terminal.
    \\It listens on this machine only unless another address is asked for, and
    \\has no authentication: anything that can reach it can run commands as you,
    \\so only listen where that is meant.
;

const models_about =
    \\Show how many providers and models the cached catalog holds, or fetch it
    \\again from models.dev. The catalog is fetched automatically the first time
    \\a run needs it.
;

const resume_about =
    \\Continue a session: the one named, or with none named the one written to
    \\most recently in this directory. `billy sessions` lists the sessions, with
    \\the id each is resumed by.
;

const sessions_about =
    \\List the sessions billy has kept, the one written to most recently first,
    \\one to a line: the id to resume it by, and the title it was given. A
    \\session that has not been named yet is listed by its id alone.
;

const billy_commands =
    \\  resume [<session>]        continue a session, or the latest one here
    \\  login [<service>]         store an API key, or list the services
    \\  config <setting> <value>  set a configuration setting by its path
    \\  sessions                  list the sessions, newest first
    \\  models [--refresh]        show the model catalog, or fetch it again
    \\  serve                     run the web frontend
;

const models_options =
    \\      --refresh   fetch the catalog from models.dev again
    \\  -h, --help      print this message
;

const command_options =
    \\  -h, --help  print this message
;

const serve_options =
    \\  -p, --port <port>  the port to listen on, by default 8787
    \\      --host <addr>  the address to listen on, by default 127.0.0.1;
    \\                     "localhost" and an address such as 0.0.0.0 or
    \\                     192.168.1.5 are taken; names are not resolved
    \\  -h, --help         print this message
;

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

const Options = struct {
    help: bool = false,

    command: Command = .none,

    const Command = union(enum) {
        none,
        resume_session: Resume,
        login: Login,
        config: Config,
        serve: Serve,
        sessions: Sessions,
        models: Models,
    };

    const Resume = struct {
        id: ?[]const u8 = null,
        help: bool = false,

        fn wanted(asked: Resume) Billy.Resume {
            const id = asked.id orelse return .{ .latest = {} };
            return .{ .id = id };
        }
    };

    const Login = struct {
        service: ?[]const u8 = null,
        help: bool = false,
    };

    const Models = struct {
        refresh: bool = false,
        help: bool = false,
    };

    const Config = struct {
        path: ?[]const u8 = null,
        value: ?[]const u8 = null,
        help: bool = false,
    };

    const Serve = struct {
        host: []const u8 = Server.default_host,
        port: u16 = Server.default_port,
        help: bool = false,
    };

    const Sessions = struct {
        help: bool = false,
    };
};

/// Runs what the command line asked for, and returns the code the process exits with.
pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| fail(err);
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const options = parseArgsSlice(argv[1..]) catch |err| switch (err) {
        error.InvalidArgument => {
            std.log.err("invalid arguments, try --help", .{});
            return report.Reported;
        },
    };

    // The writer is made once the command line is read, so the way out above has no buffer to push
    // out, and the buffer it does hold is pushed out below rather than from a `defer`: what a
    // command printed is on its way before the code the run ended with is answered.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = Terminal.Writer.detect(&stdout_file_writer);

    const code = answer(init, out, options) catch |err| {
        if (err != error.WriteFailed) return err;
        return writeFailure(&stdout_file_writer, err);
    };
    stdout_file_writer.flush() catch |err| return writeFailure(&stdout_file_writer, err);
    return code;
}

fn writeFailure(stdout: *std.Io.File.Writer, err: anyerror) anyerror!u8 {
    const cause: anyerror = if (err == error.WriteFailed) stdout.err orelse err else err;
    if (cause == error.BrokenPipe) return 0;
    std.log.err("cannot write to stdout: {t}", .{cause});
    return report.Reported;
}

fn answer(init: std.process.Init, out: Terminal.Writer, options: Options) !u8 {
    // A usage is answered before anything is read, so it works even when billy's own files cannot
    // be: which of them asked is the command's own business, so it is printed here rather than in
    // each arm below.
    if (try printAskedHelp(options, out)) return 0;

    var billy = try Billy.open(init);
    defer billy.deinit();

    switch (options.command) {
        .none => try billy.run(out, null),
        .resume_session => |asked| try billy.run(out, asked.wanted()),
        .serve => |serve| try billy.serve(serve.host, serve.port),
        .config => |config| try billy.configSet(out, config.path.?, config.value.?),
        .login => |login| try billy.login(out, login.service),
        .sessions => try billy.listSessions(out),
        .models => |models| try billy.showModels(out, models.refresh),
    }
    return 0;
}

fn fail(err: anyerror) u8 {
    if (err != report.Reported) {
        std.log.err("{t}", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    }
    return 1;
}

fn printAskedHelp(options: Options, out: Terminal.Writer) !bool {
    if (options.help) {
        try printHelp(out, "billy [command] [options]", billy_about, billy_commands, command_options);
        return true;
    }
    switch (options.command) {
        .none => {},
        .resume_session => |asked| {
            if (asked.help) {
                try printHelp(out, "billy resume [<session>]", resume_about, null, command_options);
                return true;
            }
        },
        .login => |login| {
            if (login.help) {
                try printHelp(out, "billy login [<service>]", login_about, null, command_options);
                return true;
            }
        },
        .config => |config| {
            if (config.help) {
                try printHelp(out, "billy config <setting> <value>", config_about, null, command_options);
                return true;
            }
        },
        .serve => |serve| {
            if (serve.help) {
                try printHelp(out, "billy serve [--port <port>] [--host <addr>]", serve_about, null, serve_options);
                return true;
            }
        },
        .sessions => |sessions| {
            if (sessions.help) {
                try printHelp(out, "billy sessions", sessions_about, null, command_options);
                return true;
            }
        },
        .models => |models| {
            if (models.help) {
                try printHelp(out, "billy models [--refresh]", models_about, null, models_options);
                return true;
            }
        },
    }
    return false;
}

const ParseError = error{InvalidArgument};

fn parseArgsSlice(slice: []const []const u8) ParseError!Options {
    var args = spaghet.Args.initSlice(slice);
    return try parseArgs(&args);
}

fn parseArgs(args: *spaghet.Args) ParseError!Options {
    var options: Options = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            options.help = true;
        if (args.positional()) |command|
            options.command = try parseCommand(args, command);
    }
    return options;
}

fn parseCommand(args: *spaghet.Args, command: []const u8) ParseError!Options.Command {
    if (std.mem.eql(u8, command, "resume"))
        return .{ .resume_session = try parseResume(args) };
    if (std.mem.eql(u8, command, "login"))
        return .{ .login = try parseLogin(args) };
    if (std.mem.eql(u8, command, "config"))
        return .{ .config = try parseConfig(args) };
    if (std.mem.eql(u8, command, "serve"))
        return .{ .serve = try parseServe(args) };
    if (std.mem.eql(u8, command, "sessions"))
        return .{ .sessions = try parseSessions(args) };
    if (std.mem.eql(u8, command, "models"))
        return .{ .models = try parseModels(args) };
    return error.InvalidArgument;
}

fn parseResume(args: *spaghet.Args) ParseError!Options.Resume {
    var asked: Options.Resume = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            asked.help = true;
        if (asked.id == null)
            asked.id = args.positional();
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    return asked;
}

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

fn parseModels(args: *spaghet.Args) ParseError!Options.Models {
    var models: Options.Models = .{};
    while (args.next()) {
        if (args.flag(&.{ "-h", "--help" }))
            models.help = true;
        if (args.flag(&.{"--refresh"}))
            models.refresh = true;
        if (args.positional()) |_|
            return error.InvalidArgument;
    }
    return models;
}

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
    const cases = [_]struct { argv: []const []const u8, expected: Options }{
        .{ .argv = &.{}, .expected = .{} },
        .{ .argv = &.{"--help"}, .expected = .{ .help = true } },
    };
    for (cases) |case| try expectOptions(case.expected, try parseArgsSlice(case.argv));

    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"--nope"}));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"extra"}));
    // Resuming is a subcommand, so the option it used to be names nothing.
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"--resume"}));
}

test "parseArgs reads the resume subcommand on its own" {
    try expectOptions(.{ .command = .{ .resume_session = .{} } }, try parseArgsSlice(&.{"resume"}));
    try expectOptions(
        .{ .command = .{ .resume_session = .{ .id = "dev" } } },
        try parseArgsSlice(&.{ "resume", "dev" }),
    );
    try expectOptions(
        .{ .command = .{ .resume_session = .{ .help = true } } },
        try parseArgsSlice(&.{ "resume", "-h" }),
    );
    try expectOptions(
        .{ .command = .{ .resume_session = .{ .help = true } } },
        try parseArgsSlice(&.{ "resume", "--help" }),
    );
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "resume", "dev", "extra" }));
}

test "parseArgs reads the login subcommand on its own" {
    try expectOptions(.{ .command = .{ .login = .{} } }, try parseArgsSlice(&.{"login"}));
    try expectOptions(
        .{ .command = .{ .login = .{ .service = "tavily" } } },
        try parseArgsSlice(&.{ "login", "tavily" }),
    );
    try expectOptions(
        .{ .command = .{ .login = .{ .help = true } } },
        try parseArgsSlice(&.{ "login", "-h" }),
    );
    try expectOptions(
        .{ .command = .{ .login = .{ .help = true } } },
        try parseArgsSlice(&.{ "login", "--help" }),
    );
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "login", "tavily", "extra" }));
}

test "parseArgs reads the serve subcommand on its own" {
    try expectOptions(.{ .command = .{ .serve = .{} } }, try parseArgsSlice(&.{"serve"}));

    try expectServe(9000, try parseArgsSlice(&.{ "serve", "--port", "9000" }));
    try expectServe(9000, try parseArgsSlice(&.{ "serve", "-p", "9000" }));
    try expectServe(9000, try parseArgsSlice(&.{ "serve", "--port=9000" }));
    try expectServe(0, try parseArgsSlice(&.{ "serve", "--port", "0" }));

    try expectHost("0.0.0.0", try parseArgsSlice(&.{ "serve", "--host", "0.0.0.0" }));
    try expectHost("192.168.1.5", try parseArgsSlice(&.{ "serve", "--host=192.168.1.5" }));
    try expectHost("::1", try parseArgsSlice(&.{ "serve", "--host", "::1", "--port", "9" }));
    try expectHost("::1", try parseArgsSlice(&.{ "serve", "--port", "9", "--host", "::1" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--host" }));
    try expectHost(Server.default_host, try parseArgsSlice(&.{"serve"}));

    try expectOptions(.{ .command = .{ .serve = .{ .help = true } } }, try parseArgsSlice(&.{ "serve", "-h" }));
    try expectOptions(.{ .command = .{ .serve = .{ .help = true } } }, try parseArgsSlice(&.{ "serve", "--help" }));

    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port", "abc" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port", "70000" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--port=-1" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "--nope", "x" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "serve", "extra" }));
}

fn expectServe(expected: u16, actual: Options) !void {
    try std.testing.expectEqual(expected, actual.command.serve.port);
}

fn expectHost(expected: []const u8, actual: Options) !void {
    try std.testing.expectEqualStrings(expected, actual.command.serve.host);
}

test "parseArgs reads the config subcommand on its own" {
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.bash.timeout_s", .value = "300" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.timeout_s", "300" }),
    );
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.bash.timeout_s", .value = "--nope" } } },
        try parseArgsSlice(&.{ "config", "tools.bash.timeout_s", "--nope" }),
    );
    try expectOptions(
        .{ .command = .{ .config = .{ .path = "tools.web_search.searxng.url", .value = "" } } },
        try parseArgsSlice(&.{ "config", "tools.web_search.searxng.url", "" }),
    );
    try expectOptions(.{ .command = .{ .config = .{ .help = true } } }, try parseArgsSlice(&.{ "config", "-h" }));
    try expectOptions(.{ .command = .{ .config = .{ .help = true } } }, try parseArgsSlice(&.{ "config", "--help" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{"config"}));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "config", "max_turns" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "config", "max_turns", "1", "extra" }));
}

test "parseArgs reads the models subcommand on its own" {
    try expectOptions(.{ .command = .{ .models = .{} } }, try parseArgsSlice(&.{"models"}));
    try expectOptions(.{ .command = .{ .models = .{ .refresh = true } } }, try parseArgsSlice(&.{ "models", "--refresh" }));

    try expectOptions(.{ .command = .{ .models = .{ .help = true } } }, try parseArgsSlice(&.{ "models", "-h" }));
    try expectOptions(.{ .command = .{ .models = .{ .help = true } } }, try parseArgsSlice(&.{ "models", "--help" }));

    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "models", "extra" }));
}

test "parseArgs reads the sessions subcommand on its own" {
    try expectOptions(.{ .command = .{ .sessions = .{} } }, try parseArgsSlice(&.{"sessions"}));

    try expectOptions(.{ .command = .{ .sessions = .{ .help = true } } }, try parseArgsSlice(&.{ "sessions", "-h" }));
    try expectOptions(.{ .command = .{ .sessions = .{ .help = true } } }, try parseArgsSlice(&.{ "sessions", "--help" }));

    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "sessions", "extra" }));
    try std.testing.expectError(error.InvalidArgument, parseArgsSlice(&.{ "sessions", "--nope", "x" }));
}

fn expectOptions(expected: Options, actual: Options) !void {
    try std.testing.expectEqual(expected.help, actual.help);

    switch (expected.command) {
        .none => try std.testing.expect(actual.command == .none),
        .resume_session => |asked| {
            const actual_resume = actual.command.resume_session;
            try std.testing.expectEqual(asked.help, actual_resume.help);
            if (asked.id) |id| {
                try std.testing.expectEqualStrings(id, actual_resume.id.?);
            } else {
                try std.testing.expect(actual_resume.id == null);
            }
        },
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
        .models => |models| {
            const actual_models = actual.command.models;
            try std.testing.expectEqual(models.refresh, actual_models.refresh);
            try std.testing.expectEqual(models.help, actual_models.help);
        },
    }
}

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
        .options = command_options,
    },
    .{
        .invocation = "billy resume [<session>]",
        .description = resume_about,
        .commands = null,
        .options = command_options,
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
    .{
        .invocation = "billy models [--refresh]",
        .description = models_about,
        .commands = null,
        .options = models_options,
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

        const usage_at = std.mem.find(u8, text, "usage: ").?;
        const description_at = std.mem.find(u8, text, message.description).?;
        const options_at = std.mem.find(u8, text, "Options:").?;
        try std.testing.expect(usage_at < description_at);
        try std.testing.expect(description_at < options_at);
        if (message.commands) |commands| {
            const commands_at = std.mem.find(u8, text, "Commands:").?;
            try std.testing.expect(description_at < commands_at);
            try std.testing.expect(commands_at < options_at);
            try std.testing.expect(std.mem.find(u8, text, "\n\nCommands:\n") != null);
            try std.testing.expect(std.mem.find(u8, text, "\n\nOptions:\n") != null);
            try std.testing.expect(std.mem.find(u8, text, commands) != null);
        } else {
            try std.testing.expect(std.mem.find(u8, text, "Commands:") == null);
            try std.testing.expect(std.mem.find(u8, text, "\n\nOptions:\n") != null);
        }

        try std.testing.expect(std.mem.find(u8, text, message.invocation) != null);
        try std.testing.expectEqualStrings(
            message.options,
            std.mem.trimEnd(u8, text[options_at + "Options:\n".len ..], "\n"),
        );
    }
}

test "a failure a command has reported exits non-zero and is not said again" {
    // This passes only because nothing is logged: the test runner counts an error line against the
    // test that caused it, which is the property wanted here.
    try std.testing.expectEqual(@as(u8, 1), fail(report.Reported));
}
