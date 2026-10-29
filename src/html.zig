//! Rendering for the web frontend: the HTML a browser is given.

const std = @import("std");

const Agent = @import("Agent.zig");
const diff = @import("diff.zig");
const favicons = @import("web/favicons.zig");
/// The page's markdown reader, `md` because `markdown` is this file's own renderer of a reply.
const md = @import("markdown.zig");
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
    var render: Render = .{ .gpa = gpa, .out = out };
    defer render.deinit();
    try md.write(gpa, text, render.interface());
}

/// A block that is being gathered, because how it is written out is not known until it ends: a
/// list's items take a `<p>` only once the whole list says whether it is loose.
const List = struct {
    /// Its items, in the order they were written.
    items: std.ArrayList(Item) = .empty,
    ordered: bool = false,
    /// Where a numbered list starts, read from its first item while its bytes are still there.
    start: usize = 1,
    /// Whether a blank line was seen in it, which is what makes its items take a `<p>`.
    loose: bool = false,
    /// The item being gathered: what is written inside its `<li>`, and where its paragraphs are.
    content: std.Io.Writer.Allocating,
    paragraphs: std.ArrayList(Span) = .empty,
    open: bool = false,
    task: ?bool = null,

    fn deinit(list: *List, gpa: std.mem.Allocator) void {
        for (list.items.items) |item| item.deinit(gpa);
        list.items.deinit(gpa);
        list.content.deinit();
        list.paragraphs.deinit(gpa);
    }
};

const Item = struct {
    /// What is written inside the `<li>`: a paragraph's text, a nested list's markup, both in order.
    content: []const u8,
    /// Where the paragraphs in the content begin and end.
    paragraphs: []const Span,
    task: ?bool = null,

    fn deinit(item: Item, gpa: std.mem.Allocator) void {
        gpa.free(item.content);
        gpa.free(item.paragraphs);
    }
};

const Span = struct { start: usize, end: usize };

const Render = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    /// The lists being gathered, the innermost last.
    lists: std.ArrayList(List) = .empty,
    /// A line has ended and its break is written before what comes next, not after it, so that the
    /// last line of a block does not end with one.
    pending_break: bool = false,
    /// A blank line was seen, and only what follows it says whether it makes the list loose: a line
    /// that continues the list does, and the block that ends it does not.
    pending_blank: bool = false,
    heading: ?u3 = null,
    in_code: bool = false,

    fn interface(self: *Render) md.Renderer {
        return .{ .context = self, .emit = show };
    }

    fn show(context: *anyopaque, event: md.Event) anyerror!void {
        const self: *Render = @ptrCast(@alignCast(context));
        switch (event) {
            .newline => try self.breakLine(),
            .blank => {
                self.pending_break = false;
                self.pending_blank = true;
            },
            .line => |line| try self.openLine(line),
            .text => |text| try self.writeText(text),
            .paragraph_begin => try self.openParagraph(),
            .paragraph_end => try self.closeParagraph(),
            .quote_begin => try self.write("<blockquote>\n"),
            .quote_end => {
                self.pending_break = false;
                try self.write("</blockquote>\n");
            },
            .list_begin => |list| try self.openList(list),
            .list_end => try self.closeList(),
            .item_begin => |item| {
                if (self.pending_blank and self.lists.items.len > 0) {
                    self.lists.items[self.lists.items.len - 1].loose = true;
                }
                self.pending_blank = false;
                self.openItem(item);
            },
            .item_end => try self.closeItem(),
            .span_begin => |span| try self.write(switch (span) {
                .strong => "<strong>",
                .em => "<em>",
                .code => "<code>",
                .strike => "<del>",
            }),
            .span_end => |span| try self.write(switch (span) {
                .strong => "</strong>",
                .em => "</em>",
                .code => "</code>",
                .strike => "</del>",
            }),
            .link_begin => |url| try self.openLink(url),
            .link_end => try self.write("</a>"),
            .image => |image| try self.writeImage(image),
            .rule => {
                self.pending_break = false;
                try self.write("<hr>\n");
            },
            .code_begin => |lang| try self.openCode(lang),
            .code_end => {
                self.in_code = false;
                try self.write("</code></pre>\n");
            },
            .table => |table| try self.writeTable(table),
        }
    }

    fn deinit(self: *Render) void {
        for (self.lists.items) |*list| list.deinit(self.gpa);
        self.lists.deinit(self.gpa);
    }

    /// Where what is written next goes: the page, or the item of the list being gathered.
    fn sink(self: *Render) *std.Io.Writer {
        if (self.lists.items.len == 0) return self.out;
        return &self.lists.items[self.lists.items.len - 1].content.writer;
    }

    /// Writes the break a finished line left due, before whatever follows it.
    fn before(self: *Render) !void {
        if (!self.pending_break) return;
        self.pending_break = false;
        try self.sink().writeAll("\n");
    }

    fn write(self: *Render, text: []const u8) !void {
        try self.before();
        try self.sink().writeAll(text);
    }

    fn print(self: *Render, comptime format: []const u8, args: anytype) !void {
        try self.before();
        try self.sink().print(format, args);
    }

    /// A line of source ends: inside a paragraph it is a soft break, and inside a code block it is
    /// the newline the code was written with.
    fn breakLine(self: *Render) !void {
        if (self.in_code) return try self.writeRaw("\n");
        if (self.heading) |level| return try self.closeHeading(level);
        self.pending_break = true;
    }

    fn openLine(self: *Render, line: md.Line) !void {
        const level = line.heading orelse return;
        self.pending_break = false;
        self.heading = level;
        try self.write(heading_open[level - 1]);
    }

    fn closeHeading(self: *Render, level: u3) !void {
        self.heading = null;
        self.pending_break = false;
        try self.sink().writeAll(heading_close[level - 1]);
    }

    fn openParagraph(self: *Render) !void {
        self.pending_break = false;
        if (self.lists.items.len == 0) return self.write("<p>");
        const top = &self.lists.items[self.lists.items.len - 1];
        try top.paragraphs.append(self.gpa, .{ .start = top.content.written().len, .end = 0 });
    }

    fn closeParagraph(self: *Render) !void {
        self.pending_break = false;
        if (self.lists.items.len == 0) return try self.write("</p>\n");
        const top = &self.lists.items[self.lists.items.len - 1];
        if (top.paragraphs.items.len == 0) return;
        top.paragraphs.items[top.paragraphs.items.len - 1].end = top.content.written().len;
    }

    fn openItem(self: *Render, item: md.Item) void {
        if (self.lists.items.len == 0) return;
        const top = &self.lists.items[self.lists.items.len - 1];
        top.open = true;
        top.task = item.task;
        top.content.clearRetainingCapacity();
        top.paragraphs.clearRetainingCapacity();
    }

    fn closeItem(self: *Render) !void {
        if (self.lists.items.len == 0) return;
        const top = &self.lists.items[self.lists.items.len - 1];
        if (!top.open) return;
        self.pending_break = false;
        top.open = false;
        const content = try self.gpa.dupe(u8, top.content.written());
        errdefer self.gpa.free(content);
        const paragraphs = try self.gpa.dupe(Span, top.paragraphs.items);
        errdefer self.gpa.free(paragraphs);
        try top.items.append(self.gpa, .{
            .content = content,
            .paragraphs = paragraphs,
            .task = top.task,
        });
        top.task = null;
    }

    fn openList(self: *Render, list: md.List) !void {
        self.pending_break = false;
        // A blank line before a list is the paragraph's, not the list's.
        self.pending_blank = false;
        try self.lists.append(self.gpa, .{
            .ordered = list.ordered,
            .start = startOf(list.number),
            .content = .init(self.gpa),
        });
    }

    fn closeList(self: *Render) !void {
        self.pending_blank = false;
        if (self.lists.items.len == 0) return;
        var list = self.lists.pop().?;
        defer list.deinit(self.gpa);
        self.pending_break = false;

        if (list.ordered) {
            if (list.start == 1) try self.sink().writeAll("<ol>\n") else try self.print("<ol start=\"{d}\">\n", .{list.start});
        } else {
            try self.sink().writeAll("<ul>\n");
        }
        for (list.items.items) |item| try self.writeItem(item, list.loose);
        try self.sink().writeAll(if (list.ordered) "</ol>\n" else "</ul>\n");
    }

    /// A list's item: the paragraphs it holds take a `<p>` only in a list that is loose.
    fn writeItem(self: *Render, item: Item, loose: bool) !void {
        const out = self.sink();
        try out.writeAll("<li");
        if (item.task != null) try out.writeAll(" class=\"task-list-item\"");
        try out.writeAll(">");
        if (item.task) |done| {
            try out.writeAll("<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled");
            if (done) try out.writeAll(" checked");
            try out.writeAll(">");
        }
        var at: usize = 0;
        for (item.paragraphs) |span| {
            try out.writeAll(item.content[at..span.start]);
            if (loose) {
                try out.writeAll("<p>");
                try out.writeAll(item.content[span.start..span.end]);
                try out.writeAll("</p>\n");
            } else {
                try out.writeAll(item.content[span.start..span.end]);
            }
            at = span.end;
        }
        try out.writeAll(item.content[at..]);
        try out.writeAll("</li>\n");
    }

    fn writeText(self: *Render, text: []const u8) !void {
        if (self.in_code) return escape(text, self.sink());
        try self.before();
        try escape(text, self.sink());
    }

    fn writeRaw(self: *Render, text: []const u8) !void {
        try self.sink().writeAll(text);
    }

    fn openLink(self: *Render, url: []const u8) !void {
        try self.write("<a href=\"");
        try self.writeAddress(url, .link);
        try self.write("\">");
    }

    fn openCode(self: *Render, lang: []const u8) !void {
        self.pending_break = false;
        self.in_code = true;
        try self.write("<pre><code");
        if (lang.len > 0) {
            try self.write(" class=\"language-");
            try escape(lang, self.sink());
            try self.write("\"");
        }
        try self.write(">");
    }

    fn writeImage(self: *Render, image: md.Image) !void {
        try self.write("<img src=\"");
        try self.writeAddress(image.url, .image);
        try self.write("\" alt=\"");
        try escape(image.label, self.sink());
        try self.write("\">");
    }

    fn writeAddress(self: *Render, url: []const u8, kind: Address) !void {
        if (!safeAddress(url, kind)) return try self.write("#");
        try escape(url, self.sink());
    }

    fn writeTable(self: *Render, table: md.Table) !void {
        self.pending_break = false;
        try self.write("<table>\n");
        const head = table.head + 1;
        if (head > 0 and head <= table.rows.len) {
            try self.write("<thead>\n");
            for (table.rows[0..head]) |row| try self.writeRow(row, table.aligns, "th");
            try self.write("</thead>\n");
        }
        if (head < table.rows.len) {
            try self.write("<tbody>\n");
            for (table.rows[head..]) |row| try self.writeRow(row, table.aligns, "td");
            try self.write("</tbody>\n");
        }
        try self.write("</table>\n");
    }

    fn writeRow(self: *Render, row: md.Row, aligns: []const md.Align, tag: []const u8) !void {
        try self.write("<tr>\n");
        for (row.cells, 0..) |cell, column| {
            try self.print("<{s}", .{tag});
            switch (if (column < aligns.len) aligns[column] else .none) {
                .left => try self.write(" align=\"left\""),
                .center => try self.write(" align=\"center\""),
                .right => try self.write(" align=\"right\""),
                .none => {},
            }
            try self.write(">");
            try escape(cell, self.sink());
            try self.print("</{s}>\n", .{tag});
        }
        try self.write("</tr>\n");
    }
};

/// The number a numbered list starts at, or the first it can be.
fn startOf(number: ?[]const u8) usize {
    const digits = number orelse return 1;
    return std.fmt.parseInt(usize, digits, 10) catch 1;
}

const heading_open = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
const heading_close = [_][]const u8{ "</h1>\n", "</h2>\n", "</h3>\n", "</h4>\n", "</h5>\n", "</h6>\n" };

const Address = enum { link, image };

fn safeAddress(url: []const u8, kind: Address) bool {
    var buffer: [16]u8 = undefined;
    const scheme = schemeOf(url, &buffer);
    const refused: []const []const u8 = if (kind == .link)
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
    try expectMarkdown("<p>before</p>\n<ul>\n<li>one</li>\n</ul>\n", "before\n\n- one\n");

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
    try std.testing.expect(!safeAddress("javascript:alert(1)", .link));
    try std.testing.expect(!safeAddress(" javascript:alert(1)", .link));
    try std.testing.expect(!safeAddress("java\tscript:alert(1)", .link));
    try std.testing.expect(!safeAddress("JavaScript:alert(1)", .link));
    try std.testing.expect(!safeAddress("vbscript:x", .link));

    try std.testing.expect(!safeAddress("data:text/html,x", .link));
    try std.testing.expect(!safeAddress("data:image/png;base64,x", .link));
    try std.testing.expect(safeAddress("data:image/png;base64,x", .image));

    try std.testing.expect(safeAddress("https://example.com", .link));
    try std.testing.expect(safeAddress("mailto:a@b.c", .link));
    try std.testing.expect(safeAddress("/docs", .link));
    try std.testing.expect(safeAddress("#top", .link));
    try std.testing.expect(safeAddress("relative/path", .link));
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
        return try block(page.gpa, b, page.out);
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
