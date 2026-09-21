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
const Io = std.Io;
const models = @import("models.zig");
const search = @import("search.zig");

/// Name of the file the credentials are kept in, in the billy data directory.
pub const file_name = "credentials.json";
/// Layout of the credentials file, bumped when its shape changes.
const format_version = 1;
/// Longest credentials file read back, so a damaged file cannot exhaust memory.
const max_credentials_bytes = 1 << 20;
/// The mode the file is written with. A key is a secret, so the file is kept to
/// the owner, unlike the configuration, which holds no secret.
const secret_mode: Io.File.Permissions = @enumFromInt(0o600);

/// A service billy needs a credential for.
pub const Service = enum {
    deepseek,
    openai,
    tavily,

    /// The name the service is stored and typed under, which is the variant's.
    pub fn name(service: Service) []const u8 {
        return @tagName(service);
    }

    /// The environment variable a key is read from when none is stored, which is
    /// where billy read it before it could store one.
    pub fn variable(service: Service) []const u8 {
        return switch (service) {
            .deepseek => "DEEPSEEK_API_KEY",
            .openai => "OPENAI_API_KEY",
            .tavily => "TAVILY_API_KEY",
        };
    }

    /// What the key is for, as the listing shows it.
    pub fn purpose(service: Service) []const u8 {
        return switch (service) {
            .deepseek => "DeepSeek API key",
            .openai => "OpenAI API key",
            .tavily => "Tavily web search API key",
        };
    }

    /// Every service, in the order the listing shows them.
    pub fn all() []const Service {
        return std.enums.values(Service);
    }

    /// The service called `text`, or null when it is not one.
    pub fn fromName(text: []const u8) ?Service {
        return std.meta.stringToEnum(Service, text);
    }
};

/// The service holding the key for the model endpoint of `provider`.
pub fn modelService(provider: models.Provider) Service {
    return switch (provider) {
        .deepseek => .deepseek,
    };
}

/// The service holding the key for the search backend `provider`.
pub fn searchService(provider: search.Provider) Service {
    return switch (provider) {
        .tavily => .tavily,
    };
}

/// The credential for `service`: the stored one when there is one, and the
/// service's environment variable otherwise. A stored credential is what
/// `billy login` put there, so it is the key the user asked billy to use.
pub fn credential(
    store: *const Store,
    environ: *const std.process.Environ.Map,
    service: Service,
) ?[]const u8 {
    if (store.get(service)) |key| return key;
    return environ.get(service.variable());
}

/// The model key for the endpoint at `base_url`: the credential of the provider
/// the endpoint names. An endpoint billy does not recognize, such as a proxy or
/// a self-hosted server, falls back to the model services in the order their
/// variables were read before a credential could be stored, so a shell that
/// exports one keeps working.
pub fn modelKey(
    store: *const Store,
    environ: *const std.process.Environ.Map,
    base_url: []const u8,
) ?[]const u8 {
    if (models.Provider.fromUrl(base_url)) |provider| {
        return credential(store, environ, modelService(provider));
    }
    return credential(store, environ, .deepseek) orelse credential(store, environ, .openai);
}

/// The credentials billy holds, one field per service, named after it and
/// holding the key stored for it, or null when none is. The fields are the
/// services billy needs a key for, so a field and a service cannot drift apart:
/// `get` and `put` name the field after the service, which a service without
/// one would not compile through.
///
/// The keys are allocated from the arena the process runs in, which owns them
/// along with the store, so there is nothing to free.
pub const Store = struct {
    deepseek: ?[]const u8 = null,
    openai: ?[]const u8 = null,
    tavily: ?[]const u8 = null,

    /// The key stored for `service`, or null when none is.
    pub fn get(store: *const Store, service: Service) ?[]const u8 {
        // `inline else` makes the variant comptime-known, so the field it names
        // is looked up at compile time and a missing one is a compile error.
        switch (service) {
            inline else => |which| return @field(store, @tagName(which)),
        }
    }

    /// Stores `key` for `service`, replacing the one already there. `arena` owns
    /// the key, which outlives the file being written.
    pub fn put(store: *Store, arena: std.mem.Allocator, service: Service, key: []const u8) !void {
        const owned = try arena.dupe(u8, key);
        switch (service) {
            inline else => |which| @field(store, @tagName(which)) = owned,
        }
    }
};

/// The credentials file as it is written to and read from disk. The store is
/// kept under a field of its own so the version is not mistaken for a service,
/// and so the services are written as the fields they are rather than listed
/// twice. A service with no stored key is left out of the file.
const Stored = struct {
    version: u32 = format_version,
    credentials: Store = .{},
};

/// Reads the stored credentials from `dir`. A missing file is an empty store,
/// which is what a user who has never logged in has.
pub fn load(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !Store {
    const text = dir.readFileAlloc(io, file_name, arena, .limited(max_credentials_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const stored = std.json.parseFromSliceLeaky(Stored, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CorruptCredentials;
    if (stored.version > format_version) return error.UnsupportedCredentialsVersion;
    return stored.credentials;
}

/// Writes the credentials to `file_name` in `dir`. The previous contents are
/// replaced in one step, leaving them intact if writing fails part way, and the
/// new file is readable by the owner alone. A service with no stored key is
/// written as nothing at all, so the file holds the keys there are.
///
/// It is written indented rather than compact, like the configuration and unlike
/// a session file, since a file a user may open to look at is worth reading.
pub fn save(store: *const Store, io: Io, dir: Io.Dir, gpa: std.mem.Allocator) !void {
    const text = try std.json.Stringify.valueAlloc(
        gpa,
        Stored{ .credentials = store.* },
        .{ .emit_null_optional_fields = false, .whitespace = .indent_2 },
    );
    defer gpa.free(text);

    var atomic = try dir.createFileAtomic(io, file_name, .{
        .replace = true,
        .permissions = secret_mode,
    });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file: Io.File.Writer = .init(atomic.file, io, &buffer);
    try file.interface.writeAll(text);
    try file.flush();
    try atomic.replace(io);
}

/// Runs the `login` command: with no service, lists the services and where each
/// key comes from; with one, reads a key for it and stores it. `dir_path` is the
/// directory the credentials are kept in, named in what is printed.
pub fn run(
    io: Io,
    out: *Io.Writer,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    dir_path: []const u8,
    store: *Store,
    environ: *const std.process.Environ.Map,
    service_name: ?[]const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ dir_path, file_name });
    if (service_name) |name| return login(io, out, arena, gpa, dir, path, store, name);
    try list(out, arena, store, environ, path);
}

/// Reads a key for the named service and stores it, so the next run uses it.
fn login(
    io: Io,
    out: *Io.Writer,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    path: []const u8,
    store: *Store,
    name: []const u8,
) !void {
    const service = Service.fromName(name) orelse {
        std.log.err("'{s}' is not a service billy knows; run `billy login` to list them", .{name});
        return error.UnknownService;
    };

    const prompt = try std.fmt.allocPrint(arena, "Enter {s}: ", .{service.purpose()});
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

    try store.put(arena, service, key);
    save(store, io, dir, gpa) catch |err| {
        std.log.err("cannot write the credentials in {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    try out.print("stored the {s} key in {s}\n", .{ service.name(), path });
}

/// Prints the services billy needs a key for, each with the key it has: the
/// stored one, the one in its environment variable, or none.
fn list(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    store: *const Store,
    environ: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    const services = Service.all();
    var name_width: usize = 0;
    var purpose_width: usize = 0;
    for (services) |service| {
        name_width = @max(name_width, service.name().len);
        purpose_width = @max(purpose_width, service.purpose().len);
    }

    for (services) |service| {
        const status = if (store.get(service) != null)
            "stored"
        else if (environ.get(service.variable()) != null)
            try std.fmt.allocPrint(arena, "set in {s}", .{service.variable()})
        else
            "not set";
        try out.print("{s}", .{service.name()});
        try spaces(out, name_width - service.name().len);
        try out.writeAll("  ");
        try out.print("{s}", .{service.purpose()});
        try spaces(out, purpose_width - service.purpose().len);
        try out.print("  {s}\n", .{status});
    }
    try out.print("\n`billy login <service>` stores a key in {s}\n", .{path});
}

fn spaces(out: *Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.writeAll(" ");
}

/// Reads one line from the terminal, with echo off so a key is not left on the
/// screen or in the scrollback. `prompt` is shown only when there is a terminal
/// to type at; without one the line is read as it comes, which is what lets a
/// key be piped in.
///
/// Returns null at end of input, before anything was typed.
fn readSecret(
    io: Io,
    out: *Io.Writer,
    arena: std.mem.Allocator,
    prompt: []const u8,
) !?[]const u8 {
    const interactive = try Io.File.stdin().isTty(io);
    const saved = if (interactive) saved: {
        try out.writeAll(prompt);
        try out.flush();
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var quiet = saved;
        quiet.lflag.ECHO = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, quiet);
        break :saved saved;
    } else null;
    defer if (saved) |term| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, term) catch {};
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

test "a service names its variable and what its key is for" {
    try std.testing.expectEqualStrings("deepseek", Service.deepseek.name());
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", Service.deepseek.variable());
    try std.testing.expectEqualStrings("TAVILY_API_KEY", Service.tavily.variable());
    try std.testing.expectEqualStrings("DeepSeek API key", Service.deepseek.purpose());

    try std.testing.expectEqual(Service.tavily, Service.fromName("tavily").?);
    try std.testing.expect(Service.fromName("google") == null);
    try std.testing.expectEqual(3, Service.all().len);
}

test "load of a file that is not there is an empty store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(store.get(.tavily) == null);
}

test "every service has a field, and one does not stand in for another" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var store: Store = .{};
    for (Service.all()) |service| {
        try std.testing.expect(store.get(service) == null);
        // The service's own name is the key, so every field is told apart by
        // what it holds where two would read alike.
        try store.put(allocator, service, service.name());
    }
    for (Service.all()) |service| {
        try std.testing.expectEqualStrings(service.name(), store.get(service).?);
    }
}

test "a stored key survives a save and a load" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    try store.put(allocator, .tavily, "tvly-secret");
    try store.put(allocator, .deepseek, "sk-secret");
    try save(&store, std.testing.io, tmp.dir, gpa);

    const loaded = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly-secret", loaded.get(.tavily).?);
    try std.testing.expectEqualStrings("sk-secret", loaded.get(.deepseek).?);
    try std.testing.expect(loaded.get(.openai) == null);
}

test "the file holds a field per service that has a key, and nothing else" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    try store.put(allocator, .tavily, "tvly-secret");
    try save(&store, std.testing.io, tmp.dir, gpa);

    const text = try tmp.dir.readFileAlloc(std.testing.io, file_name, allocator, .limited(max_credentials_bytes));
    // The service is a field named after it; a service with no key is left out
    // rather than written as null. The file is indented, so it is readable by
    // the user it belongs to.
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "credentials": {
        \\    "tavily": "tvly-secret"
        \\  }
        \\}
    , text);
}

test "put replaces the key already stored for a service" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var store: Store = .{};
    try store.put(allocator, .tavily, "old");
    try store.put(allocator, .tavily, "new");

    try std.testing.expectEqualStrings("new", store.get(.tavily).?);
}

test "the credentials file is written for the owner alone" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    try store.put(arena_state.allocator(), .tavily, "secret");
    try save(&store, std.testing.io, tmp.dir, gpa);

    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "load reads a key written for a service, and leaves an unknown field alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written by a newer billy, with a service this one does not know.
    // The field it cannot place is ignored, as the configuration's unknown
    // fields are, rather than making the file unusable.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"credentials\":{\"future\":\"f\",\"tavily\":\"tvly\"}}",
    });

    const store = try load(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqualStrings("tvly", store.get(.tavily).?);
    try std.testing.expect(store.get(.deepseek) == null);
}

test "a stored key is used before the environment, which is the fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put("TAVILY_API_KEY", "from-env");

    var store: Store = .{};
    // Not stored: the environment variable supplies the key.
    try std.testing.expectEqualStrings("from-env", credential(&store, &environ, .tavily).?);
    // Stored: it is the one used, environment or not.
    try store.put(allocator, .tavily, "from-store");
    try std.testing.expectEqualStrings("from-store", credential(&store, &environ, .tavily).?);
    // Neither: no key at all.
    try std.testing.expect(credential(&store, &environ, .openai) == null);
}

test "modelKey follows the endpoint and falls back to the variables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "openai-env");

    var store: Store = .{};
    // A known endpoint asks its provider's service, and the environment variable
    // answers when nothing is stored.
    try std.testing.expect(modelKey(&store, &environ, "https://api.deepseek.com") == null);
    try environ.put("DEEPSEEK_API_KEY", "deepseek-env");
    try std.testing.expectEqualStrings(
        "deepseek-env",
        modelKey(&store, &environ, "https://api.deepseek.com").?,
    );
    try store.put(allocator, .deepseek, "deepseek-stored");
    try std.testing.expectEqualStrings(
        "deepseek-stored",
        modelKey(&store, &environ, "https://api.deepseek.com").?,
    );

    // An endpoint billy does not recognize keeps the old order of the model
    // variables, and the OpenAI key is found behind the DeepSeek one.
    var no_store: Store = .{};
    var bare: std.process.Environ.Map = .init(allocator);
    defer bare.deinit();
    try bare.put("OPENAI_API_KEY", "openai-env");
    try std.testing.expectEqualStrings(
        "openai-env",
        modelKey(&no_store, &bare, "https://example.com/v1").?,
    );
    try bare.put("DEEPSEEK_API_KEY", "deepseek-env");
    try std.testing.expectEqualStrings(
        "deepseek-env",
        modelKey(&no_store, &bare, "https://example.com/v1").?,
    );
}

test "the listing shows each service and where its key comes from" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put("TAVILY_API_KEY", "tvly-env");

    var store: Store = .{};
    try store.put(allocator, .deepseek, "sk-secret");

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, allocator, &store, &environ, "/data/billy/credentials.json");

    try std.testing.expectEqualStrings(
        \\deepseek  DeepSeek API key           stored
        \\openai    OpenAI API key             not set
        \\tavily    Tavily web search API key  set in TAVILY_API_KEY
        \\
        \\`billy login <service>` stores a key in /data/billy/credentials.json
        \\
    , sink.written());
}

test "the listing names a service that has no key of any kind" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();

    const store: Store = .{};
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try list(&sink.writer, allocator, &store, &environ, "/c");

    try std.testing.expectEqualStrings(
        \\deepseek  DeepSeek API key           not set
        \\openai    OpenAI API key             not set
        \\tavily    Tavily web search API key  not set
        \\
        \\`billy login <service>` stores a key in /c
        \\
    , sink.written());
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
