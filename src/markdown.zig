//! Parsing markdown: the blocks a reply is made of and the inline forms inside them, decided as the
//! text arrives and written to a `Renderer` as events. Nothing here names a terminal or a page, so
//! one parse can be set both ways.

const std = @import("std");

const spaces = " \t";
pub const max_columns = 32;

pub const Align = enum { none, left, center, right };

pub const Item = struct {
    /// The digits a numbered item is written with, as it wrote them.
    number: ?[]const u8 = null,
    task: ?bool = null,
};

pub const Line = struct {
    quote_depth: usize = 0,
    /// Columns the line set its text in from the left.
    indent: usize = 0,
    item: ?Item = null,
    heading: ?u3 = null,
};

pub const Span = enum { strong, em, code, strike };

pub const Image = struct { url: []const u8, label: []const u8 };

pub const Row = struct { cells: []const []const u8 };

pub const Table = struct {
    aligns: []const Align,
    rows: []const Row,
    /// The rows up to and including this one are the head, where the row of dashes was.
    head: usize,
};

pub const Event = union(enum) {
    /// A line of source ends inside the block before it.
    newline,
    /// A line held nothing: the block before it has ended.
    blank,
    line: Line,
    text: []const u8,
    span_begin: Span,
    span_end: Span,
    /// Its label follows, up to `link_end`.
    link_begin: []const u8,
    link_end,
    image: Image,
    rule,
    /// The payload is the language the fence named.
    code_begin: []const u8,
    code_end,
    table: Table,
};

pub const Renderer = struct {
    context: *anyopaque,
    /// Writes one event; the bytes it carries live only as long as the call.
    emit: *const fn (context: *anyopaque, event: Event) anyerror!void,

    pub fn show(renderer: Renderer, event: Event) !void {
        try renderer.emit(renderer.context, event);
    }
};

pub fn write(gpa: std.mem.Allocator, text: []const u8, renderer: Renderer) !void {
    var parser: Parser = .{ .gpa = gpa, .out = renderer };
    defer parser.deinit();
    try parser.feed(text);
    try parser.finish();
}

/// A parse kept for a reply read in pieces: what arrives is written, and only a prefix or a marker
/// that may still grow is held back.
pub const Stream = struct {
    parser: Parser,

    pub fn open(gpa: std.mem.Allocator, renderer: Renderer) Stream {
        return .{ .parser = .{ .gpa = gpa, .out = renderer } };
    }

    pub fn feed(self: *Stream, text: []const u8) !void {
        try self.parser.feed(text);
    }

    pub fn close(self: *Stream) !void {
        try self.parser.finish();
    }

    pub fn deinit(self: *Stream) void {
        self.parser.deinit();
    }
};

/// The parse itself: the state a line is read in, and the only thing a `Stream` holds.
pub const Parser = struct {
    gpa: std.mem.Allocator,
    out: Renderer,
    /// Read and not yet written: the prefix of a line, a marker that may still grow, or a table.
    pending: std.ArrayList(u8) = .empty,
    at_line_start: bool = true,
    last: u8 = '\n',
    in_code: bool = false,
    close_fence: u8 = '`',
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    span: bool = false,
    final: bool = false,
    table: ?Buffered = null,

    fn feed(self: *Parser, text: []const u8) !void {
        try self.pending.appendSlice(self.gpa, text);
        try self.process();
    }

    /// Hands on what the held bytes hold, as far as they decide, and keeps the rest for the next piece.
    fn process(self: *Parser) !void {
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

    fn deinit(self: *Parser) void {
        self.pending.deinit(self.gpa);
        self.dropTable();
    }

    fn drop(self: *Parser, count: usize) void {
        const items = self.pending.items;
        std.mem.copyForwards(u8, items[0 .. items.len - count], items[count..]);
        self.pending.items.len -= count;
    }

    /// Ends the document: what is held is handed on as it stands, and a table still open is ended.
    fn finish(self: *Parser) !void {
        self.final = true;
        try self.process();
        if (self.table != null) try self.endTable();
        if (self.pending.items.len > 0) {
            try self.out.show(.{ .text = self.pending.items });
            self.drop(self.pending.items.len);
        }
    }

    fn emit(self: *Parser, text: []const u8) !void {
        if (text.len == 0) return;
        try self.out.show(.{ .text = text });
        self.last = text[text.len - 1];
    }

    fn next(self: *Parser, end: Event) !void {
        if (self.bold) try self.out.show(.{ .span_end = .strong });
        if (self.italic) try self.out.show(.{ .span_end = .em });
        if (self.strike) try self.out.show(.{ .span_end = .strike });
        if (self.span) try self.out.show(.{ .span_end = .code });
        self.bold = false;
        self.italic = false;
        self.strike = false;
        self.span = false;
        try self.out.show(end);
        self.at_line_start = true;
        self.last = '\n';
    }

    fn find(bytes: []const u8, from: usize, byte: u8) ?usize {
        return std.mem.findScalarPos(u8, bytes, from, byte);
    }

    /// Reads the start of the line and hands on what it asks for, or returns false when more of it
    /// is needed to tell.
    fn start(self: *Parser) !bool {
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
        const indent = i - indented;

        if (self.table != null) {
            if (bytes[i] != '|') {
                try self.endTable();
                return self.start();
            }
            return self.row();
        }

        if (bytes[i] == '\n') {
            self.drop(i + 1);
            try self.next(.blank);
            return true;
        }

        if (bytes[i] == '`' or bytes[i] == '~') {
            if (i + 3 > bytes.len) return false;
            if (bytes[i + 1] == bytes[i] and bytes[i + 2] == bytes[i]) {
                const end = find(bytes, i, '\n') orelse return false;
                self.close_fence = bytes[i];
                self.in_code = true;
                try self.out.show(.{ .code_begin = std.mem.trim(u8, bytes[i + 3 .. end], spaces) });
                self.drop(end + 1);
                return true;
            }
        }

        if (bytes[i] == '|') return self.row();

        var lead: Line = .{ .quote_depth = quotes, .indent = indent };
        var taken = i;
        switch (bytes[i]) {
            '#' => {
                var end = i;
                while (end < bytes.len and bytes[end] == '#') end += 1;
                if (end == bytes.len) return false;
                if (bytes[end] == ' ' or bytes[end] == '\n') {
                    taken = if (bytes[end] == ' ') end + 1 else end;
                    lead.heading = @intCast(@min(end - i, 6));
                }
            },
            '-', '*', '+', '_' => {
                if (i + 1 == bytes.len) return false;
                if (bytes[i + 1] == bytes[i]) {
                    const end = find(bytes, i, '\n') orelse bytes.len;
                    if (isRule(bytes[i..end])) {
                        self.drop(@min(end + 1, bytes.len));
                        try self.out.show(.rule);
                        try self.next(.newline);
                        return true;
                    }
                    if (end == bytes.len and !self.final) return false;
                }
                if (bytes[i + 1] == ' ' and bytes[i] != '_') {
                    taken = i + 2;
                    lead.item = .{};
                    if (std.mem.startsWith(u8, bytes[i + 2 ..], "[ ] ")) {
                        lead.item = .{ .task = false };
                        taken = i + 6;
                    } else if (std.mem.startsWith(u8, bytes[i + 2 ..], "[x] ") or
                        std.mem.startsWith(u8, bytes[i + 2 ..], "[X] "))
                    {
                        lead.item = .{ .task = true };
                        taken = i + 6;
                    }
                }
            },
            '0'...'9' => {
                var end = i;
                while (end < bytes.len and bytes[end] >= '0' and bytes[end] <= '9') end += 1;
                if (end + 1 >= bytes.len) return false;
                if ((bytes[end] == '.' or bytes[end] == ')') and bytes[end + 1] == ' ') {
                    taken = end + 2;
                    lead.item = .{ .number = bytes[i..end] };
                }
            },
            else => {},
        }

        try self.out.show(.{ .line = lead });
        // A marker, if the line had one, ends on a space: an underscore after it opens emphasis.
        self.last = ' ';
        self.drop(taken);
        self.at_line_start = false;
        return true;
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

    /// Hands on the current line as text, through the inline forms, up to its end or a form that
    /// cannot be decided yet.
    fn body(self: *Parser) !bool {
        const bytes = self.pending.items;
        var run: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == '\n') {
                try self.emit(bytes[run..i]);
                self.drop(i + 1);
                try self.next(.newline);
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

    /// Hands on the inline form `bytes[i..]` starts, or says how it is read.
    fn markup(self: *Parser, bytes: []const u8, i: usize) !Markup {
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
                self.span = !self.span;
                try self.out.show(if (self.span) .{ .span_begin = .code } else .{ .span_end = .code });
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
                    try self.out.show(if (self.strike) .{ .span_begin = .strike } else .{ .span_end = .strike });
                    return .{ .taken = 2 };
                }
                if (count >= 2 and self.bold) {
                    self.bold = false;
                    try self.out.show(.{ .span_end = .strong });
                    return .{ .taken = 2 };
                }
                if (count < 2 and self.italic) {
                    self.italic = false;
                    try self.out.show(.{ .span_end = .em });
                    return .{ .taken = 1 };
                }
                if (after == ' ' or after == '\t' or after == '\n') return .literal;
                if (mark == '_' and isWord(self.last) and isWord(after)) return .literal;
                if (count >= 2) {
                    self.bold = true;
                    try self.out.show(.{ .span_begin = .strong });
                    return .{ .taken = 2 };
                }
                self.italic = true;
                try self.out.show(.{ .span_begin = .em });
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

    /// Hands on `label` as the link to `url`, or as the alt text of an image.
    fn link(self: *Parser, bytes: []const u8, i: usize, kind: Destination) !Markup {
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
            try self.out.show(.{ .image = .{ .url = url, .label = label } });
        } else {
            try self.out.show(.{ .link_begin = url });
            try self.emit(label);
            try self.out.show(.link_end);
        }
        return .{ .taken = end - i + 1 };
    }

    /// Hands on the body of a fenced code block, a line at a time, and ends it at the fence that
    /// closes it.
    fn code(self: *Parser) !bool {
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
                            try self.out.show(.code_end);
                            return true;
                        }
                    } else if (self.final and std.mem.trim(u8, bytes[i + count ..], spaces).len == 0) {
                        self.drop(bytes.len);
                        self.in_code = false;
                        try self.out.show(.code_end);
                        return true;
                    } else if (!self.final) return false;
                }
            }
            self.at_line_start = false;
        }

        const end = find(self.pending.items, 0, '\n');
        const line = self.pending.items[0 .. end orelse self.pending.items.len];
        try self.out.show(.{ .text = line });
        if (line.len > 0) self.last = line[line.len - 1];
        self.drop(if (end) |at| at + 1 else self.pending.items.len);
        if (end != null) try self.next(.newline);
        return true;
    }

    const Buffered = struct {
        lines: std.ArrayList([]const u8) = .empty,
    };

    /// Keeps a table row for when the table ends, which is what tells where the columns are named.
    fn row(self: *Parser) !bool {
        const bytes = self.pending.items;
        const end = find(bytes, 0, '\n') orelse if (self.final) bytes.len else return false;
        if (self.table == null) self.table = .{};
        const line = try self.gpa.dupe(u8, std.mem.trim(u8, bytes[0..end], spaces));
        errdefer self.gpa.free(line);
        try self.table.?.lines.append(self.gpa, line);
        self.drop(@min(end + 1, bytes.len));
        return true;
    }

    fn dropTable(self: *Parser) void {
        var table = self.table orelse return;
        for (table.lines.items) |line| self.gpa.free(line);
        table.lines.deinit(self.gpa);
        self.table = null;
    }

    fn endTable(self: *Parser) !void {
        var buffered = self.table orelse return;
        self.table = null;
        defer {
            for (buffered.lines.items) |line| self.gpa.free(line);
            buffered.lines.deinit(self.gpa);
        }

        var aligns: [max_columns]Align = @splat(.none);
        var columns: usize = 0;
        var dashes: ?usize = null;
        for (buffered.lines.items, 0..) |line, at| {
            var cells: [max_columns][]const u8 = @splat("");
            const count = splitRow(line, &cells);
            if (count > 0 and allSeparators(cells[0..count]) and at > 0) {
                dashes = at;
                for (cells[0..count], 0..) |text, column| aligns[column] = alignOf(text);
                continue;
            }
            columns = @max(columns, count);
        }
        if (columns == 0) return;

        var rows: std.ArrayList(Row) = .empty;
        defer {
            for (rows.items) |held| self.gpa.free(held.cells);
            rows.deinit(self.gpa);
        }
        const column_aligns = try self.gpa.dupe(Align, aligns[0..columns]);
        defer self.gpa.free(column_aligns);
        var head_at: ?usize = null;
        for (buffered.lines.items, 0..) |line, at| {
            if (dashes != null and at == dashes.?) continue;
            var cells: [max_columns][]const u8 = @splat("");
            const count = splitRow(line, &cells);
            try rows.append(self.gpa, .{ .cells = try self.gpa.dupe([]const u8, cells[0..count]) });
            if (dashes) |dashes_at| {
                if (at + 1 == dashes_at) head_at = rows.items.len - 1;
            }
        }
        try self.out.show(.{ .table = .{
            .aligns = column_aligns,
            .rows = rows.items,
            .head = head_at orelse 0,
        } });
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

    fn alignOf(cell: []const u8) Align {
        const left = std.mem.startsWith(u8, cell, ":");
        const right = std.mem.endsWith(u8, cell, ":");
        if (left and right) return .center;
        if (right) return .right;
        if (left) return .left;
        return .none;
    }

    fn isWord(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }
};

/// A renderer that writes each event on a line, so what the parse decides can be read on its own.
const Transcript = struct {
    out: std.Io.Writer.Allocating,

    fn renderer(self: *Transcript) Renderer {
        return .{ .context = self, .emit = show };
    }

    fn show(context: *anyopaque, event: Event) anyerror!void {
        const self: *Transcript = @ptrCast(@alignCast(context));
        return try self.write(event);
    }

    fn write(self: *Transcript, event: Event) !void {
        const out = &self.out.writer;
        switch (event) {
            .newline => try out.writeAll("newline\n"),
            .blank => try out.writeAll("blank\n"),
            .line => |line| {
                try out.writeAll("line");
                if (line.quote_depth > 0) try out.print(" quote={d}", .{line.quote_depth});
                if (line.indent > 0) try out.print(" indent={d}", .{line.indent});
                if (line.item) |item| {
                    if (item.number) |number| try out.print(" number={s}", .{number});
                    if (item.task) |done| try out.print(" task={s}", .{if (done) "x" else " "});
                    if (item.number == null and item.task == null) try out.writeAll(" bullet");
                }
                if (line.heading) |level| try out.print(" heading={d}", .{level});
                try out.writeAll("\n");
            },
            .text => |text| try out.print("text:{s}\n", .{text}),
            .span_begin => |span| try out.print("+{s}\n", .{@tagName(span)}),
            .span_end => |span| try out.print("-{s}\n", .{@tagName(span)}),
            .link_begin => |url| try out.print("link:{s}\n", .{url}),
            .link_end => try out.writeAll("/link\n"),
            .image => |image| try out.print("image:{s}|{s}\n", .{ image.url, image.label }),
            .rule => try out.writeAll("rule\n"),
            .code_begin => |lang| try out.print("code:{s}\n", .{lang}),
            .code_end => try out.writeAll("/code\n"),
            .table => |table| {
                try out.print("table head={d} aligns=", .{table.head});
                for (table.aligns, 0..) |column_align, column| {
                    if (column > 0) try out.writeAll(",");
                    try out.writeAll(@tagName(column_align));
                }
                try out.writeAll("\n");
                for (table.rows) |row| {
                    try out.writeAll("row:");
                    for (row.cells, 0..) |cell, column| {
                        if (column > 0) try out.writeAll(",");
                        try out.writeAll(cell);
                    }
                    try out.writeAll("\n");
                }
            },
        }
    }
};

fn expectEvents(expected: []const u8, text: []const u8) !void {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{ .out = .init(gpa) };
    defer transcript.out.deinit();
    try write(gpa, text, transcript.renderer());
    try std.testing.expectEqualStrings(expected, transcript.out.written());
}

test "a line is read as the blocks it is in, not as the columns it is set in" {
    try expectEvents(
        "line heading=1\ntext:Title\nnewline\nline\ntext:the body\nnewline\n",
        "# Title\nthe body\n",
    );
    try expectEvents("line quote=1 indent=2 bullet\ntext:one\nnewline\n", ">   - one\n");
    try expectEvents("line indent=2\ntext:set in\nnewline\n", "  set in\n");
}

test "a blank line ends the block before it, and a wrapped one does not" {
    try expectEvents(
        "line\ntext:one\nnewline\nblank\nline\ntext:two\nnewline\n",
        "one\n\ntwo\n",
    );
    try expectEvents("line\ntext:one\nnewline\nline\ntext:two\nnewline\n", "one\ntwo\n");
}

test "an item is numbered as it was written, and a task keeps its box" {
    try expectEvents(
        "line number=3\ntext:three\nnewline\nline task=x\ntext:done\nnewline\n",
        "3. three\n- [x] done\n",
    );
}

test "a fence names the language it is written in" {
    try expectEvents("code:zig\ntext:let x = 1;\nnewline\n/code\n", "```zig\nlet x = 1;\n```\n");
}

test "an inline form is a span around the text it holds" {
    try expectEvents(
        "line\n+strong\ntext:b\n-strong\ntext: and \n+em\ntext:c\n-em\ntext: \n" ++
            "+code\ntext:d\n-code\ntext: \nlink:u\ntext:l\n/link\ntext: \nimage:v|i\nnewline\n",
        "**b** and *c* `d` [l](u) ![i](v)\n",
    );
}

test "a table says which row is its head, and how each column is set" {
    try expectEvents(
        "table head=0 aligns=none,center\nrow:a,b\nrow:1,2\n",
        "| a | b |\n| --- | :-: |\n| 1 | 2 |\n",
    );
}
