//! Rendering markdown for the terminal as it arrives: the text of the line being read is written as
//! it comes, so a reply appears while the model writes it. The forms a reply reaches for are read as
//! they come too -- headings, lists, quotes, rules, fences and tables, and emphasis, code,
//! strikethrough and links inside a line -- and nothing else is markdown.

const std = @import("std");

const Writer = @import("Writer.zig");
const Style = Writer.Style;
const terminal_width = @import("width.zig");

const Markdown = @This();

const code_indent = "    ";
const rule: [40]u8 = @splat('-');
const max_columns = 32;
const max_list_depth = 16;
const spaces = " \t";

/// What a line of source asks of the output before its text: the marks a block carries, and the
/// style its text is written in.
const Lead = struct {
    /// Bytes of the line's prefix that were read.
    taken: usize,
    /// What is written in their place: a list's bullet or its number.
    prefix: []const u8 = "",
    /// Spaces written before `prefix`.
    indent: usize = 0,
    bold: bool = false,
    dim: bool = false,
};

pub fn write(gpa: std.mem.Allocator, text: []const u8, writer: Writer) !void {
    var render = Markdown{ .gpa = gpa, .writer = writer };
    defer render.deinit();
    try render.feed(text);
    try render.finish();
}

/// A renderer kept for a reply read in pieces: what arrives is written, and only a prefix or a
/// marker that may still grow is held back.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    renderer: *Markdown,

    pub fn open(gpa: std.mem.Allocator, writer: Writer) !Stream {
        const renderer = try gpa.create(Markdown);
        errdefer gpa.destroy(renderer);
        renderer.* = .{ .gpa = gpa, .writer = writer };
        return .{ .gpa = gpa, .renderer = renderer };
    }

    pub fn feed(self: *Stream, text: []const u8) !void {
        self.renderer.feed(text) catch |err| return err;
    }

    pub fn close(self: *Stream) !void {
        defer self.deinit();
        try self.renderer.finish();
    }

    pub fn deinit(self: *Stream) void {
        self.renderer.deinit();
        self.gpa.destroy(self.renderer);
    }
};

gpa: std.mem.Allocator,
writer: Writer,

/// Bytes read and not yet written: the prefix of a line, a marker that may still grow, or a table.
pending: std.ArrayList(u8) = .empty,
/// Lines ended but not yet written, so a reply that ends with one does not write it.
pending_newlines: usize = 0,
at_line_start: bool = true,
last: u8 = '\n',
in_code: bool = false,
close_fence: u8 = '`',
bold: bool = false,
italic: bool = false,
dim: bool = false,
strike: bool = false,
span: bool = false,
shown: u4 = 0,
final: bool = false,
table: ?Table = null,

fn feed(self: *Markdown, text: []const u8) !void {
    try self.pending.appendSlice(self.gpa, text);
    try self.process();
}

/// Writes what the held bytes hold, as far as they decide, and keeps the rest for the next piece.
fn process(self: *Markdown) !void {
    while (self.pending.items.len > 0) {
        if (self.in_code) {
            if (!try self.code()) return;
        } else if (self.at_line_start) {
            if (!try self.start()) return;
        } else {
            if (!try self.body()) return;
        }
    }
}

fn deinit(self: *Markdown) void {
    self.pending.deinit(self.gpa);
    self.dropTable();
}

fn drop(self: *Markdown, count: usize) void {
    const items = self.pending.items;
    std.mem.copyForwards(u8, items[0 .. items.len - count], items[count..]);
    self.pending.items.len -= count;
}

/// Ends the document: what is held is written as it stands, and a table still open is written.
fn finish(self: *Markdown) !void {
    self.final = true;
    try self.process();
    if (self.table != null) try self.endTable();
    if (self.pending.items.len > 0) {
        try self.emit(self.pending.items);
        self.drop(self.pending.items.len);
    }
    try self.plain(0);
}

fn raw(self: *Markdown, text: []const u8) !void {
    try self.writer.out.writeAll(text);
}

fn flush(self: *Markdown) !void {
    var i: usize = 0;
    while (i < self.pending_newlines) : (i += 1) try self.raw("\n");
    self.pending_newlines = 0;
}

fn mask(self: *const Markdown) u4 {
    return @as(u4, @intFromBool(self.bold)) |
        @as(u4, @intFromBool(self.italic)) << 1 |
        @as(u4, @intFromBool(self.dim)) << 2 |
        @as(u4, @intFromBool(self.strike)) << 3;
}

/// Brings the terminal's style to what the line holds, writing the codes only when they change.
fn plain(self: *Markdown, want: u4) !void {
    if (want == self.shown) return;
    if (self.shown != 0) try self.raw(self.writer.reset());
    if (want & 1 != 0) try self.raw(self.writer.bold());
    if (want & 2 != 0) try self.raw(self.writer.italic());
    if (want & 4 != 0) try self.raw(self.writer.dim());
    if (want & 8 != 0) try self.raw(self.writer.strike());
    self.shown = want;
}

fn emit(self: *Markdown, text: []const u8) !void {
    if (text.len == 0) return;
    try self.flush();
    try self.plain(self.mask());
    try self.raw(text);
    self.last = text[text.len - 1];
}

fn next(self: *Markdown) !void {
    if (self.shown != 0) try self.plain(0);
    self.bold = false;
    self.italic = false;
    self.dim = false;
    self.strike = false;
    self.span = false;
    self.pending_newlines += 1;
    self.at_line_start = true;
    self.last = '\n';
}

fn find(bytes: []const u8, from: usize, byte: u8) ?usize {
    return std.mem.findScalarPos(u8, bytes, from, byte);
}

/// Reads the start of the line and writes what it asks for, or returns false when more of it is
/// needed to tell.
fn start(self: *Markdown) !bool {
    const bytes = self.pending.items;

    var i: usize = 0;
    var quotes: usize = 0;
    while (i < bytes.len and bytes[i] == '>') {
        i += 1;
        if (i == bytes.len) return false;
        if (bytes[i] == ' ') i += 1;
        quotes += 1;
    }

    const indented = i;
    while (i < bytes.len and std.mem.findScalar(u8, spaces, bytes[i]) != null) i += 1;
    if (i == bytes.len) return false;
    const indent = @min(i - indented, 2 * (max_list_depth - 1));

    if (self.table != null) {
        if (bytes[i] != '|') {
            try self.endTable();
            return self.start();
        }
        return self.row();
    }

    if (bytes[i] == '\n') {
        self.drop(i + 1);
        return self.blank(quotes);
    }

    if (bytes[i] == '`' or bytes[i] == '~') {
        if (i + 3 > bytes.len) return false;
        if (bytes[i + 1] == bytes[i] and bytes[i + 2] == bytes[i]) {
            const end = find(bytes, i, '\n') orelse return false;
            self.close_fence = bytes[i];
            self.in_code = true;
            self.drop(end + 1);
            return true;
        }
    }

    if (bytes[i] == '|') return self.row();

    var marker: [16]u8 = undefined;
    var lead: Lead = .{ .taken = i, .dim = quotes > 0 };
    lead.indent = indent;
    switch (bytes[i]) {
        '#' => {
            var end = i;
            while (end < bytes.len and bytes[end] == '#') end += 1;
            if (end == bytes.len) return false;
            if (bytes[end] == ' ') {
                lead.taken = end + 1;
                lead.bold = true;
            } else if (bytes[end] == '\n') {
                lead.taken = end;
                lead.bold = true;
            }
        },
        '-', '*', '+', '_' => {
            if (i + 1 == bytes.len) return false;
            if (bytes[i + 1] == bytes[i]) {
                const end = find(bytes, i, '\n') orelse bytes.len;
                if (isRule(bytes[i..end])) {
                    self.drop(@min(end + 1, bytes.len));
                    try self.writeRule();
                    return true;
                }
                if (end == bytes.len and !self.final) return false;
            }
            if (bytes[i + 1] == ' ' and bytes[i] != '_') {
                lead.taken = i + 2;
                lead.prefix = "- ";
                if (std.mem.startsWith(u8, bytes[i + 2 ..], "[ ] ")) {
                    lead.prefix = "- [ ] ";
                    lead.taken = i + 6;
                } else if (std.mem.startsWith(u8, bytes[i + 2 ..], "[x] ") or
                    std.mem.startsWith(u8, bytes[i + 2 ..], "[X] "))
                {
                    lead.prefix = "- [x] ";
                    lead.taken = i + 6;
                }
            }
        },
        '0'...'9' => {
            var end = i;
            while (end < bytes.len and bytes[end] >= '0' and bytes[end] <= '9') end += 1;
            if (end + 1 >= bytes.len) return false;
            if ((bytes[end] == '.' or bytes[end] == ')') and bytes[end + 1] == ' ') {
                lead.taken = end + 2;
                lead.prefix = std.mem.print(&marker, "{s}. ", .{bytes[i..end]}) catch "- ";
            }
        },
        else => {},
    }

    self.bold = lead.bold;
    self.dim = lead.dim;

    try self.flush();
    try self.plain(self.mask());
    var depth: usize = 0;
    while (depth < quotes) : (depth += 1) try self.raw("> ");
    var column: usize = 0;
    while (column < lead.indent) : (column += 1) try self.raw(" ");
    try self.raw(lead.prefix);
    self.last = if (lead.prefix.len > 0) lead.prefix[lead.prefix.len - 1] else ' ';
    self.drop(lead.taken);
    self.at_line_start = false;
    return true;
}

fn blank(self: *Markdown, quotes: usize) !bool {
    _ = quotes;
    try self.next();
    return true;
}

fn writeRule(self: *Markdown) !void {
    try self.flush();
    try self.plain(0);
    try self.raw(&rule);
    try self.next();
}

fn isRule(line: []const u8) bool {
    const mark = std.mem.trim(u8, line, spaces)[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    var marks: usize = 0;
    for (line) |byte| {
        if (byte == mark) {
            marks += 1;
        } else if (std.mem.findScalar(u8, spaces, byte) == null) {
            return false;
        }
    }
    return marks >= 3;
}

/// Writes the current line as text, through the inline forms, up to its end or a form that cannot
/// be decided yet.
fn body(self: *Markdown) !bool {
    const bytes = self.pending.items;
    var run: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n') {
            try self.emit(bytes[run..i]);
            self.drop(i + 1);
            try self.next();
            return true;
        }
        if (!isMark(bytes[i])) {
            i += 1;
            continue;
        }
        try self.emit(bytes[run..i]);
        switch (try self.markup(bytes, i)) {
            .hold => {
                self.drop(i);
                return false;
            },
            .literal => {
                try self.emit(bytes[i .. i + 1]);
                i += 1;
            },
            .taken => |count| i += count,
        }
        run = i;
    }
    try self.emit(bytes[run..i]);
    self.drop(i);
    return true;
}

fn isMark(byte: u8) bool {
    return switch (byte) {
        '\\', '`', '*', '_', '~', '[', '!' => true,
        else => false,
    };
}

const Markup = union(enum) {
    hold,
    literal,
    taken: usize,
};

/// Writes the inline form `bytes[i..]` starts, or says how it is read.
fn markup(self: *Markdown, bytes: []const u8, i: usize) !Markup {
    const mark = bytes[i];
    if (self.span and mark != '`') return .literal;
    switch (mark) {
        '\\' => {
            if (i + 1 == bytes.len) return if (self.final) .literal else .hold;
            if (std.mem.findScalar(u8, "\\`*_{}[]()#+-.!~|", bytes[i + 1]) == null) return .literal;
            try self.emit(bytes[i + 1 .. i + 2]);
            return .{ .taken = 2 };
        },
        '`' => {
            if (!self.span) self.dim = true else self.dim = false;
            self.span = !self.span;
            return .{ .taken = 1 };
        },
        '*', '_', '~' => {
            var count: usize = 1;
            while (i + count < bytes.len and bytes[i + count] == mark) count += 1;
            if (i + count == bytes.len and !self.final) return .hold;
            const after: u8 = if (i + count == bytes.len) '\n' else bytes[i + count];
            if (mark == '~') {
                if (count < 2) return .literal;
                self.strike = !self.strike;
                return .{ .taken = 2 };
            }
            if (count >= 2 and self.bold) {
                self.bold = false;
                return .{ .taken = 2 };
            }
            if (count < 2 and self.italic) {
                self.italic = false;
                return .{ .taken = 1 };
            }
            if (after == ' ' or after == '\t' or after == '\n') return .literal;
            if (mark == '_' and isWord(self.last) and isWord(after)) return .literal;
            if (count >= 2) {
                self.bold = true;
                return .{ .taken = 2 };
            }
            self.italic = true;
            return .{ .taken = 1 };
        },
        '[' => return self.link(bytes, i, .link),
        '!' => {
            if (i + 1 == bytes.len) return if (self.final) .literal else .hold;
            if (bytes[i + 1] != '[') return .literal;
            return self.link(bytes, i, .image);
        },
        else => return .literal,
    }
}

const Destination = enum { link, image };

/// Writes `label` as the link to `url`, or the text and its address where the terminal takes no
/// links.
fn link(self: *Markdown, bytes: []const u8, i: usize, kind: Destination) !Markup {
    const open = if (kind == .image) i + 1 else i;
    const close = find(bytes, open + 1, ']') orelse {
        if (find(bytes, open + 1, '\n') != null or self.final) return .literal;
        return .hold;
    };
    if (close + 1 == bytes.len) return if (self.final) .literal else .hold;
    if (bytes[close + 1] != '(') return .literal;
    const end = find(bytes, close + 2, ')') orelse {
        if (find(bytes, close + 2, '\n') != null or self.final) return .literal;
        return .hold;
    };

    const label = bytes[open + 1 .. close];
    const url = bytes[close + 2 .. end];
    if (kind == .image) {
        try self.emit(if (label.len > 0) label else url);
    } else if (self.writer.linkOpen().len == 0) {
        try self.emit(label);
        try self.emit(" (");
        try self.emit(url);
        try self.emit(")");
    } else {
        try self.flush();
        try self.raw(self.writer.linkOpen());
        try self.raw(url);
        try self.raw(self.writer.linkClose());
        try self.emit(label);
        try self.raw(self.writer.linkOpen());
        try self.raw(self.writer.linkClose());
    }
    return .{ .taken = end - i + 1 };
}

/// Writes the body of a fenced code block, a line at a time, and ends it at the fence that closes
/// it.
fn code(self: *Markdown) !bool {
    const bytes = self.pending.items;
    if (self.at_line_start) {
        var i: usize = 0;
        while (i < bytes.len and bytes[i] == ' ') i += 1;
        if (i == bytes.len) return false;
        if (bytes[i] == self.close_fence) {
            var count: usize = 0;
            while (i + count < bytes.len and bytes[i + count] == self.close_fence) count += 1;
            if (i + count == bytes.len and !self.final) return false;
            if (count >= 3) {
                if (find(bytes, i, '\n')) |end| {
                    if (std.mem.trim(u8, bytes[i + count .. end], spaces).len == 0) {
                        self.drop(end + 1);
                        self.in_code = false;
                        try self.plain(0);
                        return true;
                    }
                } else if (self.final and std.mem.trim(u8, bytes[i + count ..], spaces).len == 0) {
                    self.drop(bytes.len);
                    self.in_code = false;
                    try self.plain(0);
                    return true;
                } else if (!self.final) return false;
            }
        }
        try self.flush();
        self.dim = true;
        try self.plain(self.mask());
        try self.raw(code_indent);
        self.at_line_start = false;
    }

    const end = find(self.pending.items, 0, '\n');
    try self.emit(self.pending.items[0 .. end orelse self.pending.items.len]);
    self.drop(if (end) |at| at + 1 else self.pending.items.len);
    if (end != null) try self.next();
    return true;
}

const Table = struct {
    lines: std.ArrayList([]const u8) = .empty,
};

/// Keeps a table row for when the table ends: its columns are as wide as the widest cell, which
/// only the whole table tells.
fn row(self: *Markdown) !bool {
    const bytes = self.pending.items;
    const end = find(bytes, 0, '\n') orelse if (self.final) bytes.len else return false;
    if (self.table == null) self.table = .{};
    const line = try self.gpa.dupe(u8, std.mem.trim(u8, bytes[0..end], spaces));
    errdefer self.gpa.free(line);
    try self.table.?.lines.append(self.gpa, line);
    self.drop(@min(end + 1, bytes.len));
    return true;
}

fn dropTable(self: *Markdown) void {
    var table = self.table orelse return;
    for (table.lines.items) |line| self.gpa.free(line);
    table.lines.deinit(self.gpa);
    self.table = null;
}

fn endTable(self: *Markdown) !void {
    var table = self.table orelse return;
    self.table = null;
    defer {
        for (table.lines.items) |line| self.gpa.free(line);
        table.lines.deinit(self.gpa);
    }

    var widths: [max_columns]usize = @splat(0);
    var aligns: [max_columns]u2 = @splat(0);
    var columns: usize = 0;
    var rule_after: ?usize = null;

    for (table.lines.items, 0..) |line, at| {
        var cells: [max_columns][]const u8 = @splat("");
        const count = splitRow(line, &cells);
        if (count > 0 and allSeparators(cells[0..count]) and at > 0) {
            rule_after = at - 1;
            for (cells[0..count], 0..) |text, column| aligns[column] = alignOf(text);
            continue;
        }
        columns = @max(columns, count);
        for (cells[0..count], 0..) |text, column| {
            widths[column] = @max(widths[column], strippedColumns(text));
        }
    }
    if (columns == 0) return;
    // A table with no delimiter row has its first row as the header anyway.
    if (rule_after == null) rule_after = 0;

    var cell: [1024]u8 = undefined;
    for (table.lines.items, 0..) |line, at| {
        if (rule_after != null and at == rule_after.? + 1 and at > 0) continue;
        var cells: [max_columns][]const u8 = @splat("");
        const count = splitRow(line, &cells);
        try self.flush();
        try self.plain(0);
        for (0..columns) |column| {
            if (column > 0) try self.raw("  ");
            const text = if (column < count) cells[column] else "";
            const pad = widths[column] - strippedColumns(text);
            const before = switch (aligns[column]) {
                1 => pad,
                2 => pad / 2,
                else => 0,
            };
            var space: usize = 0;
            while (space < before) : (space += 1) try self.raw(" ");
            try self.raw(stripped(text, &cell));
            if (column + 1 < columns) {
                space = 0;
                while (space < pad - before) : (space += 1) try self.raw(" ");
            }
        }
        try self.next();
        if (rule_after != null and at == rule_after.?) {
            try self.flush();
            for (0..columns) |column| {
                if (column > 0) try self.raw("  ");
                var dash: usize = 0;
                while (dash < widths[column]) : (dash += 1) try self.raw("-");
            }
            try self.next();
        }
    }
}

/// Fills `cells` with the cells of a table row, and returns how many there are.
fn splitRow(line: []const u8, cells: *[max_columns][]const u8) usize {
    const text = std.mem.trim(u8, line, "|");
    var parts = std.mem.splitScalar(u8, text, '|');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == max_columns) break;
        cells[count] = std.mem.trim(u8, part, spaces);
        count += 1;
    }
    return count;
}

fn allSeparators(cells: []const []const u8) bool {
    for (cells) |cell| {
        if (!isSeparator(cell)) return false;
    }
    return true;
}

fn isSeparator(cell: []const u8) bool {
    if (cell.len == 0) return false;
    var dashes: usize = 0;
    for (cell) |byte| {
        if (byte == '-') {
            dashes += 1;
        } else if (byte != ':' and std.mem.findScalar(u8, spaces, byte) == null) {
            return false;
        }
    }
    return dashes > 0;
}

fn alignOf(cell: []const u8) u2 {
    const left = std.mem.startsWith(u8, cell, ":");
    const right = std.mem.endsWith(u8, cell, ":");
    if (left and right) return 2;
    if (right) return 1;
    return 0;
}

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

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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
