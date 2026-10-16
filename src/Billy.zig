//! Everything billy reads in before it can do anything: the directories it
//! keeps its files in, the credentials stored among them, the configuration,
//! and the waits its web backends were last given.
//!
//! It is opened once, by `main`, and every way of running billy is a method on
//! it. Nothing else holds one: a part of billy that needs to write a session, or
//! to send a request, is handed the one thing it needs rather than this.

const std = @import("std");
const agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Dirs = @import("Dirs.zig");
const Endpoints = @import("Endpoints.zig");
const Health = @import("Health.zig");
const Session = @import("Session.zig");
const Server = @import("Server.zig");
const LineEditor = @import("LineEditor.zig");
const Terminal = @import("Terminal.zig");

const Billy = @This();

/// What the run happens in. The arena is the process's own, and everything that
/// lives as long as billy does -- a conversation, a resolved endpoint -- is
/// allocated from it or from an arena of its own held here.
io: std.Io,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
environ: *const std.process.Environ.Map,

/// Every directory billy keeps its files in.
dirs: Dirs,
/// The keys stored for the services billy talks to.
credentials: Credentials,
/// The configuration, which owns an arena of its own for the strings read out
/// of the file, freed by `deinit`.
config: Config,
/// Which backends are worth trying, so one that just failed is set aside until
/// the wait it was given is over.
health: Health,

/// Where billy was started. A new session records it, so a session continues
/// where it was started rather than wherever it is picked up.
cwd: []const u8,

/// Reads the configuration, the credentials and the directories billy keeps its
/// files in, and reports what could not be read.
///
/// `out` is for the note that the configuration file was created, which is the
/// one thing here the user is told about.
pub fn open(init: std.process.Init, out: *std.Io.Writer) !Billy {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    var dirs = try Dirs.open(io, arena, environ);
    errdefer dirs.deinit(io);

    const store = Credentials.load(io, dirs.data, arena) catch |err| {
        std.log.err("cannot read the credentials: {s}", .{@errorName(err)});
        return err;
    };

    var opened = Config.open(io, dirs.config, init.gpa) catch |err| {
        std.log.err("cannot read the configuration: {s}", .{@errorName(err)});
        return err;
    };
    errdefer opened.config.deinit();

    if (opened.created) try out.print("wrote the default configuration\n", .{});

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    return .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .environ = environ,
        .dirs = dirs,
        .credentials = store,
        .config = opened.config,
        .health = try Health.load(io, init.gpa, dirs.data),
        .cwd = cwd,
    };
}

pub fn deinit(billy: *Billy) void {
    billy.health.deinit();
    billy.config.deinit();
    billy.dirs.deinit(billy.io);
}

/// Stores a key for `service`, or lists the services and the keys they have, so
/// a run need not have it exported.
///
/// The providers the configuration defines are the names a key can be stored for
/// beside the services billy ships; one it names nothing of is one no request
/// will ever ask for, so such a key is refused rather than stored.
pub fn login(billy: *Billy, out: *std.Io.Writer, service: ?[]const u8) !void {
    var provider_names: std.ArrayList([]const u8) = .empty;
    for (billy.config.stored.providers.entries) |entry| {
        try provider_names.append(billy.arena, entry.name);
    }

    const name = service orelse return billy.credentials.list(out, provider_names.items);
    if (!Credentials.acceptable(name, provider_names.items)) {
        std.log.err(
            "'{s}' is neither a service billy knows nor a provider the configuration names;" ++
                " run `billy login` to list them, or name it under `providers` in the configuration",
            .{name},
        );
        return error.UnknownService;
    }

    const purpose = Credentials.purposeOf(name) orelse name;
    const prompt = try std.fmt.allocPrint(billy.arena, "Enter {s}: ", .{purpose});
    const key = (try billy.readSecret(out, prompt)) orelse {
        std.log.err("no key read", .{});
        return error.MissingCredential;
    };
    // An empty key would be stored as a credential that cannot work, which is
    // worse than having none: the service would be offered and always fail.
    if (key.len == 0) {
        std.log.err("no key given, nothing stored", .{});
        return error.MissingCredential;
    }

    try billy.credentials.put(billy.arena, name, key);
    billy.credentials.save(billy.io, billy.dirs.data) catch |err| {
        std.log.err("cannot write the credentials: {s}", .{@errorName(err)});
        return err;
    };
    try out.print("stored the {s} key\n", .{name});
}

/// Reads one line from the terminal, keeping what is typed off the screen so a
/// key is not left there or in the scrollback. `prompt` is shown only when there
/// is a terminal to type at; without one the line is read as it comes, which is
/// what lets a key be piped in.
///
/// Returns null at end of input, before anything was typed.
fn readSecret(billy: *Billy, out: *std.Io.Writer, prompt: []const u8) !?[]const u8 {
    // The same reader the run prompts with, in its secret mode, so a key and a
    // prompt are read the one way.
    var editor = LineEditor.init(billy.io, out, billy.arena);
    defer editor.deinit();

    const line = (try editor.readSecret(prompt)) orelse return null;
    // A key is a token: the carriage return a terminal ends the line with, and
    // any space a paste brought along, are not part of it.
    return try billy.arena.dupe(u8, std.mem.trim(u8, line, &std.ascii.whitespace));
}

/// Sets the configuration setting `path` to `value` and writes the file back, so
/// a setting can be changed without opening it by hand.
pub fn configSet(billy: *Billy, out: *std.Io.Writer, path: []const u8, value: []const u8) !void {
    Config.set(&billy.config, path, value) catch |err| switch (err) {
        error.UnknownOption => {
            std.log.err("'{s}' is not a configuration setting", .{path});
            return err;
        },
        error.NotASection => {
            std.log.err("'{s}' names a section, not a setting", .{path});
            return err;
        },
        error.InvalidValue => {
            std.log.err("'{s}' is not something {s} takes", .{ value, path });
            return err;
        },
        else => |other| return other,
    };
    billy.config.save(billy.io, billy.dirs.config) catch |err| {
        std.log.err("cannot write the configuration: {s}", .{@errorName(err)});
        return err;
    };
    try out.print("set {s} to {s}\n", .{ path, value });
}

/// Runs one session in the terminal, resuming `resume_id` or starting a new one.
pub fn run(billy: *Billy, out: *std.Io.Writer, resume_id: ?[]const u8) !void {
    // A resumed session keeps the directory it was saved with, so a session
    // continues where it was started rather than wherever it is picked up.
    var session = Session.open(
        billy.io,
        billy.dirs.sessions,
        billy.gpa,
        resume_id,
        billy.cwd,
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

    // What the run is built from lives for as long as it does: the endpoint, the
    // backends and the target are all that a request needs, and nothing outside
    // the run holds them.
    var run_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    // The terminal lays its blocks out for the terminal it is on, which the
    // escape codes of a pipe or a redirection would only be noise in.
    const config = try billy.agentConfig(arena, Terminal.Style.detect(billy.io, .stdout()));

    if (resume_id != null) {
        // Replay the conversation as a transcript, so the context does not
        // have to be remembered from the previous run. Only the last few blocks
        // are shown, so resuming a long one is quick.
        try agent.printTranscript(
            billy.io,
            billy.gpa,
            out,
            &session,
            config.display,
            billy.config.stored.resume_blocks,
        );
    }
    const target = try Endpoints.sessionTarget(billy.config, &billy.credentials, arena, &session);
    try agent.run(billy.io, billy.gpa, out, config, &session, target);
}

/// Runs billy as a server with a web frontend, on `host` at `port`, until the
/// process is stopped.
pub fn serve(billy: *Billy, host: []const u8, port: u16) !void {
    // The endpoint and the backends are resolved before anything is served,
    // since a server that cannot send a request has nothing to do: a key that is
    // missing is reported here rather than on the first thing asked of it.
    var server_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer server_state.deinit();
    const arena = server_state.allocator();

    const endpoint = try Endpoints.open(arena, billy.config, &billy.credentials);

    const server = Server{
        .io = billy.io,
        .gpa = billy.gpa,
        .session_dir = billy.dirs.sessions,
        .config_dir = billy.dirs.config,
        .config = billy.config,
        .store = billy.credentials,
        .health = &billy.health,
        .cwd = billy.cwd,
        .environ = billy.environ,
        .endpoint = endpoint,
        .backends = try Endpoints.Backends.build(arena, billy.config, &billy.credentials),
    };
    return server.serve(host, port);
}

/// The configuration a request is built from, with the endpoint and the
/// backends resolved into `arena`.
fn agentConfig(billy: *Billy, arena: std.mem.Allocator, style: Terminal.Style) !agent.Config {
    return Endpoints.agentConfig(
        billy.config,
        try Endpoints.open(arena, billy.config, &billy.credentials),
        try Endpoints.Backends.build(arena, billy.config, &billy.credentials),
        &billy.health,
        billy.environ,
        style,
        billy.dirs.config,
    );
}
