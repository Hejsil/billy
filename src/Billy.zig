//! Everything billy reads in before it can do anything: the directories it
//! keeps its files in, the credentials stored among them, the configuration,
//! and the waits its web backends were last given.
//!
//! It is opened once, by `main`, and every way of running billy is a method on
//! it. Nothing else holds one: a part of billy that needs to write a session, or
//! to send a request, is handed the one thing it needs rather than this. The
//! model catalog is the exception: it is read the first time a run needs it, so
//! a command that never asks a model does not fetch it.
//!
//! The terminal frontend is here in full -- the line editor, the header, the
//! writer and the loop that reads a line and shows the answer as it is written --
//! because all of that is the frontend's. What the agent is handed is a turn.

const std = @import("std");
const Agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Dirs = @import("Dirs.zig");
const endpoint = @import("endpoint.zig");
const setup = @import("setup.zig");
const Health = @import("Health.zig");
const report = @import("report.zig");
const Session = @import("Session.zig");
const Server = @import("Server.zig");
const LineEditor = @import("LineEditor.zig");
const models = @import("models.zig");
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
/// The providers and models a request can be sent to, read from the cache the
/// first time a run needs it.
catalog: models.Catalog = .{},

/// Where billy was started. A new session records it; a resumed one keeps the
/// directory it saved, so a session continues where it was left rather than
/// wherever it is picked up.
cwd: []const u8,

/// Reads the configuration, the credentials and the directories billy keeps its
/// files in, and reports what could not be read.
///
/// `out` is for the note that the configuration file was created, which is the
/// one thing here the user is told about.
pub fn open(init: std.process.Init, out: Terminal.Writer) !Billy {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    var dirs = try Dirs.open(io, arena, environ);
    errdefer dirs.deinit(io);

    const credentials = Credentials.load(io, dirs.data, arena) catch |err| {
        std.log.err("cannot read the credentials: {s}", .{@errorName(err)});
        return report.Reported;
    };

    var opened = Config.open(io, dirs.config, init.gpa) catch |err| {
        std.log.err("cannot read the configuration: {s}", .{@errorName(err)});
        return report.Reported;
    };
    errdefer opened.config.deinit();

    if (opened.created) try out.write("wrote the default configuration\n");

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return report.Reported;
    };

    return .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .environ = environ,
        .dirs = dirs,
        .credentials = credentials,
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

/// Stores a key for `service`, or lists the services and the keys they have.
///
/// The providers the configuration defines, and the ones the model catalog
/// holds, are the names a key can be stored for beside the services billy ships;
/// one none of them names is one no request will ever ask for, so such a key is
/// refused rather than stored.
pub fn login(billy: *Billy, out: Terminal.Writer, service: ?[]const u8) !void {
    billy.ensureCatalog();
    var provider_names: std.ArrayList([]const u8) = .empty;
    for (billy.config.stored.providers.entries) |entry| {
        try provider_names.append(billy.arena, entry.name);
    }

    const name = service orelse return billy.credentials.list(out.out, provider_names.items, &billy.catalog);
    // A provider from the catalog is a service like any other: a key stored for
    // it is what a request to it asks for.
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
    // An empty key would be stored as a credential that cannot work, which is
    // worse than having none: the service would be offered and always fail.
    if (key.len == 0) {
        std.log.err("no key given, nothing stored", .{});
        return report.Reported;
    }

    try billy.credentials.put(billy.arena, name, key);
    billy.credentials.save(billy.io, billy.dirs.data) catch |err| {
        std.log.err("cannot write the credentials: {s}", .{@errorName(err)});
        return report.Reported;
    };
    try out.print("stored the {s} key\n", .{name});
}

/// Reads one line from the terminal, keeping what is typed off the screen so a
/// key is not left there or in the scrollback. `prompt` is shown only when there
/// is a terminal to type at; without one the line is read as it comes, which is
/// what lets a key be piped in.
///
/// Returns null at end of input, before anything was typed.
fn readSecret(billy: *Billy, out: Terminal.Writer, prompt: []const u8) !?[]const u8 {
    // The same reader the run prompts with, in its secret mode, so a key and a
    // prompt are read the one way.
    var editor = LineEditor.init(billy.io, out.out, billy.arena);
    defer editor.deinit();

    const line = (try editor.readSecret(prompt)) orelse return null;
    // A key is a token: the carriage return a terminal ends the line with, and
    // any space a paste brought along, are not part of it.
    return try billy.arena.dupe(u8, std.mem.trim(u8, line, &std.ascii.whitespace));
}

/// Sets the configuration setting `path` to `value` and writes the file back, so
/// a setting can be changed without opening it by hand.
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
        std.log.err("cannot write the configuration: {s}", .{@errorName(err)});
        return report.Reported;
    };
    try out.print("set {s} to {s}\n", .{ path, value });
}

/// Written in front of the line being typed, so what is being edited reads as the
/// input rather than as another block. The editor erases it when the line is
/// submitted and the emitter writes the prompt's block in its place.
const input_prompt = "> ";

/// Which session a run continues, when it continues one.
pub const Resume = union(enum) {
    /// The session with this id, in whatever directory it works.
    id: []const u8,
    /// The session written to most recently in the directory billy runs in,
    /// which is what `--resume` asks for when it names none.
    latest,
};

/// Runs one session in the terminal, resuming what `resuming` asks for or
/// starting a new one when it asks for nothing.
pub fn run(billy: *Billy, out: Terminal.Writer, resuming: ?Resume) !void {
    // Resolved before the catalog is fetched, so a resume with nothing to
    // continue says so without reading it.
    const resume_id = try billy.resumeId(resuming);
    billy.ensureCatalog();
    // A resumed session keeps the directory it was saved with, so a session
    // continues where it was left rather than wherever it is picked up.
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

    // What the run is built from lives for as long as it does: the web backends
    // are all that a request needs beyond the configuration and the credentials,
    // which the run borrows and resolves each turn's provider from itself.
    var run_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    // What the run is given, resolved once for the whole of it: what its targets
    // are resolved from, how far it goes, what its tools run with, how its blocks
    // are shown, and the home directory and instructions it reads outside the
    // session.
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
        // The user's own instructions live beside the configuration, and join
        // every session's prompt. Billy owns the directory and outlives the run.
        .instructions = billy.dirs.config,
    };

    if (resume_id != null) {
        // Replay the conversation as a transcript, so the context does not
        // have to be remembered from the previous run. Only the last few blocks
        // are shown, so resuming a long one is quick.
        try Agent.printTranscript(
            billy.io,
            billy.gpa,
            out,
            &session,
            billy.config.stored.resume_blocks,
        );
    }
    try billy.runTerminal(out, options, &session);
}

/// Runs one session on the terminal until the input ends: each line is taken as
/// the agent decides what it is, and the blocks of the answer are shown as they
/// happen. Each turn is sent where the session's model points when it begins,
/// which is resolved again for every one of them.
///
/// This is the terminal frontend, and it lives here rather than with the agent:
/// the editor, the header and the writer are the frontend's, and the agent is
/// handed only what a turn needs.
fn runTerminal(
    billy: *Billy,
    out: Terminal.Writer,
    options: Agent.Options,
    session: *Session,
) !void {
    const io = billy.io;
    const gpa = billy.gpa;
    // One HTTP client for the run, shared by the model requests and the search
    // backend, so both reuse its connections and share the certificates it scans
    // once. Every session asked in this run borrows it.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var agent = try Agent.init(io, gpa, options, session.cwd(), &http_client);
    defer agent.deinit();
    // A resumed session keeps the prompt and tools it was saved with, so it is
    // prepared here; a new one gets them from its first prompt, through `start`.
    const resumed = session.messages.items.len > 0;
    if (resumed) try agent.prepare(session);

    // The editor holds the lines it returns and its history in an arena of its
    // own, over `gpa`, so the run need not keep an allocator for them.
    var editor = LineEditor.init(io, out.out, gpa);
    defer editor.deinit();

    // The blocks of the run are shown on the terminal, the way billy has always
    // shown them, through the writer this frontend prints with.
    var terminal = Terminal{ .writer = out, .io = io, .scratch = gpa };
    defer terminal.deinit();
    const emitter = terminal.emitter();

    // The header is rebuilt for every prompt, so it reflects the context size
    // after the turns run so far. One buffer holds it for the whole loop; each pass
    // clears it and writes the header into it.
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        header.clearRetainingCapacity();
        // The header is built each pass, so it shows the session as it stands: the
        // model it recorded and the directory, which is read from the session
        // since its pool has grown with the turn and moved every string taken
        // from it before. The gauge is the window of the model the session goes
        // to now, so a model changed since the last turn reads right at once.
        try header.writer.print("{f}", .{Agent.SessionHeader.of(
            session,
            setup.sessionModel(&billy.config, &billy.catalog, session),
            options.home,
        )});
        const line = (try editor.readLine(header.written(), input_prompt)) orelse break;
        if (line.len == 0) continue;
        // What the line came to is the agent's to decide: a command is run and
        // reported through the emitter, and anything else is what is asked.
        const waiting = try agent.take(emitter, session, line);
        const text = switch (waiting) {
            .prompt => |asked| asked.text,
            // A command was run, or the model could not be resolved and the
            // notice says why: either way nothing is asked, and the run carries
            // on, so the next line can be the one that fixes it.
            .ran, .unresolved => {
                try out.flush();
                continue;
            },
        };
        // The line editor has erased the prompt it was typed behind, so the
        // prompt is written out now as the block a replay shows: the `> ` belongs
        // to the input, not to what was said. Flushed before the request, which
        // may take a while, so the user sees what was sent.
        //
        // A request that failed has been reported through the emitter by `ask`,
        // and the session carries on: a dropped connection is not the end of the
        // conversation. Only a failure of the emitter itself, which is this
        // terminal going away, reaches here.
        agent.ask(emitter, session, text) catch |err|
            std.log.err("could not show the turn: {s}", .{@errorName(err)});
        try out.flush();
    }
    try out.flush();
}

/// The id of the session `resuming` continues, or null when it asks for a new
/// one. A resume that names no id of its own asks for the session this directory
/// was last asked in, and is reported when there is none: starting a new one
/// would leave the run somewhere the user did not ask to be.
fn resumeId(billy: *Billy, resuming: ?Resume) !?[]const u8 {
    const asked = resuming orelse return null;
    switch (asked) {
        .id => |id| return id,
        .latest => {},
    }

    const found = Session.latest(billy.io, billy.dirs.sessions, billy.arena, billy.cwd) catch |err| {
        std.log.err("cannot list the sessions: {s}", .{@errorName(err)});
        return report.Reported;
    };
    return found orelse {
        std.log.err("no session to resume in '{s}'", .{billy.cwd});
        return report.Reported;
    };
}

/// Reads the model catalog from the cache, fetching it first when there is none.
///
/// A catalog that cannot be fetched or read is reported and left empty: a
/// provider the configuration names still works, without a context gauge or a
/// compaction threshold for its models.
fn ensureCatalog(billy: *Billy) void {
    if (billy.catalog.providers.len > 0) return;
    billy.catalog = models.ensure(billy.io, billy.arena, billy.gpa, billy.dirs.cache);
}

/// Fetches the model catalog, or says what the cached one holds.
pub fn showModels(billy: *Billy, out: Terminal.Writer, refresh: bool) !void {
    if (refresh) {
        const counts = models.refresh(billy.io, billy.gpa, billy.dirs.cache) catch |err| {
            std.log.err("cannot refresh the model catalog: {s}", .{@errorName(err)});
            return report.Reported;
        };
        billy.catalog = models.load(billy.io, billy.arena, billy.dirs.cache) catch |err| {
            std.log.err("the model catalog was fetched but cannot be read: {s}", .{@errorName(err)});
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

/// Lists the sessions billy has kept, the one written to most recently first,
/// one to a line: the id a session is resumed by, and the title it was given.
///
/// A session that has not been named -- one that has not been asked anything
/// yet, and one saved before titles were kept -- is listed by its id alone,
/// rather than as an id with a space after it that a shell would split off.
pub fn listSessions(billy: *Billy, out: Terminal.Writer) !void {
    const listed = Session.list(billy.io, billy.dirs.sessions, billy.gpa) catch |err| {
        std.log.err("cannot list the sessions: {s}", .{@errorName(err)});
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

/// Writes `listed` as the listing reads: each session's id, then its title.
fn printSessions(out: Terminal.Writer, listed: []const Session.Named) !void {
    for (listed) |named| {
        const space = if (named.title.len != 0) " " else "";
        try out.print("{s}{s}{s}\n", .{ named.id, space, named.title });
    }
}

/// Runs billy as a server with a web frontend, on `host` at `port`, until the
/// process is stopped.
pub fn serve(billy: *Billy, host: []const u8, port: u16) !void {
    billy.ensureCatalog();
    // What a request is sent to, and the backends it asks, are resolved before
    // anything is served, since a server that cannot send a request has nothing
    // to do: a key that is missing is reported here rather than on the first thing
    // asked of it.
    var server_state = std.heap.ArenaAllocator.init(billy.gpa);
    defer server_state.deinit();
    const arena = server_state.allocator();

    // The configured choice is resolved once here only to report a provider or a
    // key that is missing: each turn resolves its own target when it begins, and
    // a turn that cannot begin says so as a notice. A server is different: one
    // that cannot send a request at all has nothing to serve, and says so before
    // it listens rather than on the first thing asked of it.
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
        // A session with no title is written as its id alone, leaving no space
        // behind it for a shell to split on.
        .{ .id = "legacy", .title = "" },
    });

    try std.testing.expectEqualStrings(
        "01M3AAAAAAAAAAAAAAAAAAAAAA Fix the flaky test\n" ++
            "01M3BBBBBBBBBBBBBBBBBBBBBB Two words\n" ++
            "legacy\n",
        out.written(),
    );
}
