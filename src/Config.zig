//! Configuration: the settings read from a JSON file under the XDG config directory, so that a run
//! can be tuned without rebuilding the binary.

const std = @import("std");

const models = @import("models.zig");
const Tools = @import("Tools.zig");

const Config = @This();

pub const file_name = "config.json";

pub const Opened = struct {
    config: Config,
    created: bool,
};

pub const ToolSettings = struct {
    bash: Bash = .{},
    web_search: WebSearch = .{},
    web_fetch: WebFetch = .{},
};

pub const WebFetch = struct {
    providers: []const Tools.web.Provider = &.{.raw},
};

pub const WebSearch = struct {
    providers: []const Tools.web.Provider = &.{},
    max_results: usize = 5,
    searxng: Searxng = .{},

    pub const Searxng = struct {
        url: ?[]const u8 = null,
    };
};

pub const Bash = struct {
    timeout_s: usize = 120,
};

const Stored = struct {
    version: u32 = 1,
    model: []const u8 = "deepseek/deepseek-flash",
    providers: Providers = .{},
    max_turns: usize = 100,
    resume_blocks: usize = 10,
    web_blocks: usize = 200,
    compact_at: usize = 80,
    title: bool = true,
    tools: ToolSettings = .{},

    const default = Stored{};

    fn validate(stored: Stored) !void {
        if (stored.version > Stored.default.version) return error.UnsupportedConfigVersion;
        if (stored.max_turns == 0) return error.InvalidConfig;
        if (stored.tools.bash.timeout_s == 0) return error.InvalidConfig;
        try stored.validateProviders();
        try stored.validateWeb();
        try stored.validateModel();
    }

    fn validateWeb(stored: Stored) !void {
        for (stored.tools.web_search.providers) |provider| {
            if (!provider.searches()) return error.InvalidConfig;
        }
        for (stored.tools.web_fetch.providers) |provider| {
            if (!provider.fetches()) return error.InvalidConfig;
        }
    }

    fn validateModel(stored: Stored) !void {
        if (!stored.choice().isComplete()) return error.InvalidConfig;
    }

    fn validateProviders(stored: Stored) !void {
        for (stored.providers.entries) |entry| {
            if (entry.name.len == 0) return error.InvalidConfig;
            if (entry.base_url.len == 0) return error.InvalidConfig;
        }
    }

    pub fn choice(stored: Stored) models.Choice {
        return .{ .text = stored.model };
    }
};

/// The endpoints the configuration names itself, as the object the file holds them as: a name, and
/// the settings of the provider stored under it.
pub const Providers = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        name: []const u8,
        base_url: []const u8,
    };

    pub fn get(providers: Providers, name: []const u8) ?[]const u8 {
        for (providers.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.base_url;
        }
        return null;
    }

    pub fn has(providers: Providers, name: []const u8) bool {
        return providers.get(name) != null;
    }

    /// The object is read as a value and walked, since the names are the user's and no set of
    /// fields could hold them.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Providers {
        const parsed = try std.json.Value.jsonParse(allocator, source, options);
        if (parsed != .object) return error.UnexpectedToken;

        // The entries are taken from the arena the configuration was read through, which frees
        // everything it read in one go.
        // zlinter-disable-next-line require_errdefer_dealloc - the arena owns it
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

arena: std.heap.ArenaAllocator,
stored: Stored = .default,

pub fn init(gpa: std.mem.Allocator) Config {
    return .{ .arena = .init(gpa) };
}

/// Frees every string the configuration holds, at once.
pub fn deinit(config: *Config) void {
    config.arena.deinit();
}

/// Reads the configuration from `dir`, writing `file_name` with the defaults when it is missing.
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

/// Writes the configuration to `file_name` in `dir`.
pub fn save(config: *const Config, io: std.Io, dir: std.Io.Dir) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);

    var buf: [std.heap.page_size_min]u8 = undefined;
    var file = atomic.file.writer(io, &buf);

    try std.json.Stringify.value(config.stored, .{ .whitespace = .indent_2 }, &file.interface);

    try file.flush();
    try atomic.replace(io);
}

/// Sets the option named by the dotted `path` -- such as `tools.bash.timeout_s` -- to `value`, the
/// text a user typed.
pub fn set(config: *Config, path: []const u8, value: []const u8) !void {
    var stored = config.stored;
    try setPath(Stored, &stored, path, config.arena.allocator(), value);

    // A value that would make the configuration one the next read refuses, such as a zero timeout,
    // is a value this setting does not take.
    stored.validate() catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidValue,
        else => |other| return other,
    };
    config.stored = stored;
}

fn setPath(
    T: type,
    target: *T,
    path: []const u8,
    arena: std.mem.Allocator,
    value: []const u8,
) !void {
    const segment = nextSegment(path);
    if (segment.head.len == 0) return error.UnknownOption;

    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
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

const Segment = struct { head: []const u8, rest: []const u8 };

fn nextSegment(path: []const u8) Segment {
    if (std.mem.findScalar(u8, path, '.')) |dot| {
        return .{ .head = path[0..dot], .rest = path[dot + 1 ..] };
    }
    return .{ .head = path, .rest = "" };
}

fn parseValue(T: type, arena: std.mem.Allocator, value: []const u8) error{ InvalidValue, OutOfMemory }!T {
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

fn isSettable(T: type) bool {
    if (@typeInfo(T) == .@"struct") return true;
    return isSettableValue(T);
}

fn isSettableValue(T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| isSettableValue(optional.child),
        .int, .bool => true,
        .@"enum" => true,
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        else => false,
    };
}

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
    try std.testing.expectEqual(Stored.default.resume_blocks, opened.config.stored.resume_blocks);
}

test "open reads the block count a resume replays from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"resume_blocks\":3}");
    defer opened.config.deinit();
    try std.testing.expectEqual(3, opened.config.stored.resume_blocks);

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

    var bare = try openFrom(&tmp, "{}");
    defer bare.config.deinit();
    try std.testing.expectEqual(Stored.default.compact_at, bare.config.stored.compact_at);

    var off = try openFrom(&tmp, "{\"compact_at\":0}");
    defer off.config.deinit();
    try std.testing.expectEqual(0, off.config.stored.compact_at);
}

test "a retired markdown setting in the file is ignored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"markdown\":{\"format\":\"glow -\"},\"max_turns\":7}");
    defer opened.config.deinit();
    try std.testing.expectEqual(7, opened.config.stored.max_turns);
}

test "open reads the bash timeout from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    var opened = try openFrom(&tmp, "{\"tools\":{\"web_search\":{" ++
        "\"providers\":[\"searxng\"],\"searxng\":{\"url\":\"https://searx.example.org\"}}}}");
    defer opened.config.deinit();
    try std.testing.expectEqual(Tools.web.Provider.searxng, opened.config.stored.tools.web_search.providers[0]);
    try std.testing.expectEqualStrings("https://searx.example.org", opened.config.stored.tools.web_search.searxng.url.?);

    var known = try openFrom(&tmp, "{\"tools\":{\"web_search\":{\"providers\":[\"exa\"]}}}");
    defer known.config.deinit();
    try std.testing.expect(known.config.stored.tools.web_search.searxng.url == null);
}

test "open reads the web search backends and result count from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"tools\":{\"web_search\":{" ++
        "\"providers\":[\"tavily\",\"brave\"],\"max_results\":3}}}");
    defer opened.config.deinit();
    try std.testing.expectEqualSlices(Tools.web.Provider, &.{ .tavily, .brave }, opened.config.stored.tools.web_search.providers);
    try std.testing.expectEqual(3, opened.config.stored.tools.web_search.max_results);

    var bare = try openFrom(&tmp, "{}");
    defer bare.config.deinit();
    try std.testing.expectEqual(@as(usize, 0), bare.config.stored.tools.web_search.providers.len);
    try std.testing.expectEqual(Stored.default.tools.web_search.max_results, bare.config.stored.tools.web_search.max_results);

    // A name that is not a backend makes the file unusable rather than reading as "no search", so a
    // typo is not silently dropped.
    try std.testing.expectError(error.CorruptConfig, openFrom(&tmp, "{\"tools\":{\"web_search\":{\"providers\":[\"google\"]}}}"));
    // One billy knows, but that cannot do the job it is named for, is refused too: the two tools
    // share one list of providers, so the file has to say which of them may be named for each.
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"tools\":{\"web_search\":{\"providers\":[\"raw\"]}}}"));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"tools\":{\"web_fetch\":{\"providers\":[\"brave\"]}}}"));
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

    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    config.stored.tools.web_search = .{ .providers = &.{.tavily}, .max_results = 4 };
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(Tools.web.Provider.tavily, opened.config.stored.tools.web_search.providers[0]);
    try std.testing.expectEqual(4, opened.config.stored.tools.web_search.max_results);
}

test "open rejects damaged, future and unusable configurations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.CorruptConfig, openFrom(&tmp, "{"));

    try std.testing.expectError(error.UnsupportedConfigVersion, openFrom(&tmp, "{\"version\":99}"));

    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"max_turns\":0}"));

    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"tools\":{\"bash\":{\"timeout_s\":0}}}"));
}

test "the model setting names a provider and a model of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"model\":\"opencode-go/glm-5.3-flash\"}");
    defer opened.config.deinit();
    const choice = opened.config.stored.choice();
    try std.testing.expectEqualStrings("opencode-go", choice.provider());
    try std.testing.expectEqualStrings("glm-5.3-flash", choice.model());

    const nested = models.Choice{ .text = "vendor/model/variant" };
    try std.testing.expectEqualStrings("vendor", nested.provider());
    try std.testing.expectEqualStrings("model/variant", nested.model());
}

test "a model setting with half of it missing is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"deepseek-flash\"}"));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"deepseek/\"}"));
    try std.testing.expectError(error.InvalidConfig, openFrom(&tmp, "{\"model\":\"\"}"));

    try Stored.default.validate();
}

test "the providers map names an endpoint of the user's own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp,
        \\{"model":"mock/m","providers":{"mock":{"base_url":"http://127.0.0.1:8901/v1"}}}
    );
    defer opened.config.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", opened.config.stored.providers.get("mock").?);
    try std.testing.expect(opened.config.stored.providers.get("other") == null);

    try opened.config.save(std.testing.io, tmp.dir);
    var reread = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer reread.config.deinit();
    try std.testing.expectEqualStrings("mock/m", reread.config.stored.model);
    try std.testing.expectEqualStrings("http://127.0.0.1:8901/v1", reread.config.stored.providers.get("mock").?);
}

test "a model naming a provider the file does not define is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opened = try openFrom(&tmp, "{\"model\":\"opencode-go/glm-5.3-flash\"}");
    defer opened.config.deinit();
}

test "a provider entry with no name or no url is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name with no URL names nothing to send to; a URL with no name is one `model` could never
    // write.
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

    try std.testing.expectError(error.UnknownOption, config.set("nope", "1"));
    try std.testing.expectError(error.UnknownOption, config.set("tools.nope", "1"));
    try std.testing.expectError(error.UnknownOption, config.set("version", "2"));
    try std.testing.expectError(error.NotASection, config.set("tools", "x"));
    try std.testing.expectError(error.NotASection, config.set("tools.bash.timeout_s.x", "y"));
    try std.testing.expectError(error.InvalidValue, config.set("tools.bash.timeout_s", "soon"));
    try std.testing.expectError(error.UnknownOption, config.set("tools.web_search.providers", "tavily"));
    // A value the file itself would refuse is refused before it is written, and the setting keeps
    // what it had.
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
