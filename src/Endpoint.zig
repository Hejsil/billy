//! Where a request is sent, and how it is asked: the provider and model a choice
//! names, resolved into the URL of its completions endpoint, the key stored for
//! it, what is known about its window, and what that provider takes of the
//! model's thinking.
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
const llm = @import("llm.zig");
const models = @import("models.zig");

/// Where a request is sent, and how it is asked: everything a request needs of
/// the provider and model, which the conversation does not carry.
pub const Target = struct {
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    api_key: []const u8,
    /// The model id to send, which is the half of the choice after the provider.
    model: []const u8,
    /// The provider the endpoint belongs to, or null for one billy does not
    /// know, such as a proxy. It is what the model's window is looked up by.
    provider: ?models.Provider,
    /// What the request asks of the model's thinking, settled against the
    /// provider's own rules: only a provider that takes the fields is asked for
    /// them, since one that does not may refuse a request carrying them.
    reasoning: llm.Reasoning = .provider_default,
};

/// Where the configuration points: the target of the choice the file names.
pub fn configured(config: *const Config, store: *const Credentials, arena: std.mem.Allocator) !Target {
    return targetFor(config, store, arena, config.stored.model);
}

/// Where `choice`, a provider and model as `<provider>/<model>`, is sent.
///
/// The strings the target names are allocated from `arena`, which the caller
/// owns: a choice is usually a slice of a session's string pool, and a pointer
/// into that pool survives no write to it, so nothing here may keep one.
pub fn targetFor(
    config: *const Config,
    store: *const Credentials,
    arena: std.mem.Allocator,
    choice: []const u8,
) !Target {
    const halves = models.Choice{ .text = choice };
    const name = halves.provider();
    // A session's own provider decides where it goes, resolved through the same
    // table the configured one was: a provider the configuration defines, or one
    // of billy's the file did not override.
    const base_url = try resolveBaseUrl(config.stored.providers, choice);
    const provider = models.Provider.fromName(name);

    return .{
        .url = try completionsUrl(arena, base_url),
        .api_key = store.get(name) orelse return missingKey(name),
        // The model is copied out rather than sliced from `choice`: the choice a
        // session passes is a slice of its own string pool, and a pointer into
        // that pool survives no write to it, so the next intern would leave the
        // target naming freed bytes. The URL is allocated here for the same
        // reason.
        .model = try arena.dupe(u8, halves.model()),
        // Which provider answers, which is what the model's window is looked up
        // by. Null for a proxy, which leaves the model to be found among the
        // providers billy ships.
        .provider = provider,
        // What the request asks of the thinking follows the provider it is sent
        // to: a session moved to another provider is asked the way that one takes.
        .reasoning = reasoningFor(config, provider),
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
/// is known about the window of the model half of it.
pub fn modelOf(choice: []const u8) Model {
    const halves = models.Choice{ .text = choice };
    return .{
        .choice = choice,
        .info = models.lookup(models.Provider.fromName(halves.provider()), halves.model()),
    };
}

/// The full URL of the completions endpoint under `base_url`.
fn completionsUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
}

/// Where the choice is sent: the base URL the configuration gives the provider,
/// which may be one of its own or one of billy's the file overrides. Null when
/// the configuration names neither, which the caller reports.
fn baseUrlOf(providers: Config.Providers, choice: []const u8) ?[]const u8 {
    const name = (models.Choice{ .text = choice }).provider();
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

/// What a request sent to `provider` asks of the model's thinking: the
/// configuration's say, for a provider that takes the fields. One that does not
/// is left on whatever it does by itself, since a request carrying fields an
/// endpoint does not expect may be refused.
fn reasoningFor(config: *const Config, provider: ?models.Provider) llm.Reasoning {
    const known = provider orelse return .provider_default;
    if (!known.takesThinking()) return .provider_default;
    return reasoningOf(config.stored.reasoning);
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

test "a target names its provider's address and only the thinking it takes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The configuration asks for a high effort, which only a provider that takes
    // the thinking fields can be asked for.
    var config = Config.init(gpa);
    defer config.deinit();
    config.stored.reasoning = "high";
    var store: Credentials = .{};
    try store.put(arena, "deepseek", "k");
    try store.put(arena, "opencode_go", "k");

    // Sent to a provider that takes them, the effort the file names is asked for.
    const taking = try targetFor(&config, &store, arena, "deepseek/deepseek-flash");
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", taking.url);
    try std.testing.expectEqualStrings("k", taking.api_key);
    try std.testing.expectEqualStrings("deepseek-flash", taking.model);
    try std.testing.expectEqual(models.Provider.deepseek, taking.provider.?);
    try std.testing.expectEqualStrings("high", taking.reasoning.effort);

    // Sent to one that does not, the request asks nothing of them: what is asked
    // follows the provider the request goes to, not the one it started on.
    const plain = try targetFor(&config, &store, arena, "opencode_go/kimi-k2.7-code");
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", plain.url);
    try std.testing.expectEqual(@as(?models.Provider, .opencode_go), plain.provider);
    try std.testing.expectEqual(llm.Reasoning.provider_default, plain.reasoning);
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
    var store: Credentials = .{};
    try store.put(arena, "mine", "k");

    const target = try targetFor(&config, &store, arena, "mine/qwen3-coder:30b");
    try std.testing.expectEqualStrings("http://localhost:8080/v1/chat/completions", target.url);
    try std.testing.expectEqualStrings("qwen3-coder:30b", target.model);
    // A provider billy knows nothing of is left to be found by its model's name.
    try std.testing.expect(target.provider == null);
    try std.testing.expectEqual(llm.Reasoning.provider_default, target.reasoning);
}

test "a model as a header shows it carries the choice and the window of its model" {
    // A known model of a known provider has the window billy ships for it.
    const known = modelOf("opencode_go/kimi-k2.7-code");
    try std.testing.expectEqualStrings("opencode_go/kimi-k2.7-code", known.choice);
    try std.testing.expectEqual(@as(usize, 262_144), known.info.?.context_window);

    // A bare model id is looked for among every provider billy ships, since the
    // name of a provider is not always known: that is what a proxy names.
    const bare = modelOf("deepseek-flash");
    try std.testing.expectEqualStrings("deepseek-flash", bare.choice);
    try std.testing.expectEqual(models.Provider.deepseek, bare.info.?.provider);

    // A model billy has no numbers for has no window, so a header shows no gauge.
    try std.testing.expect(modelOf("test/m").info == null);
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

test "the configured choice is the target the configuration points at" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = Config.init(gpa);
    defer config.deinit();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", config.stored.model);

    var store: Credentials = .{};
    try store.put(arena, "deepseek", "k");
    const target = try configured(&config, &store, arena);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", target.url);
    try std.testing.expectEqualStrings("deepseek-flash", target.model);
    try std.testing.expectEqual(@as(?models.Provider, .deepseek), target.provider);
}
