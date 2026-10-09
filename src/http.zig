//! Reading a response body, which the model client and the web tools both do.

const std = @import("std");

/// Reads the rest of `response`'s body, decompressed, into memory owned by `gpa`.
/// It is read the way `std.http.Client.fetch` reads it, so a compressed reply still
/// parses.
pub fn readBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = try reader.streamRemaining(&body.writer);
    return body.toOwnedSlice();
}
