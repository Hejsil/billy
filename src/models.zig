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
/// The largest response billy will read, so a wrong address cannot fill memory.
const max_source_bytes = 64 << 20;

/// The providers and models billy can send a request to. Loaded from the cache
/// file; empty when it could not be fetched or read, which costs the context
/// gauge and compaction but leaves a configured provider usable.
pub const Catalog = struct {
    providers: []const Provider = &.{},

    /// The provider called `name`. A provider is matched exactly first, then
    /// with `-` and `_` taken as the same character, so the configuration's
    /// `opencode_go` finds the catalog's `opencode-go`.
    pub fn find(catalog: *const Catalog, name: []const u8) ?*const Provider {
        for (catalog.providers) |*provider| {
            if (std.mem.eql(u8, provider.name, name)) return provider;
        }
        for (catalog.providers) |*provider| {
            if (sameName(provider.name, name)) return provider;
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
                return .{ .provider = known.name, .context_window = entry.context };
            }
        }
        for (catalog.providers) |*known| {
            const entry = known.model(model) orelse continue;
            return .{ .provider = known.name, .context_window = entry.context };
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

/// One service billy can call: where its OpenAI-compatible API lives, the
/// variables a key may come from, and the models it offers.
pub const Provider = struct {
    /// The name a choice names it by, which is models.dev's provider id.
    name: []const u8,
    /// The base URL its completions path is appended to. Null for a provider
    /// whose address only the configuration can name.
    base_url: ?[]const u8 = null,
    /// Variables a key may be exported in, in the order models.dev lists them.
    env: []const []const u8 = &.{},
    models: []const Model = &.{},

    fn model(provider: *const Provider, id: []const u8) ?*const Model {
        for (provider.models) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

/// One model a provider offers.
pub const Model = struct {
    /// The id a request sends.
    id: []const u8,
    /// Tokens the context window holds.
    context: usize,
    /// Tokens the model may answer with, or zero when models.dev does not say.
    output: usize = 0,
    tools: bool = false,
    reasoning: bool = false,
};

/// What is known about a model: the provider it was found under, and its window.
pub const Metadata = struct {
    provider: []const u8,
    context_window: usize,
};

/// The shape the cache file is written and read as.
const Cache = struct {
    version: u32 = format_version,
    providers: []const Provider = &.{},
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
            _ = refresh(io, gpa, dir) catch |fetch_err| {
                std.log.warn("could not fetch the model catalog: {s}", .{@errorName(fetch_err)});
                return .{};
            };
            return load(io, arena, dir) catch |load_err| {
                std.log.warn("could not read the model catalog: {s}", .{@errorName(load_err)});
                return .{};
            };
        },
        // A file that is half written, from another version or edited by hand is
        // fetched again rather than left to blind the run until the user runs
        // the refresh command.
        error.CorruptCatalog, error.UnsupportedCatalogVersion => {
            std.log.warn("the model catalog cannot be used ({s}); fetching it again", .{@errorName(err)});
            _ = refresh(io, gpa, dir) catch |fetch_err| {
                std.log.warn("could not fetch the model catalog: {s}", .{@errorName(fetch_err)});
                return .{};
            };
            return load(io, arena, dir) catch |load_err| {
                std.log.warn("could not read the model catalog: {s}", .{@errorName(load_err)});
                return .{};
            };
        },
        else => {
            std.log.warn("could not read the model catalog: {s}", .{@errorName(err)});
            return .{};
        },
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
        .headers = .{ .user_agent = .{ .override = "billy" } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.CatalogFetchFailed;
    if (response.head.content_length) |length| {
        if (length > max_source_bytes) return error.CatalogTooLarge;
    }
    const body = try http.readBody(gpa, &response);
    defer gpa.free(body);
    if (body.len > max_source_bytes) return error.CatalogTooLarge;

    return writeFrom(io, gpa, dir, body);
}

/// Filters `body`, the models.dev document, into the cache file under `dir`.
/// Split from `refresh` so the filtering can be tested without the network.
fn writeFrom(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, body: []const u8) !Counts {
    var build_state = std.heap.ArenaAllocator.init(gpa);
    defer build_state.deinit();
    const build = build_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, build, body, .{
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;
    const catalog = switch (root) {
        .object => |object| object,
        else => return error.CorruptCatalog,
    };

    var providers: std.ArrayList(Provider) = .empty;
    defer providers.deinit(build);
    var model_count: usize = 0;

    var it = catalog.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (name.len == 0) continue;
        const provider = switch (value) {
            .object => |object| object,
            else => continue,
        };
        const npm = stringField(provider, "npm") orelse continue;
        if (!openAiCompatible(npm)) continue;
        // Some providers -- OpenAI and xAI among them -- leave the address to
        // their SDK, so models.dev has none. They are kept with no address: a
        // key can be stored for them, and the configuration can name where they
        // are reached.
        const base_url = stringField(provider, "api");
        const models_value = provider.get("models") orelse continue;
        const models_object = switch (models_value) {
            .object => |object| object,
            else => continue,
        };

        var models: std.ArrayList(Model) = .empty;
        var models_it = models_object.iterator();
        while (models_it.next()) |model_entry| {
            const model = switch (model_entry.value_ptr.*) {
                .object => |object| object,
                else => continue,
            };
            const id = stringField(model, "id") orelse model_entry.key_ptr.*;
            if (id.len == 0) continue;
            const limit = model.get("limit") orelse continue;
            const limit_object = switch (limit) {
                .object => |object| object,
                else => continue,
            };
            const context = intField(limit_object, "context") orelse continue;
            if (context == 0) continue;
            try models.append(build, .{
                .id = id,
                .context = context,
                .output = intField(limit_object, "output") orelse 0,
                .tools = boolField(model, "tool_call"),
                .reasoning = boolField(model, "reasoning"),
            });
        }
        if (models.items.len == 0) continue;
        std.mem.sort(Model, models.items, {}, byModelId);
        model_count += models.items.len;

        const env = try envOf(build, provider);
        try providers.append(build, .{
            .name = name,
            .base_url = base_url,
            .env = env,
            .models = models.items,
        });
    }
    if (providers.items.len == 0) return error.EmptyCatalog;

    std.mem.sort(Provider, providers.items, {}, byName);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try std.json.Stringify.value(Cache{
        .providers = providers.items,
    }, .{}, &text.writer);

    var atomic = try dir.createFileAtomic(io, cache_file, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buffer);
    try file.interface.writeAll(text.written());
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

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

fn envOf(arena: std.mem.Allocator, provider: std.json.ObjectMap) ![]const []const u8 {
    const value = provider.get("env") orelse return &.{};
    const list = switch (value) {
        .array => |array| array,
        else => return &.{},
    };
    const names = try arena.alloc([]const u8, list.items.len);
    var count: usize = 0;
    for (list.items) |item| {
        const name = switch (item) {
            .string => |text| text,
            else => continue,
        };
        names[count] = name;
        count += 1;
    }
    return names[0..count];
}

fn byName(_: void, a: Provider, b: Provider) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn byModelId(_: void, a: Model, b: Model) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Whether two provider names are the same with `-` and `_` taken as equal.
fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x == y) continue;
        if (isDash(x) and isDash(y)) continue;
        return false;
    }
    return true;
}

fn isDash(c: u8) bool {
    return c == '-' or c == '_';
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
        const slash = std.mem.indexOfScalar(u8, choice.text, '/') orelse return "";
        return choice.text[0..slash];
    }

    /// The model half, after the first `/`. A model id may itself contain one,
    /// so only the first is the split.
    pub fn model(choice: Choice) []const u8 {
        const slash = std.mem.indexOfScalar(u8, choice.text, '/') orelse return choice.text;
        return choice.text[slash + 1 ..];
    }

    /// Whether the string names both halves. A model with no provider in front
    /// of it names no endpoint to send it to.
    pub fn isComplete(choice: Choice) bool {
        return choice.provider().len > 0 and choice.model().len > 0;
    }
};

/// A catalog for the tests, so they need no cache file. The real catalog is
/// fetched at runtime; this is the two providers billy's tests name, with the
/// windows they expect. Only a test may use it.
pub const test_catalog = Catalog{ .providers = &.{
    .{ .name = "deepseek", .base_url = "https://api.deepseek.com", .env = &.{"DEEPSEEK_API_KEY"}, .models = &.{
        .{ .id = "deepseek-flash", .context = 1_000_000, .tools = true },
        .{ .id = "deepseek-v4-pro", .context = 1_000_000, .tools = true },
        .{ .id = "deepseek-v4-flash", .context = 1_000_000, .tools = true },
    } },
    .{ .name = "opencode-go", .base_url = "https://opencode.ai/zen/go/v1", .env = &.{"OPENCODE_API_KEY"}, .models = &.{
        .{ .id = "kimi-k2.7-code", .context = 262_144, .tools = true },
        .{ .id = "deepseek-flash", .context = 1_000_000, .tools = true },
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

test "the catalog finds a provider exactly, then with dashes and underscores" {
    const found = test_catalog.find("deepseek").?;
    try std.testing.expectEqualStrings("https://api.deepseek.com", found.base_url.?);

    // The catalog calls it `opencode-go`; the configuration and a session call
    // it `opencode_go`.
    const opencode = test_catalog.find("opencode_go").?;
    try std.testing.expectEqualStrings("opencode-go", opencode.name);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", opencode.base_url.?);

    try std.testing.expect(test_catalog.find("not-a-provider") == null);
}

test "metadata is looked up at the provider, then among all providers" {
    const flash = test_catalog.metadata("deepseek", "deepseek-flash").?;
    try std.testing.expectEqualStrings("deepseek", flash.provider);
    try std.testing.expectEqual(1_000_000, flash.context_window);

    // The same model under another provider uses that provider's window.
    const elsewhere = test_catalog.metadata("opencode_go", "kimi-k2.7-code").?;
    try std.testing.expectEqualStrings("opencode-go", elsewhere.provider);
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

    // A small models.dev-shaped document: one provider billy can call, one it
    // cannot, and one OpenAI-compatible provider whose model has no window.
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
        \\  "anthropic": {
        \\    "id": "anthropic", "name": "Anthropic", "api": "https://api.anthropic.com",
        \\    "npm": "@ai-sdk/anthropic",
        \\    "models": {"claude": {"id": "claude", "limit": {"context": 200000}}}
        \\  }
        \\}
    ;

    const counts = try writeFrom(std.testing.io, gpa, tmp.dir, body);
    try std.testing.expectEqual(@as(usize, 2), counts.providers);
    try std.testing.expectEqual(@as(usize, 2), counts.models);

    const catalog = try load(std.testing.io, arena, tmp.dir);
    // Anthropic is not an OpenAI-compatible provider, so it was left out.
    try std.testing.expect(catalog.find("anthropic") == null);

    const deepseek = catalog.find("deepseek").?;
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", deepseek.env[0]);
    try std.testing.expectEqual(@as(usize, 1), deepseek.models.len);
    try std.testing.expect(deepseek.models[0].tools);
    try std.testing.expect(deepseek.models[0].reasoning);
    try std.testing.expectEqual(@as(usize, 393216), deepseek.models[0].output);
    try std.testing.expectEqual(@as(usize, 1_048_576), deepseek.models[0].context);

    // A provider whose address is not known is left out as well; xAI is kept.
    const xai = catalog.find("xai").?;
    try std.testing.expectEqual(@as(usize, 131_072), xai.models[0].context);
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
