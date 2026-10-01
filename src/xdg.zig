//! Billy's own directories under the XDG base directory specification: where the
//! configuration and the data live. They differ only in the variable and the
//! fallback, so both are built here.

const std = @import("std");

/// Directory under the base that holds billy's files.
const app_dir = "billy";

/// `$` ++ `variable` ++ `/billy`, or `$HOME/` ++ `fallback` ++ `/billy` when the
/// variable is unset. The specification says an empty or relative path must be
/// ignored, so those fall through to `fallback` too.
pub fn dir(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    variable: []const u8,
    fallback: []const []const u8,
) ![]const u8 {
    if (environ.get(variable)) |xdg| {
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(gpa, &.{ xdg, app_dir });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const fallback_join = std.fs.path.fmtJoin(fallback);
    return std.fmt.allocPrint(gpa, "{s}{c}{f}{c}{s}", .{
        home,          std.fs.path.sep,
        fallback_join, std.fs.path.sep,
        app_dir,
    });
}

/// Checks a path `dir` built, freeing it: the caller owns what it returns.
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

    // With no variable set, the fallback under home is used.
    try environ.put("HOME", "/home/user");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
    try expectDir("/home/user/.config/billy", try dir(gpa, &environ, "XDG_CONFIG_HOME", config));

    try environ.put("XDG_DATA_HOME", "/data");
    try expectDir("/data/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));

    // An empty or relative path is ignored, as the specification says.
    try environ.put("XDG_DATA_HOME", "");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
    try environ.put("XDG_DATA_HOME", "relative");
    try expectDir("/home/user/.local/share/billy", try dir(gpa, &environ, "XDG_DATA_HOME", data));
}
