//! Everything billy reads in before it can do anything: the directories it keeps its files in, the
//! credentials stored among them, the configuration, and the waits its web backends were last
//! given.

const std = @import("std");

const Agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Dirs = @import("Dirs.zig");
const endpoint = @import("endpoint.zig");
const Health = @import("Health.zig");
const LineEditor = @import("LineEditor.zig");
const models = @import("models.zig");
const report = @import("report.zig");
const Server = @import("Server.zig");
const Session = @import("Session.zig");
const setup = @import("setup.zig");
const Terminal = @import("Terminal.zig");

const Billy = @This();

io: std.Io,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
environ: *const std.process.Environ.Map,
http_client: std.http.Client,

dirs: Dirs,
credentials: Credentials,
config: Config,
health: Health,
catalog: models.Catalog = .{},

cwd: []const u8,

pub fn open(init: std.process.Init) !Billy {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    var dirs = try Dirs.open(io, arena, environ);
    errdefer dirs.deinit(io);

    const credentials = Credentials.load(io, dirs.data, arena) catch |err| {
        std.log.err("cannot read the credentials: {t}", .{err});
        return report.Reported;
    };

    var config = Config.open(io, dirs.config, init.gpa) catch |err| {
        std.log.err("cannot read the configuration: {t}", .{err});
        return report.Reported;
    };
    errdefer config.deinit();

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {t}", .{err});
        return report.Reported;
    };

    return .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .environ = environ,
        .http_client = .{ .allocator = init.gpa, .io = io },
        .dirs = dirs,
        .credentials = credentials,
        .config = config,
        .health = try Health.load(io, init.gpa, dirs.data),
        .cwd = cwd,
    };
}

pub fn deinit(billy: *Billy) void {
    billy.http_client.deinit();
    billy.health.deinit();
    billy.config.deinit();
    billy.dirs.deinit(billy.io);
}

pub fn login(billy: *Billy, out: Terminal.Writer, service: ?[]const u8) !void {
    billy.ensureCatalog();
    // The names are collected in the run's arena, which frees them with the run, so the list needs
    // no cleanup of its own if this stops part way.
    // zlinter-disable-next-line require_errdefer_dealloc - the arena owns it
    var provider_names: std.ArrayList([]const u8) = .empty;
    for (billy.config.stored.providers.entries) |entry| {
        try provider_names.append(billy.arena, entry.name);
    }

    const name = service orelse return billy.credentials.list(out.out, provider_names.items, &billy.catalog);
    if (!Credentials.acceptable(name, provider_names.items) and billy.catalog.find(name) == null) {
        std.log.err(
            "'{s}' is neither a service billy knows nor a provider the configuration names;" ++
                " run `billy models` to list the catalog, or name it under `providers` in the configuration",
            .{name},
        );
        return report.Reported;
    }

    const purpose = Credentials.purposeOf(name) orelse name;
    const prompt = try billy.arena.print("Enter {s}: ", .{purpose});
    const key = (try billy.readSecret(out, prompt)) orelse {
        std.log.err("no key read", .{});
        return report.Reported;
    };
    // An empty key would be stored as a credential that cannot work, which is worse than having
    // none: the service would be offered and always fail.
    if (key.len == 0) {
        std.log.err("no key given, nothing stored", .{});
        return report.Reported;
    }

    try billy.credentials.put(billy.arena, name, key);
    billy.credentials.save(billy.io, billy.dirs.data) catch |err| {
        std.log.err("cannot write the credentials: {t}", .{err});
        return report.Reported;
    };
    try out.print("stored the {s} key\n", .{name});
}

fn readSecret(billy: *Billy, out: Terminal.Writer, prompt: []const u8) !?[]const u8 {
    var editor = LineEditor.init(billy.io, out.out, billy.arena);
    defer editor.deinit();

    const line = (try editor.readSecret(prompt)) orelse return null;
    return try billy.arena.dupe(u8, std.mem.trim(u8, line, &std.ascii.whitespace));
}

pub fn configSet(billy: *Billy, out: Terminal.Writer, path: []const u8, value: []const u8) !void {
    billy.config.set(path, value) catch |err| switch (err) {
        error.UnknownOption => {
            std.log.err("'{s}' is not a configuration setting", .{path});
            return report.Reported;
        },
        error.NotASection => {
            std.log.err("'{s}' names a section, not a setting", .{path});
            return report.Reported;
        },
        error.InvalidValue => {
            std.log.err("'{s}' is not something {s} takes", .{ value, path });
            return report.Reported;
        },
        else => |other| return other,
    };
    billy.config.save(billy.io, billy.dirs.config) catch |err| {
        std.log.err("cannot write the configuration: {t}", .{err});
        return report.Reported;
    };
    try out.print("set {s} to {s}\n", .{ path, value });
}

const input_prompt = "> ";

pub const Resume = union(enum) {
    id: []const u8,
    latest,
};

/// Runs one session in the terminal, resuming what `resuming` asks for or starting a new one when
/// it asks for nothing.
pub fn run(billy: *Billy, out: Terminal.Writer, resuming: ?Resume) !void {
    const resume_id = try billy.resumeId(resuming);
    billy.ensureCatalog();
    // A resumed session keeps the directory it was saved with, so a session continues where it was
    // left rather than wherever it is picked up.
    var session = Session.open(
        billy.io,
        billy.dirs.sessions,
        billy.gpa,
        resume_id,
        billy.cwd,
    ) catch |err| switch (err) {
        error.SessionNotFound => {
            std.log.err("no session '{s}'", .{resume_id.?});
            return report.Reported;
        },
        error.InvalidSessionId => {
            std.log.err("'{s}' cannot be used as a session name", .{resume_id.?});
            return report.Reported;
        },
        else => |other| return other,
    };
    defer session.deinit();

    var run_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    const options = Agent.Options{
        .config = &billy.config,
        .credentials = &billy.credentials,
        .catalog = &billy.catalog,
        .behaviour = Agent.Behaviour.fromConfig(&billy.config),
        .tools = setup.toolSettings(
            &billy.config,
            try setup.Backends.build(arena, &billy.config, &billy.credentials),
            &billy.health,
        ),
        .home = billy.environ.get("HOME"),
        .instructions = billy.dirs.config,
    };

    var terminal = Terminal{ .writer = out, .io = billy.io, .scratch = billy.gpa };
    defer terminal.deinit();

    if (resume_id != null) {
        try terminal.printTranscript(&session, billy.config.stored.resume_blocks);
    }
    try billy.runSession(&terminal, options, &session);
}

fn runSession(
    billy: *Billy,
    terminal: *Terminal,
    options: Agent.Options,
    session: *Session,
) !void {
    const io = billy.io;
    const gpa = billy.gpa;
    const out = terminal.writer;

    var agent = try Agent.init(io, gpa, options, session.cwd(), &billy.http_client);
    defer agent.deinit();
    const resumed = session.messages.items.len > 0;
    if (resumed) try agent.prepare(session);

    var editor = LineEditor.init(io, out.out, gpa);
    defer editor.deinit();

    const emitter = terminal.emitter();

    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        header.clearRetainingCapacity();
        try header.writer.print("{f}", .{Agent.SessionHeader.of(
            session,
            Agent.sessionModel(&billy.catalog, session, billy.config.stored.model),
            options.home,
        )});
        const line = (try editor.readLine(header.written(), input_prompt)) orelse break;
        if (line.len == 0) continue;
        const waiting = try agent.take(emitter, session, line);
        const text = switch (waiting) {
            .prompt => |asked| asked.text,
            .ran, .unresolved => {
                try out.flush();
                continue;
            },
        };
        agent.ask(emitter, session, text) catch |err|
            std.log.err("could not show the turn: {t}", .{err});
        try out.flush();
    }
    try out.flush();
}

fn resumeId(billy: *Billy, resuming: ?Resume) !?[]const u8 {
    const asked = resuming orelse return null;
    switch (asked) {
        .id => |id| return id,
        .latest => {},
    }

    const found = Session.latest(billy.io, billy.dirs.sessions, billy.arena, billy.cwd) catch |err| {
        std.log.err("cannot list the sessions: {t}", .{err});
        return report.Reported;
    };
    return found orelse {
        std.log.err("no session to resume in '{s}'", .{billy.cwd});
        return report.Reported;
    };
}

fn ensureCatalog(billy: *Billy) void {
    if (billy.catalog.providers.len > 0) return;
    billy.catalog = models.ensure(billy.io, billy.arena, billy.gpa, billy.dirs.cache);
}

pub fn showModels(billy: *Billy, out: Terminal.Writer, refresh: bool) !void {
    if (refresh) {
        const counts = models.refresh(billy.io, billy.gpa, billy.dirs.cache) catch |err| {
            std.log.err("cannot refresh the model catalog: {t}", .{err});
            return report.Reported;
        };
        billy.catalog = models.load(billy.io, billy.arena, billy.dirs.cache) catch |err| {
            std.log.err("the model catalog was fetched but cannot be read: {t}", .{err});
            return report.Reported;
        };
        try out.print("fetched {d} providers and {d} models\n", .{ counts.providers, counts.models });
        return;
    }

    billy.ensureCatalog();
    try out.print("{d} providers, {d} models\n", .{
        billy.catalog.providers.len,
        models.Catalog.modelCount(&billy.catalog),
    });
}

pub fn listSessions(billy: *Billy, out: Terminal.Writer) !void {
    const listed = Session.list(billy.io, billy.dirs.sessions, billy.gpa) catch |err| {
        std.log.err("cannot list the sessions: {t}", .{err});
        return report.Reported;
    };
    defer {
        for (listed) |named| {
            billy.gpa.free(named.id);
            billy.gpa.free(named.title);
        }
        billy.gpa.free(listed);
    }

    try printSessions(out, listed);
}

fn printSessions(out: Terminal.Writer, listed: []const Session.Named) !void {
    for (listed) |named| {
        const space = if (named.title.len != 0) " " else "";
        try out.print("{s}{s}{s}\n", .{ named.id, space, named.title });
    }
}

pub fn serve(billy: *Billy, host: []const u8, port: u16) !void {
    billy.ensureCatalog();
    // What a request is sent to, and the backends it asks, are resolved before anything is served,
    // since a server that cannot send a request has nothing to do: a key that is missing is
    // reported here rather than on the first thing asked of it.
    var server_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer server_state.deinit();
    const arena = server_state.allocator();

    // The configured choice is resolved once here only to report a provider or a key that is
    // missing: each turn resolves its own target when it begins, and a turn that cannot begin says
    // so as a notice.
    _ = endpoint.configured(&billy.config, &billy.credentials, &billy.catalog, arena) catch |err| switch (err) {
        error.UnknownProvider, error.MissingApiKey => {
            var notice: [256]u8 = undefined;
            std.log.err("{s}", .{endpoint.unreachableModel(&notice, err, billy.config.stored.model)});
            return report.Reported;
        },
        else => |other| return other,
    };

    const server = Server{
        .io = billy.io,
        .gpa = billy.gpa,
        .session_dir = billy.dirs.sessions,
        .config_dir = billy.dirs.config,
        .config = &billy.config,
        .catalog = &billy.catalog,
        .credentials = billy.credentials,
        .health = &billy.health,
        .http_client = &billy.http_client,
        .cwd = billy.cwd,
        .environ = billy.environ,
        .backends = try setup.Backends.build(arena, &billy.config, &billy.credentials),
    };
    return server.serve(host, port);
}

test "the listing writes each session's id and title on one line" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try printSessions(.{ .out = &out.writer }, &.{
        .{ .id = "01M3AAAAAAAAAAAAAAAAAAAAAA", .title = "Fix the flaky test" },
        .{ .id = "01M3BBBBBBBBBBBBBBBBBBBBBB", .title = "Two words" },
        .{ .id = "legacy", .title = "" },
    });

    try std.testing.expectEqualStrings(
        "01M3AAAAAAAAAAAAAAAAAAAAAA Fix the flaky test\n" ++
            "01M3BBBBBBBBBBBBBBBBBBBBBB Two words\n" ++
            "legacy\n",
        out.written(),
    );
}
