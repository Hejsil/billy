//! Raw: the url itself, read directly rather than extracted by a service.

const std = @import("std");
const transport = @import("../../web.zig");
const outcome = @import("../Outcome.zig");

/// Reads `url` directly with a GET: the bytes as the server sent them, capped so
/// one large response cannot exhaust memory.
pub fn fetch(gpa: std.mem.Allocator, http: *std.http.Client, url: []const u8) !outcome.Value {
    const text = switch (try transport.request(gpa, http, .GET, url, null, &.{}, "fetch")) {
        .text => |text| text,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    return .{ .text = try gpa.realloc(text, @min(text.len, max_fetch_bytes)) };
}

/// Most bytes a direct read keeps, so one large response cannot exhaust memory.
/// A page comes through a service instead, which trims it; this is for the url
/// read as it is, where an API or a file is small.
const max_fetch_bytes = 1 << 20;

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
