//! Everything billy reads in before it can do anything: the directories it keeps its files in, the
//! credentials stored among them, the configuration, and the waits its web backends were last
//! given.

const std = @import("std");

const Agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Health = @import("Health.zig");
const LineEditor = @import("LineEditor.zig");
const models = @import("models.zig");
const report = @import("report.zig");
const Server = @import("Server.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const xdg = @import("xdg.zig");

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
    billy.catalog.deinit(billy.gpa);
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

/// What a run is given, made once here so the terminal's run and the server's turns read the same.
fn options(billy: *Billy) Agent.Options {
    const stored = &billy.config.stored;
    return .{
        .config = &billy.config,
        .credentials = &billy.credentials,
        .catalog = &billy.catalog,
        .tools = .{
            .bash_timeout_s = stored.tools.bash.timeout_s,
            .search = stored.tools.web_search,
            .fetch = stored.tools.web_fetch,
            .health = &billy.health,
            .keys = &billy.credentials,
            .sub_agents = true,
        },
        .instructions = billy.dirs.config,
    };
}

pub const Resume = union(enum) {
    id: []const u8,
    latest,
};

/// The session a run works in: the one named, or a new one. A resumed session keeps the directory
/// it was saved with, so it continues where it was left rather than where it is picked up.
fn openSession(billy: *Billy, out: Terminal.Writer, id: ?[]const u8) !Session {
    return Session.open(billy.io, billy.dirs.sessions, billy.gpa, id, billy.cwd) catch |err| switch (err) {
        error.SessionNotFound => {
            try say(out, "no session '{s}'", .{id.?});
            return report.Reported;
        },
        error.InvalidSessionId => {
            try say(out, "'{s}' cannot be used as a session name", .{id.?});
            return report.Reported;
        },
        else => |other| return other,
    };
}

fn agentFor(billy: *Billy, session: *Session, run_options: Agent.Options) !Agent {
    return try Agent.init(billy.io, billy.gpa, run_options, session.cwd(), &billy.http_client);
}

/// Runs one session in the terminal, resuming what `resuming` asks for or starting a new one when
/// it asks for nothing.
pub fn run(billy: *Billy, out: Terminal.Writer, resuming: ?Resume) !void {
    const resume_id = try billy.resumeId(resuming);
    billy.ensureCatalog();
    var session = try billy.openSession(out, resume_id);
    defer session.deinit();

    var agent = try billy.agentFor(&session, billy.options());
    defer agent.deinit();
    // A session picked up again has its prompt and tools refreshed for where it works now.
    if (session.messages.items.len > 0) try agent.prepare(&session);

    var terminal = Terminal{
        .writer = out,
        .io = billy.io,
        .scratch = billy.gpa,
        .home = billy.environ.get("HOME"),
    };
    defer terminal.deinit();

    if (resume_id != null) {
        try terminal.printTranscript(&session, billy.config.stored.resume_blocks);
    }
    try terminal.run(&agent, &session);
}

pub const Ask = struct {
    prompt: []const u8,
    session: ?[]const u8 = null,
    /// Whether this run may start sub agents of its own, which a sub agent's run may not.
    agents: bool = true,
};

/// Asks one thing and prints the answer under its session: the terminal's turn, with nothing around it.
pub fn ask(billy: *Billy, out: Terminal.Writer, asked: Ask) !void {
    var session = try billy.openSession(out, asked.session);
    defer session.deinit();

    billy.ensureCatalog();
    var run_options = billy.options();
    // A sub agent is not given the tool that starts one, so a run starts one and no more.
    if (!asked.agents) run_options.tools.sub_agents = false;

    var agent = try billy.agentFor(&session, run_options);
    defer agent.deinit();
    try agent.prepare(&session);

    var arena_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer arena_state.deinit();
    var plain = Plain{ .arena = arena_state.allocator() };
    agent.ask(plain.emitter(), &session, asked.prompt) catch |err| {
        std.log.err("could not show the turn: {t}", .{err});
        return say(out, "the turn stopped: {t}", .{err});
    };
    if (plain.notice) |text| return say(out, "{s}", .{text});

    // Flushed here: a failed run answers with its exit code, so `main` never reaches its own flush.
    try out.print("session: {s}\n\n{s}\n", .{ session.id(), plain.answer orelse "" });
    try out.flush();
}

fn say(out: Terminal.Writer, comptime format: []const u8, args: anytype) !void {
    try out.print("error: " ++ format ++ "\n", args);
    try out.flush();
    return report.Reported;
}

const Plain = struct {
    arena: std.mem.Allocator,
    answer: ?[]const u8 = null,
    notice: ?[]const u8 = null,
    interface: Agent.Emitter = .{ .vtable = &vtable },

    const vtable: Agent.Emitter.VTable = .{ .block = show };

    fn emitter(self: *Plain) *Agent.Emitter {
        return &self.interface;
    }

    fn show(e: *Agent.Emitter, block: Agent.Block) anyerror!void {
        const self: *Plain = @alignCast(@fieldParentPtr("interface", e));
        switch (block) {
            .answer => |text| self.answer = try self.arena.dupe(u8, text),
            .notice => |text| self.notice = try self.arena.dupe(u8, text),
            else => {},
        }
    }
};

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
    if (billy.catalog.providers.items.len > 0) return;
    billy.catalog = models.ensure(billy.io, billy.gpa, billy.dirs.cache);
}

pub fn showModels(billy: *Billy, out: Terminal.Writer, refresh: bool) !void {
    if (refresh) {
        const counts = models.refresh(billy.io, billy.gpa, billy.dirs.cache) catch |err| {
            std.log.err("cannot refresh the model catalog: {t}", .{err});
            return report.Reported;
        };
        billy.catalog.deinit(billy.gpa);
        billy.catalog = models.load(billy.io, billy.gpa, billy.dirs.cache) catch |err| {
            std.log.err("the model catalog was fetched but cannot be read: {t}", .{err});
            return report.Reported;
        };
        try out.print("fetched {d} providers and {d} models\n", .{ counts.providers, counts.models });
        return;
    }

    billy.ensureCatalog();
    try out.print("{d} providers, {d} models\n", .{
        billy.catalog.providers.items.len,
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
    const server = Server{
        .io = billy.io,
        .gpa = billy.gpa,
        .session_dir = billy.dirs.sessions,
        .http_client = &billy.http_client,
        .cwd = billy.cwd,
        .home = billy.environ.get("HOME"),
        .options = billy.options(),
    };
    return try server.serve(host, port);
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

/// The directories billy keeps its files in: what it must not lose under the data directory, what
/// it may lose under the cache directory, and the configuration under the configuration directory.
const Dirs = struct {
    data: std.Io.Dir,
    cache: std.Io.Dir,
    config: std.Io.Dir,
    sessions: std.Io.Dir,

    /// Opens every directory billy uses, making each one if it is not there yet.
    fn open(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !Dirs {
        var data = try xdg.openDirBuilt(io, dataPath(arena, environ), "billy's files");
        errdefer data.close(io);

        var cache = try xdg.openDirBuilt(io, cachePath(arena, environ), "billy's cache");
        errdefer cache.close(io);

        var config = try xdg.openDirBuilt(io, configPath(arena, environ), "the configuration");
        errdefer config.close(io);

        var sessions = try xdg.openDirBuilt(io, sessionsPath(arena, environ), "sessions");
        errdefer sessions.close(io);

        return .{
            .data = data,
            .cache = cache,
            .config = config,
            .sessions = sessions,
        };
    }

    fn deinit(dirs: *Dirs, io: std.Io) void {
        dirs.sessions.close(io);
        dirs.config.close(io);
        dirs.cache.close(io);
        dirs.data.close(io);
    }

    fn dataPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
        return try xdg.dir(gpa, environ, "XDG_DATA_HOME", &.{ ".local", "share" });
    }

    fn cachePath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
        return try xdg.dir(gpa, environ, "XDG_CACHE_HOME", &.{".cache"});
    }

    fn configPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
        return try xdg.dir(gpa, environ, "XDG_CONFIG_HOME", &.{".config"});
    }

    fn sessionsPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
        const data = try dataPath(gpa, environ);
        defer gpa.free(data);

        return std.Io.Dir.path.join(gpa, &.{ data, "sessions" });
    }
};

test "each directory is the right one under each base" {
    const gpa = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");

    // The rules themselves are `xdg.dir`'s; this only pins which base each of billy's directories
    // is under, and that the sessions sit inside the data directory rather than beside it.
    const data = try Dirs.dataPath(gpa, &environ);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", data);

    const cache = try Dirs.cachePath(gpa, &environ);
    defer gpa.free(cache);
    try std.testing.expectEqualStrings("/home/user/.cache/billy", cache);

    const config = try Dirs.configPath(gpa, &environ);
    defer gpa.free(config);
    try std.testing.expectEqualStrings("/home/user/.config/billy", config);

    const sessions = try Dirs.sessionsPath(gpa, &environ);
    defer gpa.free(sessions);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", sessions);
}
