//! The favicons of a web search: one small round bubble per result, which a page
//! shows in the summary of the call so the sources are visible while the call is
//! collapsed.

const std = @import("std");

const html = @import("../html.zig");
const Search = @import("../Tools/web/Search.zig");

/// Writes the favicons of a web search: one small round bubble per result,
/// holding the source's own favicon and opening its url. They sit in the
/// summary, so a page shows which sources were found without expanding the call.
///
/// A bubble is written only for a result with an `http(s)` address, since the
/// favicon is fetched from its host and the bubble opens it. A result billy
/// cannot link to is left to the body, and nothing is written at all for text
/// that is not a list of results, such as a search that matched nothing.
pub fn write(result: []const u8, out: *std.Io.Writer) !void {
    var origin_buffer: [256]u8 = undefined;
    var found = Search.Result.parse(result);
    while (found.next()) |one| {
        const origin = originOf(one.url, &origin_buffer) orelse continue;
        try bubble(one, origin, out);
    }
}

/// The host name of `url`, without the scheme, port or path.
fn hostOf(url: []const u8) ?[]const u8 {
    const after_scheme = if (std.mem.find(u8, url, "://")) |i| url[i + 3 ..] else url;
    const end = std.mem.findAny(u8, after_scheme, "/:") orelse after_scheme.len;
    const host = after_scheme[0..end];
    if (host.len == 0) return null;
    return host;
}

/// Writes one favicon bubble: the source's favicon, filling the round bubble and
/// cropping to it, with the source's first letter behind it so a site that has no
/// favicon still reads as a small bubble rather than a broken image. The host is
/// the bubble's tooltip, and the whole bubble opens the result.
fn bubble(found: Search.Result, origin: []const u8, out: *std.Io.Writer) !void {
    const host = hostOf(found.url) orelse return;
    try out.writeAll("<a class=\"fav\" href=\"");
    try html.escape(found.url, out);
    try out.writeAll("\" title=\"");
    try html.escape(host, out);
    try out.writeAll("\" target=\"_blank\" rel=\"noopener noreferrer\" onclick=\"event.stopPropagation()\">");
    try out.writeAll("<span class=\"letter\">");
    try html.escape(host[0..1], out);
    try out.writeAll("</span><img src=\"");
    try html.escape(origin, out);
    try out.writeAll("/favicon.ico\" alt=\"\" onerror=\"this.remove()\"></a>");
}

/// The origin of `url` -- its scheme and host, without the path -- written into
/// `buffer`, or null when it is not an `http(s)` address with a host. A result's
/// favicon is fetched from its origin, so a bubble only makes sense for a result
/// whose origin is one billy will fetch from.
fn originOf(url: []const u8, buffer: []u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return null;
    return std.mem.print(buffer, "{f}", .{uri.fmt(.{
        .scheme = true,
        .authority = true,
    })}) catch null;
}

test "a result with an http address is given a bubble, and one without is not" {
    const gpa = std.testing.allocator;

    // The text a search wrote: two results billy can link to, and one it cannot,
    // since a bubble's favicon is fetched from the host it opens.
    const text =
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
        "2. Local\n   /tmp/notes.html\n   Not a page.\n\n" ++
        "3. Docs\n   https://docs.example.org/page\n   Notes.\n";
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(text, &out.writer);

    const written = out.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "<a class=\"fav\""));
    // The host is the tooltip and the first letter sits behind the image, so a
    // site with no favicon still reads as a bubble.
    try std.testing.expect(std.mem.find(u8, written, "title=\"ziglang.org\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "<span class=\"letter\">d</span>") != null);
    try std.testing.expect(std.mem.find(u8, written, "/tmp/notes.html") == null);
    // The favicon comes from the result's origin, with the path left behind.
    try std.testing.expect(std.mem.find(u8, written, "https://docs.example.org/favicon.ico") != null);
}

test "text that is not a list of results is given no bubbles" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write("(no results)", &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "hostOf strips the scheme, port and path" {
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/chat/completions").?);
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com").?);
    try std.testing.expectEqualStrings("localhost", hostOf("http://localhost:8080/v1/chat/completions").?);
    try std.testing.expectEqualStrings("example.com", hostOf("example.com/v1").?);
    try std.testing.expect(hostOf("https://") == null);
}
