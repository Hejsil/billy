//! Reading a provider's reply: the JSON whatever shape it has, under the options billy holds every
//! reply to.

const std = @import("std");

/// `bytes` parsed as `T`, or `BadReply` after saying which `provider` could not read it.
pub fn parse(comptime provider: []const u8, T: type, gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("{s}: cannot read the reply: {t}", .{ provider, err });
        return error.BadReply;
    };
}
