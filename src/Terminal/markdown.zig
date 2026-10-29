//! Rendering markdown for the terminal: what the parser decides, set with the marks it draws, the
//! codes it takes and the columns it reads, written as the text arrives.

const std = @import("std");

const markdown = @import("../markdown.zig");
const terminal_width = @import("width.zig");
const Writer = @import("Writer.zig");

const Style = Writer.Style;

const code_indent = "    ";
const rule: [40]u8 = @splat('-');
const max_list_depth = 16;

pub fn write(gpa: std.mem.Allocator, text: []const u8, writer: Writer) !void {
    var render: Render = .{ .writer = writer };
    try markdown.write(gpa, text, render.interface());
    try render.finish();
}

/// A renderer kept for a reply read in pieces: the parser holds the bytes until it can decide them,
/// and the terminal's own state has to outlive the stream it was handed to.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    render: *Render,
    parser: markdown.Stream,

    pub fn open(gpa: std.mem.Allocator, writer: Writer) !Stream {
        const render = try gpa.create(Render);
        errdefer gpa.destroy(render);
        render.* = .{ .writer = writer };
        return .{ .gpa = gpa, .render = render, .parser = markdown.Stream.open(gpa, render.interface()) };
    }

    pub fn feed(self: *Stream, text: []const u8) !void {
        try self.parser.feed(text);
    }

    pub fn close(self: *Stream) !void {
        defer self.deinit();
        try self.parser.close();
        try self.render.finish();
    }

    pub fn deinit(self: *Stream) void {
        self.parser.deinit();
        self.gpa.destroy(self.render);
    }
};

const Render = struct {
    writer: Writer,
    /// Lines ended but not yet written, so a reply that ends with one does not write it.
    pending_newlines: usize = 0,
    at_line_start: bool = true,
    in_code: bool = false,
    quotes: usize = 0,
    indent: usize = 0,
    heading: bool = false,
    strong: usize = 0,
    em: usize = 0,
    code: usize = 0,
    strike: usize = 0,
    link: ?[]const u8 = null,
    shown: u4 = 0,

    fn interface(self: *Render) markdown.Renderer {
        return .{ .context = self, .emit = show };
    }

    fn show(context: *anyopaque, event: markdown.Event) anyerror!void {
        const self: *Render = @ptrCast(@alignCast(context));
        switch (event) {
            .newline, .blank => try self.next(),
            .line => |line| try self.start(line),
            .text => |text| try self.emit(text),
            .span_begin => |span| self.open(span),
            .span_end => |span| self.close(span),
            .link_begin => |url| try self.openLink(url),
            .link_end => try self.closeLink(),
            .image => |image| try self.emit(if (image.label.len > 0) image.label else image.url),
            .rule => {
                try self.flush();
                try self.plain(0);
                try self.raw(&rule);
                try self.next();
            },
            .code_begin => self.in_code = true,
            .code_end => self.in_code = false,
            .table => |table| try self.writeTable(table),
        }
    }

    /// Ends the document: a style left on is turned off, so the terminal is not left bold.
    fn finish(self: *Render) !void {
        try self.plain(0);
    }

    fn raw(self: *Render, text: []const u8) !void {
        try self.writer.out.writeAll(text);
    }

    fn flush(self: *Render) !void {
        var i: usize = 0;
        while (i < self.pending_newlines) : (i += 1) try self.raw("\n");
        self.pending_newlines = 0;
    }

    fn mask(self: *const Render) u4 {
        return @as(u4, @intFromBool(self.heading or self.strong > 0)) |
            @as(u4, @intFromBool(self.em > 0)) << 1 |
            @as(u4, @intFromBool(self.quotes > 0 or self.in_code or self.code > 0)) << 2 |
            @as(u4, @intFromBool(self.strike > 0)) << 3;
    }

    /// Brings the terminal's style to what the line holds, writing the codes only when they change.
    fn plain(self: *Render, want: u4) !void {
        if (want == self.shown) return;
        if (self.shown != 0) try self.raw(self.writer.reset());
        if (want & 1 != 0) try self.raw(self.writer.bold());
        if (want & 2 != 0) try self.raw(self.writer.italic());
        if (want & 4 != 0) try self.raw(self.writer.dim());
        if (want & 8 != 0) try self.raw(self.writer.strike());
        self.shown = want;
    }

    fn emit(self: *Render, text: []const u8) !void {
        if (self.at_line_start) {
            if (self.in_code) {
                try self.flush();
                try self.plain(self.mask());
                try self.raw(code_indent);
            }
            self.at_line_start = false;
        }
        if (text.len == 0) return;
        try self.flush();
        try self.plain(self.mask());
        try self.raw(text);
    }

    fn next(self: *Render) !void {
        try self.plain(0);
        self.strong = 0;
        self.em = 0;
        self.code = 0;
        self.strike = 0;
        self.quotes = 0;
        self.indent = 0;
        self.heading = false;
        self.pending_newlines += 1;
        self.at_line_start = true;
    }

    /// Writes what stands before a line's text: its bars, its indentation and a list's marker.
    fn start(self: *Render, line: markdown.Line) !void {
        self.quotes = line.quote_depth;
        self.indent = line.indent;
        self.heading = line.heading != null;

        try self.flush();
        try self.plain(self.mask());
        var depth: usize = 0;
        while (depth < line.quote_depth) : (depth += 1) try self.raw("> ");
        const capped = @min(line.indent, 2 * (max_list_depth - 1));
        var column: usize = 0;
        while (column < capped) : (column += 1) try self.raw(" ");
        if (line.item) |item| try self.marker(item);
        self.at_line_start = false;
    }

    fn marker(self: *Render, item: markdown.Item) !void {
        if (item.number) |number| return try self.print("{s}. ", .{number});
        if (item.task) |done| return try self.raw(if (done) "- [x] " else "- [ ] ");
        return try self.raw("- ");
    }

    fn open(self: *Render, span: markdown.Span) void {
        switch (span) {
            .strong => self.strong += 1,
            .em => self.em += 1,
            .code => self.code += 1,
            .strike => self.strike += 1,
        }
    }

    fn close(self: *Render, span: markdown.Span) void {
        switch (span) {
            .strong => self.strong -|= 1,
            .em => self.em -|= 1,
            .code => self.code -|= 1,
            .strike => self.strike -|= 1,
        }
    }

    fn openLink(self: *Render, url: []const u8) !void {
        self.link = url;
        if (self.writer.linkOpen().len == 0) return;
        try self.flush();
        try self.raw(self.writer.linkOpen());
        try self.raw(url);
        try self.raw(self.writer.linkClose());
    }

    /// Where the terminal takes no links the label is its text and the address stands beside it.
    fn closeLink(self: *Render) !void {
        const url = self.link orelse return;
        self.link = null;
        if (self.writer.linkOpen().len == 0) {
            try self.emit(" (");
            try self.emit(url);
            return self.emit(")");
        }
        try self.flush();
        try self.raw(self.writer.linkOpen());
        try self.raw(self.writer.linkClose());
    }

    /// Lays the table out: its columns are as wide as their widest cell, which only the whole table
    /// tells, and its head is followed by a rule of dashes.
    fn writeTable(self: *Render, table: markdown.Table) !void {
        var widths: [markdown.max_columns]usize = @splat(0);
        for (table.rows) |row| {
            for (row.cells, 0..) |text, column| {
                if (column == widths.len) break;
                widths[column] = @max(widths[column], strippedColumns(text));
            }
        }
        const columns = widths[0..table.aligns.len];
        for (table.rows, 0..) |row, at| {
            try self.writeRow(row, columns, table.aligns);
            if (at == table.head) try self.writeDashes(columns);
        }
    }

    fn writeRow(self: *Render, row: markdown.Row, widths: []const usize, aligns: []const markdown.Align) !void {
        var cell: [1024]u8 = undefined;
        try self.flush();
        try self.plain(0);
        for (widths, 0..) |width, column| {
            if (column > 0) try self.raw("  ");
            const text = if (column < row.cells.len) row.cells[column] else "";
            const pad = width - strippedColumns(text);
            const before = switch (aligns[column]) {
                .right => pad,
                .center => pad / 2,
                else => 0,
            };
            var space: usize = 0;
            while (space < before) : (space += 1) try self.raw(" ");
            try self.raw(stripped(text, &cell));
            if (column + 1 < widths.len) {
                space = 0;
                while (space < pad - before) : (space += 1) try self.raw(" ");
            }
        }
        try self.next();
    }

    fn writeDashes(self: *Render, widths: []const usize) !void {
        try self.flush();
        for (widths, 0..) |width, column| {
            if (column > 0) try self.raw("  ");
            var dash: usize = 0;
            while (dash < width) : (dash += 1) try self.raw("-");
        }
        try self.next();
    }

    fn print(self: *Render, comptime format: []const u8, args: anytype) !void {
        try self.writer.out.print(format, args);
    }
};

fn isMarkByte(byte: u8) bool {
    return byte == '*' or byte == '_' or byte == '`' or byte == '~';
}

/// Whether `mark` comes in a pair in `text`, and so is a mark rather than a character of the text.
fn paired(text: []const u8, mark: u8) bool {
    var seen: usize = 0;
    for (text) |byte| {
        if (byte == mark) seen += 1;
    }
    return seen >= 2;
}

fn strippedColumns(text: []const u8) usize {
    var out: [1024]u8 = undefined;
    return terminal_width.columns(stripped(text, &out));
}

fn stripped(text: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (len == out.len) break;
        if (isMarkByte(byte) and paired(text, byte)) continue;
        out[len] = byte;
        len += 1;
    }
    return out[0..len];
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
    try expectAnsi("\x1b[2m    let x = 1;\x1b[0m", "```zig\nlet x = 1;\n```");
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

test "what arrives is written before the line ends" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stream = try Stream.open(gpa, .{ .out = &out.writer });
    defer stream.deinit();

    try stream.feed("hello, **wor");
    try std.testing.expectEqualStrings("hello, wor", out.written());
    try stream.feed("ld** and `co");
    try std.testing.expectEqualStrings("hello, world and co", out.written());
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
