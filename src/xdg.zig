//! Billy's own directories under the XDG base directory specification: where the configuration and
//! the data live.

const std = @import("std");

const report = @import("report.zig");

const app_dir = "billy";

/// `$` ++ `variable` ++ `/billy`, or `$HOME/` ++ `fallback` ++ `/billy` when the variable is unset.
pub fn dir(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    variable: []const u8,
    fallback: []const []const u8,
) ![]const u8 {
    if (environ.get(variable)) |xdg| {
        if (xdg.len > 0 and std.Io.Dir.path.isAbsolute(xdg)) {
            return std.Io.Dir.path.join(gpa, &.{ xdg, app_dir });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const fallback_join = std.Io.Dir.path.fmtJoin(fallback);
    return gpa.print("{s}{c}{f}{c}{s}", .{
        home,          std.Io.Dir.path.sep,
        fallback_join, std.Io.Dir.path.sep,
        app_dir,
    });
}

/// Opens `path` as a directory, creating it and any of its parents.
pub fn openDir(io: std.Io, path: []const u8, what: []const u8) !std.Io.Dir {
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{}) catch |err| {
        std.log.err("cannot use {s} for {s}: {s}", .{ path, what, @errorName(err) });
        return report.Reported;
    };
}

/// The directory `built` names, made if it is not there yet, where `built` is the result of working
/// the path out: a `![]const u8`, before the error has been looked at.
pub fn openDirBuilt(io: std.Io, built: anytype, what: []const u8) !std.Io.Dir {
    const path = built catch |err| {
        std.log.err("cannot find where to store {s}: {s}", .{ what, @errorName(err) });
        return report.Reported;
    };
    return openDir(io, path, what);
}

fn expectDir(expected: []const u8, actual: []const u8) !void {
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "dir follows the XDG base directory specification" {
    const gpa = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();

    const data: []const []const u8 = &.{ ".local", "share" };
    const config: []const []const u8 = &.{".config"};

    try std.testing.expectError(error.HomeNotSet, dir(gpa, &environ, "XDG_DATA_HOME", data));

    try environ.put("HOME", "/home/user");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
    try expectDir("/home/user/.config/billy", try dir(gpa, &environ, "XDG_CONFIG_HOME", config));

    try environ.put("XDG_DATA_HOME", "/data");
    try expectDir("/data/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));

    try environ.put("XDG_DATA_HOME", "");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
    try environ.put("XDG_DATA_HOME", "relative");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
}

test "openDir creates the directory and its parents" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var requested: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const path = try std.mem.print(&requested, "/tmp/billy-open-dir-{s}/a/b", .{
        std.fmt.bytesToHex(suffix, .lower),
    });
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    var opened = try openDir(io, path, "the test's directory");
    defer opened.close(io);

    try opened.writeFile(io, .{ .sub_path = "marker", .data = "x" });
    const joined = try std.Io.Dir.path.join(gpa, &.{ path, "marker" });
    defer gpa.free(joined);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, joined, gpa, .unlimited);
    defer gpa.free(written);
    try std.testing.expectEqualStrings("x", written);
}
