//! The credentials billy needs, and where it keeps the ones the user stores.

const std = @import("std");

const models = @import("models.zig");

const Credentials = @This();

pub const file_name = "credentials.json";

const secret_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));

/// A service billy is shipped knowing, so the listing can name what a key is for and `billy login`
/// can be told which one it is.
pub const Known = struct {
    name: []const u8,
    purpose: []const u8,
};

pub const known = [_]Known{
    .{ .name = "deepseek", .purpose = "DeepSeek API key" },
    .{ .name = "opencode-go", .purpose = "OpenCode Go API key" },
    .{ .name = "openai", .purpose = "OpenAI API key" },
    .{ .name = "tavily", .purpose = "Tavily web search API key" },
    .{ .name = "exa", .purpose = "Exa web search API key" },
    .{ .name = "brave", .purpose = "Brave web search API key" },
};

pub fn purposeOf(name: []const u8) ?[]const u8 {
    for (known) |service| {
        if (std.mem.eql(u8, service.name, name)) return service.purpose;
    }
    return null;
}

keys: std.json.ArrayHashMap([]const u8) = .{},

/// A table with no key stored in it, which a run that stores none is given.
pub const empty: Credentials = .{};

pub fn get(credentials: *const Credentials, name: []const u8) ?[]const u8 {
    return credentials.keys.map.get(name);
}

pub fn put(credentials: *Credentials, arena: std.mem.Allocator, name: []const u8, key: []const u8) !void {
    const owned_name = try arena.dupe(u8, name);
    const owned_key = try arena.dupe(u8, key);
    try credentials.keys.map.put(arena, owned_name, owned_key);
}

pub fn names(credentials: *const Credentials) []const []const u8 {
    return credentials.keys.map.keys();
}

const format_version: u32 = 1;

const Stored = struct {
    version: u32 = format_version,
    credentials: std.json.ArrayHashMap([]const u8) = .{},
};

pub fn load(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) !Credentials {
    const text = dir.readFileAlloc(io, file_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const file = std.json.parseFromSliceLeaky(Stored, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptCredentials;
    if (file.version > format_version) return error.UnsupportedCredentialsVersion;

    return .{ .keys = file.credentials };
}

pub fn save(credentials: *const Credentials, io: std.Io, dir: std.Io.Dir) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{
        .replace = true,
        .permissions = secret_mode,
    });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, io, &buffer);
    var json: std.json.Stringify = .{
        .writer = &file.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try credentials.write(&json);
    try file.flush();
    try atomic.replace(io);
}

fn write(credentials: *const Credentials, json: *std.json.Stringify) !void {
    return try json.write(Stored{ .credentials = credentials.keys });
}

/// Whether a key can be stored for `name`: a service billy ships, or one the configuration names.
pub fn acceptable(name: []const u8, providers: []const []const u8) bool {
    return purposeOf(name) != null or definedIn(name, providers);
}

const configured_purpose = "a provider the configuration names";

const catalog_purpose = "a provider in the model catalog";

const dangling_purpose = "a service billy does not know";

/// Prints every name a key can be stored for, and whether one is: the services billy ships, the
/// providers the configuration names, and any other name a key is stored under.
const Row = struct {
    name: []const u8,
    purpose: []const u8,
    state: KeyState,
};

pub fn list(
    credentials: *const Credentials,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    providers: []const []const u8,
    catalog: *const models.Catalog,
) !void {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);

    for (known) |service| {
        const state: KeyState = if (credentials.get(service.name) != null) .stored else .not_set;
        try rows.append(gpa, .{ .name = service.name, .purpose = service.purpose, .state = state });
    }
    for (providers) |name| {
        // One billy already knows was printed as the service it is, with what its key is for rather
        // than where it came from.
        if (purposeOf(name) != null) continue;
        const state: KeyState = if (credentials.get(name) != null) .stored else .not_set;
        try rows.append(gpa, .{ .name = name, .purpose = configured_purpose, .state = state });
    }
    for (credentials.names()) |name| {
        if (purposeOf(name) != null or definedIn(name, providers)) continue;
        const purpose = if (catalog.find(name) != null) catalog_purpose else dangling_purpose;
        try rows.append(gpa, .{ .name = name, .purpose = purpose, .state = .stored });
    }

    // Every row that will be printed decides the columns, so a long name of the user's own widens
    // them all rather than running past the end.
    var name_width: usize = 0;
    var purpose_width: usize = 0;
    for (rows.items) |row| {
        name_width = @max(name_width, row.name.len);
        purpose_width = @max(purpose_width, row.purpose.len);
    }
    for (rows.items) |row| {
        try printRow(out, row.name, row.purpose, name_width, purpose_width, row.state);
    }
    try out.writeAll("\n`billy login <service>` stores a key\n");
}

fn definedIn(name: []const u8, providers: []const []const u8) bool {
    for (providers) |defined| {
        if (std.mem.eql(u8, defined, name)) return true;
    }
    return false;
}

const KeyState = enum { stored, not_set };

fn printRow(
    out: *std.Io.Writer,
    name: []const u8,
    purpose: []const u8,
    name_width: usize,
    purpose_width: usize,
    state: KeyState,
) !void {
    try out.print("{s}", .{name});
    try out.splatByteAll(' ', name_width - name.len);
    try out.writeAll("  ");
    try out.print("{s}", .{purpose});
    try out.splatByteAll(' ', purpose_width - purpose.len);
    try out.writeAll("  ");
    try out.writeAll(switch (state) {
        .stored => "stored",
        .not_set => "not set",
    });
    try out.writeAll("\n");
}

test "a service billy knows says what a key for it is for" {
    try std.testing.expectEqualStrings("DeepSeek API key", purposeOf("deepseek").?);
    try std.testing.expectEqualStrings("Tavily web search API key", purposeOf("tavily").?);
    try std.testing.expect(purposeOf("mock") == null);
    try std.testing.expectEqual(6, known.len);
}

test "load of a file that is not there is empty credentials" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const credentials = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(credentials.get("tavily") == null);
}

test "a key is stored under its own name, known to billy or not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var credentials: Credentials = .{};
    for (known) |service| {
        try std.testing.expect(credentials.get(service.name) == null);
        // The name is the key, so two services never read alike.
        try credentials.put(allocator, service.name, service.name);
    }
    try credentials.put(allocator, "mock", "mock-key");
    try std.testing.expectEqual(@as(usize, known.len + 1), credentials.names().len);

    for (known) |service| {
        try std.testing.expectEqualStrings(service.name, credentials.get(service.name).?);
    }
    try std.testing.expectEqualStrings("mock-key", credentials.get("mock").?);
}

test "a stored key survives a save and a load" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var credentials: Credentials = .{};
    try credentials.put(allocator, "tavily", "tvly-secret");
    try credentials.put(allocator, "deepseek", "sk-secret");
    try credentials.put(allocator, "mock", "mock-secret");
    try credentials.save(std.testing.io, tmp.dir);

    const loaded = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly-secret", loaded.get("tavily").?);
    try std.testing.expectEqualStrings("sk-secret", loaded.get("deepseek").?);
    // A name billy has never heard of comes back as it was written, which is what makes a provider
    // named in the configuration work.
    try std.testing.expectEqualStrings("mock-secret", loaded.get("mock").?);
    try std.testing.expect(loaded.get("brave") == null);
}

test "the file holds a key per name that has one, and nothing else" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var credentials: Credentials = .{};
    try credentials.put(allocator, "tavily", "tvly-secret");
    try credentials.save(std.testing.io, tmp.dir);

    const text = try tmp.dir.readFileAlloc(std.testing.io, file_name, allocator, .unlimited);
    // The names are the object's keys; a name with no key is left out rather than written as null.
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "credentials": {
        \\    "tavily": "tvly-secret"
        \\  }
        \\}
    , text);
}

test "put replaces the key already stored for a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var credentials: Credentials = .{};
    try credentials.put(allocator, "tavily", "old");
    try credentials.put(allocator, "tavily", "new");

    try std.testing.expectEqualStrings("new", credentials.get("tavily").?);
    try std.testing.expectEqual(@as(usize, 1), credentials.names().len);
}

test "the credentials file is written for the owner alone" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var credentials: Credentials = .{};
    try credentials.put(arena_state.allocator(), "tavily", "secret");
    try credentials.save(std.testing.io, tmp.dir);

    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "load reads a key written for a name this billy does not know" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"credentials\":{\"future\":\"f\",\"tavily\":\"tvly\"}}",
    });

    const credentials = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly", credentials.get("tavily").?);
    try std.testing.expectEqualStrings("f", credentials.get("future").?);
    try std.testing.expect(credentials.get("deepseek") == null);
}

const StoredKey = struct { name: []const u8, key: []const u8 };

const Listing = struct {
    stored: []const StoredKey = &.{},
    providers: []const []const u8 = &.{},
};

fn renderListing(gpa: std.mem.Allocator, listing: Listing) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var credentials: Credentials = .{};
    for (listing.stored) |stored| try credentials.put(arena, stored.name, stored.key);

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try credentials.list(gpa, &sink.writer, listing.providers, &models.test_catalog);
    return sink.toOwnedSlice();
}

fn expectListing(listing: Listing, expected: []const u8) !void {
    const shown = try renderListing(std.testing.allocator, listing);
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings(expected, shown);
}

fn expectListingHas(listing: Listing, needle: []const u8) !void {
    const shown = try renderListing(std.testing.allocator, listing);
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, needle) != null);
}

fn expectListingLacks(listing: Listing, needle: []const u8) !void {
    const shown = try renderListing(std.testing.allocator, listing);
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, needle) == null);
}

test "the listing shows each service billy knows and whether a key is stored" {
    try expectListing(.{ .stored = &.{.{ .name = "deepseek", .key = "sk-secret" }} },
        \\deepseek     DeepSeek API key           stored
        \\opencode-go  OpenCode Go API key        not set
        \\openai       OpenAI API key             not set
        \\tavily       Tavily web search API key  not set
        \\exa          Exa web search API key     not set
        \\brave        Brave web search API key   not set
        \\
        \\`billy login <service>` stores a key
        \\
    );
}
test "the listing names a service that has no key of any kind" {
    try expectListing(.{},
        \\deepseek     DeepSeek API key           not set
        \\opencode-go  OpenCode Go API key        not set
        \\openai       OpenAI API key             not set
        \\tavily       Tavily web search API key  not set
        \\exa          Exa web search API key     not set
        \\brave        Brave web search API key   not set
        \\
        \\`billy login <service>` stores a key
        \\
    );
}
test "the listing shows a stored name billy does not know" {
    // A provider the configuration named has its key stored under that name, so the listing has to
    // show it or the user cannot tell it is set.
    const listing: Listing = .{ .stored = &.{.{ .name = "a-very-long-provider-name", .key = "k" }} };
    try expectListingHas(listing, "a-very-long-provider-name  a service billy does not know  stored");
    // The columns widened to fit the long name and the label, so the known rows are padded to match
    // rather than running short.
    try expectListingHas(listing, "deepseek                   DeepSeek API key               not set");
}
test "the listing names a catalog provider whose key is stored" {
    const listing: Listing = .{ .stored = &.{.{ .name = "xai", .key = "k" }} };
    try expectListingHas(listing, "a provider in the model catalog");
    try expectListingLacks(listing, "a service billy does not know");
}
test "a key is stored only for a name something will ask for" {
    try std.testing.expect(acceptable("deepseek", &.{}));
    try std.testing.expect(acceptable("tavily", &.{}));

    try std.testing.expect(acceptable("mock", &.{"mock"}));
    try std.testing.expect(acceptable("mock", &.{ "other", "mock" }));

    // Anything else is a key no request would ever carry, so storing it would only look like it
    // worked.
    try std.testing.expect(!acceptable("mock", &.{}));
    try std.testing.expect(!acceptable("deepseekk", &.{ "deepseek", "opencode-go" }));
    try std.testing.expect(!acceptable("", &.{"mock"}));
}

test "the listing names the providers the configuration defines" {
    const shown = try renderListing(std.testing.allocator, .{ .providers = &.{"mock"} });
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, "mock         a provider the configuration names  not set") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shown, "deepseek"));
    try std.testing.expect(std.mem.find(u8, shown, "a provider the configuration names") != null);
}
test "the listing shows a key under a name nothing names any more" {
    const listing: Listing = .{
        .stored = &.{.{ .name = "gone", .key = "k" }},
        .providers = &.{"mock"},
    };
    try expectListingHas(listing, "gone");
    try expectListingHas(listing, "a service billy does not know");
}
fn expectLoadError(data: []const u8, expected: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = data });
    try std.testing.expectError(expected, load(std.testing.io, tmp.dir, arena));
}

test "load refuses a damaged or future credentials file" {
    try expectLoadError("{", error.CorruptCredentials);
    try expectLoadError("{\"version\":99}", error.UnsupportedCredentialsVersion);
    // A version that is not a version is refused rather than cast, which would trap in a safe build.
    try expectLoadError("{\"version\":-1}", error.CorruptCredentials);
    try expectLoadError("{\"version\":4294967296}", error.CorruptCredentials);
}
