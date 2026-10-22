//! What a run is given, resolved from the configuration and the credentials: the
//! backends its web tools ask, how its agent behaves, what its tools run with,
//! and the model a header names.
//!
//! Where a request is actually sent -- the provider and model resolved into a URL
//! and a key -- is `Endpoint`, which the agent resolves for itself before every
//! turn. What is here is the rest of what a frontend hands a run before it starts.
//!
//! Nothing is held here: every function takes the two it needs and returns a
//! value, so either frontend can build any of it where it is needed.

const std = @import("std");
const agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Endpoint = @import("Endpoint.zig");
const Health = @import("Health.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const tools = @import("Tools.zig");

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

/// The model a session is sent to, as the header above its conversation shows
/// it: the choice it recorded, or the configured one for a session that recorded
/// none. A session keeps the choice it was started with, so the header names
/// where it goes rather than where billy is pointed. The terminal's header is
/// built from the same `Endpoint.modelOf`, so a page and a terminal agree.
pub fn sessionModel(config: Config, session: *const Session) Endpoint.Model {
    return Endpoint.modelOf(session.modelChoice(config.stored.model));
}

/// How a run's tools are built: how their blocks are laid out, the limits they
/// run under, and the backends its web tools ask.
///
/// The run adds its own plumbing -- its I/O, the directory it works in, its
/// allocator and its HTTP client -- when it builds the set, so neither frontend
/// handles those and neither can offer a tool the others do not.
pub fn toolSettings(config: Config, backends: Backends, health: ?*Health) tools.Settings {
    const stored = &config.stored;
    return .{
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

    // The choice is the session's own, provider and all, and the window is that
    // model's.
    const recorded = sessionModel(opened.config, &session);
    try std.testing.expectEqualStrings("opencode_go/kimi-k2.7-code", recorded.choice);
    try std.testing.expectEqual(@as(usize, 262_144), recorded.info.?.context_window);
    try std.testing.expectEqual(models.Provider.opencode_go, recorded.info.?.provider);

    // A session that recorded none is sent where the configuration points, so
    // that is what its header names.
    var older = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer older.deinit();
    const configured = sessionModel(opened.config, &older);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", configured.choice);
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

    // The choice a session that recorded none is given is the configured one, so
    // that is what it is sent to.
    const choice = session.modelChoice(opened.config.stored.model);
    try std.testing.expectEqualStrings("opencode_go/glm-5.3-flash", choice);
    const target = try Endpoint.targetFor(&opened.config, &store, arena, choice);
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
