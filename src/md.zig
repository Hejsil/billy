//! Markdown, rendered to HTML by md4c.
//!
//! md4c is a CommonMark implementation, so what a reply is written in is read
//! the way every other markdown reader reads it rather than by billy's own
//! approximation of it. It is a C library, fetched with the package manager and
//! built into the module (see `build.zig`); this is the whole of billy's contact
//! with it.
//!
//! Everything a model writes reaches the page escaped: md4c escapes the text it
//! writes, raw HTML is turned off below, and the address of any link is checked
//! before it is written, so a reply that contains markup shows it, and a reply
//! that links to `javascript:` gets a link that does nothing.

const std = @import("std");
const Io = std.Io;

const c = @cImport({
    @cInclude("md4c.h");
    @cInclude("md4c-html.h");
});

/// What a reply is allowed to use, on top of plain CommonMark.
///
/// The GitHub extensions a model reaches for are turned on -- tables,
/// strikethrough, task lists, and links written as bare addresses -- and raw
/// HTML is turned off, so a `<` in a reply is a `<` on the page rather than the
/// start of a tag. That is the same promise the rest of the renderer keeps, and
/// it is what makes a model's reply safe to put in a page.
const flags: c_uint = c.MD_FLAG_TABLES |
    c.MD_FLAG_STRIKETHROUGH |
    c.MD_FLAG_TASKLISTS |
    c.MD_FLAG_PERMISSIVEAUTOLINKS |
    c.MD_FLAG_NOHTMLBLOCKS |
    c.MD_FLAG_NOHTMLSPANS;

/// Renders `text` as HTML onto `out`.
///
/// The markdown is read by md4c, and the HTML it produces is then written on
/// with every link address checked (`writeSafeUrls`), which is the one thing
/// md4c leaves to its caller. `gpa` is for the rendered form, which is held
/// whole so it can be scanned; it is dropped before this returns.
pub fn toHtml(gpa: std.mem.Allocator, text: []const u8, out: *Io.Writer) !void {
    var rendered: std.Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();

    var sink = Sink{ .out = &rendered.writer };
    const result = c.md_html(text.ptr, @intCast(text.len), emit, &sink, flags, 0);
    // A write that failed is what stopped it, so that failure is reported rather
    // than the generic one md4c returns after a failed callback.
    if (sink.err) |err| return err;
    if (result < 0) return error.MarkdownFailed;

    try writeSafeUrls(rendered.written(), out);
}

/// Where md4c's output goes, and the first failure of writing it. md4c is given
/// a pointer to this as its `userdata`, and hands it back with each chunk.
const Sink = struct {
    out: *Io.Writer,
    /// The first failure of the writer, kept because the callback cannot return
    /// one. Null until a write fails.
    err: ?Io.Writer.Error = null,
};

/// Writes one chunk of md4c's output, keeping the failure if there is one. The
/// callback is C, so it returns nothing; the failure travels back in the sink.
fn emit(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(userdata.?));
    if (sink.err != null) return;
    sink.out.writeAll(text[0..size]) catch |err| {
        sink.err = err;
    };
}

/// Writes `html` on, with the address of any link or image made to do nothing
/// when it could run code.
///
/// md4c renders a `javascript:` link as a link, as a CommonMark renderer should:
/// it reads markdown, it does not sanitize it. A page is not the place for one,
/// so an address that could run code is replaced with `#`.
///
/// The two attributes searched for are the only two md4c writes an address in,
/// and a reply cannot smuggle one in as text: md4c escapes the quotes in a
/// reply, so a reply that writes `href="` reaches the page as `href=&quot;`.
fn writeSafeUrls(html: []const u8, out: *Io.Writer) !void {
    var at: usize = 0;
    while (nextAddress(html, at)) |address| {
        try out.writeAll(html[at..address.start]);
        if (safeAddress(address.value, address.is_link)) {
            try out.writeAll(html[address.start..address.end]);
        } else {
            // The attribute, kept, with an address that goes nowhere.
            try out.writeAll(caps[@intFromBool(address.is_link)]);
            try out.writeAll("#\"");
        }
        at = address.end;
    }
    try out.writeAll(html[at..]);
}

/// One address found in the rendered HTML: where its attribute begins, where it
/// ends past the closing quote, the value between the quotes, and whether it is
/// a link (as opposed to an image).
const Address = struct {
    start: usize,
    end: usize,
    value: []const u8,
    is_link: bool,
};

/// The openings of the two attributes an address is written in, indexed by
/// whether the attribute is a link.
const caps = [_][]const u8{ "src=\"", "href=\"" };

/// The first address at or after `from`, or null when there is none.
fn nextAddress(html: []const u8, from: usize) ?Address {
    const href = std.mem.indexOfPos(u8, html, from, caps[1]);
    const src = std.mem.indexOfPos(u8, html, from, caps[0]);
    const start = switch ((href != null) and (src != null)) {
        true => @min(href.?, src.?),
        false => href orelse src orelse return null,
    };
    const is_link = start == href;

    const value_start = start + caps[@intFromBool(is_link)].len;
    const close = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse return null;
    return .{
        .start = start,
        .end = close + 1,
        .value = html[value_start..close],
        .is_link = is_link,
    };
}

/// Whether the address `url` is one that is safe to put in a page. A leading run
/// of whitespace or control characters is skipped, since a browser skips it too
/// when it reads the scheme, and the scheme is then compared without regard to
/// case.
///
/// A link is held to more than an image: `data:` in a link is another document
/// to open, which is what a reply has no business doing, while an image loaded
/// from `data:` is how a picture is written without a host to fetch it from.
fn safeAddress(url: []const u8, is_link: bool) bool {
    const address = std.mem.trimStart(u8, url, " \t\r\n\x00\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e\x0f");
    const schemes: []const []const u8 = if (is_link)
        &.{ "javascript:", "vbscript:", "data:" }
    else
        &.{ "javascript:", "vbscript:" };
    for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(address, scheme)) return false;
    }
    return true;
}

test "markdown is rendered the way CommonMark reads it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try toHtml(gpa, "# Title\n\nsome *text*\n", &out.writer);
    try std.testing.expectEqualStrings("<h1>Title</h1>\n<p>some <em>text</em></p>\n", out.written());
}

test "a nested list is a nested list" {
    // The shape billy's own renderer got wrong: a numbered item with detail
    // indented under it.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try toHtml(gpa, "1. one\n   - nested\n2. two\n", &out.writer);
    try std.testing.expectEqualStrings(
        "<ol>\n<li>one<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>two</li>\n</ol>\n",
        out.written(),
    );
}

test "raw HTML in the text stays text" {
    // A reply is put into a page, so a tag a model writes is shown rather than
    // obeyed, and it is escaped on the way in.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try toHtml(gpa, "<script>alert(1)</script>\n", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "&lt;script&gt;") != null);
}

test "an address that could run code is made to do nothing" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A link that runs code, however its scheme is spelled, gets an address that
    // does nothing; the safe ones are left as they are.
    try toHtml(gpa, "[a](javascript:alert(1))\n\n[b](JavaScript:x)\n\n[c](vbscript:x)\n\n" ++
        "[d](data:text/html,<b>)\n\n[e](https://example.com/a?b=1&c=2)\n\n[f](/docs)\n", &out.writer);
    try std.testing.expectEqualStrings(
        "<p><a href=\"#\">a</a></p>\n" ++
            "<p><a href=\"#\">b</a></p>\n" ++
            "<p><a href=\"#\">c</a></p>\n" ++
            "<p><a href=\"#\">d</a></p>\n" ++
            "<p><a href=\"https://example.com/a?b=1&amp;c=2\">e</a></p>\n" ++
            "<p><a href=\"/docs\">f</a></p>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An image is held to the same for a scheme that runs code, but a `data:`
    // image is how a picture is written, so it is kept.
    try toHtml(gpa, "![a](javascript:x)\n\n![b](data:image/png;base64,AAAA)\n", &out.writer);
    try std.testing.expectEqualStrings(
        "<p><img src=\"#\" alt=\"a\"></p>\n" ++
            "<p><img src=\"data:image/png;base64,AAAA\" alt=\"b\"></p>\n",
        out.written(),
    );
}

test "a reply cannot forge an address attribute" {
    // Raw HTML is off and text is escaped, so a reply that writes an attribute
    // writes the text of one; only md4c's own attributes are rewritten.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try toHtml(gpa, "an <a href=\"javascript:x\"> tag\n", &out.writer);
    try std.testing.expectEqualStrings(
        "<p>an &lt;a href=&quot;javascript:x&quot;&gt; tag</p>\n",
        out.written(),
    );
}

test "the GitHub extensions a reply uses are on" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A fenced block keeps its language, which is what a highlighter would hang
    // off; a table is a table; `~~` strikes through.
    try toHtml(gpa, "```zig\nconst x = 1;\n```\n", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<pre><code class=\"language-zig\">") != null);

    out.clearRetainingCapacity();
    try toHtml(gpa, "| a | b |\n|---|---|\n| 1 | 2 |\n", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<table>") != null);

    out.clearRetainingCapacity();
    try toHtml(gpa, "~~gone~~ and https://example.com\n", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<del>gone</del>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<a href=\"https://example.com\">") != null);
}
