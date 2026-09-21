//! Configuration: the settings read from a JSON file under the XDG config
//! directory, so that a run can be tuned without rebuilding the binary.
//!
//! The file lives at `$XDG_CONFIG_HOME/billy/config.json`, or
//! `$HOME/.config/billy/config.json` when that is unset. It is written with the
//! defaults the first time it is needed, which is also how the settings that
//! exist are discovered. Unknown fields are ignored, so a file written by a
//! newer billy does not break an older one.

const std = @import("std");
const Io = std.Io;
const search = @import("search.zig");

const Config = @This();

/// Directory under the XDG config directory that holds the configuration.
const app_dir = "billy";
/// Name of the configuration file inside that directory.
pub const file_name = "config.json";
/// Layout of the configuration file, bumped when its shape changes.
const format_version = 1;
/// Longest configuration file read back, so a damaged file cannot exhaust memory.
const max_config_bytes = 1 << 20;

/// Turns the model is allowed per request when the file asks for nothing else.
pub const default_max_turns = 100;
/// Results asked for per search query when the file asks for nothing else.
pub const default_max_results = 5;
/// Seconds a bash command may run before it is killed when the file asks for
/// nothing else.
pub const default_timeout_s = 120;

/// What `open` found, including whether the file had to be written.
pub const Opened = struct {
    config: Config,
    /// Whether the file was missing and has just been written with defaults.
    created: bool,
};

/// Settings for the tools the agent can call, one group per tool.
pub const Tools = struct {
    bash: Bash = .{},
    edit: Edit = .{},
    web_search: WebSearch = .{},
};

/// Settings for the web search tool.
pub const WebSearch = struct {
    /// The backend to search with, or null to leave web search out of the tools
    /// the model is offered, which is the default: a fresh configuration has no
    /// key to search with. The names are the variants of `search.Provider`, and
    /// one it does not know makes the file corrupt rather than reading as "no
    /// search".
    ///
    /// The key a backend needs is read from the credential `billy login` stored
    /// for it, or from its environment variable when none is stored, and never
    /// from this file, which is written to disk in the clear.
    provider: ?search.Provider = null,
    /// Results asked for per query. The backend may return fewer, and billy caps
    /// it.
    max_results: usize = default_max_results,
};

/// Settings for the bash tool.
pub const Bash = struct {
    /// A shell script that lays a bash command out for the display: it reads the
    /// command on standard input and writes the formatted command on standard
    /// output, such as `shfmt | bat -l bash`. Null shows the command exactly as
    /// the model wrote it.
    ///
    /// Only the display changes; the command that runs, and everything stored
    /// in the session, keep what the model wrote.
    format: ?[]const u8 = null,
    /// Longest a command may run before it is killed, in seconds. A command that
    /// outlives this is killed, so a runaway command cannot hang the agent
    /// forever. Zero would kill every command as it starts, which is never what
    /// the file is meant to say, so it is rejected rather than read as "no
    /// limit"; set a large value for a command that legitimately runs long.
    timeout_s: usize = default_timeout_s,
};

/// Settings for the edit tool.
pub const Edit = struct {
    /// A shell script that lays an edit's diff out for the display: it reads the
    /// diff on standard input and writes the laid-out diff on standard output,
    /// such as `delta --paging=never` or `bat -l diff --plain`. The two sides of
    /// the change are also written to billy's own files, whose paths are passed as
    /// the script's first two arguments, so a two-file differ can name them, such
    /// as `difft "$1" "$2"`. Null shows the diff the way billy colours it.
    ///
    /// Only the display changes; the file that is written, what a session stores
    /// and what the model is sent keep the text as it was written.
    format: ?[]const u8 = null,
};

/// Settings for the markdown billy shows. Markdown is not a tool: it is the
/// form the replies and the prompts are written in, so the setting applies to
/// both.
pub const Markdown = struct {
    /// A shell script that lays markdown out for the display: it reads the text
    /// on standard input and writes the formatted text on standard output, such
    /// as `glow -` or `bat -l md --plain`. Null shows the text exactly as it was
    /// written.
    ///
    /// Only the display changes; what a session stores and what the model is
    /// sent keep the text as it was written.
    format: ?[]const u8 = null,
};

/// The configuration file as it is written to and read from disk. The settings
/// are the configuration's own, since the file holds exactly those.
const Stored = struct {
    version: u32 = format_version,
    max_turns: usize = default_max_turns,
    tools: Tools = .{},
    markdown: Markdown = .{},
};

/// Backs every string the configuration holds, which is the format scripts read
/// out of the file. The configuration owns it, so a caller frees the whole
/// configuration with `deinit` rather than tracking each string, and every
/// allocation `open` makes goes through it.
arena_state: std.heap.ArenaAllocator,

/// Model turns allowed for one request before the harness gives up on it.
max_turns: usize = default_max_turns,
/// Settings for the tools the agent can call, by tool name.
tools: Tools = .{},
/// Settings for the markdown billy shows: the replies it writes and the
/// prompts the user types.
markdown: Markdown = .{},

/// An empty configuration, with the arena a file read fills in. Its settings
/// are the defaults, which is what a missing file is written with.
pub fn init(gpa: std.mem.Allocator) Config {
    return .{ .arena_state = .init(gpa) };
}

/// Frees every string the configuration holds, at once.
pub fn deinit(config: *Config) void {
    config.arena_state.deinit();
}

/// Reads the configuration from `dir`, writing `file_name` with the defaults
/// when it is missing. `dir` must be the directory holding the file.
///
/// `gpa` backs the configuration's own arena, where every string it reads and
/// every buffer it parses through is kept; the caller frees them all at once
/// with `deinit`.
pub fn open(io: Io, dir: Io.Dir, gpa: std.mem.Allocator) !Opened {
    var config = Config.init(gpa);
    errdefer config.deinit();
    const arena = config.arena_state.allocator();

    const text = dir.readFileAlloc(io, file_name, arena, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try config.save(io, dir);
            return .{ .config = config, .created = true };
        },
        else => return err,
    };
    const stored = std.json.parseFromSliceLeaky(Stored, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CorruptConfig;
    if (stored.version > format_version) return error.UnsupportedConfigVersion;
    // Zero turns would give the model no chance to answer at all, which is
    // never what the file is meant to say.
    if (stored.max_turns == 0) return error.InvalidConfig;
    // A zero timeout would kill every command as it starts, which is never
    // what the file is meant to say either.
    if (stored.tools.bash.timeout_s == 0) return error.InvalidConfig;

    config.max_turns = stored.max_turns;
    config.tools = stored.tools;
    config.markdown = stored.markdown;
    return .{ .config = config, .created = false };
}

/// Writes the configuration to `file_name` in `dir`. The previous contents
/// are replaced in one step, leaving them intact if writing fails part way.
///
/// It is written indented rather than compact, unlike a session file: it is
/// there to be read and edited by hand, while a session is only ever read
/// back as a whole. The JSON is streamed straight onto the file, so writing it
/// allocates nothing.
pub fn save(config: *const Config, io: Io, dir: Io.Dir) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var file: Io.File.Writer = .init(atomic.file, io, &buffer);
    try std.json.Stringify.value(
        Stored{
            .max_turns = config.max_turns,
            .tools = config.tools,
            .markdown = config.markdown,
        },
        .{ .whitespace = .indent_2 },
        &file.interface,
    );
    try file.flush();
    try atomic.replace(io);
}

/// The directory holding the configuration: `$XDG_CONFIG_HOME/billy`, or
/// `$HOME/.config/billy` when that is unset, as the XDG base directory
/// specification prescribes.
pub fn defaultDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        // The specification says a relative path must be ignored.
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(gpa, &.{ xdg, app_dir });
        }
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".config", app_dir });
}

test "defaultDir follows the XDG base directory specification" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(arena);
    defer environ.deinit();

    try std.testing.expectError(error.HomeNotSet, defaultDir(allocator, &environ));

    try environ.put("HOME", "/home/user");
    try std.testing.expectEqualStrings("/home/user/.config/billy", try defaultDir(allocator, &environ));

    try environ.put("XDG_CONFIG_HOME", "/config");
    try std.testing.expectEqualStrings("/config/billy", try defaultDir(allocator, &environ));

    // An empty or relative XDG_CONFIG_HOME is ignored.
    try environ.put("XDG_CONFIG_HOME", "");
    try std.testing.expectEqualStrings("/home/user/.config/billy", try defaultDir(allocator, &environ));
    try environ.put("XDG_CONFIG_HOME", "relative");
    try std.testing.expectEqualStrings("/home/user/.config/billy", try defaultDir(allocator, &environ));
}

test "open writes the defaults when the file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer first.config.deinit();
    try std.testing.expect(first.created);
    try std.testing.expectEqual(default_max_turns, first.config.max_turns);

    // The file is now there, so a second open leaves it alone and reads it back.
    var second = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer second.config.deinit();
    try std.testing.expect(!second.created);
    try std.testing.expectEqual(default_max_turns, second.config.max_turns);
}

test "open reads the max_turns and the bash format from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An unknown field and a missing version must not stop the read.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"max_turns\":7,\"future\":true," ++
            "\"tools\":{\"bash\":{\"format\":\"shfmt | bat -l bash\",\"unknown\":1}}}",
    });

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expect(!opened.created);
    try std.testing.expectEqual(7, opened.config.max_turns);
    try std.testing.expectEqualStrings("shfmt | bat -l bash", opened.config.tools.bash.format.?);
}

test "open reads the markdown format from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"markdown\":{\"format\":\"glow -\"}}",
    });

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqualStrings("glow -", opened.config.markdown.format.?);
    // The tools are untouched by a markdown format.
    try std.testing.expect(opened.config.tools.bash.format == null);

    // A file without one leaves the format unset, as before.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{}" });
    var bare = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer bare.config.deinit();
    try std.testing.expect(bare.config.markdown.format == null);
}

test "open leaves the bash format unset when the file does not set one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session saved before the setting existed has no tools at all.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"max_turns\":7}",
    });
    var older = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer older.config.deinit();
    try std.testing.expect(older.config.tools.bash.format == null);
    // The timeout the setting was added with is the default for a file without one.
    try std.testing.expectEqual(default_timeout_s, older.config.tools.bash.timeout_s);

    // A format of null is the same as not setting one.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"bash\":{\"format\":null}}}",
    });
    var explicit = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer explicit.config.deinit();
    try std.testing.expect(explicit.config.tools.bash.format == null);
}

test "open reads the bash timeout from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The timeout is set alongside the format, and each is read on its own.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"bash\":{\"format\":\"shfmt\",\"timeout_s\":30}}}",
    });
    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(30, opened.config.tools.bash.timeout_s);
    try std.testing.expectEqualStrings("shfmt", opened.config.tools.bash.format.?);

    // A file without one falls back to the default.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"bash\":{\"format\":\"shfmt\"}}}",
    });
    var bare = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer bare.config.deinit();
    try std.testing.expectEqual(default_timeout_s, bare.config.tools.bash.timeout_s);
}

test "open reads the web search provider and result count from the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"web_search\":{\"provider\":\"tavily\",\"max_results\":3}}}",
    });

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(search.Provider.tavily, opened.config.tools.web_search.provider.?);
    try std.testing.expectEqual(3, opened.config.tools.web_search.max_results);

    // The defaults leave it off, and the count ready for a provider to be named.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{}" });
    var bare = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer bare.config.deinit();
    try std.testing.expect(bare.config.tools.web_search.provider == null);
    try std.testing.expectEqual(default_max_results, bare.config.tools.web_search.max_results);

    // A name that is not a backend makes the file unusable rather than reading
    // as "no search", so a typo is not silently dropped.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"web_search\":{\"provider\":\"google\"}}}",
    });
    try std.testing.expectError(error.CorruptConfig, Config.open(std.testing.io, tmp.dir, std.testing.allocator));
}

test "save round-trips a custom max_turns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    config.max_turns = 3;
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(3, opened.config.max_turns);
}

test "the file is indented, so it can be read and edited by hand" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config = Config.init(gpa);
    defer config.deinit();
    config.max_turns = 3;
    try config.save(std.testing.io, tmp.dir);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = try tmp.dir.readFileAlloc(std.testing.io, file_name, arena_state.allocator(), .limited(max_config_bytes));
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "max_turns": 3,
        \\  "tools": {
        \\    "bash": {
        \\      "format": null,
        \\      "timeout_s": 120
        \\    },
        \\    "edit": {
        \\      "format": null
        \\    },
        \\    "web_search": {
        \\      "provider": null,
        \\      "max_results": 5
        \\    }
        \\  },
        \\  "markdown": {
        \\    "format": null
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
    config.tools.web_search = .{ .provider = .tavily, .max_results = 4 };
    try config.save(std.testing.io, tmp.dir);

    var opened = try Config.open(std.testing.io, tmp.dir, std.testing.allocator);
    defer opened.config.deinit();
    try std.testing.expectEqual(search.Provider.tavily, opened.config.tools.web_search.provider.?);
    try std.testing.expectEqual(4, opened.config.tools.web_search.max_results);
}

test "open rejects damaged, future and unusable configurations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A rejected configuration frees the arena it made on the way out, so a
    // failure leaks nothing.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{" });
    try std.testing.expectError(error.CorruptConfig, Config.open(std.testing.io, tmp.dir, std.testing.allocator));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"version\":99}" });
    try std.testing.expectError(error.UnsupportedConfigVersion, Config.open(std.testing.io, tmp.dir, std.testing.allocator));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"max_turns\":0}" });
    try std.testing.expectError(error.InvalidConfig, Config.open(std.testing.io, tmp.dir, std.testing.allocator));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"bash\":{\"timeout_s\":0}}}",
    });
    try std.testing.expectError(error.InvalidConfig, Config.open(std.testing.io, tmp.dir, std.testing.allocator));
}
