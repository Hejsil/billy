//! The credentials billy needs, and where it keeps the ones the user stores.
//!
//! Every service billy talks to needs a key: the model endpoint needs one, and
//! so does the web search backend. `billy login <service>` reads a key and
//! stores it, so it does not have to be exported in the environment before every
//! run. The keys are kept in `credentials.json` under the data directory,
//! written so only the owner can read it, since a key is a secret. They are not
//! kept with the configuration, which is meant to be shared between machines,
//! and a key is not.
//!
//! The environment still works: a key that is not stored is read from the
//! service's variable, which is where billy read it before it could store one.
//! A stored key is the one used, since logging in is the user saying which key
//! to use.

const std = @import("std");
const models = @import("models.zig");
const settings = @import("Terminal/settings.zig");
const Tools = @import("Tools.zig");

/// Name of the file the credentials are kept in, in the billy data directory.
pub const file_name = "credentials.json";

/// The mode the file is written with. A key is a secret, so the file is kept to
/// the owner, unlike the configuration, which holds no secret.
const secret_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));

/// A service billy is shipped knowing, so the listing can name what a key is for
/// and `billy login` can be told which one it is.
///
/// A service is a name rather than a fixed set, because the providers of the
/// model endpoint are configured: a name in `config.json` under `providers` has
/// a key stored under that same name, and one billy does not know is stored and
/// read the same way.
pub const Known = struct {
    /// The name the key is stored and typed under.
    name: []const u8,
    /// What the key is for, as the listing shows it.
    purpose: []const u8,
};

/// The services billy knows, in the order the listing shows them.
pub const known = [_]Known{
    .{ .name = "deepseek", .purpose = "DeepSeek API key" },
    .{ .name = "opencode_go", .purpose = "OpenCode Go API key" },
    .{ .name = "openai", .purpose = "OpenAI API key" },
    .{ .name = "tavily", .purpose = "Tavily web search API key" },
    .{ .name = "exa", .purpose = "Exa web search API key" },
    .{ .name = "brave", .purpose = "Brave web search API key" },
};

/// What the key for `name` is for, or null when billy does not know the name.
pub fn purposeOf(name: []const u8) ?[]const u8 {
    for (known) |service| {
        if (std.mem.eql(u8, service.name, name)) return service.purpose;
    }
    return null;
}

/// The service holding the key for the search backend `provider`, or null for
/// one that needs no key. SearXNG is self-hosted, so the user's own.
pub fn searchService(provider: Tools.web.Search.Provider) ?[]const u8 {
    return switch (provider) {
        .tavily => "tavily",
        .exa => "exa",
        .brave => "brave",
        .searxng => null,
    };
}

/// The service holding the key for the fetch backend `provider`. `raw` reads the
/// url itself and asks no service, so it has none.
pub fn fetchService(provider: Tools.web.Fetch.Provider) ?[]const u8 {
    return switch (provider) {
        .tavily => "tavily",
        .exa => "exa",
        .raw => null,
    };
}

/// The credentials billy holds, one key per service name: the model provider a
/// request is sent to, and the web backends a tool asks.
///
/// The names come from the configuration rather than a fixed set, so the store
/// holds whatever has been stored under whatever name. The keys are allocated
/// from the arena the process runs in, which owns them along with the store, so
/// there is nothing to free.
pub const Store = struct {
    keys: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    /// The key stored for `name`, or null when none is.
    pub fn get(store: *const Store, name: []const u8) ?[]const u8 {
        return store.keys.get(name);
    }

    /// Stores `key` under `name`, replacing the one already there. The arena
    /// owns both strings, which outlive the file being written.
    pub fn put(store: *Store, arena: std.mem.Allocator, name: []const u8, key: []const u8) !void {
        const owned_name = try arena.dupe(u8, name);
        const owned_key = try arena.dupe(u8, key);
        try store.keys.put(arena, owned_name, owned_key);
    }

    /// Every name a key is stored under, in the order the file holds them.
    pub fn names(store: *const Store) []const []const u8 {
        return store.keys.keys();
    }
};

/// The version of the file this billy writes. Bumped when its shape changes, so
/// a file from a newer billy is refused rather than read as a shape it is not.
const format_version: u32 = 1;

/// Reads the stored credentials from `dir`. A missing file is an empty store,
/// which is what a user who has never logged in has.
///
/// The file is read as the JSON it is rather than into a type of fields, because
/// the names are the user's: a provider the configuration named has its key
/// stored under that name, which no fixed set of fields could hold.
pub fn load(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) !Store {
    const text = dir.readFileAlloc(io, file_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
        return error.CorruptCredentials;
    const object = switch (parsed) {
        .object => |object| object,
        else => return error.CorruptCredentials,
    };
    // A version billy does not know is refused before anything is read out of
    // the file, since a newer shape may put different things under the names. A
    // file without one is read as the current shape, which is what every file
    // billy writes is.
    if (object.get("version")) |reported| {
        const version: u32 = switch (reported) {
            .integer => |value| @intCast(value),
            else => return error.CorruptCredentials,
        };
        if (version > format_version) return error.UnsupportedCredentialsVersion;
    }

    const stored = switch (object.get("credentials") orelse return .{}) {
        .object => |stored| stored,
        else => return error.CorruptCredentials,
    };
    var result: Store = .{};
    var it = stored.iterator();
    while (it.next()) |entry| {
        // A key is text; anything else under a name is a shape billy never
        // wrote, and is refused rather than read as a name with no key.
        const key = switch (entry.value_ptr.*) {
            .string => |key| key,
            else => return error.CorruptCredentials,
        };
        try result.put(arena, entry.key_ptr.*, key);
    }
    return result;
}

/// Writes the credentials to `file_name` in `dir`. The previous contents are
/// replaced in one step, leaving them intact if writing fails part way, and the
/// new file is readable by the owner alone. A service with no stored key is
/// written as nothing at all, so the file holds the keys there are.
///
/// It is written indented rather than compact, like the configuration and unlike
/// a session file, since a file a user may open to look at is worth reading. The
/// JSON is streamed straight onto the file, so writing it allocates nothing.
pub fn save(store: *const Store, io: std.Io, dir: std.Io.Dir) !void {
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
    try writeStored(store, &json);
    try file.flush();
    try atomic.replace(io);
}

/// Writes the store as the file's own shape: the version, then the names as the
/// keys of an object and the keys as its values. Written by hand rather than
/// through a value, since the store's names are the user's and are not a set of
/// fields anything could be built from.
fn writeStored(store: *const Store, json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("version");
    try json.write(format_version);
    try json.objectField("credentials");
    try json.beginObject();
    for (store.keys.keys(), store.keys.values()) |name, key| {
        try json.objectField(name);
        try json.write(key);
    }
    try json.endObject();
    try json.endObject();
}

/// Whether a key can be stored for `name`: a service billy ships, or one the
/// configuration names. Any other name is one no request will ever ask for, so
/// storing a key under it would only look like it worked.
fn acceptable(name: []const u8, providers: []const []const u8) bool {
    if (purposeOf(name) != null) return true;
    for (providers) |defined| {
        if (std.mem.eql(u8, defined, name)) return true;
    }
    return false;
}

/// Reads a key for `name` and stores it, so the next run uses it.
///
/// `providers` are the names the configuration defines, which are the other
/// services a key may be stored for: a name billy does not ship is one only the
/// file that names it can make sense of, so a key stored under any other is one
/// nothing will ever read.
pub fn login(
    io: std.Io,
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    store: *Store,
    providers: []const []const u8,
    name: []const u8,
) !void {
    if (!acceptable(name, providers)) {
        std.log.err(
            "'{s}' is neither a service billy knows nor a provider the configuration names;" ++
                " run `billy login` to list them, or name it under `providers` in the configuration",
            .{name},
        );
        return error.UnknownService;
    }

    const purpose = purposeOf(name) orelse name;
    const prompt = try std.fmt.allocPrint(arena, "Enter {s}: ", .{purpose});
    const key = (try readSecret(io, out, arena, prompt)) orelse {
        std.log.err("no key read", .{});
        return error.MissingCredential;
    };
    // An empty key would be stored as a credential that cannot work, which is
    // worse than having none: the service would be offered and always fail.
    if (key.len == 0) {
        std.log.err("no key given, nothing stored", .{});
        return error.MissingCredential;
    }

    try store.put(arena, name, key);
    save(store, io, dir) catch |err| {
        std.log.err("cannot write the credentials: {s}", .{@errorName(err)});
        return err;
    };
    try out.print("stored the {s} key\n", .{name});
}

/// What a provider the configuration names is listed as. Only the file that
/// named it knows what it is for, so what it is for is not the thing to say.
const configured_purpose = "a provider the configuration names";

/// What a name neither billy nor the configuration knows is listed as. A key is
/// still shown for it, since it is in the file, but nothing reads it.
const dangling_purpose = "a service billy does not know";

/// Prints every name a key can be stored for, and whether one is: the services
/// billy ships, the providers the configuration names, and any other name a key
/// is stored under. The last are listed rather than hidden, so a file written by
/// hand or by a billy whose configuration has since changed is not a mystery.
pub fn list(out: *std.Io.Writer, store: *const Store, providers: []const []const u8) !void {
    // Every row that will be printed decides the columns, so a long name of the
    // user's own widens them all rather than running past the end.
    var name_width: usize = 0;
    var purpose_width: usize = 0;
    for (known) |service| {
        name_width = @max(name_width, service.name.len);
        purpose_width = @max(purpose_width, service.purpose.len);
    }
    for (providers) |name| {
        name_width = @max(name_width, name.len);
        purpose_width = @max(purpose_width, configured_purpose.len);
    }
    for (store.names()) |name| {
        name_width = @max(name_width, name.len);
        if (purposeOf(name) == null and !definedIn(name, providers)) {
            purpose_width = @max(purpose_width, dangling_purpose.len);
        }
    }

    for (known) |service| {
        try printRow(out, service.name, service.purpose, name_width, purpose_width, store.get(service.name) != null);
    }
    for (providers) |name| {
        // One billy already knows was printed as the service it is, with what
        // its key is for rather than where it came from.
        if (purposeOf(name) != null) continue;
        try printRow(out, name, configured_purpose, name_width, purpose_width, store.get(name) != null);
    }
    for (store.names()) |name| {
        if (purposeOf(name) != null) continue;
        if (definedIn(name, providers)) continue;
        try printRow(out, name, dangling_purpose, name_width, purpose_width, true);
    }
    try out.print("\n`billy login <service>` stores a key\n", .{});
}

/// Whether the configuration names `name` as one of its providers.
fn definedIn(name: []const u8, providers: []const []const u8) bool {
    for (providers) |defined| {
        if (std.mem.eql(u8, defined, name)) return true;
    }
    return false;
}

/// One line of the listing: the name, what its key is for, and where the key is.
fn printRow(
    out: *std.Io.Writer,
    name: []const u8,
    purpose: []const u8,
    name_width: usize,
    purpose_width: usize,
    stored: bool,
) !void {
    try out.print("{s}", .{name});
    try out.splatByteAll(' ', name_width - name.len);
    try out.writeAll("  ");
    try out.print("{s}", .{purpose});
    try out.splatByteAll(' ', purpose_width - purpose.len);
    try out.writeAll("  ");
    try out.writeAll(if (stored) "stored" else "not set");
    try out.writeAll("\n");
}

/// Reads one line from the terminal, with echo off so a key is not left on the
/// screen or in the scrollback. `prompt` is shown only when there is a terminal
/// to type at; without one the line is read as it comes, which is what lets a
/// key be piped in.
///
/// Returns null at end of input, before anything was typed.
fn readSecret(
    io: std.Io,
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    prompt: []const u8,
) !?[]const u8 {
    const interactive = try std.Io.File.stdin().isTty(io);
    const saved = if (interactive) saved: {
        try out.writeAll(prompt);
        try out.flush();
        const saved = try settings.get(std.posix.STDIN_FILENO);
        var quiet = saved;
        quiet.lflag.ECHO = false;
        try settings.set(std.posix.STDIN_FILENO, quiet);
        break :saved saved;
    } else null;
    defer if (saved) |term| {
        settings.set(std.posix.STDIN_FILENO, term) catch {};
        // The Enter the user pressed was not echoed, so the line is ended here
        // rather than left for the next thing printed to start on.
        out.writeAll("\n") catch {};
        out.flush() catch {};
    };

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(arena);
    var buffer: [256]u8 = undefined;
    while (true) {
        const len = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (len == 0) {
            // End of input: a key piped in without a trailing newline is still
            // the key, so only a read that got nothing at all is no key.
            if (line.items.len == 0) return null;
            break;
        }
        if (std.mem.indexOfScalar(u8, buffer[0..len], '\n')) |newline| {
            try line.appendSlice(arena, buffer[0..newline]);
            break;
        }
        try line.appendSlice(arena, buffer[0..len]);
    }
    // A key is a token: the carriage return a terminal ends the line with, and
    // any space a paste brought along, are not part of it.
    return try arena.dupe(u8, std.mem.trim(u8, line.items, &std.ascii.whitespace));
}

test "a service billy knows says what a key for it is for" {
    try std.testing.expectEqualStrings("DeepSeek API key", purposeOf("deepseek").?);
    try std.testing.expectEqualStrings("Tavily web search API key", purposeOf("tavily").?);
    // A name billy does not know is not a service it can describe, which is
    // what lets `billy login` accept one anyway.
    try std.testing.expect(purposeOf("mock") == null);
    try std.testing.expectEqual(6, known.len);
}

test "load of a file that is not there is an empty store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(store.get("tavily") == null);
}

test "a key is stored under its own name, known to billy or not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var store: Store = .{};
    for (known) |service| {
        try std.testing.expect(store.get(service.name) == null);
        // The name is the key, so two services never read alike.
        try store.put(allocator, service.name, service.name);
    }
    // A name the configuration invented is stored and read the same way, which
    // is the whole point: the providers of the model endpoint are the user's to
    // name.
    try store.put(allocator, "mock", "mock-key");
    try std.testing.expectEqual(@as(usize, known.len + 1), store.names().len);

    for (known) |service| {
        try std.testing.expectEqualStrings(service.name, store.get(service.name).?);
    }
    try std.testing.expectEqualStrings("mock-key", store.get("mock").?);
}

test "a stored key survives a save and a load" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    try store.put(allocator, "tavily", "tvly-secret");
    try store.put(allocator, "deepseek", "sk-secret");
    try store.put(allocator, "mock", "mock-secret");
    try save(&store, std.testing.io, tmp.dir);

    const loaded = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly-secret", loaded.get("tavily").?);
    try std.testing.expectEqualStrings("sk-secret", loaded.get("deepseek").?);
    // A name billy has never heard of comes back as it was written, which is
    // what makes a provider named in the configuration work.
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

    var store: Store = .{};
    try store.put(allocator, "tavily", "tvly-secret");
    try save(&store, std.testing.io, tmp.dir);

    const text = try tmp.dir.readFileAlloc(std.testing.io, file_name, allocator, .unlimited);
    // The names are the object's keys; a name with no key is left out rather
    // than written as null. The file is indented, so it is readable by the user
    // it belongs to.
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

    var store: Store = .{};
    try store.put(allocator, "tavily", "old");
    try store.put(allocator, "tavily", "new");

    try std.testing.expectEqualStrings("new", store.get("tavily").?);
    try std.testing.expectEqual(@as(usize, 1), store.names().len);
}

test "the credentials file is written for the owner alone" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    try store.put(arena_state.allocator(), "tavily", "secret");
    try save(&store, std.testing.io, tmp.dir);

    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "load reads a key written for a name this billy does not know" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name billy has no use for of its own is still a key the user stored,
    // so it is kept: the configuration may well be the thing that names it.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"credentials\":{\"future\":\"f\",\"tavily\":\"tvly\"}}",
    });

    const store = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly", store.get("tavily").?);
    try std.testing.expectEqualStrings("f", store.get("future").?);
    try std.testing.expect(store.get("deepseek") == null);
}

test "the listing shows each service billy knows and whether a key is stored" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var store: Store = .{};
    try store.put(allocator, "deepseek", "sk-secret");

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, &store, &.{});

    try std.testing.expectEqualStrings(
        \\deepseek     DeepSeek API key           stored
        \\opencode_go  OpenCode Go API key        not set
        \\openai       OpenAI API key             not set
        \\tavily       Tavily web search API key  not set
        \\exa          Exa web search API key     not set
        \\brave        Brave web search API key   not set
        \\
        \\`billy login <service>` stores a key
        \\
    , sink.written());
}

test "the listing names a service that has no key of any kind" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const store: Store = .{};
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, &store, &.{});

    try std.testing.expectEqualStrings(
        \\deepseek     DeepSeek API key           not set
        \\opencode_go  OpenCode Go API key        not set
        \\openai       OpenAI API key             not set
        \\tavily       Tavily web search API key  not set
        \\exa          Exa web search API key     not set
        \\brave        Brave web search API key   not set
        \\
        \\`billy login <service>` stores a key
        \\
    , sink.written());
}

test "the listing shows a stored name billy does not know" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A provider the configuration named has its key stored under that name, so
    // the listing has to show it or the user cannot tell it is set.
    var store: Store = .{};
    try store.put(allocator, "a-very-long-provider-name", "k");

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, &store, &.{});

    try std.testing.expect(std.mem.indexOf(
        u8,
        sink.written(),
        "a-very-long-provider-name  a service billy does not know  stored",
    ) != null);
    // The columns widened to fit the long name and the label, so the known rows
    // are padded to match rather than running short.
    try std.testing.expect(std.mem.indexOf(
        u8,
        sink.written(),
        "a-very-long-provider-name  a service billy does not know  stored",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sink.written(),
        "deepseek                   DeepSeek API key               not set",
    ) != null);
}

test "a key is stored only for a name something will ask for" {
    // A service billy ships is always acceptable, since it knows what the key is
    // for and a request may be sent with it.
    try std.testing.expect(acceptable("deepseek", &.{}));
    try std.testing.expect(acceptable("tavily", &.{}));

    // One the configuration names is acceptable too, which is how a provider of
    // the user's own is reached.
    try std.testing.expect(acceptable("mock", &.{"mock"}));
    try std.testing.expect(acceptable("mock", &.{ "other", "mock" }));

    // Anything else is a key no request would ever carry, so storing it would
    // only look like it worked.
    try std.testing.expect(!acceptable("mock", &.{}));
    try std.testing.expect(!acceptable("deepseekk", &.{ "deepseek", "opencode_go" }));
    try std.testing.expect(!acceptable("", &.{"mock"}));
}

test "the listing names the providers the configuration defines" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const store: Store = .{};
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, &store, &.{"mock"});

    // A provider the configuration names is one a key can be stored for, so the
    // listing shows it: `billy login` with no service is where a user looks to
    // find out what to type.
    try std.testing.expect(std.mem.indexOf(
        u8,
        sink.written(),
        "mock         a provider the configuration names  not set",
    ) != null);
    // One billy already knows is listed as the service it is, not as something
    // the configuration happened to name.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.written(), "deepseek"));
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "a provider the configuration names") != null);
}

test "the listing shows a key under a name nothing names any more" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A key stored by hand, or by a billy whose configuration has since changed,
    // is still in the file; showing it says why nothing uses it.
    var store: Store = .{};
    try store.put(allocator, "gone", "k");

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, &store, &.{"mock"});

    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "gone") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "a service billy does not know") != null);
}

test "load refuses a damaged or future credentials file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{" });
    try std.testing.expectError(error.CorruptCredentials, load(std.testing.io, tmp.dir, allocator));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"version\":99}" });
    try std.testing.expectError(error.UnsupportedCredentialsVersion, load(std.testing.io, tmp.dir, allocator));
}

test "a backend billy reaches has a service name, and a self-hosted one does not" {
    // Every backend but SearXNG is reached with a key, which is what a service
    // name is. SearXNG is the user's own, so it has none.
    try std.testing.expectEqualStrings("tavily", searchService(.tavily).?);
    try std.testing.expectEqualStrings("exa", searchService(.exa).?);
    try std.testing.expectEqualStrings("brave", searchService(.brave).?);
    try std.testing.expect(searchService(.searxng) == null);

    try std.testing.expectEqualStrings("tavily", fetchService(.tavily).?);
    try std.testing.expectEqualStrings("exa", fetchService(.exa).?);
    try std.testing.expect(fetchService(.raw) == null);
}
