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
settings: Config,
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

    // billy's own files live under the data directory: the credentials in the
    // directory itself, and the sessions in a subdirectory of it. The credentials
    // are not kept with the configuration, which is meant to be shared between
    // machines, and a key is not.
    const data_dir_path = Session.dataDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store billy's files: {s}", .{@errorName(err)});
        return err;
    };
    var data_dir = std.Io.Dir.cwd().createDirPathOpen(io, data_dir_path, .{}) catch |err| {
        std.log.err("cannot use {s} for billy's files: {s}", .{ data_dir_path, @errorName(err) });
        return err;
    };
    errdefer data_dir.close(io);

    const store = credentials.load(io, data_dir, arena) catch |err| {
        std.log.err("cannot read the credentials in {s}: {s}", .{ data_dir_path, @errorName(err) });
        return err;
    };

    const config_dir_path = Config.defaultDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store the configuration: {s}", .{@errorName(err)});
        return err;
    };
    var config_dir = std.Io.Dir.cwd().createDirPathOpen(io, config_dir_path, .{}) catch |err| {
        std.log.err("cannot use {s} for the configuration: {s}", .{ config_dir_path, @errorName(err) });
        return err;
    };
    errdefer config_dir.close(io);

    // The configuration owns an arena of its own for the strings it reads, so it
    // is freed when the run is over rather than with the process arena.
    var settings = Config.open(io, config_dir, init.gpa) catch |err| {
        std.log.err("cannot read the configuration in {s}: {s}", .{ config_dir_path, @errorName(err) });
        return err;
    };
    errdefer settings.config.deinit();
    if (settings.created) {
        try out.print("wrote the default configuration to {s}\n", .{
            try std.fs.path.join(arena, &.{ config_dir_path, Config.file_name }),
        });
    }

    const base_url = environ.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";
    const model = environ.get("BILLY_MODEL") orelse "deepseek-flash";
    // The endpoint URL is built once, here, and lives with the process. The web
    // server asks for the agent configuration once per turn, so building it
    // there would leak one allocation per turn into the process arena.
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
    const api_key = credentials.modelKey(&store, environ, base_url) orelse {
        std.log.err("run `billy login deepseek`, or set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    // The sessions live in a subdirectory of billy's data directory, apart from
    // the credentials stored in the directory itself.
    const sessions_path = Session.defaultDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store sessions: {s}", .{@errorName(err)});
        return err;
    };
    var sessions = std.Io.Dir.cwd().createDirPathOpen(io, sessions_path, .{}) catch |err| {
        std.log.err("cannot use {s} for sessions: {s}", .{ sessions_path, @errorName(err) });
        return err;
    };
    errdefer sessions.close(io);

    // Each tool reports the backend at fault on its own, since the two sets are
    // configured apart from each other.
    var search_blame: tools.web.Search.Provider = .tavily;
    const search_config = searchConfig(arena, &store, environ, settings.config, &search_blame) catch |err| {
        switch (err) {
            error.MissingApiKey => {
                // The backend is named, so a service is one of the ones reached
                // with a key.
                const service = credentials.searchService(search_blame).?;
                std.log.err(
                    "run `billy login {s}`, or set {s} to use {s}, or clear tools.web_search in the configuration",
                    .{ service.name(), service.variable(), @tagName(search_blame) },
                );
            },
            error.MissingSearchUrl => std.log.err(
                "set tools.web_search.searxng.url to your SearXNG instance, or clear tools.web_search in the configuration",
                .{},
            ),
            else => {},
        }
        return err;
    };

    var fetch_blame: tools.web.Fetch.Provider = .tavily;
    const fetch_config = fetchConfig(arena, &store, environ, settings.config, &fetch_blame) catch |err| {
        switch (err) {
            error.MissingApiKey => {
                const service = credentials.fetchService(fetch_blame).?;
                std.log.err(
                    "run `billy login {s}`, or set {s} to use {s}, or clear tools.web_fetch in the configuration",
                    .{ service.name(), service.variable(), @tagName(fetch_blame) },
                );
            },
            else => {},
        }
        return err;
    };

    return .{
        .io = io,
        .gpa = init.gpa,
        .environ = environ,
        .settings = settings.config,
        .sessions = sessions,
        .data_dir = data_dir,
        .config_dir = config_dir,
        .cwd = cwd,
        .api_key = api_key,
        .base_url = base_url,
        .url = url,
        .model = model,
        .search = search_config,
        .fetch = fetch_config,
        // The waits web backends were last given, read from disk.
        .health = try Health.load(io, init.gpa, data_dir),
    };
}

pub fn deinit(setup: *Setup) void {
    setup.health.deinit();
    setup.settings.deinit();
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

/// The web fetch settings for a configuration that names a backend, or null when
/// it names none. `raw` needs no key, so a configuration that holds only it
/// fetches without a service.
fn fetchConfig(
    arena: std.mem.Allocator,
    store: *const credentials.Store,
    environ: *const std.process.Environ.Map,
    settings: Config,
    blame: *tools.web.Fetch.Provider,
) !?tools.web.Fetch.Config {
    const web = settings.tools.web_fetch;
    if (web.providers.len == 0) return null;

    const backends = try arena.alloc(tools.web.Fetch.Backend, web.providers.len);
    for (web.providers, backends) |provider, *backend| {
        blame.* = provider;
        const service = credentials.fetchService(provider);
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |one|
                credentials.credential(store, environ, one) orelse return error.MissingApiKey
            else
                "",
        };
    }
    return .{ .backends = backends };
}

/// The web search settings for a configuration that names a backend, or null
/// when it names none. A backend named without its key is an error rather than a
/// silent "no search": the configuration asked for the tool, and leaving it out
/// without a word would look like a bug.
fn searchConfig(
    arena: std.mem.Allocator,
    store: *const credentials.Store,
    environ: *const std.process.Environ.Map,
    settings: Config,
    blame: *tools.web.Search.Provider,
) !?tools.web.Search.Config {
    const web = settings.tools.web_search;
    if (web.providers.len == 0) return null;

    // Each backend resolves its own key, or, for the one that is self-hosted,
    // needs the instance named instead. What went wrong is left to the caller to
    // report, which is what `blame` is for, so this only says which it was.
    const backends = try arena.alloc(tools.web.Search.Backend, web.providers.len);
    for (web.providers, backends) |provider, *backend| {
        blame.* = provider;
        const service = credentials.searchService(provider);
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |one|
                credentials.credential(store, environ, one) orelse return error.MissingApiKey
            else blk: {
                // A backend billy knows the address of needs only its key; one it
                // does not, SearXNG, needs the instance named.
                if (web.searxng.url == null or web.searxng.url.?.len == 0) return error.MissingSearchUrl;
                break :blk "";
            },
            // Only a self-hosted backend is reached somewhere billy does not know.
            .endpoint = if (service == null) web.searxng.url else null,
        };
    }
    return .{ .backends = backends, .max_results = web.max_results };
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
    const settings = &setup.settings;
    return .{
        .api_key = setup.api_key,
        .url = setup.url,
        .model = setup.model,
        .max_turns = settings.max_turns,
        .bash_timeout_s = settings.tools.bash.timeout_s,
        .cwd = cwd,
        .home = setup.environ.get("HOME"),
        // The user's own instructions, which live beside the configuration and
        // join every session's prompt. The setup owns the directory and outlives
        // every runner built from this.
        .user_instructions_dir = setup.config_dir,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .compact_at = settings.compact_at,
        .title = settings.title,
        // A model whose provider billy does not know is left alone: the fields
        // are one provider's own, and an endpoint that does not know them may
        // refuse a request that carries them.
        .reasoning = if (models.Provider.fromUrl(setup.base_url) != null)
            reasoningOf(settings.reasoning)
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
                .bash = if (settings.tools.bash.format) |script| .{
                    .script = script,
                    .io = setup.io,
                    .gpa = setup.gpa,
                } else null,
                .edit = if (settings.tools.edit.format) |script| .{
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
    var blame: tools.web.Search.Provider = .tavily;

    // Nothing named is no search at all.
    var off = Config.init(gpa);
    defer off.deinit();
    try std.testing.expect((try searchConfig(arena, &store, &environ, off, &blame)) == null);

    // A backend billy knows is asked for a key, and one that is not set is an
    // error rather than a silent "no search". The backend at fault is reported.
    var naming = Config.init(gpa);
    defer naming.deinit();
    naming.tools.web_search.providers = &.{.tavily};
    try std.testing.expectError(error.MissingApiKey, searchConfig(arena, &store, &environ, naming, &blame));
    try std.testing.expectEqual(tools.web.Search.Provider.tavily, blame);

    // SearXNG needs no key, but needs the instance named.
    var searx = Config.init(gpa);
    defer searx.deinit();
    searx.tools.web_search.providers = &.{.searxng};
    try std.testing.expectError(error.MissingSearchUrl, searchConfig(arena, &store, &environ, searx, &blame));

    // Every named backend becomes a backend to try, in the order named.
    searx.tools.web_search.searxng.url = "https://searx.example.org";
    const config = (try searchConfig(arena, &store, &environ, searx, &blame)).?;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(tools.web.Search.Provider.searxng, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);
    try std.testing.expectEqualStrings("https://searx.example.org", config.backends[0].endpoint.?);
}

test "the reasoning setting names what billy asks of the model's thinking" {
    // The two names billy knows, and any other name as an effort level of the
    // provider's own, which is passed on rather than refused.
    try std.testing.expectEqual(llm.Reasoning.off, reasoningOf("off"));
    try std.testing.expectEqual(llm.Reasoning.provider_default, reasoningOf("default"));
    try std.testing.expectEqualStrings("high", reasoningOf("high").effort);
    try std.testing.expectEqualStrings("low", reasoningOf("low").effort);
}
