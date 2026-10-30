//! What a run is given, resolved from the configuration and the credentials: the backends its web
//! tools ask, how its agent behaves, what its tools run with, and the model a header names.

const std = @import("std");

const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const endpoint = @import("endpoint.zig");
const Health = @import("Health.zig");
const models = @import("models.zig");
const report = @import("report.zig");
const Session = @import("Session.zig");
const Tools = @import("Tools.zig");

pub const Backends = struct {
    search: ?Tools.web.Search.Config,
    fetch: ?Tools.web.Fetch.Config,

    /// The backends the configuration names, reporting the one at fault when a backend it names
    /// cannot be built: the configuration asked for the tool, so leaving it out without a word
    /// would look like a bug.
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

pub fn sessionModel(config: *const Config, catalog: *const models.Catalog, session: *const Session) endpoint.Model {
    return endpoint.modelOf(session.modelChoice(config.stored.model), catalog);
}

pub fn toolSettings(config: *const Config, backends: Backends, health: ?*Health) Tools.Settings {
    const stored = &config.stored;
    return .{
        .bash_timeout_s = stored.tools.bash.timeout_s,
        .search = backends.search,
        .fetch = backends.fetch,
        .health = health,
    };
}

fn Resolution(T: type) type {
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

fn searchConfig(
    arena: std.mem.Allocator,
    credentials: *const Credentials,
    config: *const Config,
) !Resolution(Tools.web.Search.Config) {
    const web_config = config.stored.tools.web_search;
    if (web_config.providers.len == 0) return .none;

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
            .endpoint = if (service == null) web_config.searxng.url else null,
        };
    }
    return .{ .config = .{ .backends = backends, .max_results = web_config.max_results } };
}

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

fn reportSearchFailure(err: anyerror, provider: Tools.web.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            const service = provider.service().?;
            std.log.err(
                "run `billy login {s}` to use {t}, or clear tools.web_search in the configuration",
                .{ service, provider },
            );
        },
        error.MissingSearchUrl => std.log.err(
            "set tools.web_search.{t}.url to your {t} instance, or clear tools.web_search in the configuration",
            .{ provider, provider },
        ),
        // Nothing this function knows about: it is the last word on the failure, so it says what it
        // has rather than nothing at all.
        else => |other| std.log.err(
            "cannot use the {t} search backend: {t}",
            .{ provider, other },
        ),
    }
}

fn reportFetchFailure(err: anyerror, provider: Tools.web.Provider) void {
    switch (err) {
        error.MissingApiKey => {
            const service = provider.service().?;
            std.log.err(
                "run `billy login {s}` to use {t}, or clear tools.web_fetch in the configuration",
                .{ service, provider },
            );
        },
        else => |other| std.log.err(
            "cannot use the {t} fetch backend: {t}",
            .{ provider, other },
        ),
    }
}

test "each backend resolves its own key, and SearXNG its instance" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const credentials: Credentials = .{};

    var off = Config.init(gpa);
    defer off.deinit();
    try std.testing.expect((try searchConfig(arena, &credentials, &off)) == .none);

    // A backend billy knows is asked for a key, and one that is not set is an error rather than a
    // silent "no search".
    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_search.providers = &.{.tavily};
    const missing_key = try searchConfig(arena, &credentials, &naming);
    try std.testing.expect(missing_key == .failed);
    try std.testing.expectEqual(error.MissingApiKey, missing_key.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.tavily, missing_key.failed.provider);

    var searx = Config.init(gpa);
    defer searx.deinit();

    searx.stored.tools.web_search.providers = &.{.searxng};
    const missing_url = try searchConfig(arena, &credentials, &searx);
    try std.testing.expect(missing_url == .failed);
    try std.testing.expectEqual(error.MissingSearchUrl, missing_url.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.searxng, missing_url.failed.provider);

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

    var raw = Config.init(gpa);
    defer raw.deinit();

    const config = (try fetchConfig(arena, &credentials, &raw)).config;
    try std.testing.expectEqual(@as(usize, 1), config.backends.len);
    try std.testing.expectEqual(Tools.web.Provider.raw, config.backends[0].provider);
    try std.testing.expectEqualStrings("", config.backends[0].api_key);

    var naming = Config.init(gpa);
    defer naming.deinit();

    naming.stored.tools.web_fetch.providers = &.{.tavily};
    const missing_key = try fetchConfig(arena, &credentials, &naming);
    try std.testing.expect(missing_key == .failed);
    try std.testing.expectEqual(error.MissingApiKey, missing_key.failed.err);
    try std.testing.expectEqual(Tools.web.Provider.tavily, missing_key.failed.provider);

    var none = Config.init(gpa);
    defer none.deinit();

    none.stored.tools.web_fetch.providers = &.{};
    try std.testing.expect((try fetchConfig(arena, &credentials, &none)) == .none);
}

test "a header names the model the session goes to, not the one billy is pointed at" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = Config.file_name,
        .data = "{\"model\":\"deepseek/deepseek-flash\"}",
    });
    var config = try Config.open(std.testing.io, tmp.dir, gpa);
    defer config.deinit();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setModel("opencode-go/kimi-k2.7-code");

    const recorded = sessionModel(&config, &models.test_catalog, &session);
    try std.testing.expectEqualStrings("opencode-go/kimi-k2.7-code", recorded.choice);
    try std.testing.expectEqual(@as(usize, 262_144), recorded.info.?.context_window);

    // A session that recorded none is sent where the configuration points, so that is what its
    // header names.
    var older = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer older.deinit();
    const configured = sessionModel(&config, &models.test_catalog, &older);
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
    var config = try Config.open(std.testing.io, tmp.dir, gpa);
    defer config.deinit();
    var credentials: Credentials = .{};
    try credentials.put(arena, "opencode-go", "k");

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    const choice = session.modelChoice(config.stored.model);
    try std.testing.expectEqualStrings("opencode-go/glm-5.3-flash", choice);
    const target = try endpoint.targetFor(&config, &credentials, &models.test_catalog, arena, choice);
    // The model the session recorded is interned in its string pool, and a pointer into that pool
    // survives no write to it.
    try std.testing.expectEqualStrings("glm-5.3-flash", target.model);
    for (0..40) |i| {
        var buffer: [64]u8 = undefined;
        const filler = try std.mem.print(&buffer, "filler {d} padding padding padding padding", .{i});
        try session.append(.{ .role = .user, .content = filler });
    }
    try std.testing.expectEqualStrings("glm-5.3-flash", target.model);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", target.url);
}
