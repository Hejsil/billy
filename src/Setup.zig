//! Everything billy needs read in before it can do anything: where it keeps its
//! files, the configuration, the credentials, and the endpoint and model it talks
//! to.
//!
//! It is read in one place so the terminal run and the web server are set up the
//! same way, and cannot drift from each other. The values that depend on where a
//! command is asked for -- such as the working directory a session records -- are
//! left to the caller, which builds the agent configuration from this.

const std = @import("std");
const agent = @import("Agent.zig");
const Config = @import("Config.zig");
const credentials = @import("credentials.zig");
const Dirs = @import("Dirs.zig");
const endpoints = @import("Endpoints.zig");
const Health = @import("Health.zig");
const tools = @import("Tools.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");

const Setup = @This();

environ: *const std.process.Environ.Map,

/// The configuration. It owns an arena of its own for the strings read out of
/// the file, which `deinit` frees.
config: Config,
/// Directory handle holding the session files.
sessions: std.Io.Dir,
/// The directories billy's own files were found in, held so they stay open for
/// as long as the credentials file might be written.
data_dir: std.Io.Dir,
config_dir: std.Io.Dir,

/// Where billy was started. A new session records it, so a session continues
/// where it was started rather than wherever it is picked up.
cwd: []const u8,
/// The credentials the run read in. Kept for the whole run because a session
/// names its own provider, which may not be the configured one, so the key for
/// it is looked up when that session is prepared rather than once here. The
/// strings are the arena's, which outlives the setup.
store: credentials.Store,
/// Where the configuration sends its requests, resolved once here rather than
/// per turn.
endpoint: endpoints.Endpoint,
/// The backends the web tools ask, resolved once here on the same terms.
backends: endpoints.Backends,
/// Which search backends are worth trying, so one that just failed is set aside
/// until the wait it was given is over. Held here rather than built per turn, so
/// a backend stays set aside across turns and the web server's many connections
/// share it. The agent configuration points at it, so it must not move.
health: Health,

/// Reads the configuration, the credentials and the directories billy keeps its
/// files in, and reports what could not be read.
///
/// `out` is for the note that the configuration file was created, which is the
/// one thing here the user is told about.
pub fn open(init: std.process.Init, out: *std.Io.Writer) !Setup {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    // What billy reads its own files through, and the credentials those files
    // hold. Every one of these is reported where it failed rather than here, so
    // the report can name what the user has to fix.
    var files = try openFiles(io, arena, environ);
    errdefer files.deinit(io);

    var opened = openConfig(init, files.dirs.config, out) catch |err| {
        std.log.err("cannot read the configuration: {s}", .{@errorName(err)});
        return err;
    };
    errdefer opened.config.deinit();

    const endpoint = try endpoints.open(arena, opened.config, &files.store);

    // Which backend each set is built from, remembered so the report of a
    // failure can name it: only the builder knows which provider it was on.
    var search_failed: tools.web.Search.Provider = .tavily;
    const search_config = endpoints.searchConfig(arena, &files.store, opened.config, &search_failed) catch |err| {
        endpoints.reportSearchFailure(err, search_failed);
        return err;
    };

    var fetch_failed: tools.web.Fetch.Provider = .raw;
    const fetch_config = endpoints.fetchConfig(arena, &files.store, opened.config, &fetch_failed) catch |err| {
        endpoints.reportFetchFailure(err, fetch_failed);
        return err;
    };

    return .{
        .environ = environ,
        .config = opened.config,
        .sessions = files.dirs.sessions,
        .data_dir = files.dirs.data,
        .config_dir = files.dirs.config,
        .cwd = files.cwd,
        .store = files.store,
        .endpoint = endpoint,
        .backends = .{ .search = search_config, .fetch = fetch_config },
        // The waits web backends were last given, read from disk.
        .health = try Health.load(io, init.gpa, files.dirs.data),
    };
}

/// The directories billy keeps its own files in, the credentials stored among
/// them, and the directory the run was started in. Read in one place because
/// they are found the same way and freed together.
const Files = struct {
    /// The directory the credentials file is under, and the store read out of
    /// it. The store's keys are owned by the arena `open` runs in.
    ///
    /// The paths are kept beside the handles because a report names the file that
    /// could not be read, and a handle has no name to give.
    /// Every directory billy keeps its files in.
    dirs: Dirs,
    store: credentials.Store,
    /// Where billy was started, so a new session records it.
    cwd: []const u8,

    fn deinit(files: *Files, io: std.Io) void {
        files.dirs.deinit(io);
    }
};

/// Opens billy's own directories, reading the credentials stored in the data
/// directory, and finds the working directory the run was started in.
///
/// billy's own files live under the data directory: the credentials in the
/// directory itself, and the sessions in a subdirectory of it. The credentials
/// are not kept with the configuration, which is meant to be shared between
/// machines, and a key is not.
fn openFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !Files {
    var dirs = try Dirs.open(io, arena, environ);
    errdefer dirs.deinit(io);

    const store = credentials.load(io, dirs.data, arena) catch |err| {
        std.log.err("cannot read the credentials: {s}", .{@errorName(err)});
        return err;
    };

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    return .{
        .dirs = dirs,
        .store = store,
        .cwd = cwd,
    };
}

/// The configuration, written with its defaults when the file is missing, which
/// is reported on `out`: it is the one thing here the user is told about.
///
/// The configuration owns an arena of its own for the strings it reads, so it is
/// freed when the run is over rather than with the process arena.
fn openConfig(init: std.process.Init, config_dir: std.Io.Dir, out: *std.Io.Writer) !Config.Opened {
    var config = try Config.open(init.io, config_dir, init.gpa);
    errdefer config.config.deinit();

    if (config.created) {
        try out.print("wrote the default configuration\n", .{});
    }
    return config;
}

/// Where `session` is sent. See `endpoints.sessionTarget`.
pub fn sessionTarget(setup: *Setup, arena: std.mem.Allocator, session: *Session) !agent.Target {
    return endpoints.sessionTarget(setup.config, &setup.store, arena, session);
}

/// Where `choice` is sent. See `endpoints.targetFor`.
pub fn targetFor(setup: *Setup, arena: std.mem.Allocator, choice: []const u8) !agent.Target {
    return endpoints.targetFor(setup.config, &setup.store, arena, choice);
}

/// The configuration a run is built from. See `endpoints.agentConfig`.
pub fn agentConfig(setup: *Setup, cwd: []const u8, style: Terminal.Style) agent.Config {
    return endpoints.agentConfig(
        setup.config,
        setup.endpoint,
        setup.backends,
        &setup.health,
        setup.environ,
        cwd,
        style,
        setup.config_dir,
    );
}

pub fn deinit(setup: *Setup, io: std.Io) void {
    setup.health.deinit();
    setup.config.deinit();
    setup.sessions.close(io);
    setup.config_dir.close(io);
    setup.data_dir.close(io);
}
