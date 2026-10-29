//! Parsing markdown: the blocks a reply is made of and the inline forms inside them, decided as the
//! text arrives and written to a `Renderer` as events. Nothing here names a terminal or a page, so
//! one parse can be set both ways.

const std = @import("std");

const entities = @import("entities.zig");

const spaces = " \t";
pub const max_columns = 32;
/// The most lists that can be set inside one another.
pub const max_nesting = 16;

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
    heading: ?u3 = null,
};

/// A list a line begins or ends.
pub const List = struct {
    /// Whether its items are numbered.
    ordered: bool = false,
    /// The digits its first item is written with, when it is numbered.
    number: ?[]const u8 = null,
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
    paragraph_begin,
    paragraph_end,
    quote_begin,
    quote_end,
    list_begin: List,
    list_end,
    item_begin: Item,
    item_end,
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

/// A parse kept for a reply read in pieces: what arrives is written, and only a prefix, a marker
/// that may still grow, or a mark whose partner has not arrived is held back.
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
    final: bool = false,
    table: ?Buffered = null,
    quotes: usize = 0,
    nests: [max_nesting]Nest = @splat(.{}),
    depth: usize = 0,
    /// Where a link's label and address are decoded into: a reference is not as long as its bytes.
    scratch: std.ArrayList(u8) = .empty,
    paragraph: bool = false,
    after_blank: bool = false,

    /// A list that is open, and where a list inside it would be set.
    const Nest = struct {
        /// Columns the item's own marker is set in from the left.
        indent: usize = 0,
        /// Columns where its content starts, so a list inside it is set further in.
        content_column: usize = 0,
        ordered: bool = false,
        /// Whether an item of this list is open, which a list inside it does not close.
        item: bool = false,
    };

    const Kind = enum { text, heading, item };

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
        self.scratch.deinit(self.gpa);
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
        if (self.in_code) {
            self.in_code = false;
            try self.out.show(.code_end);
        }
        try self.closeBlock();
        try self.openQuotes(0);
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
        self.bold = false;
        self.italic = false;
        self.strike = false;
        try self.out.show(end);
        self.at_line_start = true;
        self.last = '\n';
    }

    fn find(bytes: []const u8, from: usize, byte: u8) ?usize {
        return std.mem.findScalarPos(u8, bytes, from, byte);
    }

    fn beginParagraph(self: *Parser) !void {
        if (self.paragraph) return;
        self.paragraph = true;
        try self.out.show(.paragraph_begin);
    }

    fn endParagraph(self: *Parser) !void {
        if (!self.paragraph) return;
        self.paragraph = false;
        try self.out.show(.paragraph_end);
    }

    fn beginItem(self: *Parser, item: Item) !void {
        self.nests[self.depth - 1].item = true;
        try self.out.show(.{ .item_begin = item });
        try self.beginParagraph();
    }

    fn closeItem(self: *Parser) !void {
        if (self.depth == 0 or !self.nests[self.depth - 1].item) return;
        try self.endParagraph();
        self.nests[self.depth - 1].item = false;
        try self.out.show(.item_end);
    }

    fn closeLists(self: *Parser) !void {
        while (self.depth > 0) {
            try self.closeItem();
            self.depth -= 1;
            try self.out.show(.list_end);
        }
    }

    /// Closes what a line of its own ends: the list it is not in, and the paragraph before it.
    fn closeBlock(self: *Parser) !void {
        try self.closeLists();
        try self.endParagraph();
    }

    /// Opens the list a line's marker begins, and everything the line closes on the way.
    fn openItem(self: *Parser, indent: usize, width: usize, item: Item) !void {
        const ordered = item.number != null;
        while (self.depth > 0 and indent < self.nests[self.depth - 1].indent) {
            try self.closeItem();
            self.depth -= 1;
            try self.out.show(.list_end);
        }
        if (self.depth == 0) return self.openList(indent, width, item);

        const top = self.nests[self.depth - 1];
        if (indent >= top.content_column) {
            // Set inside the item that is open, so that item is not the one this ends.
            try self.endParagraph();
            return self.openList(indent, width, item);
        }
        if (top.ordered != ordered) {
            // Another mark is another list, whatever column it is set in.
            try self.closeItem();
            self.depth -= 1;
            try self.out.show(.list_end);
            return self.openList(indent, width, item);
        }
        try self.closeItem();
        try self.beginItem(item);
    }

    fn openList(self: *Parser, indent: usize, width: usize, item: Item) !void {
        if (self.depth == max_nesting) {
            try self.closeItem();
            return self.beginItem(item);
        }
        self.nests[self.depth] = .{
            .indent = indent,
            .content_column = indent + width,
            .ordered = item.number != null,
        };
        self.depth += 1;
        try self.out.show(.{ .list_begin = .{ .ordered = item.number != null, .number = item.number } });
        try self.beginItem(item);
    }

    /// Opens the quotes the line is inside and closes the ones it is not, which are its blocks too.
    fn openQuotes(self: *Parser, depth: usize) !void {
        if (depth == self.quotes) return;
        try self.closeBlock();
        while (self.quotes > depth) : (self.quotes -= 1) try self.out.show(.quote_end);
        while (self.quotes < depth) : (self.quotes += 1) try self.out.show(.quote_begin);
    }

    fn openText(self: *Parser) !void {
        if (self.after_blank) try self.closeLists();
        try self.beginParagraph();
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

        try self.openQuotes(quotes);

        if (self.table != null) {
            if (bytes[i] != '|') {
                try self.endTable();
                return self.start();
            }
            return self.row();
        }

        if (bytes[i] == '\n') {
            self.drop(i + 1);
            try self.endParagraph();
            self.after_blank = true;
            try self.next(.blank);
            return true;
        }

        if (bytes[i] == '`' or bytes[i] == '~') {
            if (i + 3 > bytes.len) return false;
            if (bytes[i + 1] == bytes[i] and bytes[i + 2] == bytes[i]) {
                const end = find(bytes, i, '\n') orelse return false;
                self.close_fence = bytes[i];
                self.in_code = true;
                try self.closeBlock();
                self.after_blank = false;
                try self.out.show(.{ .code_begin = std.mem.trim(u8, bytes[i + 3 .. end], spaces) });
                self.drop(end + 1);
                return true;
            }
        }

        if (bytes[i] == '|') {
            try self.closeBlock();
            self.after_blank = false;
            return self.row();
        }

        var lead: Line = .{ .quote_depth = quotes, .indent = indent };
        var taken = i;
        var kind: Kind = .text;
        var item: Item = .{};
        switch (bytes[i]) {
            '#' => {
                var end = i;
                while (end < bytes.len and bytes[end] == '#') end += 1;
                if (end == bytes.len) return false;
                if (end - i <= 6 and (bytes[end] == ' ' or bytes[end] == '\n')) {
                    taken = if (bytes[end] == ' ') end + 1 else end;
                    lead.heading = @intCast(end - i);
                    kind = .heading;
                }
            },
            '-', '*', '+', '_' => {
                if (i + 1 == bytes.len) return false;
                if (bytes[i + 1] == bytes[i]) {
                    const end = find(bytes, i, '\n') orelse bytes.len;
                    if (isRule(bytes[i..end])) {
                        self.drop(@min(end + 1, bytes.len));
                        try self.closeBlock();
                        self.after_blank = false;
                        try self.out.show(.rule);
                        try self.next(.newline);
                        return true;
                    }
                    if (end == bytes.len and !self.final) return false;
                }
                if (bytes[i + 1] == ' ' and bytes[i] != '_') {
                    taken = i + 2;
                    kind = .item;
                    if (std.mem.startsWith(u8, bytes[i + 2 ..], "[ ] ")) {
                        item = .{ .task = false };
                        taken = i + 6;
                    } else if (std.mem.startsWith(u8, bytes[i + 2 ..], "[x] ") or
                        std.mem.startsWith(u8, bytes[i + 2 ..], "[X] "))
                    {
                        item = .{ .task = true };
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
                    kind = .item;
                    item = .{ .number = bytes[i..end] };
                }
            },
            else => {},
        }

        switch (kind) {
            .item => try self.openItem(indent, taken - i, item),
            .heading => try self.closeBlock(),
            .text => try self.openText(),
        }
        self.after_blank = false;

        try self.out.show(.{ .line = lead });
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

    /// Hands on the line's text, through the inline forms, up to its end or a form not yet decided.
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
            '\\', '`', '*', '_', '~', '[', '!', '&' => true,
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
        switch (mark) {
            '\\' => {
                if (i + 1 == bytes.len) return if (self.final) .literal else .hold;
                if (std.mem.findScalar(u8, "\\`*_{}[]()#+-.!~|&", bytes[i + 1]) == null) return .literal;
                try self.emit(bytes[i + 1 .. i + 2]);
                return .{ .taken = 2 };
            },
            '`' => {
                var run: usize = 1;
                while (i + run < bytes.len and bytes[i + run] == '`') run += 1;
                if (i + run == bytes.len and !self.final) return .hold;
                const end = closingRun(bytes, i + run, run) orelse {
                    // Until the line ends, the run that closes it may still arrive.
                    if (self.final or find(bytes, i + run, '\n') != null) return .literal;
                    return .hold;
                };
                // A span that begins and ends with a space is written without the outer one.
                var text = bytes[i + run .. end];
                if (text.len > 2 and text[0] == ' ' and text[text.len - 1] == ' ' and
                    std.mem.trim(u8, text, " ").len > 0)
                {
                    text = text[1 .. text.len - 1];
                }
                try self.out.show(.{ .span_begin = .code });
                try self.emit(text);
                try self.out.show(.{ .span_end = .code });
                return .{ .taken = end + run - i };
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
                // A mark with nothing to close it is a character of the text.
                const closer = closingMark(bytes, i + count, mark, if (count >= 2) 2 else 1);
                if (closer != .found) {
                    if (closer == .unknown and !self.final) return .hold;
                    return .literal;
                }
                if (count >= 2) {
                    self.bold = true;
                    try self.out.show(.{ .span_begin = .strong });
                    return .{ .taken = 2 };
                }
                self.italic = true;
                try self.out.show(.{ .span_begin = .em });
                return .{ .taken = 1 };
            },
            '&' => switch (entities.lookup(bytes[i..])) {
                .named => |reference| {
                    try self.emit(reference.text);
                    return .{ .taken = reference.len };
                },
                .numeric => |number| {
                    var buffer: [4]u8 = undefined;
                    try self.emit(entities.encode(number.codepoint, &buffer));
                    return .{ .taken = number.len };
                },
                // A reference that never completed is the text it was written as.
                .none, .incomplete => return if (self.final) .literal else .hold,
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

    const Closing = enum { found, absent, unknown };

    /// Whether a run of `mark` that could close a span opened by `count` of them comes later on the line.
    fn closingMark(bytes: []const u8, from: usize, mark: u8, count: usize) Closing {
        var i = from;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') return .absent;
            if (bytes[i] != mark) continue;
            var run: usize = 1;
            while (i + run < bytes.len and bytes[i + run] == mark) run += 1;
            if (run >= count) return .found;
            i += run - 1;
        }
        return .unknown;
    }

    /// Where the run of exactly `run` backticks that closes a code span starts, within the line.
    fn closingRun(bytes: []const u8, from: usize, run: usize) ?usize {
        var i = from;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') return null;
            if (bytes[i] != '`') continue;
            var count: usize = 1;
            while (i + count < bytes.len and bytes[i + count] == '`') count += 1;
            if (count == run) return i;
            i += count - 1;
        }
        return null;
    }

    /// The `)` that closes a destination, which may hold parentheses of its own.
    fn destinationEnd(bytes: []const u8, from: usize) ?usize {
        var depth: usize = 1;
        var i = from;
        while (i < bytes.len) : (i += 1) {
            switch (bytes[i]) {
                '\n' => return null,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    /// Hands on `label` as the link to `url`, or as the alt text of an image.
    fn link(self: *Parser, bytes: []const u8, i: usize, kind: Destination) !Markup {
        const open = if (kind == .image) i + 1 else i;
        const close = find(bytes, open + 1, ']') orelse {
            if (find(bytes, open + 1, '\n') != null or self.final) return .literal;
            return .hold;
        };
        if (close + 1 == bytes.len) return if (self.final) .literal else .hold;
        if (bytes[close + 1] != '(') return .literal;
        const end = destinationEnd(bytes, close + 2) orelse {
            if (find(bytes, close + 2, '\n') != null or self.final) return .literal;
            return .hold;
        };

        const address = try self.decode(bytes[open + 1 .. close], bytes[close + 2 .. end]);
        if (kind == .image) {
            try self.out.show(.{ .image = .{ .url = address.url, .label = address.label } });
        } else {
            try self.out.show(.{ .link_begin = address.url });
            try self.emit(address.label);
            try self.out.show(.link_end);
        }
        return .{ .taken = end - i + 1 };
    }

    const Address = struct { label: []const u8, url: []const u8 };

    /// A link's label and address as their references stand for them, in one buffer so both stay whole.
    fn decode(self: *Parser, label: []const u8, url: []const u8) !Address {
        if (std.mem.findScalar(u8, label, '&') == null and std.mem.findScalar(u8, url, '&') == null) {
            return .{ .label = label, .url = url };
        }
        self.scratch.clearRetainingCapacity();
        try self.decodeInto(label);
        const split = self.scratch.items.len;
        try self.decodeInto(url);
        return .{ .label = self.scratch.items[0..split], .url = self.scratch.items[split..] };
    }

    fn decodeInto(self: *Parser, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '&') {
                switch (entities.lookup(text[i..])) {
                    .named => |reference| {
                        try self.scratch.appendSlice(self.gpa, reference.text);
                        i += reference.len - 1;
                        continue;
                    },
                    .numeric => |number| {
                        var buffer: [4]u8 = undefined;
                        try self.scratch.appendSlice(self.gpa, entities.encode(number.codepoint, &buffer));
                        i += number.len - 1;
                        continue;
                    },
                    // An address is whole here, so a reference that did not finish is text.
                    .none, .incomplete => {},
                }
            }
            try self.scratch.append(self.gpa, text[i]);
        }
    }

    /// Hands on a fenced block's body a line at a time, and ends it at the fence that closes it.
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
                if (line.heading) |level| try out.print(" heading={d}", .{level});
                try out.writeAll("\n");
            },
            .paragraph_begin => try out.writeAll("paragraph_begin\n"),
            .paragraph_end => try out.writeAll("paragraph_end\n"),
            .quote_begin => try out.writeAll("quote_begin\n"),
            .quote_end => try out.writeAll("quote_end\n"),
            .list_begin => |list| try out.print("list_begin ordered={} number={s}\n", .{
                list.ordered,
                list.number orelse "-",
            }),
            .list_end => try out.writeAll("list_end\n"),
            .item_begin => |item| {
                try out.writeAll("item_begin");
                if (item.number) |number| try out.print(" number={s}", .{number});
                if (item.task) |done| try out.print(" task={s}", .{if (done) "x" else " "});
                if (item.number == null and item.task == null) try out.writeAll(" bullet");
                try out.writeAll("\n");
            },
            .item_end => try out.writeAll("item_end\n"),
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
        "line heading=1\ntext:Title\nnewline\nparagraph_begin\nline\ntext:the body\nnewline\n" ++
            "paragraph_end\n",
        "# Title\nthe body\n",
    );
    try expectEvents(
        "quote_begin\nlist_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\n" ++
            "line quote=1 indent=2\ntext:one\nnewline\nparagraph_end\nitem_end\nlist_end\nquote_end\n",
        ">   - one\n",
    );
    try expectEvents("paragraph_begin\nline indent=2\ntext:set in\nnewline\nparagraph_end\n", "  set in\n");
}

test "a blank line ends the block before it, and a wrapped one does not" {
    try expectEvents(
        "paragraph_begin\nline\ntext:one\nnewline\nparagraph_end\nblank\nparagraph_begin\n" ++
            "line\ntext:two\nnewline\nparagraph_end\n",
        "one\n\ntwo\n",
    );
    try expectEvents(
        "paragraph_begin\nline\ntext:one\nnewline\nline\ntext:two\nnewline\nparagraph_end\n",
        "one\ntwo\n",
    );
}

test "a list stays open across its items, and a blank line only makes it loose" {
    try expectEvents(
        "list_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nparagraph_end\nitem_end\nitem_begin bullet\nparagraph_begin\nline\ntext:two\n" ++
            "newline\nparagraph_end\nitem_end\nlist_end\n",
        "- one\n- two\n",
    );
    try expectEvents(
        "list_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nparagraph_end\nblank\nitem_end\nitem_begin bullet\nparagraph_begin\nline\n" ++
            "text:two\nnewline\nparagraph_end\nitem_end\nlist_end\n",
        "- one\n\n- two\n",
    );
    // The blank ends the item, so the line after it is not in the list at all.
    try expectEvents(
        "list_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nparagraph_end\nblank\nitem_end\nlist_end\nparagraph_begin\nline\ntext:after\n" ++
            "newline\nparagraph_end\n",
        "- one\n\nafter\n",
    );
    // A line with no marker of its own carries the item on.
    try expectEvents(
        "list_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nline\ntext:after\nnewline\nparagraph_end\nitem_end\nlist_end\n",
        "- one\nafter\n",
    );
}

test "a list set inside an item is that item's, and another mark is another list" {
    try expectEvents(
        "list_begin ordered=true number=1\nitem_begin number=1\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nparagraph_end\nlist_begin ordered=false number=-\nitem_begin bullet\n" ++
            "paragraph_begin\nline indent=3\ntext:nested\nnewline\nparagraph_end\nitem_end\n" ++
            "list_end\nitem_end\nitem_begin number=2\nparagraph_begin\nline\ntext:two\nnewline\n" ++
            "paragraph_end\nitem_end\nlist_end\n",
        "1. one\n   - nested\n2. two\n",
    );
    try expectEvents(
        "list_begin ordered=false number=-\nitem_begin bullet\nparagraph_begin\nline\ntext:one\n" ++
            "newline\nparagraph_end\nitem_end\nlist_end\nlist_begin ordered=true number=1\n" ++
            "item_begin number=1\nparagraph_begin\nline\ntext:two\nnewline\nparagraph_end\n" ++
            "item_end\nlist_end\n",
        "- one\n1. two\n",
    );
}

test "an item is numbered as it was written, and a task keeps its box" {
    try expectEvents(
        "list_begin ordered=true number=3\nitem_begin number=3\nparagraph_begin\nline\ntext:three\n" ++
            "newline\nparagraph_end\nitem_end\nlist_end\nlist_begin ordered=false number=-\n" ++
            "item_begin task=x\nparagraph_begin\nline\ntext:done\nnewline\nparagraph_end\n" ++
            "item_end\nlist_end\n",
        "3. three\n- [x] done\n",
    );
}

test "a fence names the language it is written in, and ends even when it is not closed" {
    try expectEvents("code:zig\ntext:let x = 1;\nnewline\n/code\n", "```zig\nlet x = 1;\n```\n");
    try expectEvents("code:\ntext:x\nnewline\n/code\n", "```\nx\n");
}

test "an inline form is a span around the text it holds" {
    try expectEvents(
        "paragraph_begin\nline\n+strong\ntext:b\n-strong\ntext: and \n+em\ntext:c\n-em\ntext: \n" ++
            "+code\ntext:d\n-code\ntext: \nlink:u\ntext:l\n/link\ntext: \nimage:v|i\nnewline\n" ++
            "paragraph_end\n",
        "**b** and *c* `d` [l](u) ![i](v)\n",
    );
}

test "a reference is handed on as what it stands for" {
    try expectEvents(
        "paragraph_begin\nline\ntext:a \ntext:&\ntext: b\nnewline\nparagraph_end\n",
        "a &amp; b\n",
    );
    try expectEvents("paragraph_begin\nline\ntext:&\ntext:>\nnewline\nparagraph_end\n", "&amp;&gt;\n");
    try expectEvents("paragraph_begin\nline\ntext:A\nnewline\nparagraph_end\n", "&#65;\n");
    // A reference that never finishes is the text it was written as.
    try expectEvents(
        "paragraph_begin\nline\ntext:&\ntext:amp x\nnewline\nparagraph_end\n",
        "&amp x\n",
    );
}

test "a reference in a link is decoded before the address is read" {
    try expectEvents(
        "paragraph_begin\nline\nlink:javascript:alert(1)\ntext:x\n/link\nnewline\nparagraph_end\n",
        "[x](javascript&colon;alert(1))\n",
    );
    try expectEvents(
        "paragraph_begin\nline\nlink:/docs\ntext:a & b\n/link\nnewline\nparagraph_end\n",
        "[a &amp; b](/docs)\n",
    );
}

test "a reference still arriving is held until the rest of it comes" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{ .out = .init(gpa) };
    defer transcript.out.deinit();

    var stream = Stream.open(gpa, transcript.renderer());
    defer stream.deinit();
    try stream.feed("a &am");
    try std.testing.expectEqualStrings("paragraph_begin\nline\ntext:a \n", transcript.out.written());
    try stream.feed("p; b\n");
    try stream.close();
    try std.testing.expectEqualStrings(
        "paragraph_begin\nline\ntext:a \ntext:&\ntext: b\nnewline\nparagraph_end\n",
        transcript.out.written(),
    );
}

test "a table says which row is its head, and how each column is set" {
    try expectEvents(
        "table head=0 aligns=none,center\nrow:a,b\nrow:1,2\n",
        "| a | b |\n| --- | :-: |\n| 1 | 2 |\n",
    );
}
