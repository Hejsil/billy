//! The HTTP plumbing the model client, the web tools and the catalog share: what
//! billy calls itself, and reading a response body.

const std = @import("std");

/// What billy calls itself to a service, rather than leaving the HTTP client's
/// own name, which is the standard library's. A provider that watches its
/// traffic for abuse asks to know what is talking to it.
pub const user_agent = "billy/1.0";

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
    // `readerDecompressing` fills this in before anything is read from it, which
    // is what its `*Decompress` argument is for; there is no value to give it
    // first, and `.none` wants a reader that does not exist yet.
    // zlinter-disable-next-line no_unsafe_undefined - filled in before it is read
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = try reader.streamRemaining(&body.writer);
    return body.toOwnedSlice();
}
