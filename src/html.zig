//! Rendering for the web frontend: the HTML a browser is given.
//!
//! Everything a model writes, a file holds or a user types reaches a page as
//! text and nowhere else, so every one of those is escaped before it is written.
//! A `<` in a file billy read is a `<` on the page, not the start of a tag.
//!
//! The markdown a reply is written in is read as CommonMark by md4c, not by an
//! approximation of it (`markdown`, and `md.zig`). Only the display changes: what
//! a session stores and what the model is sent keep the markdown as written.
//!
//! A tool call is a `<details>` a page shows collapsed, so a conversation with
//! many calls stays readable: the summary is the call's head and the body is what
//! it ran and what it produced.

const std = @import("std");
const Io = std.Io;
const agent = @import("agent.zig");
const diffing = @import("diff.zig");
const md = @import("md.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Tools = @import("Tools.zig");

/// Writes `text` with the characters that mean something in HTML replaced by the
/// entities that mean the characters themselves. This is what every string
/// coming from outside billy passes through before it reaches a page, so nothing
/// a model or a file writes can become markup.
pub fn escape(text: []const u8, out: *Io.Writer) !void {
    var plain: usize = 0;
    for (text, 0..) |byte, i| {
        const entity = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            // The hex form, which is what md4c writes, so billy's own escaping
            // and the markdown renderer's agree character for character.
            '\'' => "&#x27;",
            else => continue,
        };
        try out.writeAll(text[plain..i]);
        try out.writeAll(entity);
        plain = i + 1;
    }
    try out.writeAll(text[plain..]);
}

/// A writer that escapes everything written into it and passes it to another
/// writer. It is for text that something else has to build: a path the header
/// shortens, or any other value a helper writes rather than returns. Without it
/// such text would reach the page as markup, since the helper that wrote it knows
/// nothing about HTML.
///
/// Nothing is buffered, so every write is escaped as it comes. Escaping byte by
/// byte is safe across calls because each byte is escaped on its own: no entity
/// is ever split between one call and the next.
const Escaping = struct {
    inner: *Io.Writer,
    writer: Io.Writer,

    fn init(inner: *Io.Writer) Escaping {
        return .{
            .inner = inner,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Escaping = @alignCast(@fieldParentPtr("writer", w));

        // The last slice is the one repeated `splat` times, so it is written
        // that many times; the rest are written once each. Everything offered is
        // consumed, whether or not the escaping makes it longer.
        for (data[0 .. data.len - 1]) |bytes| try escape(bytes, self.inner);
        const pattern = data[data.len - 1];
        var left = splat;
        while (left > 0) : (left -= 1) try escape(pattern, self.inner);

        var offered: usize = pattern.len * splat;
        for (data[0 .. data.len - 1]) |bytes| offered += bytes.len;
        return offered;
    }
};

/// Writes the markdown of a reply or a prompt as HTML.
///
/// The markdown is read by md4c, a CommonMark parser (`md.zig`), and rendered
/// here: each block, span and run of text md4c reports is turned into the HTML
/// for it. Driving the parser rather than calling md4c's own renderer is what
/// lets billy check a link's address before writing it -- md4c renders a
/// `javascript:` link as a link, and a reply must not be able to make one that
/// runs code.
///
/// Everything a model writes is escaped, and raw HTML is turned off
/// (`md.flags`), so a tag in a reply is shown rather than obeyed.
pub fn markdown(gpa: std.mem.Allocator, text: []const u8, out: *Io.Writer) !void {
    var render = Markdown{ .gpa = gpa, .out = out };
    var parser = Markdown.parser();
    try md.parse(text, &parser, &render);
    // A callback cannot return an error, so a failed write is kept on the
    // renderer and reported here, once md4c has stopped.
    if (render.err) |err| return err;
}

/// Renders one document. It is the `userdata` md4c hands back to every callback,
/// and holds the writer each piece goes to.
///
/// md4c's callbacks say *what* a piece of the document is, and this writes the
/// HTML for it: the tags are the ones a CommonMark renderer writes, so the page
/// gets the markup it expects, with a link's address checked on the way
/// (`safeAddress`).
const Markdown = struct {
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    /// The first failure of the writer. A callback returns a number, not an
    /// error, so the failure is kept here and reported once the parse is over.
    err: ?Io.Writer.Error = null,
    /// How deep inside an image label this is. The text of a label is an
    /// attribute, so no tags are written there and a line break becomes a space.
    image_depth: usize = 0,

    /// The callbacks md4c reads the document with. None of them take any state
    /// of their own but the renderer `md4c` passes back as `userdata`.
    fn parser() md.c.MD_PARSER {
        return .{
            .abi_version = 0,
            .flags = md.flags,
            .enter_block = enterBlock,
            .leave_block = leaveBlock,
            .enter_span = enterSpan,
            .leave_span = leaveSpan,
            .text = writeText,
            .debug_log = null,
            .syntax = null,
        };
    }

    /// Writes `text` on, keeping the failure if there is one. Returns whether the
    /// write worked, so a callback can stop the parse: md4c stops at the first
    /// callback that returns non-zero.
    fn put(self: *Markdown, text: []const u8) bool {
        self.out.writeAll(text) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    /// Writes a formatted run of HTML, where `put` writes text as it is. Returns
    /// whether the write worked, so a callback can stop the parse the same way.
    fn print(self: *Markdown, comptime format: []const u8, args: anytype) bool {
        self.out.print(format, args) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    /// Writes `text` escaped, so nothing in it can become markup.
    fn putEscaped(self: *Markdown, text: []const u8) bool {
        escape(text, self.out) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    // ---- blocks ----

    fn openBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
        switch (block_type) {
            md.c.MD_BLOCK_DOC => {},
            md.c.MD_BLOCK_QUOTE => return self.put("<blockquote>\n"),
            md.c.MD_BLOCK_UL => return self.put("<ul>\n"),
            md.c.MD_BLOCK_OL => return self.openOl(@ptrCast(@alignCast(detail.?))),
            md.c.MD_BLOCK_LI => return self.openLi(@ptrCast(@alignCast(detail.?))),
            md.c.MD_BLOCK_HR => return self.put("<hr>\n"),
            md.c.MD_BLOCK_H => {
                const head: *const md.c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
                return self.put(heading_open[head.level - 1]);
            },
            md.c.MD_BLOCK_CODE => return self.openCode(@ptrCast(@alignCast(detail.?))),
            md.c.MD_BLOCK_P => return self.put("<p>"),
            md.c.MD_BLOCK_TABLE => return self.put("<table>\n"),
            md.c.MD_BLOCK_THEAD => return self.put("<thead>\n"),
            md.c.MD_BLOCK_TBODY => return self.put("<tbody>\n"),
            md.c.MD_BLOCK_TR => return self.put("<tr>\n"),
            md.c.MD_BLOCK_TH => return self.openCell("th", @ptrCast(@alignCast(detail.?))),
            md.c.MD_BLOCK_TD => return self.openCell("td", @ptrCast(@alignCast(detail.?))),
            // Raw HTML never reaches here: `md.flags` turns it off, so it comes
            // as text and is escaped. Anything else is a block of an extension
            // billy does not read.
            else => {},
        }
        return true;
    }

    fn closeBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
        switch (block_type) {
            md.c.MD_BLOCK_DOC => {},
            md.c.MD_BLOCK_QUOTE => return self.put("</blockquote>\n"),
            md.c.MD_BLOCK_UL => return self.put("</ul>\n"),
            md.c.MD_BLOCK_OL => return self.put("</ol>\n"),
            md.c.MD_BLOCK_LI => return self.put("</li>\n"),
            md.c.MD_BLOCK_HR => {},
            md.c.MD_BLOCK_H => {
                const head: *const md.c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
                return self.put(heading_close[head.level - 1]);
            },
            md.c.MD_BLOCK_CODE => return self.put("</code></pre>\n"),
            md.c.MD_BLOCK_P => return self.put("</p>\n"),
            md.c.MD_BLOCK_TABLE => return self.put("</table>\n"),
            md.c.MD_BLOCK_THEAD => return self.put("</thead>\n"),
            md.c.MD_BLOCK_TBODY => return self.put("</tbody>\n"),
            md.c.MD_BLOCK_TR => return self.put("</tr>\n"),
            md.c.MD_BLOCK_TH => return self.put("</th>\n"),
            md.c.MD_BLOCK_TD => return self.put("</td>\n"),
            else => {},
        }
        return true;
    }

    /// A list that starts at a number other than one keeps it, so a list written
    /// from 3 shows 3, 4, 5 rather than 1, 2, 3.
    fn openOl(self: *Markdown, detail: *const md.c.MD_BLOCK_OL_DETAIL) bool {
        if (detail.start == 1) return self.put("<ol>\n");
        return self.print("<ol start=\"{d}\">\n", .{detail.start});
    }

    /// A task item is a disabled checkbox, so a `- [x]` reads as a checked box
    /// rather than as its own text.
    fn openLi(self: *Markdown, detail: *const md.c.MD_BLOCK_LI_DETAIL) bool {
        if (detail.is_task == 0) return self.put("<li>");
        if (!self.put("<li class=\"task-list-item\">" ++
            "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled")) return false;
        if ((detail.task_mark == 'x' or detail.task_mark == 'X') and !self.put(" checked")) return false;
        return self.put(">");
    }

    /// A fenced block keeps its language, which is what a highlighter would hang
    /// off: `class="language-zig"`. An indented block has no language.
    fn openCode(self: *Markdown, detail: *const md.c.MD_BLOCK_CODE_DETAIL) bool {
        if (!self.put("<pre><code")) return false;
        if (detail.lang.text != null) {
            if (!self.put(" class=\"language-")) return false;
            if (self.writeAttribute(&detail.lang, .text) == false) return false;
            if (!self.put("\"")) return false;
        }
        return self.put(">");
    }

    /// A table cell, with the alignment the table asked for.
    fn openCell(self: *Markdown, tag: []const u8, detail: *const md.c.MD_BLOCK_TD_DETAIL) bool {
        if (!self.put("<")) return false;
        if (!self.put(tag)) return false;
        return switch (detail.@"align") {
            md.c.MD_ALIGN_LEFT => self.put(" align=\"left\">"),
            md.c.MD_ALIGN_CENTER => self.put(" align=\"center\">"),
            md.c.MD_ALIGN_RIGHT => self.put(" align=\"right\">"),
            else => self.put(">"),
        };
    }

    // ---- spans ----

    fn openSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        const inside_image = self.image_depth > 0;
        if (span_type == md.c.MD_SPAN_IMG) self.image_depth += 1;
        // Inside an image label only the text matters: it is the alt text, and a
        // tag written there would break out of the attribute.
        if (inside_image) return true;

        switch (span_type) {
            md.c.MD_SPAN_EM => return self.put("<em>"),
            md.c.MD_SPAN_STRONG => return self.put("<strong>"),
            md.c.MD_SPAN_A => return self.openA(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_IMG => return self.openImg(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_CODE => return self.put("<code>"),
            md.c.MD_SPAN_INS => return self.put("<ins>"),
            md.c.MD_SPAN_DEL => return self.put("<del>"),
            md.c.MD_SPAN_U => return self.put("<u>"),
            md.c.MD_SPAN_MARK => return self.put("<mark>"),
            md.c.MD_SPAN_SUPERSCRIPT => return self.put("<sup>"),
            md.c.MD_SPAN_SUBSCRIPT => return self.put("<sub>"),
            else => {},
        }
        return true;
    }

    fn closeSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        if (span_type == md.c.MD_SPAN_IMG) self.image_depth -= 1;
        if (self.image_depth > 0) return true;

        switch (span_type) {
            md.c.MD_SPAN_EM => return self.put("</em>"),
            md.c.MD_SPAN_STRONG => return self.put("</strong>"),
            md.c.MD_SPAN_A => return self.put("</a>"),
            md.c.MD_SPAN_IMG => return self.closeImg(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_CODE => return self.put("</code>"),
            md.c.MD_SPAN_INS => return self.put("</ins>"),
            md.c.MD_SPAN_DEL => return self.put("</del>"),
            md.c.MD_SPAN_U => return self.put("</u>"),
            md.c.MD_SPAN_MARK => return self.put("</mark>"),
            md.c.MD_SPAN_SUPERSCRIPT => return self.put("</sup>"),
            md.c.MD_SPAN_SUBSCRIPT => return self.put("</sub>"),
            else => {},
        }
        return true;
    }

    /// A link. Its address is checked, so one that could run code is written as a
    /// link that goes nowhere (`safeAddress`).
    fn openA(self: *Markdown, detail: *const md.c.MD_SPAN_A_DETAIL) bool {
        if (!self.put("<a href=\"")) return false;
        if (!self.writeAttribute(&detail.href, .link)) return false;
        if (detail.title.text != null) {
            if (!self.put("\" title=\"")) return false;
            if (!self.writeAttribute(&detail.title, .text)) return false;
        }
        return self.put("\">");
    }

    fn openImg(self: *Markdown, detail: *const md.c.MD_SPAN_IMG_DETAIL) bool {
        if (!self.put("<img src=\"")) return false;
        if (!self.writeAttribute(&detail.src, .image)) return false;
        return self.put("\" alt=\"");
    }

    fn closeImg(self: *Markdown, detail: *const md.c.MD_SPAN_IMG_DETAIL) bool {
        if (detail.title.text != null) {
            if (!self.put("\" title=\"")) return false;
            if (!self.writeAttribute(&detail.title, .text)) return false;
        }
        return self.put("\">");
    }

    // ---- text ----

    fn writeRun(self: *Markdown, text_type: md.c.MD_TEXTTYPE, text: []const u8) bool {
        switch (text_type) {
            // A NULL is replaced the way CommonMark says, rather than written.
            md.c.MD_TEXT_NULLCHAR => return self.put("\u{FFFD}"),
            md.c.MD_TEXT_BR => return self.put(if (self.image_depth == 0) "<br>\n" else " "),
            md.c.MD_TEXT_SOFTBR => return self.put(if (self.image_depth == 0) "\n" else " "),
            // An entity is decoded to the character it stands for, then escaped
            // like any other text, so `&amp;` reads back as `&`.
            md.c.MD_TEXT_ENTITY => {
                var value: std.ArrayList(u8) = .empty;
                defer value.deinit(self.gpa);
                self.decodeEntity(text, &value) catch return self.fail();
                return self.putEscaped(value.items);
            },
            // Everything else is text: normal text, code inside a block or span,
            // and -- with raw HTML turned off -- what would have been HTML.
            else => return self.putEscaped(text),
        }
    }

    /// Records that writing failed, having no error to carry; the write itself
    /// put the error on the renderer.
    fn fail(self: *Markdown) bool {
        if (self.err == null) self.err = error.WriteFailed;
        return false;
    }

    // ---- attribute values ----

    /// What an attribute holds, which is what decides what is safe in it.
    const Attribute = enum {
        /// Text, such as a link's title.
        text,
        /// A link's address, checked against a scheme that could run code.
        link,
        /// An image's address, which may be a `data:` image and so is held to
        /// less than a link.
        image,
    };

    /// Writes an attribute's value: an address that could run code becomes `#`,
    /// and any other value is written escaped. The value is the entity-decoded
    /// text, which is what the browser will read.
    fn writeAttribute(self: *Markdown, attribute: *const md.c.MD_ATTRIBUTE, kind: Attribute) bool {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.gpa);
        self.decodeAttribute(attribute, &value) catch return self.fail();

        if (kind != .text and !safeAddress(value.items, kind == .link)) return self.put("#");
        return self.putEscaped(value.items);
    }

    /// Reads an attribute into `value`, resolving the entities in it. md4c hands
    /// an attribute over in runs, each of which is ordinary text, an entity or a
    /// NULL character.
    fn decodeAttribute(self: *Markdown, attribute: *const md.c.MD_ATTRIBUTE, value: *std.ArrayList(u8)) !void {
        var i: usize = 0;
        while (attribute.substr_offsets[i] < attribute.size) : (i += 1) {
            const start = attribute.substr_offsets[i];
            const end = attribute.substr_offsets[i + 1];
            const chunk = attribute.text[start..end];
            switch (attribute.substr_types[i]) {
                md.c.MD_TEXT_ENTITY => try self.decodeEntity(chunk, value),
                md.c.MD_TEXT_NULLCHAR => try appendCodepoint(value, self.gpa, 0xFFFD),
                else => try value.appendSlice(self.gpa, chunk),
            }
        }
    }

    /// Appends the character the entity `text` stands for: a number with its
    /// digits, or a name looked up in md4c's table. An entity that is neither,
    /// which md4c passes through, is kept as the text it is.
    fn decodeEntity(self: *Markdown, text: []const u8, value: *std.ArrayList(u8)) !void {
        if (std.mem.startsWith(u8, text, "&#")) {
            var digits = text[2..];
            if (std.mem.endsWith(u8, digits, ";")) digits = digits[0 .. digits.len - 1];
            const base: u8 = if (digits.len > 0 and (digits[0] == 'x' or digits[0] == 'X')) blk: {
                digits = digits[1..];
                break :blk 16;
            } else 10;
            const codepoint = std.fmt.parseInt(u21, digits, base) catch
                return value.appendSlice(self.gpa, text);
            return appendCodepoint(value, self.gpa, codepoint);
        }
        const entity = md.c.entity_lookup(text.ptr, text.len);
        if (entity != null) {
            try appendCodepoint(value, self.gpa, @intCast(entity[0].codepoints[0]));
            if (entity[0].codepoints[1] != 0) {
                try appendCodepoint(value, self.gpa, @intCast(entity[0].codepoints[1]));
            }
            return;
        }
        try value.appendSlice(self.gpa, text);
    }
};

const heading_open = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
const heading_close = [_][]const u8{ "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };

/// Appends `codepoint` to `value` as UTF-8, or the replacement character when it
/// is not one that may appear in text.
fn appendCodepoint(value: *std.ArrayList(u8), gpa: std.mem.Allocator, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const encoded = std.unicode.utf8Encode(codepoint, &buffer) catch
        return value.appendSlice(gpa, "\u{FFFD}");
    return value.appendSlice(gpa, buffer[0..encoded]);
}

/// Whether the address `url` is one that is safe to write into a page. The scheme
/// of the address -- the run up to the first colon, with the whitespace and
/// control characters a browser ignores taken out -- is refused when it could run
/// code. A link is held to more than an image: `data:` in a link is another
/// document to open, while an image loaded from `data:` is how a picture is
/// written without a host to fetch it from.
fn safeAddress(url: []const u8, is_link: bool) bool {
    var buffer: [16]u8 = undefined;
    const scheme = schemeOf(url, &buffer);
    const refused: []const []const u8 = if (is_link)
        &.{ "javascript:", "vbscript:", "data:" }
    else
        &.{ "javascript:", "vbscript:" };
    for (refused) |bad| {
        if (std.mem.eql(u8, scheme, bad)) return false;
    }
    return true;
}

/// The scheme of `url`, lower case and with the characters a browser skips taking
/// out, written into `buffer`: letters up to and including the first colon, or an
/// empty string for an address with no scheme, such as a relative one. This is
/// how a browser reads the scheme, so a `java\tscript:` or a ` javascript:` is
/// seen as the scheme it is.
fn schemeOf(url: []const u8, buffer: []u8) []const u8 {
    var n: usize = 0;
    for (url) |byte| {
        // A browser drops leading whitespace and control characters, and any
        // inside the scheme, before it reads it.
        if (byte <= ' ' or byte == 0x7f) continue;
        if (byte == ':' or byte == '/' or byte == '?' or byte == '#') {
            if (byte == ':' and n < buffer.len) {
                buffer[n] = ':';
                n += 1;
            }
            break;
        }
        if (n >= buffer.len) break;
        buffer[n] = std.ascii.toLower(byte);
        n += 1;
    }
    return buffer[0..n];
}

/// Writes the HTML for one block, span or run of text, driving md4c. Each
/// callback is C, so it returns a number: zero to carry on, non-zero to stop the
/// parse, which is how a failed write stops it.
fn enterBlock(block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *Markdown = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(!self.openBlock(block_type, detail));
}

fn leaveBlock(block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *Markdown = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(!self.closeBlock(block_type, detail));
}

fn enterSpan(span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *Markdown = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(!self.openSpan(span_type, detail));
}

fn leaveSpan(span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *Markdown = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(!self.closeSpan(span_type, detail));
}

fn writeText(text_type: md.c.MD_TEXTTYPE, text: [*c]const md.c.MD_CHAR, size: md.c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *Markdown = @ptrCast(@alignCast(userdata.?));
    return @intFromBool(!self.writeRun(text_type, text[0..size]));
}

pub fn diff(lines: []const diffing.Line, out: *Io.Writer) !void {
    try out.writeAll("<pre class=\"diff\">");
    for (lines) |line| {
        switch (line.kind) {
            .elided => {
                try out.writeAll("<span class=\"elided\">");
                try out.print(" … {d} more lines", .{line.hidden});
            },
            else => {
                try out.writeAll("<span class=\"");
                try out.writeAll(switch (line.kind) {
                    .context => "context",
                    .removed => "removed",
                    .added => "added",
                    .elided => unreachable,
                });
                try out.writeAll("\">");
                try out.writeAll(&.{line.kind.mark()});
                try escape(line.text, out);
            },
        }
        try out.writeAll("</span>\n");
    }
    try out.writeAll("</pre>\n");
}

test "the characters that mean something in HTML are written as themselves" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Every one of them, and a string with none of them left as it was.
    try escape("<a href=\"x\">&'</a>", &out.writer);
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#x27;&lt;/a&gt;", out.written());

    out.clearRetainingCapacity();
    try escape("plain text 123", &out.writer);
    try std.testing.expectEqualStrings("plain text 123", out.written());
}

/// Renders `text` as markdown and checks it against `expected`.
fn expectMarkdown(expected: []const u8, text: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try markdown(gpa, text, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a paragraph is one block, however the model wrapped it" {
    try expectMarkdown(
        "<p>one line\nwrapped onto two</p>\n",
        "one line\nwrapped onto two\n",
    );
    // Two paragraphs are two blocks.
    try expectMarkdown("<p>first</p>\n<p>second</p>\n", "first\n\nsecond\n");
}

test "markup in the text is shown as text" {
    try expectMarkdown(
        "<p>a &lt;b&gt; tag and 2 &amp; 3</p>\n",
        "a <b> tag and 2 & 3\n",
    );
}

test "headings are written by their level" {
    try expectMarkdown("<h1>Title</h1>\n", "# Title\n");
    try expectMarkdown("<h3>Deeper</h3>\n", "### Deeper\n");
    // Seven `#`, or a `#` with no space, is not a heading.
    try expectMarkdown("<p>####### no</p>\n", "####### no\n");
    try expectMarkdown("<p>#no</p>\n", "#no\n");
}

test "lists are written as lists, and do not run into a paragraph" {
    try expectMarkdown("<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", "- one\n- two\n");
    try expectMarkdown("<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n", "1. one\n2. two\n");
    // A change of kind closes one list and opens the other.
    try expectMarkdown(
        "<ul>\n<li>one</li>\n</ul>\n<ol>\n<li>two</li>\n</ol>\n",
        "- one\n1. two\n",
    );
    // An unindented line after an item continues it, the way CommonMark reads
    // a list; a blank line ends it, and then a paragraph is its own block.
    try expectMarkdown("<ul>\n<li>one\nafter</li>\n</ul>\n", "- one\nafter\n");
    try expectMarkdown("<ul>\n<li>one</li>\n</ul>\n<p>after</p>\n", "- one\n\nafter\n");

    // A blank line between items does not end the list, and does not restart its
    // numbering: the items are still one list, written as one. It does make the
    // list "loose", so each item holds a paragraph, which is CommonMark.
    try expectMarkdown(
        "<ol>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ol>\n",
        "1. one\n\n2. two\n",
    );
    try expectMarkdown(
        "<ul>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ul>\n",
        "- one\n\n- two\n",
    );
    // A blank line, then something that is not an item, ends the list.
    try expectMarkdown(
        "<ol>\n<li>one</li>\n</ol>\n<p>after</p>\n",
        "1. one\n\nafter\n",
    );
    // Blank lines, however many, do not end a list: the next item continues it,
    // and the list is written as one loose list.
    try expectMarkdown(
        "<ol>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ol>\n",
        "1. one\n\n\n2. two\n",
    );

    // A list starting at a number other than 1 keeps it, so it does not show as
    // 1 where the model wrote 3.
    try expectMarkdown(
        "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n",
        "3. three\n4. four\n",
    );
    // Every item written as 1 is still one list that counts up, which is how a
    // model that numbers every item `1.` is meant to read.
    try expectMarkdown(
        "<ol>\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ol>\n",
        "1. one\n1. two\n1. three\n",
    );
}

test "a code block is kept as it was written, and nothing in it is markup" {
    try expectMarkdown(
        "<pre><code>const x = 1;\nif (x &lt; 2) return;\n</code></pre>\n",
        "```\nconst x = 1;\nif (x < 2) return;\n```\n",
    );
    // A language names the block, and a tilde fence works like a backtick one.
    try expectMarkdown(
        "<pre><code class=\"language-zig\">x\n</code></pre>\n",
        "```zig\nx\n```\n",
    );
    try expectMarkdown("<pre><code>y\n</code></pre>\n", "~~~\ny\n~~~\n");
    // A block the text ended inside is still closed.
    try expectMarkdown("<pre><code>x\n</code></pre>\n", "```\nx\n");
}

test "a quote gathers its lines into one paragraph" {
    try expectMarkdown(
        "<blockquote>\n<p>one\nand two</p>\n</blockquote>\n",
        "> one\n> and two\n",
    );
}

test "a rule is a rule, and not a list" {
    try expectMarkdown("<hr>\n", "---\n");
    try expectMarkdown("<hr>\n", "***\n");
    // Fewer than three is not a rule.
    try expectMarkdown("<p>--</p>\n", "--\n");
}

test "inline markdown is laid out inside a line" {
    try expectMarkdown("<p>a <code>x &lt; 2</code> b</p>\n", "a `x < 2` b\n");
    try expectMarkdown("<p><strong>bold</strong></p>\n", "**bold**\n");
    try expectMarkdown("<p><strong>bold</strong></p>\n", "__bold__\n");
    try expectMarkdown("<p><em>italic</em></p>\n", "*italic*\n");
    try expectMarkdown("<p><em>italic</em></p>\n", "_italic_\n");
    // Mixed, and nested: strong inside a paragraph, code inside strong.
    try expectMarkdown(
        "<p>a <strong>b and <code>c</code></strong> d</p>\n",
        "a **b and `c`** d\n",
    );
}

test "code can hold a backtick, opened and closed by a longer run" {
    // A run of backticks is closed by a run of the same length, which is the
    // only way to write code that has a backtick in it.
    try expectMarkdown("<p><code>a ` b</code></p>\n", "``a ` b``\n");
    // The spaces that set the body off from the backticks are not part of it.
    try expectMarkdown("<p><code>x</code></p>\n", "`` x ``\n");
    // A run with nothing to close it is left as it is.
    try expectMarkdown("<p>no close `here</p>\n", "no close `here\n");
    // Two spans in a line are two spans.
    try expectMarkdown("<p><code>a</code> <code>b</code></p>\n", "`a` `b`\n");
}

test "an underscore inside a word is part of the word" {
    // A coding reply is full of these, so they are not emphasis.
    try expectMarkdown("<p>session_id and foo_bar_baz</p>\n", "session_id and foo_bar_baz\n");
    // But one that starts and ends a word is.
    try expectMarkdown("<p><em>em</em> here</p>\n", "_em_ here\n");
}

test "an asterisk with nothing to close it is left as it is" {
    try expectMarkdown("<p>2 * 3 * 4</p>\n", "2 * 3 * 4\n");
    try expectMarkdown("<p>*not closed</p>\n", "*not closed\n");
}

test "a link is written with an escaped address, and a dangerous one is not followed" {
    try expectMarkdown(
        "<p><a href=\"https://example.com/a?b=1&amp;c=2\">the spec</a></p>\n",
        "[the spec](https://example.com/a?b=1&c=2)\n",
    );
    // A relative address stays on the same host.
    try expectMarkdown("<p><a href=\"/docs\">docs</a></p>\n", "[docs](/docs)\n");

    // A scheme that runs code is written as a link that goes nowhere, so the
    // text of it reads but clicking it does nothing. See `safeAddress`.
    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](javascript:alert(1))\n");
    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](data:text/html,<b>)\n");
}

test "a scheme that could run code is refused however it is spelled" {
    // The scheme is read the way a browser reads it: leading whitespace and
    // control characters are skipped, and it is compared without regard to case.
    try std.testing.expect(!safeAddress("javascript:alert(1)", true));
    try std.testing.expect(!safeAddress(" javascript:alert(1)", true));
    try std.testing.expect(!safeAddress("java\tscript:alert(1)", true));
    try std.testing.expect(!safeAddress("JavaScript:alert(1)", true));
    try std.testing.expect(!safeAddress("vbscript:x", true));

    // A `data:` address is another document to open, so a link may not use one;
    // an image loaded from `data:` is how a picture is written without a host,
    // so an image may.
    try std.testing.expect(!safeAddress("data:text/html,x", true));
    try std.testing.expect(!safeAddress("data:image/png;base64,x", true));
    try std.testing.expect(safeAddress("data:image/png;base64,x", false));

    // An address with nothing to run is left alone.
    try std.testing.expect(safeAddress("https://example.com", true));
    try std.testing.expect(safeAddress("mailto:a@b.c", true));
    try std.testing.expect(safeAddress("/docs", true));
    try std.testing.expect(safeAddress("#top", true));
    try std.testing.expect(safeAddress("relative/path", true));
}

test "a scheme spelled with entities is caught" {
    // A `javascript:` scheme can be hidden in entities. The address is decoded
    // before it is read, so it is refused all the same.
    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](jav&#x61;script:alert(1))\n");
    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](javascript&colon;alert(1))\n");
}

test "an image may be a data: image, but a link may not" {
    try expectMarkdown(
        "<p><img src=\"data:image/png;base64,AAAA\" alt=\"b\"></p>\n",
        "![b](data:image/png;base64,AAAA)\n",
    );
    try expectMarkdown("<p><img src=\"#\" alt=\"a\"></p>\n", "![a](javascript:x)\n");
}

test "a reply cannot forge an address attribute" {
    // Raw HTML is off and text is escaped, so a reply that writes an attribute
    // writes the text of one; only md4c's own attributes are checked.
    try expectMarkdown(
        "<p>an &lt;a href=&quot;javascript:x&quot;&gt; tag</p>\n",
        "an <a href=\"javascript:x\"> tag\n",
    );
}

test "a nested list is a nested list" {
    // The shape the old renderer got wrong: a numbered item with detail indented
    // under it.
    try expectMarkdown(
        "<ol>\n<li>one<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>two</li>\n</ol>\n",
        "1. one\n   - nested\n2. two\n",
    );
}

test "the GitHub extensions a reply uses are on" {
    // Tables, strikethrough, task lists: the extensions a reply reaches for.
    try expectMarkdown(
        "<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n" ++
            "<tbody>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</tbody>\n</table>\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
    );
    try expectMarkdown("<p><del>gone</del></p>\n", "~~gone~~\n");
    try expectMarkdown(
        "<ul>\n<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled>todo</li>\n" ++
            "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled checked>done</li>\n</ul>\n",
        "- [ ] todo\n- [x] done\n",
    );
}

test "raw HTML in the text stays text" {
    try expectMarkdown("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n", "<script>alert(1)</script>\n");
}

/// Documents the oracle test renders, covering everything billy's renderer is
/// meant to handle. Every address is safe: billy neutralizes a dangerous one and
/// md4c's own renderer does not, so those are checked by the tests above rather
/// than by the oracle.
const oracle_corpus = [_][]const u8{
    "# Heading one\n\n## Heading two\n\n### h3\n\n#### h4\n\n##### h5\n\n###### h6\n",
    "A paragraph with *emphasis*, **strong**, `code`, and ~~struck~~ text.\n",
    "A second paragraph.\n\nAnd a third, spread\nover two lines.\n",
    "- one\n- two\n- three\n",
    "1. one\n2. two\n3. three\n",
    "3. three\n4. four\n",
    "- a\n  - nested a\n  - nested b\n- b\n",
    "1. one\n   - nested\n2. two\n",
    "1. one\n\n2. two\n",
    "- [ ] todo\n- [x] done\n",
    "> a quote\n> over two lines\n",
    "> first\n>\n> second\n",
    "---\n\nafter a rule\n",
    "```zig\nconst x = 1 < 2;\nif (x) return;\n```\n",
    "```\nplain code, a < b & c\n```\n",
    "    an indented block\n    second line\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "| left | center | right |\n|:-----|:------:|------:|\n| 1 | 2 | 3 |\n",
    "[link](https://example.com/a?b=1&c=2 \"Title\")\n",
    "[relative](/docs)\n",
    "[mail](mailto:a@example.com)\n",
    "![image](https://example.com/x.png \"the title\")\n",
    "A bare https://example.com autolink and an address <a@example.com>.\n",
    "It's an apostrophe, an & ampersand, and a <tag>\n",
    "Entities: &amp; &lt; &copy; &#65; &#x42; &unknown;\n",
    "[title with entities](https://example.com \"a &quot; b &amp; c\")\n",
    "A hard break here  \nand the next line.\n",
    "A soft\nbreak.\n",
    "Backslash escapes: \\*not emphasis\\* and \\`not code\\`.\n",
    "* * *\n",
    "Text with a `code <span>` span and a <raw> tag.\n",
    "Term\n: not a definition list\n",
    "A footnote[^1] reference.\n\n[^1]: the definition\n",
};

test "the renderer writes what md4c's own renderer writes" {
    const gpa = std.testing.allocator;
    for (oracle_corpus) |doc| {
        var ours: std.Io.Writer.Allocating = .init(gpa);
        defer ours.deinit();
        try markdown(gpa, doc, &ours.writer);

        var theirs: std.Io.Writer.Allocating = .init(gpa);
        defer theirs.deinit();
        try md.oracleHtml(doc, &theirs.writer);

        // The two agree character for character: billy's own escaping writes a
        // character the same way md4c's does (see `escape`), so this compares
        // the bytes as they are.
        if (!std.mem.eql(u8, ours.written(), theirs.written())) {
            std.debug.print(
                "\n=== document ===\n{s}\n=== billy ===\n{s}\n=== md4c ===\n{s}\n",
                .{ doc, ours.written(), theirs.written() },
            );
        }
        try std.testing.expectEqualStrings(theirs.written(), ours.written());
    }
}

test "a diff is written as lines that name their side" {
    const gpa = std.testing.allocator;
    const lines = try diffing.lines(gpa, "a\nb\nc", "a\nx\nc");
    defer gpa.free(lines);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff(lines, &out.writer);

    try std.testing.expectEqualStrings(
        "<pre class=\"diff\">" ++
            "<span class=\"context\"> a</span>\n" ++
            "<span class=\"removed\">-b</span>\n" ++
            "<span class=\"added\">+x</span>\n" ++
            "<span class=\"context\"> c</span>\n" ++
            "</pre>\n",
        out.written(),
    );
}

test "a diff of code is escaped like any other text" {
    const gpa = std.testing.allocator;
    const lines = try diffing.lines(gpa, "if (a < b) {", "if (a > b) {");
    defer gpa.free(lines);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff(lines, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a &lt; b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a &gt; b") != null);
    // The tags of the diff itself are still tags.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<span class=\"removed\">") != null);
}

/// Writes an element holding `text`, with the text escaped. The tag and the
/// class are billy's own, written as they are; only the text comes from outside.
fn element(comptime tag: []const u8, class: []const u8, text: []const u8, out: *Io.Writer) !void {
    try out.print("<{s} class=\"{s}\">", .{ tag, class });
    try escape(text, out);
    try out.print("</{s}>\n", .{tag});
}

/// The pill a tool call shows between its name and what it acted on: a
/// fixed-width chip that holds the status the call exited with, so a status is
/// always in the same place and the description after it always lines up.
///
/// Null, where one of these is taken, means the call has no status to show,
/// which is every tool but bash.
const Status = union(enum) {
    /// The call is still running, so its status is not known yet.
    running,
    /// The call has finished: the status it exited with, or null for a result
    /// that carries none, as one stored before billy wrote the status does.
    finished: ?Tools.Exit,
};

/// Whether `call` is a bash call, the only kind with an exit status to show.
fn hasStatus(call: Tools.Call) bool {
    return switch (call) {
        .bash => true,
        else => false,
    };
}

/// Writes the pill for `status`: grey with an ellipsis while the call runs, the
/// colour of the exit and the code once it has one, and grey and empty for a
/// finished call whose status was never recorded. The element is the same width
/// in every case, so the description after it starts in the same place on every
/// row.
fn pill(status: Status, out: *Io.Writer) !void {
    switch (status) {
        // No animation: the ellipsis alone says the call has not finished.
        .running => try out.writeAll("<span class=\"exit running\" title=\"running\">…</span>"),
        .finished => |maybe_exit| {
            const exit = maybe_exit orelse return out.writeAll(
                "<span class=\"exit unknown\" title=\"the exit status was not recorded\"></span>",
            );
            try out.print("<span class=\"exit {s}\" title=\"exit code ", .{
                if (exit.ok) "ok" else "failed",
            });
            try escape(exit.code, out);
            try out.writeAll("\">");
            try out.writeAll(if (exit.ok) Tools.exit_marks.ok else Tools.exit_marks.failed);
            try out.writeAll(" ");
            try escape(exit.code, out);
            try out.writeAll("</span>");
        },
    }
}

/// Writes the `<summary>` of a tool call's `<details>`: the glyph of the tool,
/// its name, the pill of its status when it has one, and what the call acted on.
/// A collapsed call shows this line and nothing else, so it says which tool ran,
/// what it ran on, and whether it worked.
fn toolSummary(call: Tools.Call, status: ?Status, out: *Io.Writer) !void {
    const head = Tools.Heading.of(call);
    try out.writeAll("<summary class=\"tool-head\">");
    try out.print("<span class=\"glyph hue-{s}\">", .{@tagName(head.hue)});
    try escape(head.glyph, out);
    try out.writeAll("</span> <span class=\"name\">");
    try escape(head.name, out);
    try out.writeAll("</span>");
    // The status sits right after the name, before what the call acted on, so a
    // status is in the same place on every row.
    if (status) |state| try pill(state, out);
    // What the call acts on. A bash call's heading carries the model's
    // description of what the command does, so a collapsed call says what it is
    // for. A call from before the tool asked for one has no description, so the
    // first line of the command stands in, which at least names something.
    const target = if (head.target.len > 0) head.target else switch (call) {
        .bash => |args| Tools.headerLine(args.command),
        else => "",
    };
    if (target.len > 0) {
        try out.writeAll(" <span class=\"target\">");
        try escape(target, out);
        try out.writeAll("</span>");
    }
    try out.writeAll("</summary>\n");
}

/// Writes the body of a tool call: what a page shows once the call is expanded.
/// That is what the call meant to do -- an edit's diff, or the command a bash
/// call runs -- and then what it produced.
fn toolBody(gpa: std.mem.Allocator, call: Tools.Call, result: []const u8, out: *Io.Writer) !void {
    switch (call) {
        // The change the call means to make, from the call alone, so a replayed
        // session shows the same diff the run did.
        .edit => |args| {
            const lines = try diffing.lines(gpa, args.old_string, args.new_string);
            defer gpa.free(lines);
            if (lines.len > 0) try diff(lines, out);
        },
        // A bash call shows the command it runs, as the model wrote it. The
        // terminal lays it out with a format script; a page has no need of one.
        .bash => |args| try element("pre", "command", std.mem.trimEnd(u8, args.command, "\n"), out),
        else => {},
    }
    try toolResult(call, result, out);
}

/// Writes what a tool call produced, which is the other half of its body.
///
/// A write shows the content it put in the file rather than its result, since
/// that content is what it produced; an edit shows nothing, since its result
/// would only repeat the diff above it; a bash call shows the streams the
/// command filled, without the status line the summary already carries; and a
/// call that failed shows billy's message for the failure whatever it was asked
/// to do. Anything else shows the text the call returned.
fn toolResult(call: Tools.Call, result: []const u8, out: *Io.Writer) !void {
    const text = std.mem.trimEnd(u8, result, "\n");
    if (std.mem.startsWith(u8, result, "error: ")) {
        return element("pre", "error", text, out);
    }
    switch (call) {
        .write => |args| try element("pre", "result", std.mem.trimEnd(u8, args.content, "\n"), out),
        .edit => {},
        .bash => {
            // The status is the badge in the summary, so the body is only what
            // the command printed. A result billy did not write is shown as it
            // is, so a session saved before the status was written still shows
            // everything.
            const output = Tools.bashOutput(result) orelse
                return element("pre", "result", text, out);
            if (output.stdout.len > 0)
                try element("pre", "stdout", std.mem.trimEnd(u8, output.stdout, "\n"), out);
            if (output.stderr.len > 0)
                try element("pre", "stderr", std.mem.trimEnd(u8, output.stderr, "\n"), out);
            if (output.stdout.len == 0 and output.stderr.len == 0)
                try element("pre", "result", "(no output)", out);
        },
        else => try element("pre", "result", text, out),
    }
}

/// Writes one block of a run as HTML. This is where the web's rendering of a
/// session comes together: the blocks a run is made of, each as the element a
/// page shows it as.
///
/// The text of a prompt and a reply is markdown, so it is laid out; everything
/// else is the text it is, escaped. The classes name what a block is, so the
/// page can style each kind without the renderer saying how it should look.
///
/// `gpa` is for what showing a block builds, which is an edit's diff; it is the
/// caller's, freed before this returns.
pub fn block(gpa: std.mem.Allocator, b: agent.Block, out: *Io.Writer) !void {
    switch (b) {
        .prompt => |text| try titled(gpa, agent.marks.prompt.glyph, "prompt", text, out),
        .answer => |text| try titled(gpa, agent.marks.answer.glyph, "answer", text, out),
        // A tool call is one `<details>`, whose summary is the head and whose
        // body is everything the call did. Each of the two blocks is a *whole*
        // element: the `tool_begin` one a collapsed call with an empty body, and
        // the `tool_end` one the same call with its body and its status filled
        // in. Writing them next to each other -- as a stored conversation does --
        // would leave two calls, so `Page` writes the call from its end alone;
        // the stream, which sends them apart, shows the first and then replaces
        // it with the second.
        .tool_begin => |call| {
            try out.writeAll("<details class=\"tool\">");
            // A call still running shows a grey pill with an ellipsis, which the
            // result replaces with the status when it arrives. Only bash has a
            // status, so any other tool shows no pill.
            try toolSummary(call, if (hasStatus(call)) .running else null, out);
            try out.writeAll("<div class=\"tool-body\"></div></details>\n");
        },
        .tool_end => |tool| {
            const status: ?Status = if (hasStatus(tool.call))
                .{ .finished = if (Tools.bashOutput(tool.result)) |output| output.exit else null }
            else
                null;
            try out.writeAll("<details class=\"tool\">");
            try toolSummary(tool.call, status, out);
            try out.writeAll("<div class=\"tool-body\">");
            try toolBody(gpa, tool.call, tool.result, out);
            try out.writeAll("</div></details>\n");
        },
        // A compaction stands in for the messages it replaced. What it holds is
        // the ask and the summary, which a page could show; for now it is the
        // line the terminal shows it as.
        .compacted => try element("div", "compacted", agent.marks.compacted.glyph ++ " compacted", out),
        .notice => |text| try element("div", "notice", text, out),
        .elided => |count| try out.print("<div class=\"elided\">… {d} earlier blocks</div>\n", .{count}),
    }
}

/// Writes a block that is headed by a mark and holds markdown: a prompt or a
/// reply.
fn titled(gpa: std.mem.Allocator, glyph: []const u8, name: []const u8, text: []const u8, out: *Io.Writer) !void {
    try out.print("<div class=\"block {s}\"><div class=\"head\">", .{name});
    try out.print("<span class=\"glyph\">", .{});
    try escape(glyph, out);
    try out.writeAll("</span> <span class=\"name\">");
    try escape(name, out);
    try out.writeAll("</span></div>\n");
    try markdown(gpa, text, out);
    try out.writeAll("</div>\n");
}

test "a tool call is rendered as a whole element, both halves" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } });

    // The half a stream sends while the call runs: the whole call, collapsed,
    // with an empty body for the result to be added to.
    try block(gpa, .{ .tool_begin = call }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"glyph hue-blue\">▸</span> <span class=\"name\">read</span>" ++
            " <span class=\"target\">a.zig</span></summary>\n" ++
            "<div class=\"tool-body\"></div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The half sent when the result arrives: the whole call again, with the body
    // filled in, so a page can replace the first with it.
    try block(gpa, .{ .tool_end = .{ .call = call, .result = "1\tconst x = 1;" } }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"glyph hue-blue\">▸</span> <span class=\"name\">read</span>" ++
            " <span class=\"target\">a.zig</span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"result\">1\tconst x = 1;</pre>\n</div></details>\n",
        out.written(),
    );
}

test "a bash call shows its exit status in the head and its streams in the body" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const bash = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\"}",
    } });

    // The status the command exited with is a pill right after the tool's name,
    // before what it acted on, and the two streams are shown apart under it,
    // without the status line repeated.
    try block(gpa, .{ .tool_end = .{
        .call = bash,
        .result = "exit code: 2\nbuilt\nstderr:\nboom\n",
    } }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"glyph hue-cyan\">❯</span> <span class=\"name\">bash</span>" ++
            "<span class=\"exit failed\" title=\"exit code 2\">✗ 2</span>" ++
            " <span class=\"target\">make</span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"command\">make</pre>\n" ++
            "<pre class=\"stdout\">built</pre>\n" ++
            "<pre class=\"stderr\">boom</pre>\n</div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A command that succeeded reads ok, and one that printed nothing says so
    // rather than leaving the body empty.
    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "exit code: 0\n(no output)\n" } }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<span class=\"exit ok\" title=\"exit code 0\">✓ 0</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<pre class=\"result\">(no output)</pre>") != null);
    out.clearRetainingCapacity();

    // A bash result billy did not write -- a session saved before the status was
    // -- is shown as it is, with an empty grey pill rather than the running one:
    // the call has finished, so nothing should claim it is still going.
    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "make: nothing to be done" } }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<span class=\"exit unknown\" title=\"the exit status was not recorded\"></span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "running") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<pre class=\"result\">make: nothing to be done</pre>") != null);
}

test "a running call shows a grey pill, and a finished one the status" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const bash = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\",\"description\":\"build it\"}",
    } });

    // The half a stream sends while the command runs: a grey pill with an
    // ellipsis, where the status will go.
    try block(gpa, .{ .tool_begin = bash }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"glyph hue-cyan\">❯</span> <span class=\"name\">bash</span>" ++
            "<span class=\"exit running\" title=\"running\">…</span>" ++
            " <span class=\"target\">build it</span></summary>\n" ++
            "<div class=\"tool-body\"></div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The half sent when the result arrives: the same row with the status in the
    // pill, so replacing the first with it turns the ellipsis into the status.
    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "exit code: 0\n" } }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<span class=\"exit ok\" title=\"exit code 0\">✓ 0</span>") != null);

    // A tool with no status has no pill: not while it runs, and not when it is
    // done.
    out.clearRetainingCapacity();
    const read = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } });
    try block(gpa, .{ .tool_begin = read }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "class=\"exit") == null);
    out.clearRetainingCapacity();
    try block(gpa, .{ .tool_end = .{ .call = read, .result = "1\tx" } }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "class=\"exit") == null);
}

test "a bash call shows its command, and a write shows what it wrote" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const bash = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"ls -la <x>\"}",
    } });
    try toolSummary(bash, null, &out.writer);
    try toolBody(arena, bash, "some output", &out.writer);
    // The command is escaped like any other text, and its trailing newline does
    // not add a blank line; the result follows it in the same body. The head
    // carries the first line of the command too, so a collapsed call says what it
    // ran.
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\"><span class=\"glyph hue-cyan\">❯</span> " ++
            "<span class=\"name\">bash</span> <span class=\"target\">ls -la &lt;x&gt;</span></summary>\n" ++
            "<pre class=\"command\">ls -la &lt;x&gt;</pre>\n" ++
            "<pre class=\"result\">some output</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A command over several lines: the head shows its first line, the body the
    // whole of it.
    const multi = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"cd /tmp\\nls\"}",
    } });
    try toolSummary(multi, null, &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\"><span class=\"glyph hue-cyan\">❯</span> " ++
            "<span class=\"name\">bash</span> <span class=\"target\">cd /tmp</span></summary>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The description the model gave stands in front of the command, so a
    // collapsed call says what it is for; the command is no longer in the head.
    const described = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"cargo test --all\",\"description\":\"run the test suite\"}",
    } });
    try toolSummary(described, null, &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\"><span class=\"glyph hue-cyan\">❯</span> " ++
            "<span class=\"name\">bash</span> <span class=\"target\">run the test suite</span></summary>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A write shows the content it put in the file, not the result that says it
    // did, which is what the terminal shows too.
    const write = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"a.zig\",\"content\":\"hello\"}",
    } });
    try toolBody(arena, write, "wrote 5 bytes to a.zig", &out.writer);
    try std.testing.expectEqualStrings("<pre class=\"result\">hello</pre>\n", out.written());
    out.clearRetainingCapacity();

    // A failure is shown as billy's message for it, whatever the call was.
    try toolBody(arena, write, "error: cannot write a.zig: AccessDenied", &out.writer);
    try std.testing.expectEqualStrings(
        "<pre class=\"error\">error: cannot write a.zig: AccessDenied</pre>\n",
        out.written(),
    );
}

test "an edit is shown as the diff of the strings it worked on" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const edit = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "edit",
        .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
    } });
    try toolSummary(edit, null, &out.writer);
    // The diff is the body, and the result of the edit shows nothing of its own
    // -- it would only repeat the diff.
    try toolBody(arena, edit, "replaced 1 occurrence(s) in a.zig", &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\"><span class=\"glyph hue-yellow\">✎</span> " ++
            "<span class=\"name\">edit</span> <span class=\"target\">a.zig</span></summary>\n" ++
            "<pre class=\"diff\"><span class=\"removed\">-old</span>\n" ++
            "<span class=\"added\">+new</span>\n</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An edit that changes nothing shows no body at all.
    try toolBody(arena, .{ .edit = .{ .path = "a.zig", .old_string = "same", .new_string = "same" } }, "replaced 0 occurrence(s) in a.zig", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "the blocks of a run are each rendered as what they are" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A prompt and a reply are markdown, so they are laid out.
    try block(gpa, .{ .prompt = "hi <there>" }, &out.writer);
    try std.testing.expectEqualStrings(
        "<div class=\"block prompt\"><div class=\"head\"><span class=\"glyph\">»</span> " ++
            "<span class=\"name\">prompt</span></div>\n<p>hi &lt;there&gt;</p>\n</div>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try block(gpa, .{ .answer = "**done**" }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "<strong>done</strong>") != null);
    out.clearRetainingCapacity();

    // A compaction, a line billy writes, and the count of what a trimmed
    // conversation left out.
    try block(gpa, .{ .compacted = .{ .prompt = "ask", .summary = "sum" } }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"compacted\">⊟ compacted</div>\n", out.written());
    out.clearRetainingCapacity();

    try block(gpa, .{ .notice = "stopped after 3 turns" }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"notice\">stopped after 3 turns</div>\n", out.written());
    out.clearRetainingCapacity();

    try block(gpa, .{ .elided = 7 }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"elided\">… 7 earlier blocks</div>\n", out.written());
}

/// Writes a whole stored conversation as HTML, oldest block first: what the web
/// page shows when a session is opened. `gpa` is the run's, for the scratch each
/// block needs while it is written.
pub fn conversation(gpa: std.mem.Allocator, session: *const Session, out: *Io.Writer) !void {
    var page = Page{ .gpa = gpa, .out = out };
    try agent.walk(gpa, session, 0, page.emitter());
}

/// Shows each block of a conversation as its element. It is the emitter `walk`
/// takes, so a conversation is rendered by the same walk a terminal replay is.
const Page = struct {
    gpa: std.mem.Allocator,
    out: *Io.Writer,

    fn emitter(self: *Page) agent.Emitter {
        return .{ .context = self, .vtable = &.{ .block = show } };
    }

    fn show(context: *anyopaque, b: agent.Block) anyerror!void {
        const page: *Page = @ptrCast(@alignCast(context));
        // A tool call is written from its `tool_end`, which is the whole call --
        // head, body and status. The `tool_begin` half exists only for a stream
        // that shows the head while the call runs, so a written conversation
        // leaves it out rather than showing every call twice.
        switch (b) {
            .tool_begin => return,
            else => {},
        }
        return block(page.gpa, b, page.out);
    }
};

test "a whole conversation is rendered, a tool call and a compaction included" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    // A prompt and a reply, a tool call with its result, an edit with its diff,
    // and a compaction standing in for the conversation before it. The system
    // prompt is its own field, which the conversation does not show.
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = "user", .content = "read it" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
    }} });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_2",
        .function = .{
            .name = "edit",
            .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
        },
    }} });
    try session.append(.{ .role = "tool", .tool_call_id = "call_2", .content = "replaced 1 occurrence(s) in a.zig" });
    try session.append(.{ .role = "assistant", .content = "done **now**" });
    try session.appendCompaction("summarize", "the summary so far");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try conversation(gpa, &session, &out.writer);
    const page = out.written();

    // The prompt is a block of its own, and its text is laid out as markdown.
    try std.testing.expect(std.mem.indexOf(u8, page, "<div class=\"block prompt\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<p>read it</p>") != null);
    // The read call is headed and its result is the body, wrapped in one
    // `<details>` that a page shows collapsed until it is opened.
    try std.testing.expect(std.mem.indexOf(u8, page, "<details class=\"tool\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<summary class=\"tool-head\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"name\">read</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre class=\"result\">1\tconst x = 1;</pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "</div></details>\n") != null);
    // Each call is written once, from its `tool_end`: the `tool_begin` half is
    // for a stream, so a written conversation has one element per call -- the read
    // and the edit -- not two.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, page, "<details class=\"tool\">"));
    // The details is not opened, so a page shows it collapsed to begin with.
    try std.testing.expect(std.mem.indexOf(u8, page, "<details class=\"tool\" open>") == null);
    // The edit is shown as its diff, and no result of its own.
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"removed\">-old</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"added\">+new</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "replaced 1 occurrence") == null);
    // The reply's markdown is laid out.
    try std.testing.expect(std.mem.indexOf(u8, page, "<p>done <strong>now</strong></p>") != null);
    // The compaction is one line, and neither the ask nor the summary is shown
    // as a block of its own.
    try std.testing.expect(std.mem.indexOf(u8, page, "<div class=\"compacted\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "the summary so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "summarize") == null);
    // The system prompt is never shown.
    try std.testing.expect(std.mem.indexOf(u8, page, "be terse") == null);
}

/// The line above a conversation: the session, the model it runs, the directory
/// it works in, how full the context window is and what it has cost. It is the
/// same text the terminal puts above its prompt, laid out for a page.
pub const Header = struct {
    /// The session being shown.
    id: []const u8,
    /// The model the session runs.
    model: []const u8,
    /// The directory the session works in, shortened to `~` when it is inside
    /// `home`.
    cwd: []const u8,
    home: ?[]const u8,
    /// Tokens in the conversation as of the last request.
    context_tokens: usize,
    /// The window and the prices, or null for a model billy does not know, which
    /// has no gauge and no cost.
    model_info: ?models.Metadata,
    /// What the session has cost so far, in USD.
    cost: f64,
};

/// Writes the header as HTML. Every count is formatted by the same helpers the
/// terminal header uses, so the two read the same numbers the same way.
pub fn header(h: Header, out: *Io.Writer) !void {
    try out.writeAll("<div class=\"header\">");
    try part("id", h.id, out);
    try out.writeAll("<span class=\"sep\">·</span>");
    try part("model", h.model, out);
    try out.writeAll("<span class=\"sep\">·</span><span class=\"cwd\">");
    // The directory is shortened by a helper that writes rather than returns, so
    // its output is escaped on the way to the page.
    var path = Escaping.init(out);
    try agent.displayPath(&path.writer, h.cwd, h.home);
    try out.writeAll("</span>");

    if (h.model_info) |info| {
        try out.writeAll("<span class=\"sep\">·</span><span class=\"gauge\">");
        try agent.formatTokens(out, h.context_tokens);
        try out.writeAll("/");
        try agent.formatTokens(out, info.context_window);
        try out.writeAll(" (");
        try agent.formatPercent(out, h.context_tokens, info.context_window);
        try out.writeAll(")</span>");
        try out.writeAll("<span class=\"sep\">·</span><span class=\"cost\">");
        try agent.formatMoney(out, h.cost);
        try out.writeAll("</span>");
    }
    try out.writeAll("</div>\n");
}

/// Writes one part of the header as a span classed by what it is, with the text
/// escaped. The dot between parts is a part of its own, so a page can space it.
fn part(class: []const u8, text: []const u8, out: *Io.Writer) !void {
    try out.print("<span class=\"{s}\">", .{class});
    try escape(text, out);
    try out.writeAll("</span>");
}

test "the header carries the model, the directory and the gauge" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try header(.{
        .id = "01HF7YAT000000000000000000",
        .model = "deepseek-flash",
        .cwd = "/home/user/repo/billy",
        .home = "/home/user",
        .context_tokens = 16_000,
        .model_info = .{
            .provider = .deepseek,
            .model = "deepseek-flash",
            .context_window = 128_000,
            .price = .{},
        },
        .cost = 0.42,
    }, &out.writer);

    // The same numbers the terminal header shows, each in a part of its own.
    try std.testing.expectEqualStrings(
        "<div class=\"header\">" ++
            "<span class=\"id\">01HF7YAT000000000000000000</span>" ++
            "<span class=\"sep\">·</span>" ++
            "<span class=\"model\">deepseek-flash</span>" ++
            "<span class=\"sep\">·</span><span class=\"cwd\">~/repo/billy</span>" ++
            "<span class=\"sep\">·</span><span class=\"gauge\">16k/128k (12%)</span>" ++
            "<span class=\"sep\">·</span><span class=\"cost\">$0.42</span>" ++
            "</div>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A model billy does not know has no window and no prices, so the gauge and
    // the cost are left out rather than shown as zero.
    try header(.{
        .id = "dev",
        .model = "who-knows",
        .cwd = "/work",
        .home = null,
        .context_tokens = 5000,
        .model_info = null,
        .cost = 12.34,
    }, &out.writer);
    try std.testing.expectEqualStrings(
        "<div class=\"header\">" ++
            "<span class=\"id\">dev</span>" ++
            "<span class=\"sep\">·</span>" ++
            "<span class=\"model\">who-knows</span>" ++
            "<span class=\"sep\">·</span><span class=\"cwd\">/work</span>" ++
            "</div>\n",
        out.written(),
    );

    // A path a model or a directory could carry is escaped like any other text.
    out.clearRetainingCapacity();
    try header(.{
        .id = "x<y",
        .model = "m",
        .cwd = "/a<b",
        .home = null,
        .context_tokens = 0,
        .model_info = null,
        .cost = 0,
    }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "x&lt;y") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "/a&lt;b") != null);
}
