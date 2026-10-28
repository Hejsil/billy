//! The model catalog: the providers billy can talk to, the models each offers, and the context
//! window of each.

const std = @import("std");

const http = @import("http.zig");

pub const cache_file = "models.json";
/// Where the catalog is fetched from: one document holding every provider and model models.dev
/// knows.
pub const source_url = "https://models.dev/api.json";
pub const format_version: u32 = 1;

pub const Catalog = struct {
    providers: []const Provider = &.{},

    /// The provider called `name`, which is the spelling models.dev lists it under: the
    /// configuration names a provider the way the catalog does.
    pub fn find(catalog: *const Catalog, name: []const u8) ?*const Provider {
        for (catalog.providers) |*provider| {
            if (std.mem.eql(u8, provider.name, name)) return provider;
        }
        return null;
    }

    /// What is known about `model` at `provider`, or among all providers when the provider is
    /// unknown or not named.
    pub fn metadata(catalog: *const Catalog, provider: ?[]const u8, model: []const u8) ?Metadata {
        if (provider) |name| {
            if (catalog.find(name)) |known| {
                const entry = known.model(model) orelse return null;
                return .{ .context_window = entry.context };
            }
        }
        for (catalog.providers) |*known| {
            const entry = known.model(model) orelse continue;
            return .{ .context_window = entry.context };
        }
        return null;
    }

    pub fn modelCount(catalog: *const Catalog) usize {
        var count: usize = 0;
        for (catalog.providers) |provider| count += provider.models.len;
        return count;
    }
};

pub const Provider = struct {
    name: []const u8,
    base_url: ?[]const u8 = null,
    models: []const Model = &.{},

    fn model(provider: *const Provider, id: []const u8) ?*const Model {
        for (provider.models) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

pub const Model = struct {
    id: []const u8,
    context: usize,
};

/// What is known about a model: the window its provider gives it, which is what the gauge shows and
/// what compaction is measured against.
pub const Metadata = struct {
    context_window: usize,
};

const Cache = struct {
    version: u32 = format_version,
    providers: []const Provider = &.{},
};

const Source = std.json.ArrayHashMap(SourceProvider);

const SourceProvider = struct {
    npm: ?[]const u8 = null,
    api: ?[]const u8 = null,
    models: std.json.ArrayHashMap(SourceModel) = .{},
};

const SourceModel = struct {
    id: ?[]const u8 = null,
    limit: SourceLimit = .{},
};

const SourceLimit = struct {
    context: ?usize = null,
};

pub fn load(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) !Catalog {
    const text = try dir.readFileAlloc(io, cache_file, arena, .unlimited);
    const cache = std.json.parseFromSliceLeaky(Cache, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;
    if (cache.version != format_version) return error.UnsupportedCatalogVersion;
    if (cache.providers.len == 0) return error.CorruptCatalog;
    return .{ .providers = cache.providers };
}

/// Reads the cached catalog, fetching one first when there is none or the one there cannot be used.
pub fn ensure(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, dir: std.Io.Dir) Catalog {
    return load(io, arena, dir) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("fetching the model catalog", .{});
            return fetchThenLoad(io, arena, gpa, dir);
        },
        // A file that is half written, from another version or edited by hand is fetched again
        // rather than left to blind the run until the user runs the refresh command.
        error.CorruptCatalog, error.UnsupportedCatalogVersion => {
            std.log.warn("the model catalog cannot be used ({s}); fetching it again", .{@errorName(err)});
            return fetchThenLoad(io, arena, gpa, dir);
        },
        // Nothing about a directory billy cannot read is made better by fetching.
        else => {
            std.log.warn("could not read the model catalog: {s}", .{@errorName(err)});
            return .{};
        },
    };
}

fn fetchThenLoad(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, dir: std.Io.Dir) Catalog {
    _ = refresh(io, gpa, dir) catch |err| {
        std.log.warn("could not fetch the model catalog: {s}", .{@errorName(err)});
        return .{};
    };
    return load(io, arena, dir) catch |err| {
        std.log.warn("could not read the model catalog: {s}", .{@errorName(err)});
        return .{};
    };
}

pub const Counts = struct { providers: usize, models: usize };

pub fn refresh(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !Counts {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(source_url), .{
        .headers = .{ .user_agent = .{ .override = http.user_agent } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.CatalogFetchFailed;
    const body = try http.readBody(gpa, &response);
    defer gpa.free(body);

    return writeFrom(io, gpa, dir, body);
}

fn writeFrom(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, body: []const u8) !Counts {
    var build_state = std.heap.ArenaAllocator.init(gpa);
    defer build_state.deinit();
    const build = build_state.allocator();

    const source = std.json.parseFromSliceLeaky(Source, build, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;

    var providers: std.ArrayList(Provider) = .empty;
    defer providers.deinit(build);
    var model_count: usize = 0;

    for (source.map.keys(), source.map.values()) |name, provider| {
        if (name.len == 0) continue;
        if (!openAiCompatible(provider.npm orelse continue)) continue;

        var models: std.ArrayList(Model) = .empty;
        for (provider.models.map.keys(), provider.models.map.values()) |key, model| {
            const id = model.id orelse key;
            const context = model.limit.context orelse continue;
            if (id.len == 0 or context == 0) continue;
            try models.append(build, .{ .id = id, .context = context });
        }
        if (models.items.len == 0) continue;
        model_count += models.items.len;

        try providers.append(build, .{
            .name = name,
            .base_url = provider.api,
            .models = models.items,
        });
    }
    if (providers.items.len == 0) return error.EmptyCatalog;

    var atomic = try dir.createFileAtomic(io, cache_file, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buffer);
    try std.json.Stringify.value(Cache{ .providers = providers.items }, .{}, &file.interface);
    try file.flush();
    try atomic.replace(io);

    return .{ .providers = providers.items.len, .models = model_count };
}

fn openAiCompatible(npm: []const u8) bool {
    return std.mem.eql(u8, npm, "@ai-sdk/openai-compatible") or
        std.mem.eql(u8, npm, "@ai-sdk/openai") or
        std.mem.eql(u8, npm, "@ai-sdk/xai");
}

pub const Choice = struct {
    text: []const u8,

    pub fn provider(choice: Choice) []const u8 {
        const slash = std.mem.findScalar(u8, choice.text, '/') orelse return "";
        return choice.text[0..slash];
    }

    pub fn model(choice: Choice) []const u8 {
        const slash = std.mem.findScalar(u8, choice.text, '/') orelse return choice.text;
        return choice.text[slash + 1 ..];
    }

    pub fn isComplete(choice: Choice) bool {
        return choice.provider().len > 0 and choice.model().len > 0;
    }
};

pub const test_catalog = Catalog{ .providers = &.{
    .{ .name = "deepseek", .base_url = "https://api.deepseek.com", .models = &.{
        .{ .id = "deepseek-flash", .context = 1_000_000 },
        .{ .id = "deepseek-v4-pro", .context = 1_000_000 },
        .{ .id = "deepseek-v4-flash", .context = 1_000_000 },
    } },
    .{ .name = "opencode-go", .base_url = "https://opencode.ai/zen/go/v1", .models = &.{
        .{ .id = "kimi-k2.7-code", .context = 262_144 },
        .{ .id = "deepseek-flash", .context = 1_000_000 },
    } },
    .{ .name = "xai", .base_url = "https://api.x.ai/v1", .models = &.{
        .{ .id = "grok-4", .context = 131_072 },
    } },
} };

test "a choice names its provider before the slash and its model after it" {
    const flash = Choice{ .text = "deepseek/deepseek-flash" };
    try std.testing.expectEqualStrings("deepseek", flash.provider());
    try std.testing.expectEqualStrings("deepseek-flash", flash.model());
    try std.testing.expect(flash.isComplete());

    const variant = Choice{ .text = "vendor/model/variant" };
    try std.testing.expectEqualStrings("vendor", variant.provider());
    try std.testing.expectEqualStrings("model/variant", variant.model());

    const bare = Choice{ .text = "qwen3-coder:30b" };
    try std.testing.expectEqualStrings("", bare.provider());
    try std.testing.expectEqualStrings("qwen3-coder:30b", bare.model());
    try std.testing.expect(!bare.isComplete());
}

test "the catalog finds a provider by the name models.dev lists it under" {
    const found = test_catalog.find("deepseek").?;
    try std.testing.expectEqualStrings("https://api.deepseek.com", found.base_url.?);

    const opencode = test_catalog.find("opencode-go").?;
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", opencode.base_url.?);

    try std.testing.expect(test_catalog.find("opencode_go") == null);
    try std.testing.expect(test_catalog.find("not-a-provider") == null);
}

test "metadata is looked up at the provider, then among all providers" {
    const flash = test_catalog.metadata("deepseek", "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, flash.context_window);

    const elsewhere = test_catalog.metadata("opencode-go", "kimi-k2.7-code").?;
    try std.testing.expectEqual(262_144, elsewhere.context_window);

    const discovered = test_catalog.metadata(null, "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, discovered.context_window);

    try std.testing.expect(test_catalog.metadata("deepseek", "kimi-k2.7-code") == null);

    try std.testing.expect(test_catalog.metadata(null, "who-knows") == null);
}

test "the cache is filtered to OpenAI-compatible providers, and reads back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{
        \\  "deepseek": {
        \\    "id": "deepseek", "name": "DeepSeek", "api": "https://api.deepseek.com",
        \\    "env": ["DEEPSEEK_API_KEY"], "npm": "@ai-sdk/openai-compatible",
        \\    "models": {
        \\      "deepseek-flash": {"id": "deepseek-flash", "tool_call": true, "reasoning": true,
        \\        "limit": {"context": 1048576, "output": 393216}},
        \\      "no-window": {"id": "no-window"}
        \\    }
        \\  },
        \\  "xai": {
        \\    "id": "xai", "name": "xAI", "api": "https://api.x.ai/v1",
        \\    "npm": "@ai-sdk/xai",
        \\    "models": {"grok": {"id": "grok", "limit": {"context": 131072}}}
        \\  },
        \\  "openai": {
        \\    "id": "openai", "name": "OpenAI", "npm": "@ai-sdk/openai",
        \\    "models": {"gpt": {"id": "gpt", "limit": {"context": 128000}}}
        \\  },
        \\  "anthropic": {
        \\    "id": "anthropic", "name": "Anthropic", "api": "https://api.anthropic.com",
        \\    "npm": "@ai-sdk/anthropic",
        \\    "models": {"claude": {"id": "claude", "limit": {"context": 200000}}}
        \\  }
        \\}
    ;

    const counts = try writeFrom(std.testing.io, gpa, tmp.dir, body);
    try std.testing.expectEqual(@as(usize, 3), counts.providers);
    try std.testing.expectEqual(@as(usize, 3), counts.models);

    const catalog = try load(std.testing.io, arena, tmp.dir);
    try std.testing.expect(catalog.find("anthropic") == null);

    const deepseek = catalog.find("deepseek").?;
    try std.testing.expectEqual(@as(usize, 1), deepseek.models.len);
    try std.testing.expectEqualStrings("deepseek-flash", deepseek.models[0].id);
    try std.testing.expectEqual(@as(usize, 1_048_576), deepseek.models[0].context);

    const xai = catalog.find("xai").?;
    try std.testing.expectEqual(@as(usize, 131_072), xai.models[0].context);

    const openai = catalog.find("openai").?;
    try std.testing.expect(openai.base_url == null);
}

test "a missing cache is a miss, and a damaged one is refused" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.FileNotFound, load(std.testing.io, arena, tmp.dir));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_file, .data = "not json" });
    try std.testing.expectError(error.CorruptCatalog, load(std.testing.io, arena, tmp.dir));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = cache_file,
        .data = "{\"version\":99,\"providers\":[{\"name\":\"x\",\"models\":[{\"id\":\"m\",\"context\":1}]}]}",
    });
    try std.testing.expectError(error.UnsupportedCatalogVersion, load(std.testing.io, arena, tmp.dir));
}
