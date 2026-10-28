//! Where a request is sent: the provider and model a choice names, resolved into the URL of its
//! completions endpoint, the key stored for it, and what is known about its window.

const std = @import("std");

const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const models = @import("models.zig");

pub const Target = struct {
    url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub fn configured(
    config: *const Config,
    credentials: *const Credentials,
    catalog: *const models.Catalog,
    arena: std.mem.Allocator,
) !Target {
    return try targetFor(config, credentials, catalog, arena, config.stored.model);
}

pub fn targetFor(
    config: *const Config,
    credentials: *const Credentials,
    catalog: *const models.Catalog,
    arena: std.mem.Allocator,
    choice: []const u8,
) !Target {
    const halves = models.Choice{ .text = choice };
    const provider = halves.provider();
    const base_url = baseUrlOf(config.stored.providers, catalog, choice) orelse
        return error.UnknownProvider;

    return .{
        .url = try completionsUrl(arena, base_url),
        .api_key = credentials.get(provider) orelse return error.MissingApiKey,
        // The model is copied out rather than sliced from `choice`: the choice a session passes is
        // a slice of its own string pool, and a pointer into that pool survives no write to it, so
        // the next intern would leave the target naming freed bytes.
        .model = try arena.dupe(u8, halves.model()),
    };
}

pub const Model = struct {
    choice: []const u8,
    info: ?models.Metadata,
};

pub fn modelOf(choice: []const u8, catalog: *const models.Catalog) Model {
    const halves = models.Choice{ .text = choice };
    return .{
        .choice = choice,
        .info = catalog.metadata(halves.provider(), halves.model()),
    };
}

fn completionsUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return try arena.print("{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
}

fn baseUrlOf(providers: Config.Providers, catalog: *const models.Catalog, choice: []const u8) ?[]const u8 {
    const name = (models.Choice{ .text = choice }).provider();
    if (providers.get(name)) |base_url| return base_url;
    const provider = catalog.find(name) orelse return null;
    return provider.base_url;
}

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

    const kimi = try targetFor(&config, &credentials, &models.test_catalog, arena, "opencode-go/kimi-k2.7-code");
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", kimi.url);
    try std.testing.expectEqualStrings("kimi-k2.7-code", kimi.model);
}

test "a target is resolved through a provider the configuration defines itself" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    const known = modelOf("opencode-go/kimi-k2.7-code", &models.test_catalog);
    try std.testing.expectEqualStrings("opencode-go/kimi-k2.7-code", known.choice);
    try std.testing.expectEqual(@as(usize, 262_144), known.info.?.context_window);

    const bare = modelOf("kimi-k2.7-code", &models.test_catalog);
    try std.testing.expectEqualStrings("kimi-k2.7-code", bare.choice);
    try std.testing.expectEqual(@as(usize, 262_144), bare.info.?.context_window);

    try std.testing.expect(modelOf("test/m", &models.test_catalog).info == null);
}

test "the endpoint comes from the provider the choice names" {
    const none: Config.Providers = .{};

    try std.testing.expectEqualStrings(
        "https://api.deepseek.com",
        baseUrlOf(none, &models.test_catalog, "deepseek/deepseek-flash").?,
    );
    try std.testing.expectEqualStrings(
        "https://opencode.ai/zen/go/v1",
        baseUrlOf(none, &models.test_catalog, "opencode-go/glm-5.3-flash").?,
    );

    const defined: Config.Providers = .{ .entries = &.{
        .{ .name = "mock", .base_url = "http://127.0.0.1:8901/v1" },
    } };
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", baseUrlOf(defined, &models.test_catalog, "mock/m").?);

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
    // A typo would otherwise send the conversation to whichever endpoint billy fell back on, which
    // is worse than failing: the request would go somewhere the user did not name.
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "who-knows/m") == null);
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "m") == null);
    try std.testing.expect(baseUrlOf(none, &models.test_catalog, "/m") == null);

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

    try std.testing.expectEqualStrings(
        "the model deepseek/deepseek-flash cannot be reached: no key is stored for 'deepseek'" ++
            " — run `billy login deepseek` to store one",
        unreachableModel(&buffer, error.MissingApiKey, "deepseek/deepseek-flash"),
    );

    try std.testing.expectEqualStrings(
        "the model who-knows/m cannot be reached: name its address under `providers`" ++
            " in the configuration, or run `billy models --refresh`",
        unreachableModel(&buffer, error.UnknownProvider, "who-knows/m"),
    );

    // A buffer too small for the sentence loses it rather than the message: what is shown still
    // says the model cannot be reached.
    var small: [8]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, unreachableModel(&small, error.MissingApiKey, "a/b"), "the model cannot be reached"));
}
