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

pub const Config = struct {
    /// Model turns allowed for one request before the harness gives up on it.
    max_turns: usize = default_max_turns,
    /// Settings for the tools the agent can call, by tool name.
    tools: Tools = .{},

    /// What `open` found, including whether the file had to be written.
    pub const Opened = struct {
        config: Config,
        /// Whether the file was missing and has just been written with defaults.
        created: bool,
    };

    /// Reads the configuration from `dir`, writing `file_name` with the defaults
    /// when it is missing. `dir` must be the directory holding the file.
    pub fn open(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !Opened {
        const text = dir.readFileAlloc(io, file_name, arena, .limited(max_config_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                const config: Config = .{};
                try config.save(io, dir, arena);
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
        return .{
            .config = .{ .max_turns = stored.max_turns, .tools = stored.tools },
            .created = false,
        };
    }

    /// Writes the configuration to `file_name` in `dir`. The previous contents
    /// are replaced in one step, leaving them intact if writing fails part way.
    pub fn save(config: Config, io: Io, dir: Io.Dir, gpa: std.mem.Allocator) !void {
        const text = try std.json.Stringify.valueAlloc(
            gpa,
            Stored{ .max_turns = config.max_turns, .tools = config.tools },
            .{},
        );
        defer gpa.free(text);

        var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var file: Io.File.Writer = .init(atomic.file, io, &buffer);
        try file.interface.writeAll(text);
        try file.flush();
        try atomic.replace(io);
    }
};

/// Settings for the tools the agent can call, one group per tool.
pub const Tools = struct {
    bash: Bash = .{},
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
};

/// The configuration file as it is written to and read from disk. The tool
/// settings are the configuration's own, since the file holds exactly those.
const Stored = struct {
    version: u32 = format_version,
    max_turns: usize = default_max_turns,
    tools: Tools = .{},
};

/// The directory holding the configuration: `$XDG_CONFIG_HOME/billy`, or
/// `$HOME/.config/billy` when that is unset, as the XDG base directory
/// specification prescribes.
pub fn defaultDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        // The specification says a relative path must be ignored.
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(arena, &.{ xdg, app_dir });
        }
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, ".config", app_dir });
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(first.created);
    try std.testing.expectEqual(default_max_turns, first.config.max_turns);

    // The file is now there, so a second open leaves it alone and reads it back.
    const second = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(!second.created);
    try std.testing.expectEqual(default_max_turns, second.config.max_turns);
}

test "open reads the max_turns and the bash format from the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An unknown field and a missing version must not stop the read.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"max_turns\":7,\"future\":true," ++
            "\"tools\":{\"bash\":{\"format\":\"shfmt | bat -l bash\",\"unknown\":1}}}",
    });

    const opened = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(!opened.created);
    try std.testing.expectEqual(7, opened.config.max_turns);
    try std.testing.expectEqualStrings("shfmt | bat -l bash", opened.config.tools.bash.format.?);
}

test "open leaves the bash format unset when the file does not set one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A session saved before the setting existed has no tools at all.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"max_turns\":7}",
    });
    const older = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(older.config.tools.bash.format == null);

    // A format of null is the same as not setting one.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data = "{\"tools\":{\"bash\":{\"format\":null}}}",
    });
    const explicit = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expect(explicit.config.tools.bash.format == null);
}

test "save round-trips a custom max_turns" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try (Config{ .max_turns = 3 }).save(std.testing.io, tmp.dir, gpa);

    const opened = try Config.open(std.testing.io, tmp.dir, allocator);
    try std.testing.expectEqual(3, opened.config.max_turns);
}

test "open rejects damaged, future and unusable configurations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{" });
    try std.testing.expectError(error.CorruptConfig, Config.open(std.testing.io, tmp.dir, allocator));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"version\":99}" });
    try std.testing.expectError(error.UnsupportedConfigVersion, Config.open(std.testing.io, tmp.dir, allocator));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"max_turns\":0}" });
    try std.testing.expectError(error.InvalidConfig, Config.open(std.testing.io, tmp.dir, allocator));
}
