//! Rendering markdown for the terminal.

const std = @import("std");

const md = @import("../md.zig");
const Writer = @import("Writer.zig");
const Style = Writer.Style;
const terminal_width = @import("width.zig");

const Markdown = @This();

const max_list_depth = 16;
const code_indent = "    ";
const rule: [40]u8 = @splat('-');
const max_columns = 32;

gpa: std.mem.Allocator,
writer: Writer,
err: ?anyerror = null,

pending_newlines: usize = 0,
at_line_start: bool = true,

quote_depth: usize = 0,
list_depth: usize = 0,
list: [max_list_depth]ListFrame = undefined,
container_depth: usize = 0,
emitted: bool = false,
need_blank: bool = false,
block_head: bool = false,
in_code: bool = false,
in_head: bool = false,

image_depth: usize = 0,
image_label: std.ArrayList(u8) = .empty,
image_url: []const u8 = "",
link_url: []const u8 = "",

table: bool = false,
rows: std.ArrayList(Row) = .empty,
row: std.ArrayList([]u8) = .empty,
cell: std.ArrayList(u8) = .empty,
aligns: std.ArrayList(md.c.MD_ALIGN) = .empty,

const Numbering = enum { ordered, unordered };

const ListFrame = struct {
    numbering: Numbering = .unordered,
    next: usize = 1,
};

const Row = struct {
    header: bool = false,
    cells: std.ArrayList([]u8) = .empty,
};

/// Writes `text`, read as markdown, as the terminal shows it.
pub fn write(gpa: std.mem.Allocator, text: []const u8, writer: Writer) !void {
    var render = Markdown{ .gpa = gpa, .writer = writer };
    defer render.deinit();

    var callbacks = md.parser(Markdown);
    try md.parse(text, &callbacks, &render);

    // A callback cannot return an error, so a failed write is kept on the renderer and reported
    // here, once the parser has stopped.
    if (render.err) |err| return err;
}

/// A renderer and the streaming parser driving it, kept together so the parser's `userdata` pointer
/// stays valid for as long as the document does.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    renderer: *Markdown,
    stream: md.Stream,

    /// Starts a document.
    pub fn open(gpa: std.mem.Allocator, writer: Writer) !Stream {
        const renderer = try gpa.create(Markdown);
        errdefer gpa.destroy(renderer);
        renderer.* = .{ .gpa = gpa, .writer = writer };
        errdefer renderer.deinit();

        var callbacks = md.parser(Markdown);
        return .{
            .gpa = gpa,
            .renderer = renderer,
            .stream = try md.Stream.init(&callbacks, renderer),
        };
    }

    /// Writes more of the reply.
    pub fn feed(self: *Stream, text: []const u8) !void {
        self.stream.feed(text) catch |err| return self.renderer.err orelse err;
    }

    /// Ends the document, writing the last line and closing the blocks still open, and frees what
    /// was held for it.
    pub fn close(self: *Stream) !void {
        var failure = self.renderer.err;
        if (!self.stream.failed and failure == null) {
            self.stream.flush() catch |err| {
                failure = self.renderer.err orelse err;
            };
        }
        self.stream.deinit();
        self.renderer.deinit();
        self.gpa.destroy(self.renderer);
        if (failure) |err| return err;
    }

    /// Drops a document that will not be finished, without writing more of it.
    pub fn deinit(self: *Stream) void {
        self.stream.deinit();
        self.renderer.deinit();
        self.gpa.destroy(self.renderer);
    }
};

fn deinit(self: *Markdown) void {
    self.image_label.deinit(self.gpa);
    self.freeTable();
}

fn raw(self: *Markdown, bytes: []const u8) bool {
    if (self.err != null) return false;
    self.writer.out.writeAll(bytes) catch |err| {
        self.err = err;
        return false;
    };
    return true;
}

fn flush(self: *Markdown) bool {
    var i: usize = 0;
    while (i < self.pending_newlines) : (i += 1)
        if (!self.raw("\n")) return false;

    if (self.pending_newlines > 0)
        self.at_line_start = true;
    self.pending_newlines = 0;
    return true;
}

fn newline(self: *Markdown) void {
    self.pending_newlines += 1;
    self.at_line_start = true;
}

fn endLine(self: *Markdown) void {
    if (!self.at_line_start) self.newline();
}

fn writeIndent(self: *Markdown) bool {
    if (!self.at_line_start)
        return true;

    self.at_line_start = false;
    var i: usize = 0;

    while (i < self.quote_depth) : (i += 1)
        if (!self.raw("> ")) return false;

    i = 0;
    while (i < self.indentDepth()) : (i += 1)
        if (!self.raw("  ")) return false;

    if (self.in_code and !self.raw(code_indent))
        return false;
    return true;
}

fn put(self: *Markdown, text: []const u8) bool {
    var rest: []const u8 = text;
    while (rest.len > 0) {
        const cut = std.mem.findScalar(u8, rest, '\n');
        const line = if (cut) |i| rest[0..i] else rest;
        if (line.len > 0) {
            if (!self.flush()) return false;
            if (!self.writeIndent()) return false;
            if (!self.raw(line)) return false;
        }
        if (cut) |i| {
            self.newline();
            rest = rest[i + 1 ..];
        } else break;
    }
    return true;
}

fn blank(self: *Markdown) bool {
    self.newline();
    return true;
}

const Head = enum { heading, body };

fn beginBlock(self: *Markdown, head: Head) bool {
    if (self.container_depth != 0) return true;
    if (self.emitted and self.need_blank and !self.blank()) return false;
    self.emitted = true;
    self.block_head = head == .heading;
    return true;
}

fn endBlock(self: *Markdown) void {
    if (self.container_depth != 0) return;
    self.need_blank = !self.block_head;
}

pub fn enterBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
    switch (block_type) {
        md.c.MD_BLOCK_DOC => {},
        md.c.MD_BLOCK_QUOTE => {
            if (!self.beginBlock(.body)) return false;
            self.quote_depth += 1;
            self.container_depth += 1;
            if (!self.raw(self.writer.dim())) return false;
        },
        md.c.MD_BLOCK_UL => return self.openList(.unordered, 1),
        md.c.MD_BLOCK_OL => {
            const list: *const md.c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail.?));
            return self.openList(.ordered, list.start);
        },
        md.c.MD_BLOCK_LI => return self.openItem(@ptrCast(@alignCast(detail.?))),
        md.c.MD_BLOCK_HR => {
            if (!self.beginBlock(.body)) return false;
            if (!self.put(&rule)) return false;
        },
        md.c.MD_BLOCK_H => {
            if (!self.beginBlock(.heading)) return false;
            if (!self.raw(self.writer.bold())) return false;
        },
        md.c.MD_BLOCK_CODE => {
            if (!self.beginBlock(.body)) return false;
            self.in_code = true;
            if (!self.raw(self.writer.dim())) return false;
        },
        md.c.MD_BLOCK_P => {
            if (!self.beginBlock(.body)) return false;
        },
        md.c.MD_BLOCK_TABLE => return self.openTable(),
        md.c.MD_BLOCK_THEAD => self.in_head = true,
        md.c.MD_BLOCK_TBODY => self.in_head = false,
        md.c.MD_BLOCK_TR => self.row = .empty,
        md.c.MD_BLOCK_TH, md.c.MD_BLOCK_TD => {
            self.cell.clearRetainingCapacity();
            if (self.in_head) {
                const cell: *const md.c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail.?));
                self.aligns.append(self.gpa, cell.@"align") catch return self.fail();
            }
        },
        // Raw HTML never reaches here (`md.flags` turns it off), and a block of an extension billy
        // does not read is ignored.
        else => {},
    }
    return true;
}

pub fn leaveBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
    _ = detail;
    switch (block_type) {
        md.c.MD_BLOCK_DOC => {},
        md.c.MD_BLOCK_QUOTE => {
            if (!self.raw(self.writer.reset())) return false;
            self.quote_depth -= 1;
            self.container_depth -= 1;
            self.endBlock();
        },
        md.c.MD_BLOCK_UL, md.c.MD_BLOCK_OL => {
            self.endLine();
            self.list_depth -= 1;
            self.container_depth -= 1;
            self.endBlock();
        },
        md.c.MD_BLOCK_LI => self.container_depth -= 1,
        md.c.MD_BLOCK_HR => {
            self.endLine();
            self.endBlock();
        },
        md.c.MD_BLOCK_H => {
            if (!self.raw(self.writer.reset())) return false;
            self.endLine();
            self.endBlock();
        },
        md.c.MD_BLOCK_CODE => {
            if (!self.raw(self.writer.reset())) return false;
            self.in_code = false;
            self.endLine();
            self.endBlock();
        },
        md.c.MD_BLOCK_P => {
            self.endLine();
            self.endBlock();
        },
        md.c.MD_BLOCK_TABLE => return self.closeTable(),
        md.c.MD_BLOCK_THEAD, md.c.MD_BLOCK_TBODY => {},
        md.c.MD_BLOCK_TR => {
            self.rows.append(self.gpa, .{ .header = self.in_head, .cells = self.row }) catch
                return self.fail();
            self.row = .empty;
        },
        md.c.MD_BLOCK_TH, md.c.MD_BLOCK_TD => {
            const text = self.gpa.dupe(u8, self.cell.items) catch return self.fail();
            self.row.append(self.gpa, text) catch return self.fail();
        },
        else => {},
    }
    return true;
}

fn indentDepth(self: *const Markdown) usize {
    return @min(self.list_depth, max_list_depth);
}

fn openList(self: *Markdown, numbering: Numbering, start: usize) bool {
    if (!self.beginBlock(.body))
        return false;

    if (self.list_depth < max_list_depth)
        self.list[self.list_depth] = .{ .numbering = numbering, .next = start };

    self.list_depth += 1;
    self.container_depth += 1;
    return true;
}

fn openItem(self: *Markdown, detail: *const md.c.MD_BLOCK_LI_DETAIL) bool {
    self.endLine();
    if (!self.flush())
        return false;

    self.at_line_start = true;

    var i: usize = 0;
    while (i < self.quote_depth) : (i += 1)
        if (!self.raw("> ")) return false;

    i = 0;
    while (i + 1 < self.indentDepth()) : (i += 1)
        if (!self.raw("  ")) return false;

    self.at_line_start = false;

    const frame = &self.list[self.indentDepth() - 1];
    var buffer: [24]u8 = undefined;
    const marker: []const u8 = if (frame.numbering == .ordered) blk: {
        const written = std.mem.print(&buffer, "{d}. ", .{frame.next}) catch return self.fail();

        frame.next += 1;
        break :blk written;
    } else if (detail.is_task != 0) blk: {
        break :blk if (detail.task_mark == 'x' or detail.task_mark == 'X') "- [x] " else "- [ ] ";
    } else "- ";
    if (!self.raw(marker))
        return false;

    self.container_depth += 1;
    return true;
}

fn openTable(self: *Markdown) bool {
    if (!self.beginBlock(.body)) return false;
    self.table = true;
    self.rows = .empty;
    self.row = .empty;
    self.cell = .empty;
    self.aligns = .empty;
    return true;
}

fn closeTable(self: *Markdown) bool {
    defer self.freeTable();
    self.table = false;
    if (self.rows.items.len == 0) {
        self.endLine();
        self.endBlock();
        return true;
    }

    var widths: [max_columns]usize = @splat(0);
    const columns = self.columnCount();
    for (self.rows.items) |row| {
        for (row.cells.items, 0..) |cell, column| {
            if (column >= columns) break;
            widths[column] = @max(widths[column], terminal_width.columns(cell));
        }
    }

    for (self.rows.items) |row| {
        if (!self.flush()) return false;
        self.at_line_start = true;
        if (!self.writeIndent()) return false;
        for (0..columns) |column| {
            if (column > 0 and !self.raw("  ")) return false;
            const cell = if (column < row.cells.items.len) row.cells.items[column] else "";
            const last = column + 1 == columns;
            if (!self.writeCell(cell, widths[column], self.alignAt(column), !last)) return false;
        }
        self.endLine();
        if (row.header and !self.writeRule(&widths, columns)) return false;
    }
    self.endBlock();
    return true;
}

fn writeRule(self: *Markdown, widths: []const usize, columns: usize) bool {
    if (!self.flush()) return false;
    self.at_line_start = true;
    if (!self.writeIndent()) return false;
    for (0..columns) |column| {
        if (column > 0 and !self.raw("  ")) return false;
        if (!self.fill('-', widths[column])) return false;
    }
    self.endLine();
    return true;
}

fn writeCell(self: *Markdown, text: []const u8, width: usize, alignment: md.c.MD_ALIGN, pad_right: bool) bool {
    const pad = width - terminal_width.columns(text);
    const before = switch (alignment) {
        md.c.MD_ALIGN_RIGHT => pad,
        md.c.MD_ALIGN_CENTER => pad / 2,
        else => 0,
    };
    const after = if (pad_right) pad else before;
    if (!self.fill(' ', before)) return false;
    if (!self.raw(text)) return false;
    return self.fill(' ', after - before);
}

fn fill(self: *Markdown, byte: u8, count: usize) bool {
    if (self.err != null) return false;
    self.writer.out.splatByteAll(byte, count) catch |err| {
        self.err = err;
        return false;
    };
    return true;
}

fn columnCount(self: *Markdown) usize {
    var columns: usize = 0;
    for (self.rows.items) |row| columns = @max(columns, row.cells.items.len);
    return @min(columns, max_columns);
}

fn alignAt(self: *Markdown, column: usize) md.c.MD_ALIGN {
    if (column < self.aligns.items.len) return self.aligns.items[column];
    return md.c.MD_ALIGN_DEFAULT;
}

fn freeTable(self: *Markdown) void {
    for (self.rows.items) |*row| {
        for (row.cells.items) |cell| self.gpa.free(cell);
        row.cells.deinit(self.gpa);
    }
    self.rows.deinit(self.gpa);
    self.rows = .empty;
    self.row.deinit(self.gpa);
    self.row = .empty;
    self.cell.deinit(self.gpa);
    self.cell = .empty;
    self.aligns.deinit(self.gpa);
    self.aligns = .empty;
}

pub fn enterSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
    if (span_type == md.c.MD_SPAN_IMG) {
        const img: *const md.c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail.?));
        self.image_url = attribute(img.src);
        self.image_depth += 1;
        return true;
    }
    // Inside a table cell only the text is kept: a code of colour would make the column widths
    // wrong.
    if (self.table) return true;
    return switch (span_type) {
        md.c.MD_SPAN_EM => self.raw(self.writer.italic()),
        md.c.MD_SPAN_STRONG => self.raw(self.writer.bold()),
        md.c.MD_SPAN_CODE => self.raw(self.writer.dim()),
        md.c.MD_SPAN_DEL => self.raw(self.writer.strike()),
        md.c.MD_SPAN_A => self.openA(@ptrCast(@alignCast(detail.?))),
        else => true,
    };
}

pub fn leaveSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
    _ = detail;
    if (span_type == md.c.MD_SPAN_IMG) return self.closeImg();
    if (self.table) return true;
    return switch (span_type) {
        md.c.MD_SPAN_EM, md.c.MD_SPAN_STRONG, md.c.MD_SPAN_CODE, md.c.MD_SPAN_DEL => self.raw(self.writer.reset()),
        md.c.MD_SPAN_A => self.closeA(),
        else => true,
    };
}

fn openA(self: *Markdown, detail: *const md.c.MD_SPAN_A_DETAIL) bool {
    self.link_url = attribute(detail.href);
    if (self.writer.linkOpen().len == 0) return true;
    if (!self.raw(self.writer.linkOpen()) or !self.raw(self.link_url) or !self.raw(self.writer.linkClose())) return false;
    return true;
}

fn closeA(self: *Markdown) bool {
    if (self.writer.linkOpen().len > 0) {
        if (!self.raw(self.writer.linkOpen()) or !self.raw(self.writer.linkClose())) return false;
    } else if (self.link_url.len > 0) {
        if (!self.put(" (")) return false;
        if (!self.put(self.link_url)) return false;
        if (!self.put(")")) return false;
    }
    self.link_url = "";
    return true;
}

fn closeImg(self: *Markdown) bool {
    self.image_depth -= 1;
    if (self.image_depth > 0) return true;

    const label = self.image_label.items;
    const has_label = std.mem.trim(u8, label, " \t\r\n").len > 0;
    const shown: []const u8 = if (has_label) label else self.image_url;
    const opens = self.writer.linkOpen().len > 0 and self.image_url.len > 0;
    if (opens and !self.raw(self.writer.linkOpen())) return false;
    if (opens and !self.raw(self.image_url)) return false;
    if (opens and !self.raw(self.writer.linkClose())) return false;
    if (!self.put(shown)) return false;
    if (opens and !self.raw(self.writer.linkOpen())) return false;
    if (opens and !self.raw(self.writer.linkClose())) return false;
    self.image_label.clearRetainingCapacity();
    self.image_url = "";
    return true;
}

pub fn writeText(self: *Markdown, text_type: md.c.MD_TEXTTYPE, text: []const u8) bool {
    if (self.image_depth > 0) {
        self.image_label.appendSlice(self.gpa, text) catch return self.fail();
        return true;
    }
    return switch (text_type) {
        // A NULL is replaced the way CommonMark says, rather than written.
        md.c.MD_TEXT_NULLCHAR => self.emit("\u{FFFD}"),
        md.c.MD_TEXT_BR, md.c.MD_TEXT_SOFTBR => self.emit("\n"),
        md.c.MD_TEXT_ENTITY => self.writeEntity(text),
        // A code block's text is written as it is: the newline that ends its last line is held like
        // any other, so the colour code that closes the block lands on that line rather than below
        // it.
        else => self.emit(text),
    };
}

fn writeEntity(self: *Markdown, text: []const u8) bool {
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(self.gpa);
    md.decodeEntity(self.gpa, text, &value) catch return self.fail();
    return self.emit(value.items);
}

fn emit(self: *Markdown, bytes: []const u8) bool {
    if (self.table) {
        self.cell.appendSlice(self.gpa, bytes) catch return self.fail();
        return true;
    }
    return self.put(bytes);
}

fn fail(self: *Markdown) bool {
    if (self.err == null) self.err = error.OutOfMemory;
    return false;
}

fn attribute(value: md.c.MD_ATTRIBUTE) []const u8 {
    if (value.text == null or value.size == 0) return "";
    return value.text[0..value.size];
}

fn expectRendered(expected: []const u8, text: []const u8, style: Style) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const writer: Writer = .{ .style = style, .out = &out.writer };
    try write(std.testing.allocator, text, writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

fn expectPlain(expected: []const u8, text: []const u8) !void {
    try expectRendered(expected, text, .plain);
}

fn expectAnsi(expected: []const u8, text: []const u8) !void {
    try expectRendered(expected, text, .ansi);
}

test "a paragraph is written as it stands" {
    try expectPlain("hello world", "hello world");
    try expectPlain("one\ntwo", "one\ntwo");
}

test "inline markdown is set in the style of the terminal" {
    try expectPlain("bold and italic and code", "**bold** and *italic* and `code`");
    try expectAnsi(
        "\x1b[1mbold\x1b[0m and \x1b[3mitalic\x1b[0m and \x1b[2mcode\x1b[0m",
        "**bold** and *italic* and `code`",
    );
    try expectAnsi("\x1b[9mgone\x1b[0m", "~~gone~~");
}

test "a heading is its text in bold, with no mark" {
    try expectPlain("Title", "# Title");
    try expectAnsi("\x1b[1mTitle\x1b[0m", "## Title");
}

test "a list is bulleted and indented, a nested list further" {
    try expectPlain("- one\n- two", "- one\n- two");
    try expectPlain("- one\n  - deeper", "- one\n  - deeper");
}

test "an ordered list keeps its numbers" {
    try expectPlain("1. one\n2. two", "1. one\n2. two");
    try expectPlain("3. three\n4. four", "3. three\n4. four");
}

test "a task list shows its boxes" {
    try expectPlain("- [x] done\n- [ ] todo", "- [x] done\n- [ ] todo");
}

test "a code block is set apart and left as written" {
    try expectPlain("    let x = 1;\n    x += 1;", "```\nlet x = 1;\nx += 1;\n```");
    try expectAnsi(
        "\x1b[2m    let x = 1;\x1b[0m",
        "```zig\nlet x = 1;\n```",
    );
}

test "a quote is barred and dim" {
    try expectPlain("> quoted", "> quoted");
    try expectAnsi("\x1b[2m> quoted\x1b[0m", "> quoted");
}

test "a horizontal rule is a line of dashes" {
    try expectPlain(&rule, "---");
}

test "a link is clickable where the terminal takes escape codes, else its address is shown" {
    try expectPlain("the spec (https://example.com)", "[the spec](https://example.com)");
    try expectAnsi(
        "\x1b]8;;https://example.com\x1b\\the spec\x1b]8;;\x1b\\",
        "[the spec](https://example.com)",
    );
}

test "an image is shown as its alt text" {
    try expectPlain("a cat", "![a cat](cat.png)");
    try expectPlain("cat.png", "![](cat.png)");
}

test "a table is aligned in columns" {
    try expectPlain(
        "name  age\n----  ---\nana   3\nbo    12",
        "| name | age |\n| --- | --- |\n| ana | 3 |\n| bo | 12 |",
    );
}

test "a table is aligned by characters, not bytes" {
    try expectPlain(
        "name  n\n----  --\n\u{e9}     1\nabc   22",
        "| name | n |\n| --- | --- |\n| \u{e9} | 1 |\n| abc | 22 |",
    );
}

test "a list nested past the indent cap is still shown" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..max_list_depth + 4) |depth| {
        for (0..depth) |_| try text.appendSlice(gpa, "  ");
        try text.appendSlice(gpa, "- item\n");
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer: Writer = .{ .out = &out.writer };
    try write(gpa, text.items, writer);

    const written = out.written();
    const last = written[std.mem.findScalarLast(u8, written, '\n').? + 1 ..];
    const indent: [2 * (max_list_depth - 1)]u8 = @splat(' ');
    try std.testing.expectEqualStrings(&indent ++ "- item", last);
}

test "a block is set off from the one before it" {
    try expectPlain("one\n\ntwo", "one\n\ntwo");
    try expectPlain("Title\nthe body", "# Title\nthe body");
}

test "a reply read in pieces is laid out like one read whole" {
    const gpa = std.testing.allocator;
    const text =
        "# Title\n" ++
        "\n" ++
        "Hello **world**, and `code`.\n" ++
        "\n" ++
        "- one\n" ++
        "- two\n" ++
        "\n" ++
        "| name | age |\n" ++
        "| --- | --- |\n" ++
        "| ana | 3 |\n";

    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    try write(gpa, text, .{ .out = &whole.writer });

    var streamed: std.Io.Writer.Allocating = .init(gpa);
    defer streamed.deinit();
    var stream = try Stream.open(gpa, .{ .out = &streamed.writer });
    var rest: []const u8 = text;
    while (rest.len > 0) {
        const count = @min(rest.len, 3);
        try stream.feed(rest[0..count]);
        rest = rest[count..];
    }
    try stream.close();

    try std.testing.expectEqualStrings(whole.written(), streamed.written());
}
