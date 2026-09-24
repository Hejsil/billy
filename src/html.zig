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
const agent = @import("agent.zig");
const diffing = @import("diff.zig");
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
            '\'' => "&#39;",
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
    // How many blank lines have been seen since the last line that was not
    // blank. One blank line does not end a list: a list written with a blank
    // line between its items is still one list, and closing it there would
    // restart its numbering, which is what makes every item show as 1. The count
    // is kept so that a list is ended by a second blank line, rather than
    // reaching across a gap to the next item.
    var blanks: usize = 0;

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
            // A blank line ends a paragraph, a quote or a code block at once. A
            // list may carry on after one blank line, so it is left open for the
            // next line to decide; two blank lines end it.
            if (open == .ordered or open == .unordered) {
                blanks += 1;
                if (blanks >= 2) try close(&open, out);
            } else {
                try close(&open, out);
            }
            continue;
        }
        blanks = 0;

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
                // An ordered list keeps the number it was written starting at, so
                // a list that starts at 3 shows 3, 4, 5 rather than 1, 2, 3. The
                // numbers after the first are not written: an `<ol>` counts its
                // own items from wherever it starts.
                if (!item.ordered) {
                    try out.writeAll("<ul>\n");
                } else if (item.number > 1) {
                    try out.print("<ol start=\"{d}\">\n", .{item.number});
                } else {
                    try out.writeAll("<ol>\n");
                }
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

const Item = struct {
    ordered: bool,
    text: []const u8,
    /// The number an ordered item was written with. Only the first item of a
    /// list matters: it is where the list starts, and the rest are numbered from
    /// it. An unordered item is always 1.
    number: usize = 1,
};

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
    // The number is where the list starts. A number too long to be one is read
    // as the start of one, so a nonsense marker is still a list.
    const number = std.fmt.parseInt(usize, line[0..digits], 10) catch 1;
    return .{
        .ordered = true,
        .text = std.mem.trimStart(u8, line[digits + 2 ..], " \t"),
        .number = number,
    };
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

    // A blank line between items does not end the list, and does not restart its
    // numbering: the items are still one list, written as one.
    try expectMarkdown(
        "<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n",
        "1. one\n\n2. two\n",
    );
    try expectMarkdown(
        "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n",
        "- one\n\n- two\n",
    );
    // A blank line, then something that is not an item, ends the list.
    try expectMarkdown(
        "<ol>\n<li>one</li>\n</ol>\n<p>after</p>\n",
        "1. one\n\nafter\n",
    );
    // Two blank lines end it too, so a list does not reach across a gap; the
    // next item starts a new list at the number it was written with.
    try expectMarkdown(
        "<ol>\n<li>one</li>\n</ol>\n<ol start=\"2\">\n<li>two</li>\n</ol>\n",
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

/// Writes an element holding `text`, with the text escaped. The tag and the
/// class are billy's own, written as they are; only the text comes from outside.
fn element(comptime tag: []const u8, class: []const u8, text: []const u8, out: *Io.Writer) !void {
    try out.print("<{s} class=\"{s}\">", .{ tag, class });
    try escape(text, out);
    try out.print("</{s}>\n", .{tag});
}

/// Writes the head of a tool call's block: the glyph of the tool, its name and
/// what the call acts on, and then what the call shows under that -- an edit's
/// diff, or the command a bash call runs.
///
/// A call's block is two pieces, this and `toolEnd`, rather than one element
/// opened here and closed there. A piece that is opened and never closed would
/// swallow whatever follows it, and a live call shows its head long before its
/// result; two pieces written next to each other are safe either way, and the
/// frontend styles them as one block.
pub fn toolBegin(gpa: std.mem.Allocator, call: Tools.Call, out: *Io.Writer) !void {
    const head = Tools.Heading.of(call);
    try out.writeAll("<div class=\"tool-head\">");
    try out.print("<span class=\"glyph hue-{s}\">", .{@tagName(head.hue)});
    try escape(head.glyph, out);
    try out.writeAll("</span> <span class=\"name\">");
    try escape(head.name, out);
    try out.writeAll("</span>");
    if (head.target.len > 0) {
        try out.writeAll(" <span class=\"target\">");
        try escape(head.target, out);
        try out.writeAll("</span>");
    }
    try out.writeAll("</div>\n");

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
}

/// Writes the body of a tool call's block: what the call produced.
///
/// A write shows the content it put in the file rather than its result, since
/// that content is what it produced; an edit shows nothing, since its result
/// would only repeat the diff above it; and a call that failed shows billy's
/// message for the failure whatever it was asked to do. Anything else shows the
/// text the call returned.
pub fn toolEnd(call: Tools.Call, result: []const u8, out: *Io.Writer) !void {
    const text = std.mem.trimEnd(u8, result, "\n");
    if (std.mem.startsWith(u8, result, "error: ")) {
        return element("pre", "error", text, out);
    }
    switch (call) {
        .write => |args| try element("pre", "result", std.mem.trimEnd(u8, args.content, "\n"), out),
        .edit => {},
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
        .prompt => |text| try titled(agent.marks.prompt.glyph, "prompt", text, out),
        .answer => |text| try titled(agent.marks.answer.glyph, "answer", text, out),
        .tool_begin => |call| try toolBegin(gpa, call, out),
        .tool_end => |tool| try toolEnd(tool.call, tool.result, out),
        // A compaction stands in for the messages it replaced. What it holds is
        // the ask and the summary, which a page could show; for now it is the
        // line the terminal shows it as.
        .compacted => try element("div", "compacted", agent.marks.compacted.glyph ++ " compacted", out),
        .notice => |text| try element("div", "notice", text, out),
        .elided => |count| {
            var buffer: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "… {d} earlier blocks", .{count}) catch "… earlier blocks";
            try element("div", "elided", line, out);
        },
    }
}

/// Writes a block that is headed by a mark and holds markdown: a prompt or a
/// reply.
fn titled(glyph: []const u8, name: []const u8, text: []const u8, out: *Io.Writer) !void {
    try out.print("<div class=\"block {s}\"><div class=\"head\">", .{name});
    try out.print("<span class=\"glyph\">", .{});
    try escape(glyph, out);
    try out.writeAll("</span> <span class=\"name\">");
    try escape(name, out);
    try out.writeAll("</span></div>\n");
    try markdown(text, out);
    try out.writeAll("</div>\n");
}

test "a tool call is rendered as a head and a body" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A read: the head names the tool and its path, the body is what came back.
    try toolBegin(arena, Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), &out.writer);
    try toolEnd(.{ .read = .{ .path = "a.zig" } }, "1\tconst x = 1;", &out.writer);
    try std.testing.expectEqualStrings(
        "<div class=\"tool-head\"><span class=\"glyph hue-blue\">▸</span> " ++
            "<span class=\"name\">read</span> <span class=\"target\">a.zig</span></div>\n" ++
            "<pre class=\"result\">1\tconst x = 1;</pre>\n",
        out.written(),
    );
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
    try toolBegin(arena, bash, &out.writer);
    // The command is escaped like any other text, and its trailing newline does
    // not add a blank line.
    try std.testing.expectEqualStrings(
        "<div class=\"tool-head\"><span class=\"glyph hue-cyan\">❯</span> " ++
            "<span class=\"name\">bash</span></div>\n" ++
            "<pre class=\"command\">ls -la &lt;x&gt;</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A write shows the content it put in the file, not the result that says it
    // did, which is what the terminal shows too.
    const write = Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "write",
        .arguments = "{\"path\":\"a.zig\",\"content\":\"hello\"}",
    } });
    try toolEnd(write, "wrote 5 bytes to a.zig", &out.writer);
    try std.testing.expectEqualStrings("<pre class=\"result\">hello</pre>\n", out.written());
    out.clearRetainingCapacity();

    // A failure is shown as billy's message for it, whatever the call was.
    try toolEnd(write, "error: cannot write a.zig: AccessDenied", &out.writer);
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
    try toolBegin(arena, edit, &out.writer);
    // The diff is right under the header, and its result shows nothing.
    try std.testing.expectEqualStrings(
        "<div class=\"tool-head\"><span class=\"glyph hue-yellow\">✎</span> " ++
            "<span class=\"name\">edit</span> <span class=\"target\">a.zig</span></div>\n" ++
            "<pre class=\"diff\"><span class=\"removed\">-old</span>\n" ++
            "<span class=\"added\">+new</span>\n</pre>\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try toolEnd(edit, "replaced 1 occurrence(s) in a.zig", &out.writer);
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
    // and a compaction standing in for the conversation before it.
    try session.append(.{ .role = "system", .content = "be terse" });
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
    // The read call is headed and its result is the body.
    try std.testing.expect(std.mem.indexOf(u8, page, "<span class=\"name\">read</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<pre class=\"result\">1\tconst x = 1;</pre>") != null);
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
