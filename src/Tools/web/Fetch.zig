const std = @import("std");
const search = @import("../../search.zig");

const Fetch = @This();

url: []const u8,
/// Read the url directly instead of extracting a page, for an address
/// whose bytes are wanted as they are, such as a JSON API. Extraction
/// escapes its text as markdown, which would mangle it.
raw: bool = false,

/// Fetches one url and writes its content as text. A page is extracted by the
/// backend; `raw` reads the url directly, for an API or a file. Like a search, a
/// fetch is offered only when a backend is configured, which is what the client
/// carries.
pub fn run(fetch: Fetch, gpa: std.mem.Allocator, client: *search.Client, out: *std.Io.Writer) !void {
    if (fetch.url.len == 0) return out.writeAll("error: no url to fetch");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const text = client.extract(arena_state.allocator(), fetch.url, fetch.raw) catch |err|
        return out.print("fetch failed: {s}", .{@errorName(err)});
    try out.writeAll(text);
}
