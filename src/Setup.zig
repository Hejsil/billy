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
/// The provider and model a new session starts on, as `provider/model`, after
/// the environment's override. It is what a session records, so a run pointed at
/// a provider the configuration defines records the name it gave it, so the run
/// that resumes it resolves the same endpoint.
model_choice: []const u8,
/// The credentials the run read in. Kept for the whole run because a session
/// names its own provider, which may not be the configured one, so the key for
/// it is looked up when that session is prepared rather than once here. The
/// strings are the arena's, which outlives the setup.
store: credentials.Store,
/// The provider the endpoint belongs to, or null for one billy does not know.
/// A new session records the provider and model it was started with, which is
/// `provider` and `model` together; null leaves the session naming only the
/// model, since a proxy has no name in billy's table to record.
provider: ?models.Provider,
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

    const endpoint = try openEndpoint(arena, opened.config, &files.store);

    // Which backend each set is built from, remembered so the report of a
    // failure can name it: only the builder knows which provider it was on.
    var search_failed: tools.web.Search.Provider = .tavily;
    const search_config = searchConfig(arena, &files.store, opened.config, &search_failed) catch |err| {
        reportSearchFailure(err, search_failed);
        return err;
    };

    var fetch_failed: tools.web.Fetch.Provider = .raw;
    const fetch_config = fetchConfig(arena, &files.store, opened.config, &fetch_failed) catch |err| {
        reportFetchFailure(err, fetch_failed);
        return err;
    };

    return .{
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
        .model_choice = endpoint.choice,
        .store = files.store,
        .provider = endpoint.provider,
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
///
/// Everything comes from the configuration: the provider and model from its one
/// `model` setting, and the endpoint from the provider table the file may add to.
fn openEndpoint(
    arena: std.mem.Allocator,
    config: Config,
    store: *const credentials.Store,
) !Endpoint {
    const choice = config.stored.choice();
    const name = providerName(choice.text);
    const base_url = try resolveBaseUrl(config.stored.providers, choice.text);
    const api_key = store.get(name) orelse return missingKey(name);

    return .{
        .base_url = base_url,
        .api_key = api_key,
        // Every provider billy knows takes the completions path under its base,
        // so one is enough; a base that already carries it would double it, and
        // none of them do.
        .url = try completionsUrl(arena, base_url),
        .model = modelOf(choice.text),
        .choice = choice.text,
        .provider = models.Provider.fromName(name),
    };
}

/// The full URL of the completions endpoint under `base_url`.
fn completionsUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
}

/// The provider half of a choice: `deepseek` from `deepseek/deepseek-flash`.
fn providerName(choice: []const u8) []const u8 {
    return (models.Choice{ .text = choice }).provider();
}

/// Where the choice is sent: the base URL the configuration gives the provider,
/// which may be one of its own or one of billy's the file overrides. Null when
/// the configuration names neither, which the caller reports.
fn baseUrlOf(providers: Config.Providers, choice: []const u8) ?[]const u8 {
    const name = providerName(choice);
    if (providers.get(name)) |base_url| return base_url;
    const provider = models.Provider.fromName(name) orelse return null;
    return models.Provider.baseUrl(provider);
}

/// The base URL a request is sent to, reporting a provider the configuration
/// does not name before failing: the name came from a file the user wrote, so
/// they are the one who can add it.
fn resolveBaseUrl(providers: Config.Providers, choice: []const u8) error{UnknownProvider}![]const u8 {
    return baseUrlOf(providers, choice) orelse {
        std.log.err("'{s}' names no provider the configuration defines", .{choice});
        return error.UnknownProvider;
    };
}

/// The model id to send, from the choice a run was given. A choice with a
/// provider in front of it carries its own model; one without is a bare model
/// id, which is what a run against a proxy names and which is sent as it is.
fn modelOf(choice: []const u8) []const u8 {
    const chosen = models.Choice{ .text = choice };
    if (chosen.provider().len > 0) return chosen.model();
    return choice;
}

/// Reports that no key is stored for the provider a request is sent to, naming
/// the login that stores one. Fails the request rather than sending it without a
/// key, which the provider would only refuse with less to go on.
fn missingKey(name: []const u8) error{MissingApiKey} {
    std.log.err("no key stored for '{s}'; run `billy login {s}` to store one", .{ name, name });
    return error.MissingApiKey;
}

/// Where billy talks to the model, and as which model.
const Endpoint = struct {
    base_url: []const u8,
    api_key: []const u8,
    /// The full URL of the chat completions endpoint, built from `base_url`.
    url: []const u8,
    model: []const u8,
    /// The provider and model a new session starts on, as the one string the
    /// configuration and a session both name it by, after any environment
    /// override.
    choice: []const u8,
    /// The provider the endpoint belongs to, or null for one billy does not
    /// know, such as a proxy.
    provider: ?models.Provider,
};

/// Where a session is sent, and as which model: everything a request needs that
/// follows from the provider and model the session recorded rather than from the
/// configuration.
///
/// A session keeps the choice it was started with, so resuming one can point at
/// a provider other than the configured one; everything a request needs is
/// resolved from that choice, not from the setup's own endpoint. `model` is the
/// id to send, which is the half after the provider in the choice.
pub const Target = struct {
    provider: ?models.Provider,
    base_url: []const u8,
    url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// What is known about the model: its window, for the gauge and the
    /// compaction threshold. Null for a model billy has no numbers for.
    info: ?models.Metadata,
};

/// Where `session` is sent, recording the configured choice on a session that
/// has none.
///
/// A session keeps the choice it began with rather than following the
/// configuration, because a conversation belongs to the model that produced it.
/// One that recorded none was being sent wherever billy was pointed, so it takes
/// the configured choice and keeps it from here on.
pub fn sessionTarget(setup: *Setup, gpa: std.mem.Allocator, session: *Session) !agent.Target {
    if (!session.hasModel()) try session.setModel(setup.model_choice);
    return setup.targetFor(gpa, session.modelChoice(setup.model_choice));
}

/// Where `choice` is sent, which is the four things a request needs that follow
/// from it rather than from the configured endpoint.
pub fn targetFor(setup: *Setup, arena: std.mem.Allocator, choice: []const u8) !agent.Target {
    const providers = setup.config.stored.providers;
    const name = providerName(choice);
    // A session's own provider decides where it goes, resolved through the same
    // table the configured one was: a provider the configuration defines, or one
    // of billy's the file did not override.
    const base_url = try resolveBaseUrl(providers, choice);
    const api_key = setup.store.get(name) orelse return missingKey(name);

    // The model is copied out rather than sliced from `choice`: the choice a
    // session passes is a slice of its own string pool, and a pointer into that
    // pool survives no write to it, so the next intern would leave the target
    // naming freed bytes. The URL is allocated here for the same reason.
    const model = try arena.dupe(u8, modelOf(choice));
    return .{
        .base_url = base_url,
        .url = try completionsUrl(arena, base_url),
        .api_key = api_key,
        .model = model,
        .info = models.lookup(models.Provider.fromName(name), model),
    };
}

pub fn deinit(setup: *Setup, io: std.Io) void {
    setup.health.deinit();
    setup.config.deinit();
    setup.sessions.close(io);
    setup.config_dir.close(io);
    setup.data_dir.close(io);
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
            .api_key = if (service) |name|
                store.get(name) orelse return error.MissingApiKey
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
            .api_key = if (service) |name|
                store.get(name) orelse return error.MissingApiKey
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
                "run `billy login {s}` to use {s}, or clear tools.web_search in the configuration",
                .{ service, @tagName(provider) },
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
                "run `billy login {s}` to use {s}, or clear tools.web_fetch in the configuration",
                .{ service, @tagName(provider) },
            );
        },
        else => {},
    }
}

/// The agent configuration for a session working in `cwd`, with its blocks
/// decorated for `style`.
///
/// The window is not reported by the API, so it is looked up by provider and
/// model; an unknown model simply has no gauge, and so no compaction, which needs
/// a window to measure a conversation against.
///
/// Nothing is allocated here: every string is one the setup already holds, so
/// asking for this once a turn costs nothing that would have to be freed.
pub fn agentConfig(setup: *Setup, cwd: []const u8, style: Terminal.Style) agent.Config {
    const config = &setup.config.stored;
    return .{
        .api_key = setup.api_key,
        .url = setup.url,
        .model = setup.model,
        .model_choice = setup.model_choice,
        .max_turns = config.max_turns,
        .bash_timeout_s = config.tools.bash.timeout_s,
        .cwd = cwd,
        .home = setup.environ.get("HOME"),
        // The user's own instructions, which live beside the configuration and
        // join every session's prompt. The setup owns the directory and outlives
        // every runner built from this.
        .user_instructions_dir = setup.config_dir,
        .model_info = models.lookup(setup.provider, setup.model),
        .compact_at = config.compact_at,
        .title = config.title,
        // The thinking fields are one provider's own, so they are sent only to a
        // provider that takes them: a model whose provider billy does not know,
        // or one whose endpoint does not accept them, is left alone.
        .reasoning = if (setup.provider) |provider|
            if (provider.takesThinking()) reasoningOf(config.reasoning) else .provider_default
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
                .bash = if (config.tools.bash.format) |script| .{ .script = script } else null,
                .edit = if (config.tools.edit.format) |script| .{ .script = script } else null,
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
    try std.testing.expect((try searchConfig(arena, &store, off, &failed)) == null);

    // A backend billy knows is asked for a key, and one that is not set is an
    // error rather than a silent "no search".
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_search.providers = &.{.tavily};
    try std.testing.expectError(error.MissingApiKey, searchConfig(arena, &store, naming, &failed));
    // The backend at fault is the one the report names.
    try std.testing.expectEqual(tools.web.Search.Provider.tavily, failed);

    // SearXNG needs no key, but needs the instance named.
    var searx = Config.init(gpa);
    defer searx.deinit();

    searx.stored.tools.web_search.providers = &.{.searxng};
    try std.testing.expectError(error.MissingSearchUrl, searchConfig(arena, &store, searx, &failed));

    // Every named backend becomes a backend to try, in the order named.
    searx.stored.tools.web_search.searxng.url = "https://searx.example.org";
    const config = (try searchConfig(arena, &store, searx, &failed)).?;
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
    const config = (try fetchConfig(arena, &store, raw, &failed)).?;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(tools.web.Fetch.Provider.raw, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);

    // A service needs its key, on the same terms as a search backend.
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_fetch.providers = &.{.tavily};
    try std.testing.expectError(error.MissingApiKey, fetchConfig(arena, &store, naming, &failed));
    try std.testing.expectEqual(tools.web.Fetch.Provider.tavily, failed);

    // A set with nothing in it leaves `web_fetch` out of the request.
    var none = Config.init(gpa);
    defer none.deinit();

    none.stored.tools.web_fetch.providers = &.{};
    try std.testing.expect((try fetchConfig(arena, &store, none, &failed)) == null);
}

test "the model id is the half after the provider, and a bare one is itself" {
    // A configured choice carries its provider in the string, so the id sent is
    // the half after the slash.
    try std.testing.expectEqualStrings("deepseek-flash", modelOf("deepseek/deepseek-flash"));
    try std.testing.expectEqualStrings("glm-5.3-flash", modelOf("opencode_go/glm-5.3-flash"));
    try std.testing.expectEqualStrings("kimi-k2.7-code", modelOf("opencode_go/kimi-k2.7-code"));
    // A model id with a slash of its own keeps the rest of it.
    try std.testing.expectEqualStrings("model/variant", modelOf("vendor/model/variant"));

    // An override with no provider in front of it is a bare model id, which is
    // what a run against a proxy or a local server names.
    try std.testing.expectEqualStrings("m", modelOf("m"));
    try std.testing.expectEqualStrings("qwen3-coder:30b", modelOf("qwen3-coder:30b"));
}

test "a target names bytes of its own, not a slice of the session's pool" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    defer environ.deinit();

    var opened = try Config.open(std.testing.io, tmp.dir, gpa);
    defer opened.config.deinit();
    // The key a request is sent with is the one stored under the provider's
    // name, so the store has to hold it for the target to resolve at all.
    var store: credentials.Store = .{};
    try store.put(arena, "opencode_go", "k");

    var setup: Setup = .{
        .environ = &environ,
        .config = opened.config,
        .sessions = tmp.dir,
        .data_dir = tmp.dir,
        .config_dir = tmp.dir,
        .cwd = "/work",
        .api_key = "k",
        .base_url = "https://opencode.ai/zen/go/v1",
        .url = "https://opencode.ai/zen/go/v1/chat/completions",
        .model = "glm-5.3-flash",
        .model_choice = "opencode_go/glm-5.3-flash",
        .store = store,
        .provider = .opencode_go,
        .search = null,
        .fetch = null,
        .health = .{ .io = std.testing.io, .gpa = gpa, .dir = tmp.dir },
    };

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    const target = try setup.sessionTarget(arena, &session);
    // The model the session recorded is interned in its string pool, and a
    // pointer into that pool survives no write to it. Writing more strings, as
    // a turn does when it stores a message, must not leave the target naming
    // freed bytes: the earlier code sliced the pool and sent `UUUUU...` on the
    // wire once the pool grew.
    try std.testing.expectEqualStrings("glm-5.3-flash", target.model);
    for (0..40) |i| {
        var buffer: [64]u8 = undefined;
        const filler = try std.fmt.bufPrint(&buffer, "filler {d} padding padding padding padding", .{i});
        try session.append(.{ .role = .user, .content = filler });
    }
    try std.testing.expectEqualStrings("glm-5.3-flash", target.model);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", target.url);
}

test "the endpoint comes from the provider the choice names" {
    const none: Config.Providers = .{};

    // A provider billy ships decides its own endpoint, so a configured
    // `opencode_go/glm-5.3-flash` reaches Go with no URL written anywhere.
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com",
        baseUrlOf(none, "deepseek/deepseek-flash").?,
    );
    try std.testing.expectEqualStrings(
        "https://opencode.ai/zen/go/v1",
        baseUrlOf(none, "opencode_go/glm-5.3-flash").?,
    );

    // One the configuration defines does the same, which is how a proxy, a
    // server of the user's own, or a stand-in a test points a run at is reached.
    const defined: Config.Providers = .{ .entries = &.{
        .{ .name = "mock", .base_url = "http://127.0.0.1:8901/v1" },
    } };
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", baseUrlOf(defined, "mock/m").?);

    // A name the configuration gives to one of billy's own overrides what billy
    // would have used, so a proxy in front of a known provider is reachable.
    const overriding: Config.Providers = .{ .entries = &.{
        .{ .name = "deepseek", .base_url = "http://127.0.0.1:9/v1" },
    } };
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9/v1",
        baseUrlOf(overriding, "deepseek/deepseek-flash").?,
    );
}

test "a provider the configuration does not name is refused, not defaulted" {
    const none: Config.Providers = .{};
    // A typo would otherwise send the conversation to whichever endpoint billy
    // fell back on, which is worse than failing: the request would go somewhere
    // the user did not name.
    try std.testing.expect(baseUrlOf(none, "who-knows/m") == null);
    try std.testing.expect(baseUrlOf(none, "m") == null);
    try std.testing.expect(baseUrlOf(none, "/m") == null);

    // Once the configuration defines the name, the same choice resolves, which
    // is what makes a proxy or a server of the user's own reachable.
    const defined: Config.Providers = .{ .entries = &.{
        .{ .name = "who-knows", .base_url = "http://127.0.0.1:8901/v1" },
    } };
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", baseUrlOf(defined, "who-knows/m").?);
}

test "the completions path is appended once, whatever the base carries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/chat/completions",
        try completionsUrl(arena, "https://api.deepseek.com"),
    );
    // A base written with a trailing slash does not double it.
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/chat/completions",
        try completionsUrl(arena, "https://api.deepseek.com/"),
    );
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8901/v1/chat/completions",
        try completionsUrl(arena, "http://127.0.0.1:8901/v1"),
    );
}

test "the reasoning setting names what billy asks of the model's thinking" {
    // The two names billy knows, and any other name as an effort level of the
    // provider's own, which is passed on rather than refused.
    try std.testing.expectEqual(llm.Reasoning.off, reasoningOf("off"));
    try std.testing.expectEqual(llm.Reasoning.provider_default, reasoningOf("default"));
    try std.testing.expectEqualStrings("high", reasoningOf("high").effort);
    try std.testing.expectEqualStrings("low", reasoningOf("low").effort);
}
