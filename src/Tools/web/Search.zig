const std = @import("std");
const search = @import("../../search.zig");
const Tools = @import("../../Tools.zig");

const Search = @This();

query: []const u8,

/// Runs one web search and writes its results as text. No backend is configured
/// only when a resumed session carries the tool from a run that had one; the
/// model is told so rather than the call failing outright.
pub fn run(s: Search, gpa: std.mem.Allocator, client: *search.Client, out: *std.Io.Writer) !void {
    // The search builds its answer in an arena of its own, which is dropped once
    // the text has been written on.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const text = client.search(arena_state.allocator(), s.query) catch |err| switch (err) {
        // Every backend is set aside after failing, which is what the user can
        // fix: one backend is a single point of failure.
        error.AllBackendsSetAside => return Tools.fail(
            out,
            "every search backend is set aside after failing; add another to tools.web_search.providers, or wait",
            .{},
        ),
        else => return Tools.fail(out, "search failed: {s}", .{@errorName(err)}),
    };
    try out.writeAll(text);
}
