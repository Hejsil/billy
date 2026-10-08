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
const llm = @import("llm.zig");
const Config = @import("Config.zig");
const credentials = @import("credentials.zig");
const Health = @import("Health.zig");
const models = @import("models.zig");
const tools = @import("Tools.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");

const Setup = @This();

io: std.Io,
/// Temporary allocations, and what a tool format script is given to lay its
/// output out with.
gpa: std.mem.Allocator,
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
/// The key for the model endpoint, already resolved from the credentials or the
/// environment.
api_key: []const u8,
/// The endpoint billy talks to, and the model it asks for.
base_url: []const u8,
/// The full URL of the chat completions endpoint, built once from `base_url`.
/// It is kept here rather than made per run because both frontends ask for it
/// often -- the web server once per turn -- and it never changes.
url: []const u8,
model: []const u8,
/// Web search, when the configuration names a backend and its key is set. Null
/// leaves `web_search` out of the tools the model is offered.
search: ?tools.web.Search.Config,
/// Web fetch, on the same terms, with its own backends.
fetch: ?tools.web.Fetch.Config,
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

    var opened = openConfig(init, files.config_dir, files.config_dir_path, out) catch |err| {
        std.log.err("cannot read the configuration in {s}: {s}", .{
            files.config_dir_path, @errorName(err),
        });
        return err;
    };
    errdefer opened.config.deinit();

    const endpoint = try openEndpoint(arena, environ, &files.store);

    // Which backend each set is built from, remembered so the report of a
    // failure can name it: only the builder knows which provider it was on.
    var search_failed: tools.web.Search.Provider = .tavily;
    const search_config = searchConfig(arena, &files.store, environ, opened.config, &search_failed) catch |err| {
        reportSearchFailure(err, search_failed);
        return err;
    };

    var fetch_failed: tools.web.Fetch.Provider = .raw;
    const fetch_config = fetchConfig(arena, &files.store, environ, opened.config, &fetch_failed) catch |err| {
        reportFetchFailure(err, fetch_failed);
        return err;
    };

    return .{
        .io = io,
        .gpa = init.gpa,
        .environ = environ,
        .config = opened.config,
        .sessions = files.sessions,
        .data_dir = files.data_dir,
        .config_dir = files.config_dir,
        .cwd = files.cwd,
        .api_key = endpoint.api_key,
        .base_url = endpoint.base_url,
        .url = endpoint.url,
        .model = endpoint.model,
        .search = search_config,
        .fetch = fetch_config,
        // The waits web backends were last given, read from disk.
        .health = try Health.load(io, init.gpa, files.data_dir),
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
    data_dir: std.Io.Dir,
    data_dir_path: []const u8,
    store: credentials.Store,
    /// The directory the configuration file is under.
    config_dir: std.Io.Dir,
    config_dir_path: []const u8,
    /// The directory holding the session files.
    sessions: std.Io.Dir,
    /// Where billy was started, so a new session records it.
    cwd: []const u8,

    fn deinit(files: *Files, io: std.Io) void {
        files.sessions.close(io);
        files.config_dir.close(io);
        files.data_dir.close(io);
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
    var data_dir = try Session.openDataDir(io, arena, environ);
    errdefer data_dir.close(io);

    var config_dir = try Config.openDefaultDir(io, arena, environ);
    errdefer config_dir.close(io);

    var sessions = try Session.openDefaultDir(io, arena, environ);
    errdefer sessions.close(io);

    const data_dir_path = try Session.dataDir(arena, environ);
    const store = credentials.load(io, data_dir, arena) catch |err| {
        std.log.err("cannot read the credentials in {s}: {s}", .{ data_dir_path, @errorName(err) });
        return err;
    };

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    return .{
        .data_dir = data_dir,
        .data_dir_path = data_dir_path,
        .store = store,
        .config_dir = config_dir,
        .config_dir_path = try Config.defaultDir(arena, environ),
        .sessions = sessions,
        .cwd = cwd,
    };
}

/// The configuration, written with its defaults when the file is missing, which
/// is reported on `out`: it is the one thing here the user is told about.
///
/// The configuration owns an arena of its own for the strings it reads, so it is
/// freed when the run is over rather than with the process arena.
fn openConfig(
    init: std.process.Init,
    config_dir: std.Io.Dir,
    config_dir_path: []const u8,
    out: *std.Io.Writer,
) !Config.Opened {
    var config = try Config.open(init.io, config_dir, init.gpa);
    errdefer config.config.deinit();

    if (config.created) {
        try out.print("wrote the default configuration to {s}\n", .{
            try std.fs.path.join(init.arena.allocator(), &.{ config_dir_path, Config.file_name }),
        });
    }
    return config;
}

/// The model endpoint billy talks to, and the key it is asked with. The URL is
/// built once, here, and lives with the process: the web server asks for the
/// agent configuration once per turn, so building it there would leak one
/// allocation per turn into the process arena.
fn openEndpoint(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    store: *const credentials.Store,
) !Endpoint {
    const base_url = environ.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";
    const api_key = credentials.modelKey(store, environ, base_url) orelse {
        std.log.err("run `billy login deepseek`, or set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };

    return .{
        .base_url = base_url,
        .api_key = api_key,
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
            std.mem.trimEnd(u8, base_url, "/"),
        }),
        .model = environ.get("BILLY_MODEL") orelse "deepseek-flash",
    };
}

/// Where billy talks to the model, and as which model.
const Endpoint = struct {
    base_url: []const u8,
    api_key: []const u8,
    /// The full URL of the chat completions endpoint, built from `base_url`.
    url: []const u8,
    model: []const u8,
};

pub fn deinit(setup: *Setup) void {
    setup.health.deinit();
    setup.config.deinit();
    setup.sessions.close(setup.io);
    setup.config_dir.close(setup.io);
    setup.data_dir.close(setup.io);
}

/// What the configuration's `reasoning` asks of the model's thinking: `off` for
/// none, `default` to leave it to the model's provider, and any other name as an
/// effort level of the provider's own. A level billy does not know is passed on
/// rather than refused, since the levels are the provider's to name, and one
/// that is not a level at all comes back as the provider's own refusal rather
/// than as a wait that was never set.
fn reasoningOf(setting: []const u8) llm.Reasoning {
    if (std.mem.eql(u8, setting, "off")) return .off;
    if (std.mem.eql(u8, setting, "default")) return .provider_default;
    return .{ .effort = setting };
}

/// The web search settings for a configuration that names a backend, or null
/// when it names none. A backend named without its key is an error rather than a
/// silent "no search": the configuration asked for the tool, and leaving it out
/// without a word would look like a bug.
///
/// The report of what went wrong is written here rather than by the caller, so
/// naming the backend that is at fault does not need an out-parameter: only this
/// function knows which provider it was on.
fn searchConfig(
    arena: std.mem.Allocator,
    store: *const credentials.Store,
    environ: *const std.process.Environ.Map,
    config: Config,
    failed: *tools.web.Search.Provider,
) !?tools.web.Search.Config {
    const web_config = config.stored.tools.web_search;
    if (web_config.providers.len == 0) return null;

    // Each backend resolves its own key, or, for the one that is self-hosted,
    // needs the instance named instead.
    const backends = try arena.alloc(tools.web.Search.Backend, web_config.providers.len);
    for (web_config.providers, backends) |provider, *backend| {
        failed.* = provider;
        const service = credentials.searchService(provider);
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |one|
                credentials.credential(store, environ, one) orelse
                    return error.MissingApiKey
            else blk: {
                // A backend billy knows the address of needs only its key; one it
                // does not, SearXNG, needs the instance named.
                const url = web_config.searxng.url orelse
                    return error.MissingSearchUrl;
                if (url.len == 0) return error.MissingSearchUrl;
                break :blk "";
            },
            // Only a self-hosted backend is reached somewhere billy does not know.
            .endpoint = if (service == null) web_config.searxng.url else null,
        };
    }
    return .{ .backends = backends, .max_results = web_config.max_results };
}

/// The web fetch settings for a configuration that names a backend, or null when
/// it names none. `raw` needs no key, so a configuration that holds only it
/// fetches without a service.
fn fetchConfig(
    arena: std.mem.Allocator,
    store: *const credentials.Store,
    environ: *const std.process.Environ.Map,
    config: Config,
    failed: *tools.web.Fetch.Provider,
) !?tools.web.Fetch.Config {
    const web_config = config.stored.tools.web_fetch;
    if (web_config.providers.len == 0) return null;

    const backends = try arena.alloc(tools.web.Fetch.Backend, web_config.providers.len);
    for (web_config.providers, backends) |provider, *backend| {
        failed.* = provider;
        const service = credentials.fetchService(provider);
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |one|
                credentials.credential(store, environ, one) orelse
                    return error.MissingApiKey
            else
                "",
        };
    }
    return .{ .backends = backends };
}

/// Tells the user what to fix about the search backend that could not be built:
/// the login that stores its key, the variable the same key can come from, or the
/// instance a self-hosted backend needs named.
///
/// A failure here is one the configuration asked for -- it named the backend --
/// so leaving the tool out quietly would look like a bug rather than a choice.
fn reportSearchFailure(err: anyerror, provider: tools.web.Search.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            // A backend reached with a key is one of the services, since the one
            // billy hosts itself is reached without one.
            const service = credentials.searchService(provider).?;
            std.log.err(
                "run `billy login {s}`, or set {s} to use {s}, or clear tools.web_search in the configuration",
                .{ service.name(), service.variable(), @tagName(provider) },
            );
        },
        error.MissingSearchUrl => std.log.err(
            "set tools.web_search.{s}.url to your {s} instance, or clear tools.web_search in the configuration",
            .{ @tagName(provider), @tagName(provider) },
        ),
        else => {},
    }
}

/// Tells the user what to fix about the fetch backend that could not be built,
/// on the same terms as `reportSearchFailure`.
fn reportFetchFailure(err: anyerror, provider: tools.web.Fetch.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            const service = credentials.fetchService(provider).?;
            std.log.err(
                "run `billy login {s}`, or set {s} to use {s}, or clear tools.web_fetch in the configuration",
                .{ service.name(), service.variable(), @tagName(provider) },
            );
        },
        else => {},
    }
}

/// The agent configuration for a session working in `cwd`, with its blocks
/// decorated for `style`.
///
/// The window and the prices are not reported by the API, so they are looked up
/// by provider and model; an unknown model simply has no gauge and no cost, and
/// so no compaction, which needs a window to measure a conversation against.
///
/// Nothing is allocated here: every string is one the setup already holds, so
/// asking for this once a turn costs nothing that would have to be freed.
pub fn agentConfig(setup: *Setup, cwd: []const u8, style: Terminal.Style) agent.Config {
    const config = &setup.config.stored;
    return .{
        .api_key = setup.api_key,
        .url = setup.url,
        .model = setup.model,
        .max_turns = config.max_turns,
        .bash_timeout_s = config.tools.bash.timeout_s,
        .cwd = cwd,
        .home = setup.environ.get("HOME"),
        // The user's own instructions, which live beside the configuration and
        // join every session's prompt. The setup owns the directory and outlives
        // every runner built from this.
        .user_instructions_dir = setup.config_dir,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .compact_at = config.compact_at,
        .title = config.title,
        // A model whose provider billy does not know is left alone: the fields
        // are one provider's own, and an endpoint that does not know them may
        // refuse a request that carries them.
        .reasoning = if (models.Provider.fromUrl(setup.base_url) != null)
            reasoningOf(config.reasoning)
        else
            .provider_default,
        // How billy lays out and decorates what it shows. A bash command is laid
        // out by its format script, so the user reads the command the way it
        // runs; an edit is shown as a diff, laid out by its own script when one
        // is set; and the block headers are decorated for `style`. Only the
        // display changes: the command that runs, the file that is written, the
        // session and the model keep the text as it was written. A reply and a
        // prompt are markdown, laid out by billy's own renderer.
        .display = .{
            .formats = .{
                .bash = if (config.tools.bash.format) |script| .{
                    .script = script,
                    .io = setup.io,
                    .gpa = setup.gpa,
                } else null,
                .edit = if (config.tools.edit.format) |script| .{
                    .script = script,
                    .io = setup.io,
                    .gpa = setup.gpa,
                } else null,
            },
            .style = style,
        },
        // A web tool is offered only when the configuration names a backend for
        // it and its key is set; the tool is left out of the request otherwise.
        // The waits travel with the run, so a backend that just failed is
        // skipped.
        .search = setup.search,
        .fetch = setup.fetch,
        .health = &setup.health,
    };
}

test "each backend resolves its own key, and SearXNG its instance" {
    const gpa = std.testing.allocator;
    // The backends are built in the arena the setup runs in, which owns them.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const store: credentials.Store = .{};

    // Nothing named is no search at all.
    var off = Config.init(gpa);
    defer off.deinit();
    var failed: tools.web.Search.Provider = .tavily;
    try std.testing.expect((try searchConfig(arena, &store, &environ, off, &failed)) == null);

    // A backend billy knows is asked for a key, and one that is not set is an
    // error rather than a silent "no search".
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_search.providers = &.{.tavily};
    try std.testing.expectError(error.MissingApiKey, searchConfig(arena, &store, &environ, naming, &failed));
    // The backend at fault is the one the report names.
    try std.testing.expectEqual(tools.web.Search.Provider.tavily, failed);

    // SearXNG needs no key, but needs the instance named.
    var searx = Config.init(gpa);
    defer searx.deinit();

    searx.stored.tools.web_search.providers = &.{.searxng};
    try std.testing.expectError(error.MissingSearchUrl, searchConfig(arena, &store, &environ, searx, &failed));

    // Every named backend becomes a backend to try, in the order named.
    searx.stored.tools.web_search.searxng.url = "https://searx.example.org";
    const config = (try searchConfig(arena, &store, &environ, searx, &failed)).?;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(tools.web.Search.Provider.searxng, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);
    try std.testing.expectEqualStrings("https://searx.example.org", config.backends[0].endpoint.?);
}

test "a fetch backend is asked for its key, and raw for none" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const store: credentials.Store = .{};

    // The default holds only `raw`, which asks no service, so it resolves with
    // no key stored at all.
    var raw = Config.init(gpa);
    defer raw.deinit();

    var failed: tools.web.Fetch.Provider = .raw;
    const config = (try fetchConfig(arena, &store, &environ, raw, &failed)).?;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(tools.web.Fetch.Provider.raw, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);

    // A service needs its key, on the same terms as a search backend.
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_fetch.providers = &.{.tavily};
    try std.testing.expectError(error.MissingApiKey, fetchConfig(arena, &store, &environ, naming, &failed));
    try std.testing.expectEqual(tools.web.Fetch.Provider.tavily, failed);

    // A set with nothing in it leaves `web_fetch` out of the request.
    var none = Config.init(gpa);
    defer none.deinit();

    none.stored.tools.web_fetch.providers = &.{};
    try std.testing.expect((try fetchConfig(arena, &store, &environ, none, &failed)) == null);
}

test "the reasoning setting names what billy asks of the model's thinking" {
    // The two names billy knows, and any other name as an effort level of the
    // provider's own, which is passed on rather than refused.
    try std.testing.expectEqual(llm.Reasoning.off, reasoningOf("off"));
    try std.testing.expectEqual(llm.Reasoning.provider_default, reasoningOf("default"));
    try std.testing.expectEqualStrings("high", reasoningOf("high").effort);
    try std.testing.expectEqualStrings("low", reasoningOf("low").effort);
}
