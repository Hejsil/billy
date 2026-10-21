//! The endpoints billy talks to: the model endpoint its requests are sent to,
//! which follows from the provider and model the configuration names, and the
//! backends its web tools ask.
//!
//! What a run is otherwise given, beyond its conversation, is resolved here too,
//! since it follows from the same two things: the settings the agent reads while
//! it runs, what its tools run with, and how its blocks are shown.
//!
//! All of it is built from the configuration and the credentials, both of which
//! are read in once and passed in. Nothing is held here, so a caller that has
//! those two can build any of it where it is needed, and a session can be sent
//! somewhere other than where the configuration points.

const std = @import("std");
const agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Health = @import("Health.zig");
const llm = @import("llm.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const tools = @import("Tools.zig");

/// The model endpoint requests are sent to: where it is, what it is asked with,
/// and which model it is asked for.
pub const Endpoint = struct {
    base_url: []const u8,
    /// The full URL of the completions endpoint, built from `base_url`.
    url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// The provider the endpoint belongs to, or null for one billy does not
    /// know, such as a proxy. It is what the model's window is looked up by, and
    /// what decides whether the provider's own thinking fields are sent.
    provider: ?models.Provider,
};

/// The backends billy's web tools ask, in the order they are tried. A tool whose
/// backend is null is left out of the ones the model is offered.
pub const Backends = struct {
    search: ?tools.web.Search.Config,
    fetch: ?tools.web.Fetch.Config,

    /// The backends the configuration names, reporting the one at fault when a
    /// backend it names cannot be built: the configuration asked for the tool,
    /// so leaving it out without a word would look like a bug.
    pub fn build(arena: std.mem.Allocator, config: Config, store: *const Credentials) !Backends {
        // Which backend each set is built from, remembered so the report can
        // name it: only the builder knows which provider it was on.
        var search_failed: tools.web.Search.Provider = .tavily;
        const search_config = searchConfig(arena, store, config, &search_failed) catch |err| {
            reportSearchFailure(err, search_failed);
            return err;
        };

        var fetch_failed: tools.web.Fetch.Provider = .raw;
        const fetch_config = fetchConfig(arena, store, config, &fetch_failed) catch |err| {
            reportFetchFailure(err, fetch_failed);
            return err;
        };

        return .{ .search = search_config, .fetch = fetch_config };
    }
};

/// Where the configuration sends its requests: the provider and model it names,
/// resolved to an endpoint and the key stored for it.
pub fn open(arena: std.mem.Allocator, config: Config, store: *const Credentials) !Endpoint {
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
        .model = choice.model(),
        .provider = models.Provider.fromName(name),
    };
}

/// Where `session` is sent, recording the configured choice on a session that
/// has none.
///
/// A session keeps the choice it began with rather than following the
/// configuration, because a conversation belongs to the model that produced it.
/// One that recorded none was being sent wherever billy was pointed, so it takes
/// the configured choice and keeps it from here on.
pub fn sessionTarget(
    config: Config,
    store: *const Credentials,
    arena: std.mem.Allocator,
    session: *Session,
) !agent.Target {
    const choice = config.stored.model;
    if (session.model() == null) try session.setModel(choice);
    return targetFor(config, store, arena, session.modelChoice(choice));
}

/// Where `choice` is sent, which is the four things a request needs that follow
/// from it rather than from the configured endpoint.
fn targetFor(
    config: Config,
    store: *const Credentials,
    arena: std.mem.Allocator,
    choice: []const u8,
) !agent.Target {
    const name = providerName(choice);
    // A session's own provider decides where it goes, resolved through the same
    // table the configured one was: a provider the configuration defines, or one
    // of billy's the file did not override.
    const base_url = try resolveBaseUrl(config.stored.providers, choice);

    // The model is copied out rather than sliced from `choice`: the choice a
    // session passes is a slice of its own string pool, and a pointer into that
    // pool survives no write to it, so the next intern would leave the target
    // naming freed bytes. The URL is allocated here for the same reason.
    const model = try arena.dupe(u8, (models.Choice{ .text = choice }).model());
    return .{
        .url = try completionsUrl(arena, base_url),
        .api_key = store.get(name) orelse return missingKey(name),
        .model = model,
        // Which provider answers, which is what the agent looks the model's
        // window up by. Null for a proxy, which leaves the model to be found
        // among the providers billy ships.
        .provider = models.Provider.fromName(name),
    };
}

/// Where a run's requests are sent, as the agent takes it: the endpoint the
/// configuration resolved to, and which provider answers it, asked for the
/// model's thinking as the configuration says and that provider allows.
pub fn agentEndpoint(config: Config, endpoint: Endpoint) agent.Endpoint {
    return .{
        .target = .{
            .url = endpoint.url,
            .api_key = endpoint.api_key,
            .model = endpoint.model,
            // Which provider answers, so the window the header gauges against is
            // the one of the model actually being sent. A provider billy does not
            // know leaves the model to be found among the ones it ships.
            .provider = endpoint.provider,
        },
        // The thinking fields are one provider's own, so they are sent only to a
        // provider that takes them: a model whose provider billy does not know,
        // or one whose endpoint does not accept them, is left alone.
        .reasoning = if (endpoint.provider) |provider|
            if (provider.takesThinking()) reasoningOf(config.stored.reasoning) else .provider_default
        else
            .provider_default,
    };
}

/// How a run's blocks are laid out and decorated: the formatter scripts the
/// configuration names for a tool's block, and the style of the terminal that
/// shows them. A reply and a prompt are markdown, laid out by billy's own
/// renderer.
///
/// Only the display changes: the command that runs, the file that is written, the
/// session and the model keep the text as it was written.
pub fn display(config: Config, style: Terminal.Style) Terminal.Display {
    const stored = &config.stored;
    return .{
        // A bash command is laid out by its format script, so the user reads the
        // command the way it runs; an edit is shown as a diff, laid out by its
        // own script when one is set.
        .formats = .{
            .bash = if (stored.tools.bash.format) |script| .{ .script = script } else null,
            .edit = if (stored.tools.edit.format) |script| .{ .script = script } else null,
        },
        .style = style,
    };
}

/// How a run's agent behaves: the turns it gives the model, the share of the
/// window it fills before the conversation is folded into a summary, and whether
/// it names the session. Where its requests go is resolved separately, as
/// `agentEndpoint`, what its tools run with as `toolSettings`, and how its blocks
/// are shown as `display`.
pub fn behaviour(config: Config) agent.Behaviour {
    const stored = &config.stored;
    return .{
        .max_turns = stored.max_turns,
        .compact_at = stored.compact_at,
        .title = stored.title,
    };
}

/// One model as a header shows it: the id a request names, and what is known
/// about its window.
pub const Model = struct {
    /// The model id, which is the half of a choice after the provider.
    id: []const u8,
    /// What is known about it: its window, for the gauge. Null for a model billy
    /// has no numbers for.
    info: ?models.Metadata,
};

/// The model a session is sent to, as the header above its conversation shows
/// it: the choice it recorded, or the configured one for a session that recorded
/// none. A session keeps the choice it was started with, so the header names
/// where it goes rather than where billy is pointed, and both frontends read it
/// here so a page and a terminal agree.
pub fn sessionModel(config: Config, session: *const Session) Model {
    const choice = models.Choice{ .text = session.modelChoice(config.stored.model) };
    const id = choice.model();
    return .{
        .id = id,
        .info = models.lookup(models.Provider.fromName(choice.provider()), id),
    };
}

/// How a run's tools are built: how their blocks are laid out, the limits they
/// run under, and the backends its web tools ask.
///
/// The run adds its own plumbing -- its I/O, the directory it works in, its
/// allocator and its HTTP client -- when it builds the set, so neither frontend
/// handles those and neither can offer a tool the others do not.
pub fn toolSettings(
    config: Config,
    backends: Backends,
    health: ?*Health,
    shown: Terminal.Display,
) tools.Settings {
    const stored = &config.stored;
    return .{
        // A tool's block is laid out and decorated for the display the run's
        // blocks are shown on, so a call reads the same in the transcript as it
        // did when it ran.
        .display = shown,
        .bash_timeout_s = stored.tools.bash.timeout_s,
        // A web tool is offered only when the configuration names a backend for
        // it and its key is set; the tool is left out of the request otherwise.
        // The waits travel with the run, so a backend that just failed is
        // skipped.
        .search = backends.search,
        .fetch = backends.fetch,
        .health = health,
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

/// Reports that no key is stored for the provider a request is sent to, naming
/// the login that stores one. Fails the request rather than sending it without a
/// key, which the provider would only refuse with less to go on.
fn missingKey(name: []const u8) error{MissingApiKey} {
    std.log.err("no key stored for '{s}'; run `billy login {s}` to store one", .{ name, name });
    return error.MissingApiKey;
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
    store: *const Credentials,
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
        const service = Credentials.searchService(provider);
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
pub fn fetchConfig(
    arena: std.mem.Allocator,
    store: *const Credentials,
    config: Config,
    failed: *tools.web.Fetch.Provider,
) !?tools.web.Fetch.Config {
    const web_config = config.stored.tools.web_fetch;
    if (web_config.providers.len == 0) return null;

    const backends = try arena.alloc(tools.web.Fetch.Backend, web_config.providers.len);
    for (web_config.providers, backends) |provider, *backend| {
        failed.* = provider;
        const service = Credentials.fetchService(provider);
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
            const service = Credentials.searchService(provider).?;
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
            const service = Credentials.fetchService(provider).?;
            std.log.err(
                "run `billy login {s}` to use {s}, or clear tools.web_fetch in the configuration",
                .{ service, @tagName(provider) },
            );
        },
        else => {},
    }
}

test "each backend resolves its own key, and SearXNG its instance" {
    const gpa = std.testing.allocator;
    // The backends are built in the arena the setup runs in, which owns them.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const store: Credentials = .{};

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
    const store: Credentials = .{};

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

test "a header names the model the session goes to, not the one billy is pointed at" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The configuration points at DeepSeek; the session recorded a model of
    // another provider, which is where it is sent.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = Config.file_name,
        .data = "{\"model\":\"deepseek/deepseek-flash\"}",
    });
    var opened = try Config.open(std.testing.io, tmp.dir, gpa);
    defer opened.config.deinit();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setModel("opencode_go/kimi-k2.7-code");

    // The id is the half of its own choice, and the window the one of that model.
    const recorded = sessionModel(opened.config, &session);
    try std.testing.expectEqualStrings("kimi-k2.7-code", recorded.id);
    try std.testing.expectEqual(@as(usize, 262_144), recorded.info.?.context_window);
    try std.testing.expectEqual(models.Provider.opencode_go, recorded.info.?.provider);

    // A session that recorded none is sent where the configuration points, so
    // that is what its header names.
    var older = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer older.deinit();
    const configured = sessionModel(opened.config, &older);
    try std.testing.expectEqualStrings("deepseek-flash", configured.id);
    try std.testing.expectEqual(@as(usize, 1_000_000), configured.info.?.context_window);
}

test "a target names bytes of its own, not a slice of the session's pool" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = Config.file_name,
        .data = "{\"model\":\"opencode_go/glm-5.3-flash\"}",
    });
    var opened = try Config.open(std.testing.io, tmp.dir, gpa);
    defer opened.config.deinit();
    // The key a request is sent with is the one stored under the provider's
    // name, so the store has to hold it for the target to resolve at all.
    var store: Credentials = .{};
    try store.put(arena, "opencode_go", "k");

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    const target = try sessionTarget(opened.config, &store, arena, &session);
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

test "a run's endpoint carries the address and the provider, and only the thinking it takes" {
    const gpa = std.testing.allocator;
    var config = Config.init(gpa);
    defer config.deinit();
    config.stored.reasoning = "high";

    const endpoint: Endpoint = .{
        .base_url = "https://api.deepseek.com",
        .url = "https://api.deepseek.com/chat/completions",
        .api_key = "k",
        .model = "deepseek-flash",
        .provider = .deepseek,
    };

    // Where the request goes, and which provider answers it, are taken as they
    // were resolved; a provider that takes the thinking fields is asked for what
    // the configuration says.
    const asked = agentEndpoint(config, endpoint);
    try std.testing.expectEqualStrings(endpoint.url, asked.target.url);
    try std.testing.expectEqualStrings("k", asked.target.api_key);
    try std.testing.expectEqualStrings("deepseek-flash", asked.target.model);
    try std.testing.expectEqual(models.Provider.deepseek, asked.target.provider.?);
    try std.testing.expectEqualStrings("high", asked.reasoning.effort);

    // A provider that does not take them is left on whatever it does by itself:
    // a request carrying fields an endpoint does not expect may be refused.
    var untaken = endpoint;
    untaken.provider = .opencode_go;
    try std.testing.expectEqual(llm.Reasoning.provider_default, agentEndpoint(config, untaken).reasoning);

    // An endpoint billy knows no provider of keeps that unknown, so the agent
    // finds the model it names among the ones billy ships.
    var unknown = endpoint;
    unknown.provider = null;
    const unattributed = agentEndpoint(config, unknown);
    try std.testing.expectEqual(llm.Reasoning.provider_default, unattributed.reasoning);
    try std.testing.expect(unattributed.target.provider == null);
}
