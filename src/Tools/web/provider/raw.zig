//! Raw: the url itself, read directly rather than extracted by a service.

const std = @import("std");
const transport = @import("../../web.zig");
const outcome = @import("../Outcome.zig");

/// Reads `url` directly with a GET: the bytes as the server sent them.
pub fn fetch(gpa: std.mem.Allocator, http: *std.http.Client, url: []const u8) !outcome.Value {
    return switch (try transport.request(gpa, http, .GET, url, null, &.{}, "fetch")) {
        .text => |text| .{ .text = text },
        .retry_after_ms => |ms| .{ .retry_after_ms = ms },
    };
}

const Mock = @import("../../../Mock.zig");

test "a raw fetch reads the url directly, and keeps the bytes as they are" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The bytes come back exactly as sent, so a JSON body is not escaped as
    // markdown, which is what a service would do to it.
    const reply = "{\"node_id\":\"abc\",\"full_name\":\"a/b\"}";
    var mock = try Mock.start("/api", 1, Mock.fixed(reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const value = try fetch(gpa, &http, mock.url);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // No authorization went out: the url was read directly, not through a
    // service.
    try std.testing.expect(mock.header("authorization") == null);
    try std.testing.expectEqualStrings(reply, value.text);
}

test "a raw fetch keeps a body of any size whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Larger than the 1 MiB the read used to be cut to.
    const reply: [(1 << 20) + 10]u8 = @splat('x');
    var mock = try Mock.start("/big", 1, Mock.fixed(&reply));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    const value = try fetch(gpa, &http, mock.url);
    defer gpa.free(value.text);
    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(reply.len, value.text.len);
}
