//! Configuration: the settings read from a JSON file under the XDG config
//! directory, so that a run can be tuned without rebuilding the binary.
//!
//! The file lives at `$XDG_CONFIG_HOME/billy/config.json`, or
//! `$HOME/.config/billy/config.json` when that is unset. It is written with the
//! defaults the first time it is needed, which is also how the settings that
//! exist are discovered. Unknown fields are ignored, so a file written by a
//! newer billy does not break an older one.

const std = @import("std");
const models = @import("models.zig");
const toolset = @import("Tools.zig");

const Config = @This();

/// Directory under the XDG config directory that holds the configuration.
const app_dir = "billy";

/// Name of the configuration file inside that directory.
pub const file_name = "config.json";

/// What `open` found, including whether the file had to be written.
pub const Opened = struct {
    config: Config,
    /// Whether the file was missing and has just been written with defaults.
    created: bool,
};

/// Settings for the tools the agent can call, one group per tool.
pub const Tools = struct {
    bash: Bash = .{},
    web_search: WebSearch = .{},
    web_fetch: WebFetch = .{},
};

/// Settings for the web fetch tool.
pub const WebFetch = struct {
    /// The backends to read a url with, in the order they are tried: the first
    /// that reads it is used. Empty leaves `web_fetch` out of the tools the
    /// model is offered. `raw` is the url itself, read directly, which is what a
    /// call asking for the bytes as they are uses; a fresh configuration holds
    /// only that, so fetching works without a service to extract a page.
    ///
    /// The key a backend needs is read from the credential `billy login` stored
    /// for it, or from its environment variable when none is stored.
    providers: []const toolset.web.Fetch.Provider = &.{.raw},
};

/// Settings for the web search tool.
pub const WebSearch = struct {
    /// The backends to search with, in the order they are tried: the first that
    /// answers is used, so a backend that is down or rate-limited falls through
    /// to the next. Empty leaves web search out of the tools the model is
    /// offered, which is the default: a fresh configuration has no key to search
    /// with. The names are the variants of `Search.Provider`, and one billy does
    /// not know makes the file corrupt rather than reading as "no search".
    ///
    /// The key a backend needs is read from the credential `billy login` stored
    /// for it, or from its environment variable when none is stored, and never
    /// from this file, which is written to disk in the clear.
    providers: []const toolset.web.Search.Provider = &.{},
    /// Results asked for per query. The backend may return fewer, and billy caps
    /// it.
    max_results: usize = 5,
    /// Settings for the SearXNG backend, under its own name. A backend that billy
    /// knows the address of needs none of its own.
    searxng: Searxng = .{},

    /// Settings for SearXNG, which is self-hosted rather than a service billy
    /// knows the address of.
    pub const Searxng = struct {
        /// The instance to search with, such as `https://searx.example.org`. It
        /// must have the JSON format turned on, which SearXNG leaves off by
        /// default.
        url: ?[]const u8 = null,
    };
};

/// Settings for the bash tool.
pub const Bash = struct {
    /// Longest a command may run before it is killed, in seconds. A command that
    /// outlives this is killed, so a runaway command cannot hang the agent
    /// forever. Zero would kill every command as it starts, which is never what
    /// the file is meant to say, so it is rejected rather than read as "no
    /// limit"; set a large value for a command that legitimately runs long.
    timeout_s: usize = 120,
};

/// The configuration file as it is written to and read from disk. The settings
/// are the configuration's own, since the file holds exactly those.
const Stored = struct {
    version: u32 = 1,
    /// Which provider and model a new session asks for, as `provider/model`:
    /// `deepseek/deepseek-v4-flash`, `opencode_go/glm-5.3-flash`.
    ///
    /// It is one setting rather than two because the two halves are only
    /// meaningful together: a model id alone names no endpoint, and the model
    /// ids of two providers do not overlap enough for the provider to be
    /// guessed from one. A session keeps the choice it was started with, so
    /// changing this affects new sessions and not the ones in progress.
    model: []const u8 = "deepseek/deepseek-flash",
    /// The endpoints billy talks to that its own table does not name: a proxy, a
    /// server of the user's own, or a stand-in a test points a run at. Each is
    /// written as a provider name with the base URL its completions path is
    /// appended to, and named in `model` like any other provider.
    ///
    /// A name billy already knows may be given here too, which is how a proxy in
    /// front of a known provider is reached.
    providers: Providers = .{},
    max_turns: usize = 100,
    /// Blocks to replay on a resume. Zero shows the whole session.
    resume_blocks: usize = 10,
    /// Blocks of a session the web page shows when it is opened. Zero shows the
    /// whole session. It is its own setting rather than `resume_blocks` because
    /// the two are read on different things: a replay fills a terminal's screen,
    /// while the page is scrolled, so it wants far more of the conversation and
    /// still far less than all of it.
    web_blocks: usize = 200,
    /// How full the context window must be, as a whole percentage, before the
    /// conversation is compacted into a summary. Zero turns compaction off.
    compact_at: usize = 80,
    /// Whether billy asks the model for a short title for a session, after its
    /// first turn, so the web frontend can list it by name. Off asks for none,
    /// and a session is then listed by its id.
    title: bool = true,
    tools: Tools = .{},

    const default = Stored{};

    /// Whether the file is one billy can use: a version it knows, a turn limit
    /// above zero, and a bash timeout above zero. Zero turns would give the model
    /// no chance to answer at all, and a zero timeout would kill every command as
    /// it starts, neither of which is ever what the file is meant to say.
    fn validate(stored: Stored) !void {
        if (stored.version > Stored.default.version) return error.UnsupportedConfigVersion;
        if (stored.max_turns == 0) return error.InvalidConfig;
        if (stored.tools.bash.timeout_s == 0) return error.InvalidConfig;
        try stored.validateProviders();
        try stored.validateModel();
    }

    /// Whether the model setting names a provider billy can reach and a model of
    /// it. A model of a provider billy does not know is refused here rather than
    /// at the request, where it would fail as an endpoint it never had.
    fn validateModel(stored: Stored) !void {
        // Both halves are checked before either is judged: an empty setting has
        // no provider to be unknown, and saying so is less confusing than
        // calling the empty string a provider billy does not know.
        if (!stored.choice().isComplete()) return error.InvalidConfig;
        const name = stored.providerName();
        // A provider billy ships, or one the file defines itself: anything else
        // names no endpoint, and would fail at the request as one it never had.
        if (std.meta.stringToEnum(models.Provider, name) != null) return;
        if (stored.providers.has(name)) return;
        return error.UnknownProvider;
    }

    /// Whether every provider the file defines is one a request could be sent
    /// to: a name to write in `model`, and a URL to send it to.
    fn validateProviders(stored: Stored) !void {
        for (stored.providers.entries) |entry| {
            if (entry.name.len == 0) return error.InvalidConfig;
            if (entry.base_url.len == 0) return error.InvalidConfig;
        }
    }

    /// The provider half of the model setting, before the first `/`.
    fn providerName(stored: Stored) []const u8 {
        return stored.choice().provider();
    }

    /// What the model setting asks for, as the pair of halves it holds.
    pub fn choice(stored: Stored) models.Choice {
        return .{ .text = stored.model };
    }
};

/// The endpoints the configuration names itself, as the object the file holds
/// them as: a name, and the settings of the provider stored under it.
///
/// Written as an object keyed by name rather than a list, since the name is what
/// `model` and `credentials.json` both refer to, and a list would spell it twice.
pub const Providers = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        /// The name `model` writes before the `/`.
        name: []const u8,
        /// The base URL its completions path is appended to.
        base_url: []const u8,
    };

    /// The base URL of `name`, or null when the configuration does not name it.
    pub fn get(providers: Providers, name: []const u8) ?[]const u8 {
        for (providers.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.base_url;
        }
        return null;
    }

    /// Whether the configuration names it at all.
    pub fn has(providers: Providers, name: []const u8) bool {
        return providers.get(name) != null;
    }

    /// The object is read as a value and walked, since the names are the user's
    /// and no set of fields could hold them.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Providers {
        const parsed = try std.json.Value.jsonParse(allocator, source, options);
        if (parsed != .object) return error.UnexpectedToken;

        var entries: std.ArrayList(Entry) = .empty;
        var it = parsed.object.iterator();
        while (it.next()) |setting| {
            if (setting.value_ptr.* != .object) return error.UnexpectedToken;
            const base_url = setting.value_ptr.object.get("base_url") orelse
                return error.UnexpectedToken;
            if (base_url != .string) return error.UnexpectedToken;
            try entries.append(allocator, .{
                .name = setting.key_ptr.*,
                .base_url = base_url.string,
            });
        }
        return .{ .entries = try entries.toOwnedSlice(allocator) };
    }

    pub fn jsonStringify(providers: Providers, json: anytype) !void {
        try json.beginObject();
        for (providers.entries) |entry| {
            try json.objectField(entry.name);
            try json.beginObject();
            try json.objectField("base_url");
            try json.write(entry.base_url);
            try json.endObject();
        }
        try json.endObject();
    }
};

/// Backs every string the configuration holds, which is what the settings read
/// out of the file are kept in. The configuration owns it, so a caller frees the
/// whole configuration with `deinit` rather than tracking each string, and every
/// allocation `open` makes goes through it.
arena: std.heap.ArenaAllocator,
stored: Stored = .default,

/// An empty configuration, with the arena a file read fills in. Its settings
/// are the defaults, which is what a missing file is written with.
pub fn init(gpa: std.mem.Allocator) Config {
    return .{ .arena = .init(gpa) };
}

/// Frees every string the configuration holds, at once.
pub fn deinit(config: *Config) void {
    config.arena.deinit();
}

/// Reads the configuration from `dir`, writing `file_name` with the defaults
/// when it is missing. `dir` must be the directory holding the file.
///
/// `gpa` backs the configuration's own arena, where every string it reads and
/// every buffer it parses through is kept; the caller frees them all at once
/// with `deinit`.
pub fn open(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) !Opened {
    var config = Config.init(gpa);
    errdefer config.deinit();

    const arena = config.arena.allocator();

    const text = dir.readFileAlloc(io, file_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try config.save(io, dir);
            return .{ .config = config, .created = true };
        },
        else => return err,
    };

    config.stored = std.json.parseFromSliceLeaky(Stored, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.CorruptConfig;

    try config.stored.validate();
    return .{ .config = config, .created = false };
}

/// Writes the configuration to `file_name` in `dir`. The previous contents
/// are replaced in one step, leaving them intact if writing fails part way.
///
/// It is written indented rather than compact, unlike a session file: it is
/// there to be read and edited by hand, while a session is only ever read
/// back as a whole. The JSON is streamed straight onto the file, so writing it
/// allocates nothing.
pub fn save(config: *const Config, io: std.Io, dir: std.Io.Dir) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);

    var buf: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buf);

    try std.json.Stringify.value(config.stored, .{ .whitespace = .indent_2 }, &file.interface);

    try file.flush();
    try atomic.replace(io);
}

/// Sets the option named by the dotted `path` -- such as `tools.bash.timeout_s` --
/// to `value`, the text a user typed. The path names a field of the settings
/// and, dot by dot, the sections it lives in; the value is read as that field's
/// type, a string kept as it is and `null` clearing an optional setting. Every
/// field the configuration declares is reachable, so a setting added to it is
/// settable without anything here changing.
///
/// The result is checked the way a file read is, and written into the
/// configuration only once it passes, so a value that would make the
/// configuration unusable, such as a zero timeout, is refused rather than
/// stored. Strings are kept in the configuration's own arena.
pub fn set(config: *Config, path: []const u8, value: []const u8) !void {
    var stored = config.stored;
    try setPath(Stored, &stored, path, config.arena.allocator(), value);

    // A value that would make the configuration one the next read refuses, such
    // as a zero timeout, is a value this setting does not take.
    stored.validate() catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidValue,
        else => |other| return other,
    };
    config.stored = stored;
}

/// Walks `path` into `target` one field at a time and sets the leaf it names.
/// The field is found by name at run time, but the descent is compiled section
/// by section, so a field no path can name is skipped rather than walked into.
fn setPath(
    comptime T: type,
    target: *T,
    path: []const u8,
    arena: std.mem.Allocator,
    value: []const u8,
) !void {
    const segment = nextSegment(path);
    if (segment.head.len == 0) return error.UnknownOption;

    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        // The version is the file's own, not a setting a path names.
        if (comptime !std.mem.eql(u8, name, "version") and isSettable(Field)) {
            if (std.mem.eql(u8, name, segment.head)) {
                if (segment.rest.len == 0) {
                    if (comptime @typeInfo(Field) == .@"struct") return error.NotASection;
                    @field(target, name) = try parseValue(Field, arena, value);
                    return;
                }
                if (comptime @typeInfo(Field) == .@"struct") {
                    return setPath(Field, &@field(target, name), segment.rest, arena, value);
                }
                return error.NotASection;
            }
        }
    }
    return error.UnknownOption;
}

/// The first dotted segment of `path`, and the rest that follows it. The rest is
/// empty when the segment is the last, which is the value the path names.
const Segment = struct { head: []const u8, rest: []const u8 };

fn nextSegment(path: []const u8) Segment {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return .{ .head = path[0..dot], .rest = path[dot + 1 ..] };
    }
    return .{ .head = path, .rest = "" };
}

/// Reads `value` as a `T`: a string as itself, a number from its digits, a
/// boolean from true or false, an enum from a variant's name, and an optional
/// as null when it says `null` or as its child otherwise. A string is copied
/// into `arena`, which owns it.
fn parseValue(comptime T: type, arena: std.mem.Allocator, value: []const u8) error{ InvalidValue, OutOfMemory }!T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (std.mem.eql(u8, value, "null")) return null;
            return try parseValue(optional.child, arena, value);
        },
        .int => return std.fmt.parseInt(T, value, 10) catch error.InvalidValue,
        .bool => {
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return error.InvalidValue;
        },
        .@"enum" => return std.meta.stringToEnum(T, value) orelse error.InvalidValue,
        .pointer => |pointer| {
            if (comptime pointer.size != .slice or pointer.child != u8) {
                @compileError("cannot set a " ++ @typeName(T) ++ " from the command line");
            }
            return arena.dupe(u8, value);
        },
        else => @compileError("cannot set a " ++ @typeName(T) ++ " from the command line"),
    }
}

/// Whether a path can reach `T`: a value a string can set, or a section the walk
/// goes into. A section is walked into whatever it holds, since a field a path
/// cannot name -- a list, say -- leaves the fields beside it reachable.
fn isSettable(comptime T: type) bool {
    if (@typeInfo(T) == .@"struct") return true;
    return isSettableValue(T);
}

/// Whether a value of `T` can be set from one string: a string, a number, a
/// boolean, an enum, or an optional of one of those. Anything else is not a
/// setting a path can name, so the walk leaves it alone.
fn isSettableValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| isSettableValue(optional.child),
        .int, .bool => true,
        .@"enum" => true,
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        else => false,
    };
}

/// Writes `json` as the configuration file and opens it, so a test reads as the
/// file it wrote and the setting it read back. The caller frees what comes back
/// with `opened.config.deinit()`.
fn openFrom(tmp: *std.testing.TmpDir, json: []const u8) !Opened {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = json });
    return Config.open(std.testing.io, tmp.dir, std.testing.allocator);
}

test "open writes the defaults when the file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer first.config.deinit();
    try std.testing.expect(first.created);
    try std.testing.expectEqual(Stored.default.max_turns, first.config.stored.max_turns);

    // The file is now there, so a second open leaves it alone and reads it back.
    var second = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer second.config.deinit();
    try std.testing.expect(!second.created);
    try std.testing.expectEqual(Stored.default.max_turns, second.config.stored.max_turns);
}

test "open reads the max_turns and the bash timeout from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An unknown field and a missing version must not stop the read.
    var opened = try openFrom(&tmp, "{\"max_turns\":7,\"future\":true," ++
        "\"tools\":{\"bash\":{\"timeout_s\":30,\"unknown\":1}}}");
    defer opened.config.deinit();
    try std.testing.expect(!opened.created);
    try std.testing.expectEqual(7, opened.config.stored.max_turns);
    try std.testing.expectEqual(30, opened.config.stored.tools.bash.timeout_s);
    // A file without a replay count shows the default number of blocks.
    try std.testing.expectEqual(Stored.default.resume_blocks, opened.config.stored.resume_blocks);
}

test "open reads the block count a resume replays from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"resume_blocks\":3}");
    defer opened.config.deinit();
    try std.testing.expectEqual(3, opened.config.stored.resume_blocks);

    // Zero is allowed: it shows the whole session.
    var whole = try openFrom(&tmp, "{\"resume_blocks\":0}");
    defer whole.config.deinit();
    try std.testing.expectEqual(0, whole.config.stored.resume_blocks);
}

test "open reads the compaction threshold from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"compact_at\":50}");
    defer opened.config.deinit();
    try std.testing.expectEqual(50, opened.config.stored.compact_at);

    // A file without it falls back to the default.
    var bare = try openFrom(&tmp, "{}");
    defer bare.config.deinit();
    try std.testing.expectEqual(Stored.default.compact_at, bare.config.stored.compact_at);

    // Zero turns compaction off; it is a setting, not a mistake.
    var off = try openFrom(&tmp, "{\"compact_at\":0}");
    defer off.config.deinit();
    try std.testing.expectEqual(0, off.config.stored.compact_at);
}

test "a retired markdown setting in the file is ignored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A reply and a prompt are laid out by billy's own renderer now, so the
    // `markdown` section a file may still carry is read the way any unknown field
    // is: left alone, without making the file unusable.
    var opened = try openFrom(&tmp, "{\"markdown\":{\"format\":\"glow -\"},\"max_turns\":7}");
    defer opened.config.deinit();
    try std.testing.expectEqual(7, opened.config.stored.max_turns);
}

test "open reads the bash timeout from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file written before the setting existed has no tools at all, so the
    // default timeout stands.
    var older = try openFrom(&tmp, "{\"max_turns\":7}");
    defer older.config.deinit();
    try std.testing.expectEqual(Stored.default.tools.bash.timeout_s, older.config.stored.tools.bash.timeout_s);

    var opened = try openFrom(&tmp, "{\"tools\":{\"bash\":{\"timeout_s\":30}}}");
    defer opened.config.deinit();
    try std.testing.expectEqual(30, opened.config.stored.tools.bash.timeout_s);
}

test "open reads a self-hosted backend's instance from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // SearXNG is the one backend with no address billy knows, so its instance is
    // named under its own section. A backend billy knows leaves it unset.
    var opened = try openFrom(&tmp, "{\"tools\":{\"web_search\":{" ++
        "\"providers\":[\"searxng\"],\"searxng\":{\"url\":\"https://searx.example.org\"}}}}");
    defer opened.config.deinit();
    try std.testing.expectEqual(toolset.web.Search.Provider.searxng, opened.config.stored.tools.web_search.providers[0]);
    try std.testing.expectEqualStrings("https://searx.example.org", opened.config.stored.tools.web_search.searxng.url.?);

    var known = try openFrom(&tmp, "{\"tools\":{\"web_search\":{\"providers\":[\"exa\"]}}}");
    defer known.config.deinit();
    try std.testing.expect(known.config.stored.tools.web_search.searxng.url == null);
}

test "open reads the web search backends and result count from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The backends are kept in the order they are named, since that is the order
    // they are tried.
    var opened = try openFrom(&tmp, "{\"tools\":{\"web_search\":{" ++
        "\"providers\":[\"tavily\",\"brave\"],\"max_results\":3}}}");
    defer opened.config.deinit();
    try std.testing.expectEqualSlices(toolset.web.Search.Provider, &.{ .tavily, .brave }, opened.config.stored.tools.web_search.providers);
    try std.testing.expectEqual(3, opened.config.stored.tools.web_search.max_results);

    // The defaults leave it off, and the count ready for a backend to be named.
    var bare = try openFrom(&tmp, "{}");
    defer bare.config.deinit();
    try std.testing.expectEqual(@as(usize, 0), bare.config.stored.tools.web_search.providers.len);
    try std.testing.expectEqual(Stored.default.tools.web_search.max_results, bare.config.stored.tools.web_search.max_results);

    // A name that is not a backend makes the file unusable rather than reading
    // as "no search", so a typo is not silently dropped.
    try std.testing.expectError(error.CorruptConfig, openFrom(&tmp, "{\"tools\":{\"web_search\":{\"providers\":[\"google\"]}}}"));
}

test "save round-trips a custom max_turns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    config.stored.max_turns = 3;
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(3, opened.config.stored.max_turns);
}

test "the file is indented, so it can be read and edited by hand" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config = Config.init(gpa);
    defer config.deinit();

    config.stored.max_turns = 3;
    try config.save(std.testing.io, tmp.dir);

    const text = try tmp.dir.readFileAlloc(std.testing.io, file_name, gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "model": "deepseek/deepseek-flash",
        \\  "providers": {},
        \\  "max_turns": 3,
        \\  "resume_blocks": 10,
        \\  "web_blocks": 200,
        \\  "compact_at": 80,
        \\  "title": true,
        \\  "tools": {
        \\    "bash": {
        \\      "timeout_s": 120
        \\    },
        \\    "web_search": {
        \\      "providers": [],
        \\      "max_results": 5,
        \\      "searxng": {
        \\        "url": null
        \\      }
        \\    },
        \\    "web_fetch": {
        \\      "providers": [
        \\        "raw"
        \\      ]
        \\    }
        \\  }
        \\}
    , text);
}

test "save round-trips a configured search backend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The backend is written by name, which is the variant's own, and read back
    // as the variant it names.
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    config.stored.tools.web_search = .{ .providers = &.{.tavily}, .max_results = 4 };
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(toolset.web.Search.Provider.tavily, opened.config.stored.tools.web_search.providers[0]);
    try std.testing.expectEqual(4, opened.config.stored.tools.web_search.max_results);
}

test "open rejects damaged, future and unusable configurations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A rejected configuration frees the arena it made on the way out, so a
    // failure leaks nothing.
    try std.testing.expectError(error.CorruptConfig, openFrom(&tmp, "{"));

    try std.testing.expectError(error.UnsupportedConfigVersion, openFrom(&tmp, "{\"version\":99}"));

    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"max_turns\":0}"));

    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"tools\":{\"bash\":{\"timeout_s\":0}}}"));
}

test "the model setting names a provider and a model of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"model\":\"opencode_go/glm-5.3-flash\"}");
    defer opened.config.deinit();
    const choice = opened.config.stored.choice();
    try std.testing.expectEqualStrings("opencode_go", choice.provider());
    try std.testing.expectEqualStrings("glm-5.3-flash", choice.model());

    // A model id may hold a slash of its own, so only the first one splits the
    // string; the rest is the model.
    const nested = models.Choice{ .text = "vendor/model/variant" };
    try std.testing.expectEqualStrings("vendor", nested.provider());
    try std.testing.expectEqualStrings("model/variant", nested.model());
}

test "a model setting billy cannot use is refused, not read as another endpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A provider billy does not know names no endpoint it can send to.
    try std.testing.expectError(error.UnknownProvider, openFrom(&tmp, "{\"model\":\"who-knows/m\"}"));
    // A model with no provider in front of it, or a provider with no model
    // after it, names a pair with a missing half rather than an unknown one.
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"deepseek-flash\"}"));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"deepseek/\"}"));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"\"}"));

    // The default the file is written with is one billy can use.
    try Stored.default.validate();
}

test "the providers map names an endpoint of the user's own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A provider billy does not ship, named by the file and used by `model`,
    // which is how a proxy or a server of the user's own is reached.
    var opened = try openFrom(&tmp,
        \\{"model":"mock/m","providers":{"mock":{"base_url":"http://127.0.0.1:8901/v1"}}}
    );
    defer opened.config.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", opened.config.stored.providers.get("mock").?);
    try std.testing.expect(opened.config.stored.providers.get("other") == null);

    // It survives a save and a read back, so the file is the whole truth.
    try opened.config.save(std.testing.io, tmp.dir);
    var reread = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer reread.config.deinit();
    try std.testing.expectEqualStrings("mock/m", reread.config.stored.model);
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", reread.config.stored.providers.get("mock").?);
}

test "a model naming a provider the file does not define is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A provider billy ships needs no definition.
    var known = try openFrom(&tmp, "{\"model\":\"opencode_go/glm-5.3-flash\"}");
    defer known.config.deinit();

    // One it does not, and the file does not either, names no endpoint.
    try std.testing.expectError(error.UnknownProvider, openFrom(&tmp, "{\"model\":\"mock/m\"}"));
}

test "a provider entry with no name or no url is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name with no URL names nothing to send to; a URL with no name is one
    // `model` could never write.
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp,
        \\{"model":"mock/m","providers":{"mock":{"base_url":""}}}
    ));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp,
        \\{"model":"deepseek/m","providers":{"":{"base_url":"http://127.0.0.1:9/v1"}}}
    ));
}

test "set names a setting by its dotted path" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    try config.set("tools.bash.timeout_s", "30");
    try std.testing.expectEqual(30, config.stored.tools.bash.timeout_s);

    try config.set("max_turns", "7");
    try std.testing.expectEqual(7, config.stored.max_turns);

    try config.set("resume_blocks", "0");
    try std.testing.expectEqual(0, config.stored.resume_blocks);

    try config.set("compact_at", "60");
    try std.testing.expectEqual(60, config.stored.compact_at);
    try config.set("compact_at", "0");
    try std.testing.expectEqual(0, config.stored.compact_at);

    try config.set("tools.web_search.max_results", "3");
    try std.testing.expectEqual(3, config.stored.tools.web_search.max_results);
    try config.set("tools.web_search.searxng.url", "https://searx.example.org");
    try std.testing.expectEqualStrings("https://searx.example.org", config.stored.tools.web_search.searxng.url.?);
}

test "set writes null to clear a setting that has no value" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    try config.set("tools.web_search.searxng.url", "https://searx.example.org");
    try config.set("tools.web_search.searxng.url", "null");
    try std.testing.expect(config.stored.tools.web_search.searxng.url == null);
}

test "set refuses a setting that is unknown, a section, or a bad value" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    // A path that names no field, at the top or inside a section.
    try std.testing.expectError(error.UnknownOption, config.set("nope", "1"));
    try std.testing.expectError(error.UnknownOption, config.set("tools.nope", "1"));
    // The version is the file's own, not a setting.
    try std.testing.expectError(error.UnknownOption, config.set("version", "2"));
    // A section is walked into, not set from one string, and a value has nothing
    // below it.
    try std.testing.expectError(error.NotASection, config.set("tools", "x"));
    try std.testing.expectError(error.NotASection, config.set("tools.bash.timeout_s.x", "y"));
    // Text that is not the kind of value the setting takes.
    try std.testing.expectError(error.InvalidValue, config.set("tools.bash.timeout_s", "soon"));
    // A list setting is edited in the file, not named by a path, so it is not a
    // setting the command knows.
    try std.testing.expectError(error.UnknownOption, config.set("tools.web_search.providers", "tavily"));
    // A value the file itself would refuse is refused before it is written, and
    // the setting keeps what it had.
    try std.testing.expectError(error.InvalidValue, config.set("tools.bash.timeout_s", "0"));
    try std.testing.expectError(error.InvalidValue, config.set("max_turns", "0"));
    try std.testing.expectEqual(Stored.default.tools.bash.timeout_s, config.stored.tools.bash.timeout_s);
    try std.testing.expectEqual(Stored.default.max_turns, config.stored.max_turns);
}

test "a setting set by path is written and read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try config.set("tools.bash.timeout_s", "45");
    try config.set("tools.web_search.searxng.url", "https://searx.example.org");
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();

    try std.testing.expectEqual(45, opened.config.stored.tools.bash.timeout_s);
    try std.testing.expectEqualStrings("https://searx.example.org", opened.config.stored.tools.web_search.searxng.url.?);
}
