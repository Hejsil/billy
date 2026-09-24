//! Rendering for the web frontend: the HTML a browser is given.
//!
//! Everything a model writes, a file holds or a user types reaches a page as
//! text and nowhere else, so every one of those is escaped before it is written.
//! A `<` in a file billy read is a `<` on the page, not the start of a tag.
//!
//! The markdown a reply is written in is laid out here rather than by the format
//! script the terminal uses, since a script lays text out with escape codes and
//! a page is not a terminal. Only the display changes: what a session stores and
//! what the model is sent keep the markdown as it was written.
//!
//! The layout is a prototype covering the common part of markdown a reply uses --
//! paragraphs, headings, top-level lists, quotes, code (fenced and inline),
//! emphasis, links and a rule. Anything else is shown as the text it is, which is
//! always right, if not always pretty; `markdown` says where it falls short and
//! what it would take to do properly.

const std = @import("std");
const Io = std.Io;
const diffing = @import("diff.zig");

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
            '\'' => "&#39;",
            else => continue,
        };
        try out.writeAll(text[plain..i]);
        try out.writeAll(entity);
        plain = i + 1;
    }
    try out.writeAll(text[plain..]);
}

/// What is open at the block level: a run of lines that belongs together and is
/// closed when something else begins.
const Block = enum {
    none,
    paragraph,
    unordered,
    ordered,
    /// A quote is a paragraph inside a `<blockquote>`, so its lines gather the
    /// way a paragraph's do.
    quote,
};

/// Writes the markdown of a reply or a prompt as HTML.
///
/// TODO: this is a prototype, not a markdown implementation. It covers the part
/// of markdown a reply uses most -- paragraphs, headings, top-level lists,
/// quotes, fenced and inline code, emphasis, links, a rule -- and it stops there.
/// Anything else is shown as the text it is, which is why an unfinished reply
/// reads flat rather than wrong, with two exceptions that do read wrong: an
/// indented (nested) list item becomes a paragraph with its dash and indentation
/// showing, and a four-space indented code block is a paragraph. Those are not
/// rare: a numbered list with nested detail under each item is a shape the model
/// reaches for constantly, and it is the one thing this gets visibly wrong.
///
/// The right answer is a real renderer -- a CommonMark implementation, whether
/// written here or taken from elsewhere -- because the long tail is a treadmill:
/// list nesting, lazy continuation lines, delimiter runs such as `***x***`,
/// tables, setext headings, entities. This exists to have the seam in place while
/// the frontend is built; replacing what is behind `markdown(text, out)` touches
/// nothing else.
pub fn markdown(text: []const u8, out: *Io.Writer) !void {
    var open: Block = .none;
    // The marker of the fence a code block was opened with, until the fence that
    // closes it; null when no code block is open.
    var fence: ?[]const u8 = null;

    // Split what is written, not the newline that ends it: a text ending in a
    // newline would otherwise have a last empty line, which at the end of a code
    // block shows as a blank line that was never written. Trailing newlines only
    // close blocks that are closed at the end anyway.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        // Inside a code block nothing is markup: the lines are the code, escaped
        // as they are, until the fence closes.
        if (fence) |marker| {
            if (closesFence(line, marker)) {
                try out.writeAll("</code></pre>\n");
                fence = null;
            } else {
                try escape(line, out);
                try out.writeAll("\n");
            }
            continue;
        }

        const trimmed = std.mem.trimEnd(u8, line, " \t");
        if (trimmed.len == 0) {
            try close(&open, out);
            continue;
        }

        if (fenceOf(trimmed)) |opening| {
            try close(&open, out);
            try out.writeAll("<pre><code");
            if (opening.language.len != 0) {
                try out.writeAll(" class=\"language-");
                try escape(opening.language, out);
                try out.writeAll("\"");
            }
            try out.writeAll(">");
            fence = opening.marker;
            continue;
        }

        if (heading(trimmed)) |head| {
            try close(&open, out);
            try out.print("<{s}>", .{head.tag});
            try inlineText(head.text, out);
            try out.print("</{s}>\n", .{head.tag});
            continue;
        }

        if (isRule(trimmed)) {
            try close(&open, out);
            try out.writeAll("<hr>\n");
            continue;
        }

        if (itemOf(trimmed)) |item| {
            const wanted: Block = if (item.ordered) .ordered else .unordered;
            if (open != wanted) {
                try close(&open, out);
                try out.writeAll(if (item.ordered) "<ol>\n" else "<ul>\n");
                open = wanted;
            }
            try out.writeAll("<li>");
            try inlineText(item.text, out);
            try out.writeAll("</li>\n");
            continue;
        }

        if (trimmed[0] == '>') {
            const inner = std.mem.trimStart(u8, trimmed[1..], " \t");
            if (open != .quote) {
                try close(&open, out);
                try out.writeAll("<blockquote><p>");
                open = .quote;
            } else {
                // A quote's lines gather the way a paragraph's do.
                try out.writeAll("\n");
            }
            try inlineText(inner, out);
            continue;
        }

        // Anything left is a paragraph. Its lines gather into one, so a reply
        // wrapped by the model reads as one paragraph rather than one per line.
        if (open != .paragraph) {
            try close(&open, out);
            try out.writeAll("<p>");
            open = .paragraph;
        } else {
            try out.writeAll("\n");
        }
        try inlineText(trimmed, out);
    }

    // A code block the reply ended inside is closed here, so the page is whole
    // even though the markdown was not.
    if (fence != null) try out.writeAll("</code></pre>\n");
    try close(&open, out);
}

/// Closes the block that is open, if any, and leaves none open.
fn close(open: *Block, out: *Io.Writer) !void {
    switch (open.*) {
        .none => {},
        .paragraph => try out.writeAll("</p>\n"),
        .unordered => try out.writeAll("</ul>\n"),
        .ordered => try out.writeAll("</ol>\n"),
        .quote => try out.writeAll("</p></blockquote>\n"),
    }
    open.* = .none;
}

/// The fences a code block opens with: three or more backticks or tildes, and
/// the language named after them.
const Fence = struct { marker: []const u8, language: []const u8 };

fn fenceOf(line: []const u8) ?Fence {
    const text = std.mem.trimStart(u8, line, " ");
    if (text.len == 0) return null;
    const byte = text[0];
    if (byte != '`' and byte != '~') return null;

    var count: usize = 0;
    while (count < text.len and text[count] == byte) count += 1;
    if (count < 3) return null;

    // The language is the first word after the fence; anything else on the line
    // is not something this renders.
    const info = std.mem.trim(u8, text[count..], " \t");
    const language = info[0 .. std.mem.indexOfAny(u8, info, " \t") orelse info.len];
    return .{ .marker = text[0..count], .language = language };
}

/// Whether `line` is the fence that closes one opened with `marker`: the same
/// character, at least as many of them, and nothing else on the line.
fn closesFence(line: []const u8, marker: []const u8) bool {
    const text = std.mem.trim(u8, line, " \t");
    if (text.len < marker.len) return false;
    for (text) |byte| {
        if (byte != marker[0]) return false;
    }
    return true;
}

const Heading = struct { tag: []const u8, text: []const u8 };

/// A heading of one to six `#`, with the text it holds. A `#` that is not
/// followed by a space, or more than six of them, is not a heading.
fn heading(line: []const u8) ?Heading {
    if (line.len == 0 or line[0] != '#') return null;

    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level > 6) return null;
    if (level == line.len) return null;
    if (line[level] != ' ' and line[level] != '\t') return null;

    const tags = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };
    return .{ .tag = tags[level - 1], .text = std.mem.trim(u8, line[level..], " \t") };
}

/// Whether `line` is a rule: three or more of `-`, `*` or `_` and nothing else.
fn isRule(line: []const u8) bool {
    const byte = line[0];
    if (byte != '-' and byte != '*' and byte != '_') return false;

    var count: usize = 0;
    for (line) |current| {
        if (current == byte) {
            count += 1;
        } else if (current != ' ' and current != '\t') {
            return false;
        }
    }
    return count >= 3;
}

const Item = struct { ordered: bool, text: []const u8 };

/// A list item: `-`, `*` or `+` and a space for an unordered one, or digits and
/// a `.` or `)` and a space for an ordered one.
fn itemOf(line: []const u8) ?Item {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+')) {
        if (line[1] != ' ' and line[1] != '\t') return null;
        return .{ .ordered = false, .text = std.mem.trimStart(u8, line[2..], " \t") };
    }

    var digits: usize = 0;
    while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
    if (digits == 0 or digits + 1 >= line.len) return null;
    if (line[digits] != '.' and line[digits] != ')') return null;
    if (line[digits + 1] != ' ' and line[digits + 1] != '\t') return null;
    return .{ .ordered = true, .text = std.mem.trimStart(u8, line[digits + 2 ..], " \t") };
}

/// Writes the inline markdown of one line of text: code, emphasis and links,
/// with everything else escaped as it is written. This is the markdown that can
/// sit inside a paragraph, a heading, a list item or a quote.
fn inlineText(text: []const u8, out: *Io.Writer) Io.Writer.Error!void {
    var plain: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];

        if (byte == '`') {
            if (code(text, i)) |found| {
                try escape(text[plain..i], out);
                try out.writeAll("<code>");
                try escape(found.body, out);
                try out.writeAll("</code>");
                i = found.end;
                plain = i;
                continue;
            }
        }

        if (byte == '*' or byte == '_') {
            if (emphasis(text, i)) |found| {
                try escape(text[plain..i], out);
                try out.print("<{s}>", .{found.tag});
                try inlineText(text[i + found.open .. found.close], out);
                try out.print("</{s}>", .{found.tag});
                i = found.close + found.open;
                plain = i;
                continue;
            }
        }

        if (byte == '[') {
            if (link(text, i)) |found| {
                try escape(text[plain..i], out);
                try writeLink(found.url, found.text, out);
                i = found.end;
                plain = i;
                continue;
            }
        }

        i += 1;
    }
    try escape(text[plain..], out);
}

/// A code span found at `start`: the text it holds and where it ends after the
/// run of backticks that closes it.
const Code = struct { body: []const u8, end: usize };

/// The code span a backtick at `start` opens, or null when none closes it.
///
/// A span is opened by a run of backticks and closed by a run of the *same*
/// length, which is what lets code holding a backtick be written at all: the
/// usual way is to open and close with two, so ``` ``a ` b`` ``` is one span
/// holding `a ` b`. A longer run does not close a shorter one.
fn code(text: []const u8, start: usize) ?Code {
    var open: usize = 0;
    while (start + open < text.len and text[start + open] == '`') open += 1;

    var i = start + open;
    while (i < text.len) {
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < text.len and text[i + run] == '`') run += 1;
        if (run == open) {
            // A space on both sides of the body is only there to set it off from
            // the backticks, so it is not part of the code.
            var body = text[start + open .. i];
            if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ') {
                body = body[1 .. body.len - 1];
            }
            return .{ .body = body, .end = i + run };
        }
        i += run;
    }
    return null;
}

/// An emphasis run found at `start`: where its text begins and ends, how long
/// the closing marker is, and the tag it is written with.
const Emphasis = struct { open: usize, close: usize, tag: []const u8 };

/// The emphasis an `*` or `_` at `start` opens, or null when there is none.
///
/// A backslash does not escape here, since nothing that reaches a page is
/// written with one, but `_` is left alone inside a word: `session_id` is an
/// identifier, not the word `session` in emphasis, and a coding reply is full of
/// them.
fn emphasis(text: []const u8, start: usize) ?Emphasis {
    const byte = text[start];
    const doubled = start + 1 < text.len and text[start + 1] == byte;
    const width: usize = if (doubled) 2 else 1;

    if (byte == '_' and start > 0 and isWordByte(text[start - 1])) return null;

    var i = start + width;
    while (i + width <= text.len) : (i += 1) {
        if (text[i] != byte) continue;
        if (doubled and (i + 1 >= text.len or text[i + 1] != byte)) continue;
        // An emphasis that opens on a space, or closes on one, is not emphasis:
        // `a * b * c` is arithmetic, not italic.
        if (i == start + width) continue;
        if (text[i - 1] == ' ') continue;
        // `_` closes only at a word boundary for the same reason it opens at one.
        if (byte == '_' and i + width < text.len and isWordByte(text[i + width])) continue;

        const tag: []const u8 = if (doubled) "strong" else "em";
        return .{ .open = width, .close = i, .tag = tag };
    }
    return null;
}

/// Whether `byte` is part of a word, as a name is written: a letter, a digit or
/// the underscore that joins them.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// A link found at `start`: its label, the address it points at, and where the
/// link ends after the closing parenthesis.
const Link = struct { text: []const u8, url: []const u8, end: usize };

/// The link a `[` at `start` opens, or null when there is none or the address is
/// one that must not be linked.
///
/// A link is written as `<a href="…">`, so the address is escaped into the
/// attribute and the scheme is checked: only addresses that cannot run code when
/// they are followed are linked. Everything else is shown as its own text, which
/// is what a model writing `[x](javascript:…)` gets.
fn link(text: []const u8, start: usize) ?Link {
    const label_end = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
    const url_end = std.mem.indexOfScalarPos(u8, text, label_end + 2, ')') orelse return null;
    const url = text[label_end + 2 .. url_end];
    if (!linkable(url)) return null;
    return .{ .text = text[start + 1 .. label_end], .url = url, .end = url_end + 1 };
}

/// Writes a link, which needs the address as well as its label.
fn writeLink(url: []const u8, label: []const u8, out: *Io.Writer) Io.Writer.Error!void {
    try out.writeAll("<a href=\"");
    try escape(url, out);
    try out.writeAll("\">");
    try inlineText(label, out);
    try out.writeAll("</a>");
}

/// Whether `url` may be put in a link. A page given `javascript:` runs what
/// follows when the link is followed, so only the schemes that fetch something
/// are allowed; a relative address is fine, since it stays on the same host.
fn linkable(url: []const u8) bool {
    const end = std.mem.indexOfAny(u8, url, "/?#") orelse url.len;
    const colon = std.mem.indexOfScalar(u8, url[0..end], ':') orelse return true;
    const scheme = url[0..colon];
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto");
}

/// Writes an edit's diff as HTML: what the model asked to remove and what it
/// asked to put in its place, one line to a span so the two sides can be told
/// apart by a class as well as by their mark.
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
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;", out.written());

    out.clearRetainingCapacity();
    try escape("plain text 123", &out.writer);
    try std.testing.expectEqualStrings("plain text 123", out.written());
}

/// Renders `text` as markdown and checks it against `expected`.
fn expectMarkdown(expected: []const u8, text: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try markdown(text, &out.writer);
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
    // A paragraph after a list is its own block.
    try expectMarkdown("<ul>\n<li>one</li>\n</ul>\n<p>after</p>\n", "- one\nafter\n");
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
        "<blockquote><p>one\nand two</p></blockquote>\n",
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

    // A scheme that runs code is not a link, so what is left is the text of it.
    try expectMarkdown(
        "<p>[x](javascript:alert(1))</p>\n",
        "[x](javascript:alert(1))\n",
    );
    try expectMarkdown("<p>[x](data:text/html,&lt;b&gt;)</p>\n", "[x](data:text/html,<b>)\n");
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
