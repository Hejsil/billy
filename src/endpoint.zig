//! Where a request is sent: the provider and model a choice names, resolved into
//! the URL of its completions endpoint, the key stored for it, and what is known
//! about its window.
//!
//! Everything here follows from the configuration and the credentials alone, so
//! the agent can resolve a target itself, from the two it is given, at the moment
//! it needs one -- just before a turn -- and a session that was moved to another
//! model is sent where that model lives without the frontend being asked.
//!
//! Nothing is held here: every function takes what it needs and returns a value.

const std = @import("std");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const models = @import("models.zig");

/// Where a request is sent, and how it is asked: everything a request needs of
/// the provider and model, which the conversation does not carry.
pub const Target = struct {
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    api_key: []const u8,
    /// The model id to send, which is the half of the choice after the provider.
    model: []const u8,
};

/// Where the configuration points: the target of the choice the file names.
pub fn configured(
    config: *const Config,
    credentials: *const Credentials,
    catalog: *const models.Catalog,
    arena: std.mem.Allocator,
) !Target {
    return targetFor(config, credentials, catalog, arena, config.stored.model);
}

/// Where `choice`, a provider and model as `<provider>/<model>`, is sent.
///
/// Fails with `error.MissingApiKey` when no key is stored for the provider, and
/// with `error.UnknownProvider` when neither the configuration nor the catalog
/// names its address. Both are the user's to fix and neither is logged here:
/// `unreachableModel` writes the sentence they are shown, and where it is shown
/// is the frontend's business -- a notice a terminal can go on from, or the
/// failure of a run that cannot start.
///
/// The strings the target names are allocated from `arena`, which the caller
/// owns: a choice is usually a slice of a session's string pool, and a pointer
/// into that pool survives no write to it, so nothing here may keep one.
pub fn targetFor(
    config: *const Config,
    credentials: *const Credentials,
    catalog: *const models.Catalog,
    arena: std.mem.Allocator,
    choice: []const u8,
) !Target {
    const halves = models.Choice{ .text = choice };
    const provider = halves.provider();
    // A session's own provider decides where it goes: a base URL the
    // configuration names, or the catalog's own when it knows the provider.
    const base_url = baseUrlOf(config.stored.providers, catalog, choice) orelse
        return error.UnknownProvider;

    return .{
        .url = try completionsUrl(arena, base_url),
        // The key is stored under the provider the choice names, which is the
        // catalog's own spelling of it.
        .api_key = credentials.get(provider) orelse return error.MissingApiKey,
        // The model is copied out rather than sliced from `choice`: the choice a
        // session passes is a slice of its own string pool, and a pointer into
        // that pool survives no write to it, so the next intern would leave the
        // target naming freed bytes. The URL is allocated here for the same
        // reason.
        .model = try arena.dupe(u8, halves.model()),
    };
}

/// One model as a header shows it: the provider and model a request names, and
/// what is known about its window.
pub const Model = struct {
    /// The provider and model, as `<provider>/<model>`, which is the whole choice
    /// a session records and what both headers show.
    choice: []const u8,
    /// What is known about it: its window, for the gauge. Null for a model billy
    /// has no numbers for.
    info: ?models.Metadata,
};

/// The model `choice` names, as a header shows it: the choice itself, and what
/// the catalog knows about the window of the model half of it.
pub fn modelOf(choice: []const u8, catalog: *const models.Catalog) Model {
    const halves = models.Choice{ .text = choice };
    return .{
        .choice = choice,
        .info = catalog.metadata(halves.provider(), halves.model()),
    };
}

/// The full URL of the completions endpoint under `base_url`.
fn completionsUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return arena.print("{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
}

/// Where the choice is sent: the base URL the configuration gives the provider,
/// which may be one of its own or one the catalog knows. Null when neither
/// names it, which leaves the choice pointing nowhere.
fn baseUrlOf(providers: Config.Providers, catalog: *const models.Catalog, choice: []const u8) ?[]const u8 {
    const name = (models.Choice{ .text = choice }).provider();
    if (providers.get(name)) |base_url| return base_url;
    const provider = catalog.find(name) orelse return null;
    return provider.base_url;
}

/// What is wrong with the model `choice` names, in one sentence, and what the
/// user can do about it: written into `buffer`, which the caller owns, so
/// nothing here allocates or keeps it.
///
/// The sentence is returned rather than logged because where it belongs depends
/// on why a target was resolved: a turn that cannot begin shows it as a notice
/// the next line can answer, and a run that cannot start at all reports it as
/// its failure. `err` is what `targetFor` failed with.
pub fn unreachableModel(buffer: []u8, err: anyerror, choice: []const u8) []const u8 {
    const provider = (models.Choice{ .text = choice }).provider();
    return switch (err) {
        error.MissingApiKey => std.mem.print(
            buffer,
            "the model {s} cannot be reached: no key is stored for '{s}' — run `billy login {s}` to store one",
            .{ choice, provider, provider },
        ) catch "the model cannot be reached: no key is stored for the provider it names",
        else => std.mem.print(
            buffer,
            "the model {s} cannot be reached: name its address under `providers` in the configuration," ++
                " or run `billy models --refresh`",
            .{choice},
        ) catch "the model cannot be reached: no address is known for the provider it names",
    };
}

test "a target carries the address, the key and the model of the choice it names" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = Config.init(gpa);
    defer config.deinit();
    var credentials: Credentials = .{};
    try credentials.put(arena, "deepseek", "k");
    try credentials.put(arena, "opencode-go", "k");

    const flash = try targetFor(&config, &credentials, &models.test_catalog, arena, "deepseek/deepseek-flash");
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", flash.url);
    try std.testing.expectEqualStrings("k", flash.api_key);
    try std.testing.expectEqualStrings("deepseek-flash", flash.model);

    // Another provider is another address, and the key stored for that one.
    const kimi = try targetFor(&config, &credentials, &models.test_catalog, arena, "opencode-go/kimi-k2.7-code");
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", kimi.url);
    try std.testing.expectEqualStrings("kimi-k2.7-code", kimi.model);
}

test "a target is resolved through a provider the configuration defines itself" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A proxy of the user's own: a name billy does not know, at an address the
    // file gives, which is what a run against a local server names.
    var config = Config.init(gpa);
    defer config.deinit();
    config.stored.providers = .{ .entries = &.{
        .{ .name = "mine", .base_url = "http://localhost:8080/v1" },
    } };
    var credentials: Credentials = .{};
    try credentials.put(arena, "mine", "k");

    const target = try targetFor(&config, &credentials, &models.test_catalog, arena, "mine/qwen3-coder:30b");
    try std.testing.expectEqualStrings("http://localhost:8080/v1/chat/completions", target.url);
    try std.testing.expectEqualStrings("qwen3-coder:30b", target.model);
}

test "a model as a header shows it carries the choice and the window of its model" {
    // A known model of a known provider has the window the catalog gives it.
    const known = modelOf("opencode-go/kimi-k2.7-code", &models.test_catalog);
    try std.testing.expectEqualStrings("opencode-go/kimi-k2.7-code", known.choice);
    try std.testing.expectEqual(@as(usize, 262_144), known.info.?.context_window);

    // A bare model id is looked for among every provider the catalog holds, since
    // the name of a provider is not always known: that is what a proxy names. The
    // model is one only a single provider lists, so finding its window at all is
    // finding it there.
    const bare = modelOf("kimi-k2.7-code", &models.test_catalog);
    try std.testing.expectEqualStrings("kimi-k2.7-code", bare.choice);
    try std.testing.expectEqual(@as(usize, 262_144), bare.info.?.context_window);

    // A model billy has no numbers for has no window, so a header shows no gauge.
    try std.testing.expect(modelOf("test/m", &models.test_catalog).info == null);
}

test "the endpoint comes from the provider the choice names" {
    const none: Config.Providers = .{};

    // A provider the catalog holds decides its own endpoint, so a configured
    // `opencode-go/glm-5.3-flash` reaches Go with no URL written anywhere.
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com",
        baseUrlOf(none, &models.test_catalog, "deepseek/deepseek-flash").?,
    );
    try std.testing.expectEqualStrings(
        "https://opencode.ai/zen/go/v1",
        baseUrlOf(none, &models.test_catalog, "opencode-go/glm-5.3-flash").?,
    );

    // One the configuration defines does the same, which is how a proxy, a
    // server of the user's own, or a stand-in a test points a run at is reached.
    const defined: Config.Providers = .{ .entries = &.{
        .{ .name = "mock", .base_url = "http://127.0.0.1:8901/v1" },
    } };
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", baseUrlOf(defined, &models.test_catalog, "mock/m").?);

    // A name the configuration gives to one of billy's own overrides what billy
    // would have used, so a proxy in front of a known provider is reachable.
    const overriding: Config.Providers = .{ .entries = &.{
        .{ .name = "deepseek", .base_url = "http://127.0.0.1:9/v1" },
    } };
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9/v1",
        baseUrlOf(overriding, &models.test_catalog, "deepseek/deepseek-flash").?,
    );
}

test "a provider the configuration does not name is refused, not defaulted" {
    const none: Config.Providers = .{};
    // A typo would otherwise send the conversation to whichever endpoint billy
    // fell back on, which is worse than failing: the request would go somewhere
    // the user did not name.
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "who-knows/m") == null);
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "m") == null);
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "/m") == null);

    // Once the configuration defines the name, the same choice resolves, which
    // is what makes a proxy or a server of the user's own reachable.
    const defined: Config.Providers = .{ .entries = &.{
        .{ .name = "who-knows", .base_url = "http://127.0.0.1:8901/v1" },
    } };
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", baseUrlOf(defined, &models.test_catalog, "who-knows/m").?);
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

test "the configured choice is the target the configuration points at" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = Config.init(gpa);
    defer config.deinit();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", config.stored.model);

    var credentials: Credentials = .{};
    try credentials.put(arena, "deepseek", "k");
    const target = try configured(&config, &credentials, &models.test_catalog, arena);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", target.url);
    try std.testing.expectEqualStrings("deepseek-flash", target.model);
}

test "what is wrong with a model is said with what to do about it" {
    var buffer: [256]u8 = undefined;

    // No key stored: the login that stores one is the thing to name, and the
    // provider is named as the credential file names it.
    try std.testing.expectEqualStrings(
        "the model deepseek/deepseek-flash cannot be reached: no key is stored for 'deepseek'" ++
            " — run `billy login deepseek` to store one",
        unreachableModel(&buffer, error.MissingApiKey, "deepseek/deepseek-flash"),
    );

    // Neither the configuration nor the catalog names its address, so the two
    // places an address can come from are what it says.
    try std.testing.expectEqualStrings(
        "the model who-knows/m cannot be reached: name its address under `providers`" ++
            " in the configuration, or run `billy models --refresh`",
        unreachableModel(&buffer, error.UnknownProvider, "who-knows/m"),
    );

    // A buffer too small for the sentence loses it rather than the message:
    // what is shown still says the model cannot be reached.
    var small: [8]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, unreachableModel(&small, error.MissingApiKey, "a/b"), "the model cannot be reached"));
}
