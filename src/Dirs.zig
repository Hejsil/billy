//! The directories billy keeps its files in: what it must not lose under the data directory, what
//! it may lose under the cache directory, and the configuration under the configuration directory.

const std = @import("std");

const xdg = @import("xdg.zig");

const Dirs = @This();

data: std.Io.Dir,
cache: std.Io.Dir,
config: std.Io.Dir,
sessions: std.Io.Dir,

/// Opens every directory billy uses, making each one if it is not there yet.
pub fn open(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !Dirs {
    var data = try xdg.openDirBuilt(io, dataPath(arena, environ), "billy's files");
    errdefer data.close(io);

    var cache = try xdg.openDirBuilt(io, cachePath(arena, environ), "billy's cache");
    errdefer cache.close(io);

    var config = try xdg.openDirBuilt(io, configPath(arena, environ), "the configuration");
    errdefer config.close(io);

    var sessions = try xdg.openDirBuilt(io, sessionsPath(arena, environ), "sessions");
    errdefer sessions.close(io);

    return .{
        .data = data,
        .cache = cache,
        .config = config,
        .sessions = sessions,
    };
}

pub fn deinit(dirs: *Dirs, io: std.Io) void {
    dirs.sessions.close(io);
    dirs.config.close(io);
    dirs.cache.close(io);
    dirs.data.close(io);
}

fn dataPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return xdg.dir(gpa, environ, "XDG_DATA_HOME", &.{ ".local", "share" });
}

fn cachePath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return xdg.dir(gpa, environ, "XDG_CACHE_HOME", &.{".cache"});
}

fn configPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return xdg.dir(gpa, environ, "XDG_CONFIG_HOME", &.{".config"});
}

fn sessionsPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const data = try dataPath(gpa, environ);
    defer gpa.free(data);

    return std.Io.Dir.path.join(gpa, &.{ data, "sessions" });
}

test "each directory is the right one under each base" {
    const gpa = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");

    // The rules themselves are `xdg.dir`'s; this only pins which base each of billy's directories
    // is under, and that the sessions sit inside the data directory rather than beside it.
    const data = try dataPath(gpa, &environ);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy", data);

    const cache = try cachePath(gpa, &environ);
    defer gpa.free(cache);
    try std.testing.expectEqualStrings("/home/user/.cache/billy", cache);

    const config = try configPath(gpa, &environ);
    defer gpa.free(config);
    try std.testing.expectEqualStrings("/home/user/.config/billy", config);

    const sessions = try sessionsPath(gpa, &environ);
    defer gpa.free(sessions);
    try std.testing.expectEqualStrings("/home/user/.local/share/billy/sessions", sessions);
}
