//! Rendering for the web frontend: the HTML a browser is given.

const std = @import("std");

const Agent = @import("Agent.zig");
const diff = @import("diff.zig");
const favicons = @import("web/favicons.zig");
const md = @import("md.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Tools = @import("Tools.zig");

/// Writes `text` with the characters that mean something in HTML replaced by the entities that mean
/// the characters themselves.
pub fn escape(text: []const u8, out: *std.Io.Writer) !void {
    var plain: usize = 0;
    for (text, 0..) |byte, i| {
        const entity = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#x27;",
            else => continue,
        };
        try out.writeAll(text[plain..i]);
        try out.writeAll(entity);
        plain = i + 1;
    }
    try out.writeAll(text[plain..]);
}

/// Writes the markdown of a reply or a prompt as HTML.
pub fn markdown(gpa: std.mem.Allocator, text: []const u8, out: *std.Io.Writer) !void {
    var render = Markdown{ .gpa = gpa, .out = out };
    var callbacks = md.parser(Markdown);
    try md.parse(text, &callbacks, &render);
    // A callback cannot return an error, so a failed write is kept on the renderer and reported
    // here, once the parser has stopped.
    if (render.err) |err| return err;
}

const Markdown = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    err: ?std.Io.Writer.Error = null,
    image_depth: usize = 0,

    fn put(self: *Markdown, text: []const u8) bool {
        self.out.writeAll(text) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    fn print(self: *Markdown, comptime format: []const u8, args: anytype) bool {
        self.out.print(format, args) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    fn putEscaped(self: *Markdown, text: []const u8) bool {
        escape(text, self.out) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    pub fn enterBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
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
            // Raw HTML never reaches here: `md.flags` turns it off, so it comes as text and is
            // escaped.
            else => {},
        }
        return true;
    }

    pub fn leaveBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
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

    fn openOl(self: *Markdown, detail: *const md.c.MD_BLOCK_OL_DETAIL) bool {
        if (detail.start == 1) return self.put("<ol>\n");
        return self.print("<ol start=\"{d}\">\n", .{detail.start});
    }

    fn openLi(self: *Markdown, detail: *const md.c.MD_BLOCK_LI_DETAIL) bool {
        if (detail.is_task == 0) return self.put("<li>");
        if (!self.put("<li class=\"task-list-item\">" ++
            "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled")) return false;
        if ((detail.task_mark == 'x' or detail.task_mark == 'X') and !self.put(" checked")) return false;
        return self.put(">");
    }

    fn openCode(self: *Markdown, detail: *const md.c.MD_BLOCK_CODE_DETAIL) bool {
        if (!self.put("<pre><code")) return false;
        if (detail.lang.text != null) {
            if (!self.put(" class=\"language-")) return false;
            if (!self.writeAttribute(&detail.lang, .text)) return false;
            if (!self.put("\"")) return false;
        }
        return self.put(">");
    }

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

    pub fn enterSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        const inside_image = self.image_depth > 0;
        if (span_type == md.c.MD_SPAN_IMG) self.image_depth += 1;
        // Inside an image label only the text matters: it is the alt text, and a tag written there
        // would break out of the attribute.
        if (inside_image) return true;

        switch (span_type) {
            md.c.MD_SPAN_EM => return self.put("<em>"),
            md.c.MD_SPAN_STRONG => return self.put("<strong>"),
            md.c.MD_SPAN_A => return self.openA(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_IMG => return self.openImg(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_CODE => return self.put("<code>"),
            md.c.MD_SPAN_DEL => return self.put("<del>"),
            md.c.MD_SPAN_U => return self.put("<u>"),
            md.c.MD_SPAN_MARK => return self.put("<mark>"),
            md.c.MD_SPAN_SUPERSCRIPT => return self.put("<sup>"),
            md.c.MD_SPAN_SUBSCRIPT => return self.put("<sub>"),
            else => {},
        }
        return true;
    }

    pub fn leaveSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        if (span_type == md.c.MD_SPAN_IMG) self.image_depth -= 1;
        if (self.image_depth > 0) return true;

        switch (span_type) {
            md.c.MD_SPAN_EM => return self.put("</em>"),
            md.c.MD_SPAN_STRONG => return self.put("</strong>"),
            md.c.MD_SPAN_A => return self.put("</a>"),
            md.c.MD_SPAN_IMG => return self.closeImg(@ptrCast(@alignCast(detail.?))),
            md.c.MD_SPAN_CODE => return self.put("</code>"),
            md.c.MD_SPAN_DEL => return self.put("</del>"),
            md.c.MD_SPAN_U => return self.put("</u>"),
            md.c.MD_SPAN_MARK => return self.put("</mark>"),
            md.c.MD_SPAN_SUPERSCRIPT => return self.put("</sup>"),
            md.c.MD_SPAN_SUBSCRIPT => return self.put("</sub>"),
            else => {},
        }
        return true;
    }

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

    pub fn writeText(self: *Markdown, text_type: md.c.MD_TEXTTYPE, text: []const u8) bool {
        switch (text_type) {
            // A NULL is replaced the way CommonMark says, rather than written.
            md.c.MD_TEXT_NULLCHAR => return self.put("\u{FFFD}"),
            md.c.MD_TEXT_BR => return self.put(if (self.image_depth == 0) "<br>\n" else " "),
            md.c.MD_TEXT_SOFTBR => return self.put(if (self.image_depth == 0) "\n" else " "),
            md.c.MD_TEXT_ENTITY => {
                var value: std.ArrayList(u8) = .empty;
                defer value.deinit(self.gpa);
                md.decodeEntity(self.gpa, text, &value) catch return self.fail();
                return self.putEscaped(value.items);
            },
            // Everything else is text: normal text, code inside a block or span, and -- with raw
            // HTML turned off -- what would have been HTML.
            else => return self.putEscaped(text),
        }
    }

    fn fail(self: *Markdown) bool {
        if (self.err == null) self.err = error.WriteFailed;
        return false;
    }

    const Attribute = enum {
        text,
        link,
        image,
    };

    fn writeAttribute(self: *Markdown, attribute: *const md.c.MD_ATTRIBUTE, kind: Attribute) bool {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.gpa);
        self.decodeAttribute(attribute, &value) catch return self.fail();

        if (kind != .text and !safeAddress(value.items, kind == .link)) return self.put("#");
        return self.putEscaped(value.items);
    }

    fn decodeAttribute(self: *Markdown, attribute: *const md.c.MD_ATTRIBUTE, value: *std.ArrayList(u8)) !void {
        var i: usize = 0;
        while (attribute.substr_offsets[i] < attribute.size) : (i += 1) {
            const start = attribute.substr_offsets[i];
            const end = attribute.substr_offsets[i + 1];
            const chunk = attribute.text[start..end];
            switch (attribute.substr_types[i]) {
                md.c.MD_TEXT_ENTITY => try md.decodeEntity(self.gpa, chunk, value),
                md.c.MD_TEXT_NULLCHAR => try md.appendCodepoint(value, self.gpa, 0xFFFD),
                else => try value.appendSlice(self.gpa, chunk),
            }
        }
    }
};

const heading_open = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
const heading_close = [_][]const u8{ "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };

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

fn schemeOf(url: []const u8, buffer: []u8) []const u8 {
    var n: usize = 0;
    for (url) |byte| {
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

/// Writes an edit's diff as a `<pre>` of marked lines.
pub fn diffLines(lines: []const diff.Line, out: *std.Io.Writer) !void {
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

    try escape("<a href=\"x\">&'</a>", &out.writer);
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#x27;&lt;/a&gt;", out.written());

    out.clearRetainingCapacity();
    try escape("plain text 123", &out.writer);
    try std.testing.expectEqualStrings("plain text 123", out.written());
}

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
    try expectMarkdown("<p>####### no</p>\n", "####### no\n");
    try expectMarkdown("<p>#no</p>\n", "#no\n");
}

test "lists are written as lists, and do not run into a paragraph" {
    try expectMarkdown("<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", "- one\n- two\n");
    try expectMarkdown("<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n", "1. one\n2. two\n");
    try expectMarkdown(
        "<ul>\n<li>one</li>\n</ul>\n<ol>\n<li>two</li>\n</ol>\n",
        "- one\n1. two\n",
    );
    try expectMarkdown("<ul>\n<li>one\nafter</li>\n</ul>\n", "- one\nafter\n");
    try expectMarkdown("<ul>\n<li>one</li>\n</ul>\n<p>after</p>\n", "- one\n\nafter\n");

    try expectMarkdown(
        "<ol>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ol>\n",
        "1. one\n\n2. two\n",
    );
    try expectMarkdown(
        "<ul>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ul>\n",
        "- one\n\n- two\n",
    );
    try expectMarkdown(
        "<ol>\n<li>one</li>\n</ol>\n<p>after</p>\n",
        "1. one\n\nafter\n",
    );
    try expectMarkdown(
        "<ol>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ol>\n",
        "1. one\n\n\n2. two\n",
    );

    try expectMarkdown(
        "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n",
        "3. three\n4. four\n",
    );
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
    try expectMarkdown(
        "<pre><code class=\"language-zig\">x\n</code></pre>\n",
        "```zig\nx\n```\n",
    );
    try expectMarkdown("<pre><code>y\n</code></pre>\n", "~~~\ny\n~~~\n");
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
    try expectMarkdown("<p>--</p>\n", "--\n");
}

test "inline markdown is laid out inside a line" {
    try expectMarkdown("<p>a <code>x &lt; 2</code> b</p>\n", "a `x < 2` b\n");
    try expectMarkdown("<p><strong>bold</strong></p>\n", "**bold**\n");
    try expectMarkdown("<p><strong>bold</strong></p>\n", "__bold__\n");
    try expectMarkdown("<p><em>italic</em></p>\n", "*italic*\n");
    try expectMarkdown("<p><em>italic</em></p>\n", "_italic_\n");
    try expectMarkdown(
        "<p>a <strong>b and <code>c</code></strong> d</p>\n",
        "a **b and `c`** d\n",
    );
}

test "code can hold a backtick, opened and closed by a longer run" {
    try expectMarkdown("<p><code>a ` b</code></p>\n", "``a ` b``\n");
    try expectMarkdown("<p><code>x</code></p>\n", "`` x ``\n");
    try expectMarkdown("<p>no close `here</p>\n", "no close `here\n");
    try expectMarkdown("<p><code>a</code> <code>b</code></p>\n", "`a` `b`\n");
}

test "an underscore inside a word is part of the word" {
    try expectMarkdown("<p>session_id and foo_bar_baz</p>\n", "session_id and foo_bar_baz\n");
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
    try expectMarkdown("<p><a href=\"/docs\">docs</a></p>\n", "[docs](/docs)\n");

    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](javascript:alert(1))\n");
    try expectMarkdown("<p><a href=\"#\">x</a></p>\n", "[x](data:text/html,<b>)\n");
}

test "a scheme that could run code is refused however it is spelled" {
    try std.testing.expect(!safeAddress("javascript:alert(1)", true));
    try std.testing.expect(!safeAddress(" javascript:alert(1)", true));
    try std.testing.expect(!safeAddress("java\tscript:alert(1)", true));
    try std.testing.expect(!safeAddress("JavaScript:alert(1)", true));
    try std.testing.expect(!safeAddress("vbscript:x", true));

    try std.testing.expect(!safeAddress("data:text/html,x", true));
    try std.testing.expect(!safeAddress("data:image/png;base64,x", true));
    try std.testing.expect(safeAddress("data:image/png;base64,x", false));

    try std.testing.expect(safeAddress("https://example.com", true));
    try std.testing.expect(safeAddress("mailto:a@b.c", true));
    try std.testing.expect(safeAddress("/docs", true));
    try std.testing.expect(safeAddress("#top", true));
    try std.testing.expect(safeAddress("relative/path", true));
}

test "a scheme spelled with entities is caught" {
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
    try expectMarkdown(
        "<p>an &lt;a href=&quot;javascript:x&quot;&gt; tag</p>\n",
        "an <a href=\"javascript:x\"> tag\n",
    );
}

test "a nested list is a nested list" {
    try expectMarkdown(
        "<ol>\n<li>one<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>two</li>\n</ol>\n",
        "1. one\n   - nested\n2. two\n",
    );
}

test "the GitHub extensions a reply uses are on" {
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

test "a diff is written as lines that name their side" {
    const gpa = std.testing.allocator;
    const lines = try diff.lines(gpa, "a\nb\nc", "a\nx\nc");
    defer gpa.free(lines);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diffLines(lines, &out.writer);

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
    const lines = try diff.lines(gpa, "if (a < b) {", "if (a > b) {");
    defer gpa.free(lines);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diffLines(lines, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "a &lt; b") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "a &gt; b") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "<span class=\"removed\">") != null);
}

fn element(comptime tag: []const u8, class: []const u8, text: []const u8, out: *std.Io.Writer) !void {
    try out.print("<{s} class=\"{s}\">", .{ tag, class });
    try escape(text, out);
    try out.print("</{s}>\n", .{tag});
}

const Status = union(enum) {
    running,
    finished: ?Tools.Exit,
};

fn showsStatus(call: Tools.Call) bool {
    return switch (call) {
        .bash => true,
        else => false,
    };
}

fn pill(status: Status, out: *std.Io.Writer) !void {
    switch (status) {
        .running => try out.writeAll(
            "<span class=\"exit running\" title=\"running\">" ++
                "<span class=\"dots\"><i></i><i></i><i></i></span></span>",
        ),
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

fn toolSummary(call: Tools.Call, result: []const u8, status: ?Status, out: *std.Io.Writer) !void {
    const head = Tools.Heading.of(call);
    try out.writeAll("<summary class=\"tool-head\">");
    try out.writeAll("<span class=\"name\">");
    try escape(head.name, out);
    try out.writeAll("</span>");
    const target = head.target;
    if (target.len > 0) {
        try out.writeAll(" <span class=\"target\">");
        try escape(target, out);
        try out.writeAll("</span>");
    }
    // What the call produced, on a row of its own under the head: the status a bash call exited
    // with, and the sources a web search found.
    if (status != null or call == .web_search) {
        try out.writeAll("<span class=\"produced\">");
        if (status) |state| try pill(state, out);
        if (call == .web_search) try favicons.write(result, out);
        try out.writeAll("</span>");
    }
    try out.writeAll("</summary>\n");
}

fn toolBody(gpa: std.mem.Allocator, call: Tools.Call, result: []const u8, out: *std.Io.Writer) !void {
    switch (call) {
        .edit => |args| {
            const lines = try diff.lines(gpa, args.old_string, args.new_string);
            defer gpa.free(lines);
            if (lines.len > 0) try diffLines(lines, out);
        },
        .bash => |args| try element("pre", "command", std.mem.trimEnd(u8, args.command, "\n"), out),
        else => {},
    }
    try toolResult(call, result, out);
}

fn toolResult(call: Tools.Call, result: []const u8, out: *std.Io.Writer) !void {
    if (result.len == 0) return;
    const text = std.mem.trimEnd(u8, result, "\n");
    if (std.mem.startsWith(u8, result, "error: ")) {
        return element("pre", "error", text, out);
    }
    switch (call) {
        .write => |args| try element("pre", "result", std.mem.trimEnd(u8, args.content, "\n"), out),
        .edit => {},
        .bash => {
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

/// Writes one block of a run as HTML.
pub fn block(gpa: std.mem.Allocator, b: Agent.Block, out: *std.Io.Writer) !void {
    switch (b) {
        .prompt => |text| try titled(gpa, "»", "prompt", text, out),
        .answer => |text| try titled(gpa, "◆", "answer", text, out),
        // A tool call is one `<details>`, whose summary is the head and whose body is everything
        // the call did.
        .tool_begin => |call| {
            try out.writeAll("<details class=\"tool\">");
            try toolSummary(call, "", if (showsStatus(call)) .running else null, out);
            // What the call means to do is already known, so it is shown while the call runs: the
            // command a bash call is about to run, and the change an edit means to make.
            try out.writeAll("<div class=\"tool-body\">");
            try toolBody(gpa, call, "", out);
            try out.writeAll("</div></details>\n");
        },
        .tool_end => |tool| {
            const status: ?Status = if (showsStatus(tool.call))
                .{ .finished = if (Tools.bashOutput(tool.result)) |output| output.exit else null }
            else
                null;
            try out.writeAll("<details class=\"tool\">");
            try toolSummary(tool.call, tool.result, status, out);
            try out.writeAll("<div class=\"tool-body\">");
            try toolBody(gpa, tool.call, tool.result, out);
            try out.writeAll("</div></details>\n");
        },
        .compacted => try element("div", "compacted", "⊟ compacted", out),
        .notice => |text| try element("div", "notice", text, out),
        .hidden => |count| try out.print("<div class=\"elided\">… {d} earlier blocks</div>\n", .{count}),
    }
}

fn titled(gpa: std.mem.Allocator, glyph: []const u8, name: []const u8, text: []const u8, out: *std.Io.Writer) !void {
    try out.print("<div class=\"block {s}\"><div class=\"head\">", .{name});
    try out.writeAll("<span class=\"glyph\">");
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

    try block(gpa, .{ .tool_begin = call }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"name\">read</span>" ++
            " <span class=\"target\">a.zig</span></summary>\n" ++
            "<div class=\"tool-body\"></div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try block(gpa, .{ .tool_end = .{ .call = call, .result = "1\tconst x = 1;" } }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"name\">read</span>" ++
            " <span class=\"target\">a.zig</span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"result\">1\tconst x = 1;</pre>\n</div></details>\n",
        out.written(),
    );
}

test "a call naming a tool billy has not got is headed by its name as text" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A call billy cannot run is headed by the name it named, which is the model's own string and
    // not one of billy's.
    const unknown = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "<img src=x onerror=alert(1)>",
        .arguments = "{}",
    } });
    try block(gpa, .{ .tool_begin = unknown }, &out.writer);
    try std.testing.expect(std.mem.find(
        u8,
        out.written(),
        "<span class=\"name\">&lt;img src=x onerror=alert(1)&gt;</span>",
    ) != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "<img") == null);
    out.clearRetainingCapacity();

    const malformed = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read\" onclick=\"x",
        .arguments = "{",
    } });
    try block(gpa, .{ .tool_end = .{ .call = malformed, .result = "error: invalid arguments for read: SyntaxError" } }, &out.writer);
    try std.testing.expect(std.mem.find(
        u8,
        out.written(),
        "<span class=\"name\">read&quot; onclick=&quot;x</span>",
    ) != null);
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

    try block(gpa, .{ .tool_end = .{
        .call = bash,
        .result = "exit code: 2\nbuilt\nstderr:\nboom\n",
    } }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"name\">bash</span> <span class=\"target\">make</span>" ++
            "<span class=\"produced\">" ++
            "<span class=\"exit failed\" title=\"exit code 2\">✗ 2</span></span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"command\">make</pre>\n" ++
            "<pre class=\"stdout\">built</pre>\n" ++
            "<pre class=\"stderr\">boom</pre>\n</div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A command that succeeded reads ok, and one that printed nothing says so rather than leaving
    // the body empty.
    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "exit code: 0\n(no output)\n" } }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "<span class=\"exit ok\" title=\"exit code 0\">✓ 0</span>") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "<pre class=\"result\">(no output)</pre>") != null);
    out.clearRetainingCapacity();

    // A bash result billy did not write -- a session saved before the status was -- is shown as it
    // is, with an empty grey pill rather than the running one: the call has finished, so nothing
    // should claim it is still going.
    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "make: nothing to be done" } }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "<span class=\"exit unknown\" title=\"the exit status was not recorded\"></span>") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "running") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "<pre class=\"result\">make: nothing to be done</pre>") != null);
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

    try block(gpa, .{ .tool_begin = bash }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"name\">bash</span> <span class=\"target\">build it</span>" ++
            "<span class=\"produced\">" ++
            "<span class=\"exit running\" title=\"running\">" ++
            "<span class=\"dots\"><i></i><i></i><i></i></span></span></span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"command\">make</pre>\n</div></details>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try block(gpa, .{ .tool_end = .{ .call = bash, .result = "exit code: 0\n" } }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "<span class=\"exit ok\" title=\"exit code 0\">✓ 0</span>") != null);

    out.clearRetainingCapacity();
    const read = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } });
    try block(gpa, .{ .tool_begin = read }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "class=\"exit") == null);
    out.clearRetainingCapacity();
    try block(gpa, .{ .tool_end = .{ .call = read, .result = "1\tx" } }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "class=\"exit") == null);
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
    try toolSummary(bash, "", null, &out.writer);
    try toolBody(arena, bash, "some output", &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\">" ++
            "<span class=\"name\">bash</span> <span class=\"target\">ls -la &lt;x&gt;</span></summary>\n" ++
            "<pre class=\"command\">ls -la &lt;x&gt;</pre>\n" ++
            "<pre class=\"result\">some output</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    const multi = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"cd /tmp\\nls\"}",
    } });
    try toolSummary(multi, "", null, &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\">" ++
            "<span class=\"name\">bash</span> <span class=\"target\">cd /tmp</span></summary>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    const described = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"cargo test --all\",\"description\":\"run the test suite\"}",
    } });
    try toolSummary(described, "", null, &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\">" ++
            "<span class=\"name\">bash</span> <span class=\"target\">run the test suite</span></summary>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    const write = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"a.zig\",\"content\":\"hello\"}",
    } });
    try toolBody(arena, write, "wrote 5 bytes to a.zig", &out.writer);
    try std.testing.expectEqualStrings("<pre class=\"result\">hello</pre>\n", out.written());
    out.clearRetainingCapacity();

    try toolBody(arena, write, "error: cannot write a.zig: AccessDenied", &out.writer);
    try std.testing.expectEqualStrings(
        "<pre class=\"error\">error: cannot write a.zig: AccessDenied</pre>\n",
        out.written(),
    );
}

test "a web search shows its sources as favicons in the summary" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "web_search",
        .arguments = "{\"query\":\"zig lang\"}",
    } });

    try block(gpa, .{ .tool_end = .{
        .call = call,
        .result = "1. Zig\n   https://ziglang.org\n   A language.\n\n2. Docs\n   https://ziglang.org/documentation\n",
    } }, &out.writer);
    try std.testing.expectEqualStrings(
        "<details class=\"tool\"><summary class=\"tool-head\">" ++
            "<span class=\"name\">web_search</span>" ++
            " <span class=\"target\">zig lang</span>" ++
            "<span class=\"produced\">" ++
            "<a class=\"fav\" href=\"https://ziglang.org\" title=\"ziglang.org\"" ++
            " target=\"_blank\" rel=\"noopener noreferrer\" onclick=\"event.stopPropagation()\">" ++
            "<span class=\"letter\">z</span><img src=\"https://ziglang.org/favicon.ico\"" ++
            " alt=\"\" onerror=\"this.remove()\"></a>" ++
            "<a class=\"fav\" href=\"https://ziglang.org/documentation\" title=\"ziglang.org\"" ++
            " target=\"_blank\" rel=\"noopener noreferrer\" onclick=\"event.stopPropagation()\">" ++
            "<span class=\"letter\">z</span><img src=\"https://ziglang.org/favicon.ico\"" ++
            " alt=\"\" onerror=\"this.remove()\"></a>" ++
            "</span></summary>\n" ++
            "<div class=\"tool-body\"><pre class=\"result\">1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation</pre>\n</div></details>\n",
        out.written(),
    );
}

test "a search with nothing to link to shows no favicons" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "web_search",
        .arguments = "{\"query\":\"nothing\"}",
    } });

    // A search that matched nothing, and one whose only result is not an `http(s)` address, both
    // leave no bubbles.
    for ([_][]const u8{ "(no results)", "1. Odd\n   javascript:alert(1)\n" }) |result| {
        try block(gpa, .{ .tool_end = .{ .call = call, .result = result } }, &out.writer);
        try std.testing.expect(std.mem.find(u8, out.written(), "<a class=\"fav\"") == null);
        try std.testing.expect(std.mem.find(u8, out.written(), "<span class=\"produced\"></span>") != null);
        out.clearRetainingCapacity();
    }
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
    try toolSummary(edit, "", null, &out.writer);
    // The diff is the body, and the result of the edit shows nothing of its own -- it would only
    // repeat the diff.
    try toolBody(arena, edit, "replaced 1 occurrence(s) in a.zig", &out.writer);
    try std.testing.expectEqualStrings(
        "<summary class=\"tool-head\">" ++
            "<span class=\"name\">edit</span> <span class=\"target\">a.zig</span></summary>\n" ++
            "<pre class=\"diff\"><span class=\"removed\">-old</span>\n" ++
            "<span class=\"added\">+new</span>\n</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try toolBody(arena, .{ .edit = .{ .path = "a.zig", .old_string = "same", .new_string = "same" } }, "replaced 0 occurrence(s) in a.zig", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "the blocks of a run are each rendered as what they are" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try block(gpa, .{ .prompt = "hi <there>" }, &out.writer);
    try std.testing.expectEqualStrings(
        "<div class=\"block prompt\"><div class=\"head\"><span class=\"glyph\">»</span> " ++
            "<span class=\"name\">prompt</span></div>\n<p>hi &lt;there&gt;</p>\n</div>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try block(gpa, .{ .answer = "**done**" }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "<strong>done</strong>") != null);
    out.clearRetainingCapacity();

    try block(gpa, .{ .compacted = .{ .prompt = "ask", .summary = "sum" } }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"compacted\">⊟ compacted</div>\n", out.written());
    out.clearRetainingCapacity();

    try block(gpa, .{ .notice = "stopped after 3 turns" }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"notice\">stopped after 3 turns</div>\n", out.written());
    out.clearRetainingCapacity();

    try block(gpa, .{ .hidden = 7 }, &out.writer);
    try std.testing.expectEqualStrings("<div class=\"elided\">… 7 earlier blocks</div>\n", out.written());
}

/// Writes a stored conversation as HTML, oldest block first: what the web page shows when a session
/// is opened.
pub fn conversation(
    gpa: std.mem.Allocator,
    session: *const Session,
    blocks: usize,
    out: *std.Io.Writer,
) !void {
    var page = Page{ .gpa = gpa, .out = out };
    try Agent.walk(gpa, session, blocks, page.emitter());
}

const Page = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    interface: Agent.Emitter = .{ .vtable = &vtable },

    const vtable: Agent.Emitter.VTable = .{ .block = show };

    fn emitter(self: *Page) *Agent.Emitter {
        return &self.interface;
    }

    fn show(e: *Agent.Emitter, b: Agent.Block) anyerror!void {
        const page: *Page = @alignCast(@fieldParentPtr("interface", e));
        // A tool call is written from its `tool_end`, which is the whole call -- head, body and
        // status.
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

    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "read it" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_1",
        .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_2",
        .function = .{
            .name = "edit",
            .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
        },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_2", .content = "replaced 1 occurrence(s) in a.zig" });
    try session.append(.{ .role = .assistant, .content = "done **now**" });
    try session.appendCompaction("summarize", "the summary so far");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try conversation(gpa, &session, 0, &out.writer);
    const page = out.written();

    try std.testing.expect(std.mem.find(u8, page, "<div class=\"block prompt\">") != null);
    try std.testing.expect(std.mem.find(u8, page, "<p>read it</p>") != null);
    try std.testing.expect(std.mem.find(u8, page, "<details class=\"tool\">") != null);
    try std.testing.expect(std.mem.find(u8, page, "<summary class=\"tool-head\">") != null);
    try std.testing.expect(std.mem.find(u8, page, "<span class=\"name\">read</span>") != null);
    try std.testing.expect(std.mem.find(u8, page, "<pre class=\"result\">1\tconst x = 1;</pre>") != null);
    try std.testing.expect(std.mem.find(u8, page, "</div></details>\n") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, page, "<details class=\"tool\">"));
    try std.testing.expect(std.mem.find(u8, page, "<details class=\"tool\" open>") == null);
    try std.testing.expect(std.mem.find(u8, page, "<span class=\"removed\">-old</span>") != null);
    try std.testing.expect(std.mem.find(u8, page, "<span class=\"added\">+new</span>") != null);
    try std.testing.expect(std.mem.find(u8, page, "replaced 1 occurrence") == null);
    try std.testing.expect(std.mem.find(u8, page, "<p>done <strong>now</strong></p>") != null);
    try std.testing.expect(std.mem.find(u8, page, "<div class=\"compacted\">") != null);
    try std.testing.expect(std.mem.find(u8, page, "the summary so far") == null);
    try std.testing.expect(std.mem.find(u8, page, "summarize") == null);
    // The system prompt is never shown.
    try std.testing.expect(std.mem.find(u8, page, "be terse") == null);
}

/// The line above a conversation: the session, the model it runs, the directory it works in, and
/// how full the context window is.
pub const Header = struct {
    id: []const u8,
    model: []const u8,
    cwd: []const u8,
    home: ?[]const u8,
    context_tokens: usize,
    model_info: ?models.Metadata,
};

/// Writes the header as HTML.
pub fn header(h: Header, out: *std.Io.Writer) !void {
    try out.writeAll("<div class=\"header\">");
    try part("id", h.id, out);
    try out.writeAll("<span class=\"sep\">·</span>");
    try part("model", h.model, out);
    try out.writeAll("<span class=\"sep\">·</span><span class=\"cwd\">");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try escape(Agent.displayPath(&path_buffer, h.cwd, h.home), out);
    try out.writeAll("</span>");

    if (h.model_info) |info| {
        try out.writeAll("<span class=\"sep\">·</span><span class=\"gauge\">");
        try Agent.formatTokens(out, h.context_tokens);
        try out.writeAll("/");
        try Agent.formatTokens(out, info.context_window);
        try out.writeAll(" (");
        try Agent.formatPercent(out, h.context_tokens, info.context_window);
        try out.writeAll(")</span>");
    }
    try out.writeAll("</div>\n");
}

fn part(class: []const u8, text: []const u8, out: *std.Io.Writer) !void {
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
        .model = "deepseek/deepseek-flash",
        .cwd = "/home/user/repo/billy",
        .home = "/home/user",
        .context_tokens = 16_000,
        .model_info = .{ .context_window = 128_000 },
    }, &out.writer);

    try std.testing.expectEqualStrings(
        "<div class=\"header\">" ++
            "<span class=\"id\">01HF7YAT000000000000000000</span>" ++
            "<span class=\"sep\">·</span>" ++
            "<span class=\"model\">deepseek/deepseek-flash</span>" ++
            "<span class=\"sep\">·</span><span class=\"cwd\">~/repo/billy</span>" ++
            "<span class=\"sep\">·</span><span class=\"gauge\">16k/128k (12%)</span>" ++
            "</div>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A model billy does not know has no window, so the gauge is left out rather than shown as
    // zero.
    try header(.{
        .id = "dev",
        .model = "who-knows",
        .cwd = "/work",
        .home = null,
        .context_tokens = 5000,
        .model_info = null,
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

    out.clearRetainingCapacity();
    try header(.{
        .id = "x<y",
        .model = "m",
        .cwd = "/a<b",
        .home = null,
        .context_tokens = 0,
        .model_info = null,
    }, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "x&lt;y") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "/a&lt;b") != null);
}
