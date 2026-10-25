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
const Agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Endpoint = @import("Endpoint.zig");
const models = @import("models.zig");
const Health = @import("Health.zig");
const report = @import("report.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const Tools = @import("Tools.zig");

const Setup = @This();

/// The backends billy's web tools ask, in the order they are tried. A tool whose
/// backend is null is left out of the ones the model is offered.
pub const Backends = struct {
    search: ?Tools.web.Search.Config,
    fetch: ?Tools.web.Fetch.Config,

    /// The backends the configuration names, reporting the one at fault when a
    /// backend it names cannot be built: the configuration asked for the tool,
    /// so leaving it out without a word would look like a bug.
    pub fn build(arena: std.mem.Allocator, config: *const Config, credentials: *const Credentials) !Backends {
        const search_config = switch (try searchConfig(arena, credentials, config)) {
            .none => null,
            .config => |settings| settings,
            .failed => |failed| {
                reportSearchFailure(failed.err, failed.provider);
                return report.Reported;
            },
        };

        const fetch_config = switch (try fetchConfig(arena, credentials, config)) {
            .none => null,
            .config => |settings| settings,
            .failed => |failed| {
                reportFetchFailure(failed.err, failed.provider);
                return report.Reported;
            },
        };

        return .{ .search = search_config, .fetch = fetch_config };
    }
};

/// The model a session is sent to, as the header above its conversation shows
/// it: the choice it recorded, or the configured one for a session that recorded
/// none. A session keeps the choice it recorded, so the header names where it
/// goes rather than where billy is pointed. The terminal's header is
/// built from the same `Endpoint.modelOf`, so a page and a terminal agree.
pub fn sessionModel(config: *const Config, catalog: *const models.Catalog, session: *const Session) Endpoint.Model {
    return Endpoint.modelOf(session.modelChoice(config.stored.model), catalog);
}

/// How a run's tools are built: how their blocks are laid out, the limits they
/// run under, and the backends its web tools ask.
///
/// The run adds its own plumbing -- its I/O, the directory it works in, its
/// allocator and its HTTP client -- when it builds the set, so neither frontend
/// handles those and neither can offer a tool the others do not.
pub fn toolSettings(config: *const Config, backends: Backends, health: ?*Health) Tools.Settings {
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

/// What resolving one tool's backends came to: nothing configured, the settings,
/// or the provider that could not be built and why. The failure carries the
/// provider, so the caller can report it by name without an out-parameter.
fn Resolution(comptime T: type) type {
    return union(enum) {
        none,
        config: T,
        failed: Failure,
    };
}

const Failure = struct {
    provider: Tools.web.Provider,
    err: anyerror,
};

/// The web search settings for a configuration that names a backend, or `.none`
/// when it names none. A backend named without its key is a failure rather than
/// a silent "no search": the configuration asked for the tool, and leaving it
/// out without a word would look like a bug.
///
/// The failure carries the provider it was on, since only this function knows
/// which one it was; the caller reports it by that name.
fn searchConfig(
    arena: std.mem.Allocator,
    credentials: *const Credentials,
    config: *const Config,
) !Resolution(Tools.web.Search.Config) {
    const web_config = config.stored.tools.web_search;
    if (web_config.providers.len == 0) return .none;

    // Each backend resolves its own key, or, for the one that is self-hosted,
    // needs the instance named instead.
    const backends = try arena.alloc(Tools.web.Search.Backend, web_config.providers.len);
    for (web_config.providers, backends) |provider, *backend| {
        const service = provider.service();
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |name|
                credentials.get(name) orelse return .{ .failed = .{
                    .provider = provider,
                    .err = error.MissingApiKey,
                } }
            else blk: {
                // A backend billy knows the address of needs only its key; one it
                // does not, SearXNG, needs the instance named.
                const url = web_config.searxng.url orelse return .{ .failed = .{
                    .provider = provider,
                    .err = error.MissingSearchUrl,
                } };
                if (url.len == 0) return .{ .failed = .{
                    .provider = provider,
                    .err = error.MissingSearchUrl,
                } };
                break :blk "";
            },
            // Only a self-hosted backend is reached somewhere billy does not know.
            .endpoint = if (service == null) web_config.searxng.url else null,
        };
    }
    return .{ .config = .{ .backends = backends, .max_results = web_config.max_results } };
}

/// The web fetch settings for a configuration that names a backend, or `.none`
/// when it names none. `raw` needs no key, so a configuration that holds only it
/// fetches without a service.
fn fetchConfig(
    arena: std.mem.Allocator,
    credentials: *const Credentials,
    config: *const Config,
) !Resolution(Tools.web.Fetch.Config) {
    const web_config = config.stored.tools.web_fetch;
    if (web_config.providers.len == 0) return .none;

    const backends = try arena.alloc(Tools.web.Fetch.Backend, web_config.providers.len);
    for (web_config.providers, backends) |provider, *backend| {
        const service = provider.service();
        backend.* = .{
            .provider = provider,
            .api_key = if (service) |name|
                credentials.get(name) orelse return .{ .failed = .{
                    .provider = provider,
                    .err = error.MissingApiKey,
                } }
            else
                "",
        };
    }
    return .{ .config = .{ .backends = backends } };
}

/// Tells the user what to fix about the search backend that could not be built:
/// the login that stores its key, the variable the same key can come from, or the
/// instance a self-hosted backend needs named.
///
/// A failure here is one the configuration asked for -- it named the backend --
/// so leaving the tool out quietly would look like a bug rather than a choice.
fn reportSearchFailure(err: anyerror, provider: Tools.web.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            // A backend reached with a key is one of the services, since the one
            // billy hosts itself is reached without one.
            const service = provider.service().?;
            std.log.err(
                "run `billy login {s}` to use {s}, or clear tools.web_search in the configuration",
                .{ service, @tagName(provider) },
            );
        },
        error.MissingSearchUrl => std.log.err(
            "set tools.web_search.{s}.url to your {s} instance, or clear tools.web_search in the configuration",
            .{ @tagName(provider), @tagName(provider) },
        ),
        // Nothing this function knows about: it is the last word on the
        // failure, so it says what it has rather than nothing at all.
        else => |other| std.log.err(
            "cannot use the {s} search backend: {s}",
            .{ @tagName(provider), @errorName(other) },
        ),
    }
}

/// Tells the user what to fix about the fetch backend that could not be built,
/// on the same terms as `reportSearchFailure`.
fn reportFetchFailure(err: anyerror, provider: Tools.web.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            const service = provider.service().?;
            std.log.err(
                "run `billy login {s}` to use {s}, or clear tools.web_fetch in the configuration",
                .{ service, @tagName(provider) },
            );
        },
        // As in `reportSearchFailure`: this is the last word on it.
        else => |other| std.log.err(
            "cannot use the {s} fetch backend: {s}",
            .{ @tagName(provider), @errorName(other) },
        ),
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
    const credentials: Credentials = .{};

    // Nothing named is no search at all.
    var off = Config.init(gpa);
    defer off.deinit();
    try std.testing.expect((try searchConfig(arena, &credentials, &off)) == .none);

    // A backend billy knows is asked for a key, and one that is not set is an
    // error rather than a silent "no search".
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_search.providers = &.{.tavily};
    // The backend at fault is the one the failure carries, for the report to
    // name.
    const missing_key = try searchConfig(arena, &credentials, &naming);
    try std.testing.expect(missing_key == .failed);
    try std.testing.expectEqual(error.MissingApiKey, missing_key.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.tavily, missing_key.failed.provider);

    // SearXNG needs no key, but needs the instance named.
    var searx = Config.init(gpa);
    defer searx.deinit();

    searx.stored.tools.web_search.providers = &.{.searxng};
    const missing_url = try searchConfig(arena, &credentials, &searx);
    try std.testing.expect(missing_url == .failed);
    try std.testing.expectEqual(error.MissingSearchUrl, missing_url.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.searxng, missing_url.failed.provider);

    // Every named backend becomes a backend to try, in the order named.
    searx.stored.tools.web_search.searxng.url = "https://searx.example.org";
    const config = (try searchConfig(arena, &credentials, &searx)).config;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(Tools.web.Provider.searxng, config.backends[0].provider);
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
    const credentials: Credentials = .{};

    // The default holds only `raw`, which asks no service, so it resolves with
    // no key stored at all.
    var raw = Config.init(gpa);
    defer raw.deinit();

    const config = (try fetchConfig(arena, &credentials, &raw)).config;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(Tools.web.Provider.raw, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);

    // A service needs its key, on the same terms as a search backend.
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_fetch.providers = &.{.tavily};
    const missing_key = try fetchConfig(arena, &credentials, &naming);
    try std.testing.expect(missing_key == .failed);
    try std.testing.expectEqual(error.MissingApiKey, missing_key.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.tavily, missing_key.failed.provider);

    // A set with nothing in it leaves `web_fetch` out of the request.
    var none = Config.init(gpa);
    defer none.deinit();

    none.stored.tools.web_fetch.providers = &.{};
    try std.testing.expect((try fetchConfig(arena, &credentials, &none)) == .none);
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
    try session.setModel("opencode-go/kimi-k2.7-code");

    // The choice is the session's own, provider and all, and the window is that
    // model's.
    const recorded = sessionModel(&opened.config, &models.test_catalog, &session);
    try std.testing.expectEqualStrings("opencode-go/kimi-k2.7-code", recorded.choice);
    try std.testing.expectEqual(@as(usize, 262_144), recorded.info.?.context_window);

    // A session that recorded none is sent where the configuration points, so
    // that is what its header names.
    var older = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer older.deinit();
    const configured = sessionModel(&opened.config, &models.test_catalog, &older);
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
        .data = "{\"model\":\"opencode-go/glm-5.3-flash\"}",
    });
    var opened = try Config.open(std.testing.io, tmp.dir, gpa);
    defer opened.config.deinit();
    // The key a request is sent with is the one stored under the provider's
    // name, so the credentials have to hold it for the target to resolve at all.
    var credentials: Credentials = .{};
    try credentials.put(arena, "opencode-go", "k");

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    // The choice a session that recorded none is given is the configured one, so
    // that is what it is sent to.
    const choice = session.modelChoice(opened.config.stored.model);
    try std.testing.expectEqualStrings("opencode-go/glm-5.3-flash", choice);
    const target = try Endpoint.targetFor(&opened.config, &credentials, &models.test_catalog, arena, choice);
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
