//! The web tools, and the HTTP plumbing every provider they use shares.

const std = @import("std");
const Health = @import("../Health.zig");
const tools = @import("../Tools.zig");

pub const Search = @import("web/Search.zig");
pub const Fetch = @import("web/Fetch.zig");
pub const outcome = @import("web/Outcome.zig");

/// What one request to a provider came back with: the body, or the wait the
/// provider asked for before it is asked again.
pub const Answer = union(enum) {
    text: []const u8,
    retry_after_ms: i64,
};

/// Does one request and returns its body, owned by `gpa`, or the wait the
/// provider asked for.
///
/// This is `std.http.Client.fetch` done by hand, because `fetch` throws the
/// response headers away and a `Retry-After` is one of them: what the provider
/// asked to be waited is read here and handed back rather than kept beside the
/// client. The body is read the way `fetch` reads it, so a compressed reply
/// still parses.
pub fn request(
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    method: std.http.Method,
    location: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    what: []const u8,
) !Answer {
    var req = try http.request(method, try std.Uri.parse(location), .{
        // A redirect is followed, so an endpoint that moved still answers.
        .redirect_behavior = @fromBackingInt(@intCast(3)),
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
        },
        .extra_headers = headers,
    });
    defer req.deinit();

    if (payload) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var sending = try req.sendBodyUnflushed(&.{});
        try sending.writer.writeAll(body);
        try sending.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // What the provider asked to be waited, when it said, is the answer: a
    // provider that is rate-limited is not one that is broken.
    const retry_after_ms = Health.retryAfterMs(response.head.bytes);

    if (response.head.status.class() != .success) {
        // A provider failing is a warning rather than an error: with more than
        // one configured the caller tries the next, and the failure is reported
        // to the model as the result of the call.
        std.log.warn("{s}: HTTP {d}", .{ what, @backingInt(response.head.status) });
        const discarded = response.reader(&.{});
        _ = discarded.discardRemaining() catch {};
        if (retry_after_ms) |ms| return .{ .retry_after_ms = @intCast(@min(ms, max_retry_after_ms)) };
        return error.RequestFailed;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);

    var body_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer body_writer.deinit();

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = try reader.streamRemaining(&body_writer.writer);

    return .{ .text = try body_writer.toOwnedSlice() };
}

/// A url carrying `query` as the `q` parameter, followed by `tail`, which is
/// whatever else the provider wants such as a result count. The query is
/// percent-encoded, so a space or an `&` in it is part of the value rather than
/// breaking the url.
pub fn queryUrl(
    gpa: std.mem.Allocator,
    base: []const u8,
    query: []const u8,
    comptime tail: []const u8,
    tail_args: anytype,
) ![]const u8 {
    var url: std.Io.Writer.Allocating = .init(gpa);
    defer url.deinit();
    try url.writer.print("{s}?q=", .{base});
    for (query) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try url.writer.writeByte(c),
        else => try url.writer.print("%{x:0>2}", .{c}),
    };
    try url.writer.print(tail, tail_args);
    return url.toOwnedSlice();
}

/// The longest a `Retry-After` is honored, so a provider cannot set billy aside
/// for longer than the waits ever reach anyway.
const max_retry_after_ms: u64 = @intCast(Health.max_wait_ms);
