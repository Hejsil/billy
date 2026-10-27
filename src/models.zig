//! The model catalog: the providers billy can talk to, the models each offers,
//! and the context window of each. Nothing is compiled in. The catalog is
//! fetched from models.dev into the cache directory the first time a run needs
//! it, and `billy models --refresh` fetches it again.

const std = @import("std");
const http = @import("http.zig");

/// The cache file, under billy's cache directory.
pub const cache_file = "models.json";
/// Where the catalog is fetched from: one document holding every provider and
/// model models.dev knows.
pub const source_url = "https://models.dev/api.json";
/// The shape of the cache file. A file of another version is fetched again
/// rather than guessed at.
pub const format_version: u32 = 1;

/// The providers and models billy can send a request to. Loaded from the cache
/// file; empty when it could not be fetched or read, which costs the context
/// gauge and compaction but leaves a configured provider usable.
pub const Catalog = struct {
    providers: []const Provider = &.{},

    /// The provider called `name`, which is the spelling models.dev lists it
    /// under: the configuration names a provider the way the catalog does.
    pub fn find(catalog: *const Catalog, name: []const u8) ?*const Provider {
        for (catalog.providers) |*provider| {
            if (std.mem.eql(u8, provider.name, name)) return provider;
        }
        return null;
    }

    /// What is known about `model` at `provider`, or among all providers when
    /// the provider is unknown or not named. Null when the model is not in the
    /// catalog.
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

    /// How many models the catalog holds, for a command to report.
    pub fn modelCount(catalog: *const Catalog) usize {
        var count: usize = 0;
        for (catalog.providers) |provider| count += provider.models.len;
        return count;
    }
};

/// One service billy can call: where its OpenAI-compatible API lives, and the
/// models it offers.
pub const Provider = struct {
    /// The name a choice names it by, which is models.dev's provider id.
    name: []const u8,
    /// The base URL its completions path is appended to. Null for a provider
    /// models.dev gives no address for -- OpenAI and xAI as it lists them today,
    /// which leave the address to their SDK: a key can still be stored for one,
    /// and the configuration can name where it is reached.
    base_url: ?[]const u8 = null,
    models: []const Model = &.{},

    fn model(provider: *const Provider, id: []const u8) ?*const Model {
        for (provider.models) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

/// One model a provider offers. Only what billy reads is kept: models.dev says
/// much more about a model than a request or a header needs.
pub const Model = struct {
    /// The id a request sends.
    id: []const u8,
    /// Tokens the context window holds.
    context: usize,
};

/// What is known about a model: the window its provider gives it, which is what
/// the gauge shows and what compaction is measured against. Where it was found is
/// not kept: the choice the caller asked about already names it.
pub const Metadata = struct {
    context_window: usize,
};

/// The shape the cache file is written and read as. Its version guards the
/// shape a reader cannot bend to; a field that is dropped is not one, since a
/// reader skips what it does not know.
const Cache = struct {
    version: u32 = format_version,
    providers: []const Provider = &.{},
};

/// The models.dev document, as far as billy reads it: what it names that billy
/// does not use, a model's price and its release date among them, is skipped as
/// it is parsed rather than read and dropped again.
const Source = std.json.ArrayHashMap(SourceProvider);

const SourceProvider = struct {
    /// The SDK models.dev knows the provider through, which is how one that
    /// speaks the chat-completions wire billy sends is told from one that does
    /// not. A provider it does not name is one billy cannot call.
    npm: ?[]const u8 = null,
    api: ?[]const u8 = null,
    models: std.json.ArrayHashMap(SourceModel) = .{},
};

const SourceModel = struct {
    /// The id a request sends, which is the key the model is listed under; the
    /// field is read because models.dev states it, and the key is the fallback.
    id: ?[]const u8 = null,
    limit: SourceLimit = .{},
};

const SourceLimit = struct {
    /// Tokens the context window holds. A model models.dev gives no window for
    /// is left out rather than kept with an invented one.
    context: ?usize = null,
};

/// Reads the catalog from `dir`, into `arena`. A missing file is
/// `error.FileNotFound`, which `ensure` uses to fetch one; a file that cannot
/// be read is `error.CorruptCatalog`.
pub fn load(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) !Catalog {
    const text = try dir.readFileAlloc(io, cache_file, arena, .unlimited);
    const cache = std.json.parseFromSliceLeaky(Cache, arena, text, .{
        .ignore_unknown_fields = true,
        // The text is in `arena`, which outlives the parsed value, so the
        // strings may point into it.
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;
    if (cache.version != format_version) return error.UnsupportedCatalogVersion;
    if (cache.providers.len == 0) return error.CorruptCatalog;
    return .{ .providers = cache.providers };
}

/// Reads the cached catalog, fetching one first when there is none or the one
/// there cannot be used. A failure to fetch is reported and leaves an empty
/// catalog: a run with a configured provider still works, without a gauge.
pub fn ensure(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, dir: std.Io.Dir) Catalog {
    return load(io, arena, dir) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("fetching the model catalog", .{});
            return fetchThenLoad(io, arena, gpa, dir);
        },
        // A file that is half written, from another version or edited by hand is
        // fetched again rather than left to blind the run until the user runs
        // the refresh command.
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

/// Fetches a catalog and reads it back, reporting whichever step fails.
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

/// What a refresh wrote, so the command can say how much it got.
pub const Counts = struct { providers: usize, models: usize };

/// Fetches models.dev and writes the providers billy can call to the cache file
/// under `dir`. The response is filtered to OpenAI-compatible providers and the
/// fields billy uses, so the cache stays small and the reader simple.
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

/// Filters `body`, the models.dev document, into the cache file under `dir`.
/// Split from `refresh` so the filtering can be tested without the network.
fn writeFrom(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, body: []const u8) !Counts {
    var build_state = std.heap.ArenaAllocator.init(gpa);
    defer build_state.deinit();
    const build = build_state.allocator();

    const source = std.json.parseFromSliceLeaky(Source, build, body, .{
        .ignore_unknown_fields = true,
        // The text is `body`, which outlives what is built from it, so the
        // strings may point into it.
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;

    var providers: std.ArrayList(Provider) = .empty;
    defer providers.deinit(build);
    var model_count: usize = 0;

    for (source.map.keys(), source.map.values()) |name, provider| {
        if (name.len == 0) continue;
        if (!openAiCompatible(provider.npm orelse continue)) continue;

        // A model without a window is left out, and a provider left with no
        // models is no endpoint: neither is a row.
        var models: std.ArrayList(Model) = .empty;
        for (provider.models.map.keys(), provider.models.map.values()) |key, model| {
            const id = model.id orelse key;
            const context = model.limit.context orelse continue;
            if (id.len == 0 or context == 0) continue;
            try models.append(build, .{ .id = id, .context = context });
        }
        if (models.items.len == 0) continue;
        model_count += models.items.len;

        // A provider models.dev gives no address for is still a row: a key can
        // be stored for it, and the configuration can name where it is reached.
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

/// Whether a models.dev provider speaks the OpenAI chat-completions wire
/// format, which is the only one billy sends.
fn openAiCompatible(npm: []const u8) bool {
    return std.mem.eql(u8, npm, "@ai-sdk/openai-compatible") or
        std.mem.eql(u8, npm, "@ai-sdk/openai") or
        std.mem.eql(u8, npm, "@ai-sdk/xai");
}

/// A provider and the model of its that a run asks for, as the one string the
/// configuration and a session store: `provider/model`, such as
/// `deepseek/deepseek-v4-flash`.
///
/// Kept as the string it is read from rather than resolved to a provider and a
/// model id here, so a session file can name a provider a later catalog adds
/// without this having to be edited, and so a session that names one billy does
/// not know is refused where it can be reported rather than silently read as
/// some other endpoint.
pub const Choice = struct {
    /// The whole string, as configured. It is what a session stores and what an
    /// error names, so the two halves are not kept apart from it.
    text: []const u8,

    /// The provider half, before the first `/`.
    pub fn provider(choice: Choice) []const u8 {
        const slash = std.mem.findScalar(u8, choice.text, '/') orelse return "";
        return choice.text[0..slash];
    }

    /// The model half, after the first `/`. A model id may itself contain one,
    /// so only the first is the split.
    pub fn model(choice: Choice) []const u8 {
        const slash = std.mem.findScalar(u8, choice.text, '/') orelse return choice.text;
        return choice.text[slash + 1 ..];
    }

    /// Whether the string names both halves. A model with no provider in front
    /// of it names no endpoint to send it to.
    pub fn isComplete(choice: Choice) bool {
        return choice.provider().len > 0 and choice.model().len > 0;
    }
};

/// A catalog for the tests, so they need no cache file. The real catalog is
/// fetched at runtime; this is the providers billy's tests name, with the windows
/// they expect. Only a test may use it. `xai` is one only the catalog could
/// name: billy ships no purpose for it.
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

    // Only the first slash is the split, so a model id with one of its own keeps
    // the rest of it.
    const variant = Choice{ .text = "vendor/model/variant" };
    try std.testing.expectEqualStrings("vendor", variant.provider());
    try std.testing.expectEqualStrings("model/variant", variant.model());

    // A bare model id names no provider.
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

    // A spelling of the user's own is a provider billy does not know, rather
    // than one guessed at: the catalog itself says `opencode-go`.
    try std.testing.expect(test_catalog.find("opencode_go") == null);
    try std.testing.expect(test_catalog.find("not-a-provider") == null);
}

test "metadata is looked up at the provider, then among all providers" {
    const flash = test_catalog.metadata("deepseek", "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, flash.context_window);

    // A model is asked for at the provider named, and answers with that
    // provider's window: the same id is 262k at one provider and not at another.
    const elsewhere = test_catalog.metadata("opencode-go", "kimi-k2.7-code").?;
    try std.testing.expectEqual(262_144, elsewhere.context_window);

    // Without a provider, the model is found among all of them.
    const discovered = test_catalog.metadata(null, "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, discovered.context_window);

    // A model the provider does not offer is not looked up elsewhere.
    try std.testing.expect(test_catalog.metadata("deepseek", "kimi-k2.7-code") == null);

    // An unknown model has no metadata, so the header shows no gauge.
    try std.testing.expect(test_catalog.metadata(null, "who-knows") == null);
}

test "the cache is filtered to OpenAI-compatible providers, and reads back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A small models.dev-shaped document: the providers billy can call, one it
    // cannot, one whose models have no window, and one models.dev gives no
    // address for. The fields billy does not keep are here as models.dev writes
    // them, since they are what the parse has to skip.
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
    // Anthropic is not an OpenAI-compatible provider, so it was left out.
    try std.testing.expect(catalog.find("anthropic") == null);

    const deepseek = catalog.find("deepseek").?;
    try std.testing.expectEqual(@as(usize, 1), deepseek.models.len);
    try std.testing.expectEqualStrings("deepseek-flash", deepseek.models[0].id);
    try std.testing.expectEqual(@as(usize, 1_048_576), deepseek.models[0].context);

    const xai = catalog.find("xai").?;
    try std.testing.expectEqual(@as(usize, 131_072), xai.models[0].context);

    // A provider models.dev gives no address for is kept without one, so a key
    // can be stored for it and the configuration can say where it is reached.
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
