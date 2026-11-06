//! The model catalog: the providers billy can talk to, the models each offers, and their windows.

const std = @import("std");

const http = @import("http.zig");
const Pool = @import("Pool.zig");
const store = @import("store.zig");

/// The cache file: the catalog, in the bytes it is held as.
pub const cache_file = "catalog";

/// Where the catalog is fetched from: one document holding every provider models.dev knows.
pub const source_url = "https://models.dev/api.json";
pub const format_version: u32 = 1;

const magic = "BILLYMDL";

/// What a catalog file opens with: how long each block is, and how long the file is.
const Header = extern struct {
    magic: [magic.len]u8 = magic.*,
    version: u32 = format_version,
    header_len: u32 = @sizeOf(Header),
    strings_len: u64 = 0,
    providers_len: u64 = 0,
    models_len: u64 = 0,
    file_len: u64 = 0,

    fn bodyLen(header: Header) u64 {
        return header.strings_len +
            header.providers_len * @sizeOf(Provider) +
            header.models_len * @sizeOf(Model);
    }
};

const header_len = @sizeOf(Header);

// A file is the structs a catalog is held as: what fails here is what says to bump `format_version`.
comptime {
    store.fixedSize(Header, 48);
    store.fixedSize(Provider, 16);
    store.fixedSize(Model, 8);
    store.fixedPacking(Header);
    store.fixedPacking(Provider);
    store.fixedPacking(Model);
    store.fixedOffset(Header, "strings_len", 16);
    store.fixedOffset(Header, "file_len", 40);
}

/// A provider as the catalog keeps it: where its name and address sit, and the models it offers.
pub const Provider = extern struct {
    name: Pool.Index,
    base_url: Pool.Index,
    models_start: u32,
    models_len: u32,
};

/// A model and the window its provider gives it, which is what compaction is measured against.
pub const Model = extern struct {
    id: Pool.Index,
    context: u32,
};

pub const Catalog = struct {
    pool: Pool = .{},
    providers: std.ArrayList(Provider) = .empty,
    models: std.ArrayList(Model) = .empty,

    pub fn deinit(catalog: *Catalog, gpa: std.mem.Allocator) void {
        catalog.pool.deinit(gpa);
        catalog.providers.deinit(gpa);
        catalog.models.deinit(gpa);
        catalog.* = .{};
    }

    /// The provider called `name`, which is the spelling models.dev lists it under.
    pub fn find(catalog: *const Catalog, name: []const u8) ?*const Provider {
        // Providers are in name order, so a lookup is a short walk of the block rather than all of it.
        var low: usize = 0;
        var high: usize = catalog.providers.items.len;
        while (low < high) {
            const at = low + (high - low) / 2;
            const provider = &catalog.providers.items[at];
            switch (std.mem.order(u8, catalog.pool.get(provider.name) orelse "", name)) {
                .lt => low = at + 1,
                .gt => high = at,
                .eq => return provider,
            }
        }
        return null;
    }

    pub fn baseUrl(catalog: *const Catalog, provider: *const Provider) ?[]const u8 {
        return catalog.pool.get(provider.base_url);
    }

    /// What is known about `model` at `provider`, or among all providers when it is not named.
    pub fn metadata(catalog: *const Catalog, provider: ?[]const u8, model: []const u8) ?Metadata {
        if (provider) |name| {
            if (catalog.find(name)) |known| {
                const entry = catalog.modelOf(known, model) orelse return null;
                return .{ .context_window = entry.context };
            }
        }
        for (catalog.providers.items) |*known| {
            const entry = catalog.modelOf(known, model) orelse continue;
            return .{ .context_window = entry.context };
        }
        return null;
    }

    fn modelOf(catalog: *const Catalog, provider: *const Provider, id: []const u8) ?*const Model {
        const offered = catalog.models.items[provider.models_start..][0..provider.models_len];
        for (offered) |*entry| {
            if (std.mem.eql(u8, catalog.pool.get(entry.id) orelse "", id)) return entry;
        }
        return null;
    }

    pub fn modelCount(catalog: *const Catalog) usize {
        return catalog.models.items.len;
    }

    /// Whether what the file said adds up: every index names a string, and every range has models.
    fn sound(catalog: *const Catalog) bool {
        const pool = &catalog.pool;
        var held = true;
        for (catalog.providers.items) |provider| {
            held = held and pool.validateIndicesInStruct(Provider, provider);
            held = held and @as(u64, provider.models_start) + provider.models_len <= catalog.models.items.len;
        }
        for (catalog.models.items) |model| held = held and pool.validateIndicesInStruct(Model, model);
        return held;
    }
};

/// What is known about a model: the window its provider gives it, which compaction is measured by.
pub const Metadata = struct {
    context_window: usize,
};

pub fn load(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !Catalog {
    var file = try dir.openFile(io, cache_file, .{});
    defer file.close(io);

    var read_buf: [store.read_buffer]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    const header = try readHeader(reader, try file_reader.getSize());
    if (header.providers_len == 0) return error.CorruptCatalog;

    var catalog: Catalog = .{};
    errdefer catalog.deinit(gpa);
    try catalog.pool.strings.resize(gpa, @intCast(header.strings_len));
    try catalog.providers.resize(gpa, @intCast(header.providers_len));
    try catalog.models.resize(gpa, @intCast(header.models_len));

    var blocks = [_][]u8{
        catalog.pool.strings.items,
        std.mem.sliceAsBytes(catalog.providers.items),
        std.mem.sliceAsBytes(catalog.models.items),
    };
    reader.readVecAll(&blocks) catch |err| switch (err) {
        // The header counted this file's length already, so a short block is a file that changed.
        error.EndOfStream => return error.CorruptCatalog,
        else => |other| return other,
    };

    if (!catalog.sound()) return error.CorruptCatalog;
    return catalog;
}

fn readHeader(reader: *std.Io.Reader, file_len: u64) !Header {
    const bytes = reader.take(header_len) catch return error.CorruptCatalog;

    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes);
    if (!std.mem.eql(u8, &header.magic, magic)) return error.CorruptCatalog;
    if (header.header_len != header_len) return error.CorruptCatalog;
    if (header.version > format_version) return error.UnsupportedCatalogVersion;
    // A file says how long it is, so one cut short, or whose counts do not add up, is refused first.
    if (header.file_len != file_len) return error.CorruptCatalog;
    if (header_len + Header.bodyLen(header) != file_len) return error.CorruptCatalog;
    return header;
}

/// Writes the catalog as the header and the blocks it counts, each the bytes it is held as.
fn write(catalog: *const Catalog, writer: *std.Io.Writer) !void {
    var header: Header = .{
        .strings_len = catalog.pool.strings.items.len,
        .providers_len = catalog.providers.items.len,
        .models_len = catalog.models.items.len,
    };
    header.file_len = header_len + Header.bodyLen(header);

    var blocks = [_][]const u8{
        std.mem.asBytes(&header),
        catalog.pool.strings.items,
        std.mem.sliceAsBytes(catalog.providers.items),
        std.mem.sliceAsBytes(catalog.models.items),
    };
    try writer.writeVecAll(&blocks);
}

/// Reads the cached catalog, fetching one first when there is none or the one there cannot be used.
pub fn ensure(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) Catalog {
    return load(io, gpa, dir) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("fetching the model catalog", .{});
            return fetchThenLoad(io, gpa, dir);
        },
        // A file half written, of another version or edited by hand is fetched again rather than
        // left to blind the run.
        error.CorruptCatalog, error.UnsupportedCatalogVersion => {
            std.log.warn("the model catalog cannot be used ({t}); fetching it again", .{err});
            return fetchThenLoad(io, gpa, dir);
        },
        // Nothing about a directory billy cannot read is made better by fetching.
        else => {
            std.log.warn("could not read the model catalog: {t}", .{err});
            return .{};
        },
    };
}

fn fetchThenLoad(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) Catalog {
    _ = refresh(io, gpa, dir) catch |err| {
        std.log.warn("could not fetch the model catalog: {t}", .{err});
        return .{};
    };
    return load(io, gpa, dir) catch |err| {
        std.log.warn("could not read the model catalog: {t}", .{err});
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

/// Filters what models.dev said down to the providers billy can talk to, and writes it out.
fn writeFrom(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, body: []const u8) !Counts {
    var build_state = std.heap.ArenaAllocator.init(gpa);
    defer build_state.deinit();
    const build = build_state.allocator();

    const source = std.json.parseFromSliceLeaky(Source, build, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCatalog;

    const catalog = try fromSource(build, source);
    if (catalog.providers.items.len == 0) return error.EmptyCatalog;

    var atomic = try dir.createFileAtomic(io, cache_file, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buffer);
    try write(&catalog, &file.interface);
    try file.flush();
    try atomic.replace(io);

    return .{ .providers = catalog.providers.items.len, .models = catalog.models.items.len };
}

/// The catalog a fetched document holds: the providers that speak billy's API, with the models of
/// each that give a window, named once however many providers offer them.
fn fromSource(build: std.mem.Allocator, source: Source) !Catalog {
    var pool: Pool = .{};
    var seen: std.StringHashMap(Pool.Index) = .init(build);
    errdefer seen.deinit();
    var providers: std.ArrayList(Provider) = .empty;
    errdefer providers.deinit(build);
    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(build);

    for (source.map.keys(), source.map.values()) |name, provider| {
        if (name.len == 0) continue;
        if (!openAiCompatible(provider.npm orelse continue)) continue;

        const start: u32 = @intCast(models.items.len);
        for (provider.models.map.keys(), provider.models.map.values()) |key, model| {
            const id = model.id orelse key;
            const context = std.math.cast(u32, model.limit.context orelse continue) orelse continue;
            if (id.len == 0 or context == 0) continue;
            try models.append(build, .{ .id = try intern(build, &pool, &seen, id), .context = context });
        }
        if (models.items.len == start) continue;

        try providers.append(build, .{
            .name = try intern(build, &pool, &seen, name),
            .base_url = try intern(build, &pool, &seen, provider.api),
            .models_start = start,
            .models_len = @intCast(models.items.len - start),
        });
    }

    // Written in name order, with each provider's models in id order, so a lookup walks one block.
    for (providers.items) |provider| {
        const offered = models.items[provider.models_start..][0..provider.models_len];
        std.mem.sort(Model, offered, &pool, lessById);
    }
    std.mem.sort(Provider, providers.items, &pool, lessByName);

    return .{ .pool = pool, .providers = providers, .models = models };
}

/// Adds `text` to the pool unless it is already there, which half of the model ids are.
fn intern(
    build: std.mem.Allocator,
    pool: *Pool,
    seen: *std.StringHashMap(Pool.Index),
    text: ?[]const u8,
) !Pool.Index {
    const value = text orelse return .none;
    if (seen.get(value)) |known| return known;
    const index = try pool.intern(build, value);
    try seen.put(value, index);
    return index;
}

fn lessByName(pool: *const Pool, a: Provider, b: Provider) bool {
    return std.mem.order(u8, pool.get(a.name) orelse "", pool.get(b.name) orelse "") == .lt;
}

fn lessById(pool: *const Pool, a: Model, b: Model) bool {
    return std.mem.order(u8, pool.get(a.id) orelse "", pool.get(b.id) orelse "") == .lt;
}

fn openAiCompatible(npm: []const u8) bool {
    return std.mem.eql(u8, npm, "@ai-sdk/openai-compatible") or
        std.mem.eql(u8, npm, "@ai-sdk/openai") or
        std.mem.eql(u8, npm, "@ai-sdk/xai");
}

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

const Spec = struct {
    name: []const u8,
    base_url: ?[]const u8 = null,
    models: []const struct { id: []const u8, context: u32 },
};

const TestBuild = struct {
    strings: [1024]u8 = @splat(0),
    strings_len: usize = 0,
    models: [16]Model = undefined,
    models_len: usize = 0,
    providers: [4]Provider = undefined,
    providers_len: usize = 0,

    fn intern(built: *TestBuild, text: ?[]const u8) Pool.Index {
        const value = text orelse return .none;
        const start: u32 = @intCast(built.strings_len);
        @memcpy(built.strings[built.strings_len..][0..value.len], value);
        built.strings_len += value.len + 1;
        return @fromBackingInt(start);
    }

    fn add(built: *TestBuild, spec: Spec) void {
        const start: u32 = @intCast(built.models_len);
        for (spec.models) |model| {
            built.models[built.models_len] = .{ .id = built.intern(model.id), .context = model.context };
            built.models_len += 1;
        }
        built.providers[built.providers_len] = .{
            .name = built.intern(spec.name),
            .base_url = built.intern(spec.base_url),
            .models_start = start,
            .models_len = @intCast(spec.models.len),
        };
        built.providers_len += 1;
    }
};

/// The catalog the tests point at instead of a cache, in the order the writer would give it.
const test_built = testBuild();

fn testBuild() TestBuild {
    @setEvalBranchQuota(10_000);
    var built: TestBuild = .{};
    built.add(.{ .name = "deepseek", .base_url = "https://api.deepseek.com", .models = &.{
        .{ .id = "deepseek-flash", .context = 1_000_000 },
        .{ .id = "deepseek-v4-flash", .context = 1_000_000 },
        .{ .id = "deepseek-v4-pro", .context = 1_000_000 },
    } });
    built.add(.{ .name = "opencode-go", .base_url = "https://opencode.ai/zen/go/v1", .models = &.{
        .{ .id = "deepseek-flash", .context = 1_000_000 },
        .{ .id = "kimi-k2.7-code", .context = 262_144 },
    } });
    built.add(.{ .name = "xai", .base_url = "https://api.x.ai/v1", .models = &.{
        .{ .id = "grok-4", .context = 131_072 },
    } });
    return built;
}

// The blocks the test catalog is held as, so that it is a catalog of the same shape as any other.
var test_strings: [test_built.strings_len]u8 = test_built.strings[0..test_built.strings_len].*;
var test_providers: [test_built.providers_len]Provider = test_built.providers[0..test_built.providers_len].*;
var test_models: [test_built.models_len]Model = test_built.models[0..test_built.models_len].*;

pub const test_catalog: Catalog = .{
    .pool = .{ .strings = .{
        .items = &test_strings,
        .capacity = test_strings.len,
        .pointer_stability = .{},
    } },
    .providers = .{
        .items = &test_providers,
        .capacity = test_providers.len,
        .pointer_stability = .{},
    },
    .models = .{
        .items = &test_models,
        .capacity = test_models.len,
        .pointer_stability = .{},
    },
};

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
    try std.testing.expectEqualStrings("https://api.deepseek.com", test_catalog.baseUrl(found).?);

    const opencode = test_catalog.find("opencode-go").?;
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", test_catalog.baseUrl(opencode).?);

    try std.testing.expect(test_catalog.find("opencode_go") == null);
    try std.testing.expect(test_catalog.find("not-a-provider") == null);
    // Every name it holds is found, which says the block is in the order a lookup expects.

    for (test_catalog.providers.items) |provider|
        try std.testing.expect(test_catalog.find(test_catalog.pool.get(provider.name).?) != null);
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

const source_body =
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

test "the cache is filtered to OpenAI-compatible providers, and reads back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const counts = try writeFrom(std.testing.io, gpa, tmp.dir, source_body);
    try std.testing.expectEqual(@as(usize, 3), counts.providers);
    try std.testing.expectEqual(@as(usize, 3), counts.models);

    var catalog = try load(std.testing.io, gpa, tmp.dir);
    defer catalog.deinit(gpa);
    try std.testing.expect(catalog.find("anthropic") == null);

    const deepseek = catalog.find("deepseek").?;
    try std.testing.expectEqual(@as(u32, 1), deepseek.models_len);
    const flash = catalog.models.items[deepseek.models_start];
    try std.testing.expectEqualStrings("deepseek-flash", catalog.pool.get(flash.id).?);
    try std.testing.expectEqual(@as(u32, 1_048_576), flash.context);

    const xai = catalog.find("xai").?;
    try std.testing.expectEqual(@as(u32, 131_072), catalog.models.items[xai.models_start].context);

    const openai = catalog.find("openai").?;
    try std.testing.expect(catalog.baseUrl(openai) == null);
}

test "a catalog read back and written again is the same bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try writeFrom(std.testing.io, gpa, tmp.dir, source_body);
    const first = try tmp.dir.readFileAlloc(std.testing.io, cache_file, gpa, .unlimited);
    defer gpa.free(first);

    var catalog = try load(std.testing.io, gpa, tmp.dir);
    defer catalog.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&catalog, &out.writer);
    try std.testing.expectEqualStrings(first, out.written());
}

test "the catalog is written in the order its lookups walk it in" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try writeFrom(std.testing.io, gpa, tmp.dir, source_body);

    var catalog = try load(std.testing.io, gpa, tmp.dir);
    defer catalog.deinit(gpa);

    // The document holds xai before openai, and anthropic is not written at all.
    const names = [_][]const u8{ "deepseek", "openai", "xai" };
    try std.testing.expectEqual(names.len, catalog.providers.items.len);
    for (names, catalog.providers.items) |name, provider|
        try std.testing.expectEqualStrings(name, catalog.pool.get(provider.name).?);
}

test "a missing cache is a miss, and a damaged one is refused" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.FileNotFound, load(std.testing.io, gpa, tmp.dir));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_file, .data = "not a catalog" });
    try std.testing.expectError(error.CorruptCatalog, load(std.testing.io, gpa, tmp.dir));

    _ = try writeFrom(std.testing.io, gpa, tmp.dir, source_body);
    const written = try tmp.dir.readFileAlloc(std.testing.io, cache_file, gpa, .unlimited);
    defer gpa.free(written);

    // A header of a version this billy does not know, over a file that is otherwise its own.
    var future = try gpa.dupe(u8, written);
    defer gpa.free(future);
    std.mem.writeInt(u32, future[@offsetOf(Header, "version")..][0..4], format_version + 1, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_file, .data = future });
    try std.testing.expectError(error.UnsupportedCatalogVersion, load(std.testing.io, gpa, tmp.dir));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_file, .data = written[0 .. written.len - 1] });
    try std.testing.expectError(error.CorruptCatalog, load(std.testing.io, gpa, tmp.dir));

    const last = try gpa.dupe(u8, written);
    defer gpa.free(last);
    std.mem.writeInt(u32, last[last.len - @sizeOf(Model) ..][0..4], 9_999, .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_file, .data = last });
    try std.testing.expectError(error.CorruptCatalog, load(std.testing.io, gpa, tmp.dir));
}
