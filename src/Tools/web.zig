//! The web tools, and the HTTP plumbing every provider they use shares.

const std = @import("std");
const Health = @import("../Health.zig");

pub const Search = @import("web/Search.zig");
pub const Fetch = @import("web/Fetch.zig");

/// What a call to a provider came back with: its text, or the wait the provider
/// asked for before it is asked again. The text is the response body for
/// `request`, and what the model reads for a provider's `search` or `fetch`.
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
        .headers = .{
            .content_type = if (payload) |_| .{ .override = "application/json" } else .default,
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

/// What `requestJson` came back with: the reply parsed as `T`, or the wait the
/// provider asked for.
pub fn JsonAnswer(comptime T: type) type {
    return union(enum) {
        parsed: std.json.Parsed(T),
        retry_after_ms: i64,
    };
}

/// As `request`, for a provider whose reply is JSON of type `T`. The parsed reply
/// owns its strings. A reply that does not parse is `error.BadReply`.
pub fn requestJson(
    comptime T: type,
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    method: std.http.Method,
    location: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    what: []const u8,
) !JsonAnswer(T) {
    const text = switch (try request(gpa, http, method, location, payload, headers, what)) {
        .text => |text| text,
        .retry_after_ms => |ms| return .{ .retry_after_ms = ms },
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(T, gpa, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("{s}: cannot read the reply: {s}", .{ what, @errorName(err) });
        return error.BadReply;
    };
    return .{ .parsed = parsed };
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

const Mock = @import("../Mock.zig");

test "a JSON reply is parsed, and one of another shape is a bad reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Shape = struct { a: u32 };

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var good = try Mock.start("/x", 1, Mock.fixed("{\"a\":7,\"extra\":1}"));
    defer good.deinit();
    try good.serve();
    const answer = try requestJson(Shape, gpa, &http, .GET, good.url, null, &.{}, "search");
    defer answer.parsed.deinit();
    try good.group.await(io);
    if (good.err) |err| return err;
    try std.testing.expectEqual(7, answer.parsed.value.a);

    var bad = try Mock.start("/x", 1, Mock.fixed("not json"));
    defer bad.deinit();
    try bad.serve();
    try std.testing.expectError(
        error.BadReply,
        requestJson(Shape, gpa, &http, .GET, bad.url, null, &.{}, "search"),
    );
    try bad.group.await(io);
    if (bad.err) |err| return err;
}
