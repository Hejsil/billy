//! Rendering markdown for the terminal.
//!
//! A reply and a prompt are written in markdown, and a terminal has no browser to
//! lay it out. The same parser the page uses reads it (`md.zig`), and this module
//! writes the text a terminal shows: headings bold, lists bulleted, code set
//! apart, a link clickable where the terminal takes escape codes. Only the
//! display changes -- what a session stores and the model is sent keep the
//! markdown as it was written.
//!
//! Nothing here measures the terminal. A line is written as it is and left for
//! the terminal to wrap, which is how the terminal's own scrollback already
//! works: billy prints a block once and never redraws it, so a width it read at
//! one moment would be wrong the next. Structure the terminal cannot show is kept
//! in place of colour, so the text still reads as markdown when piped to a file.

const std = @import("std");
const md = @import("md.zig");
const Terminal = @import("Terminal.zig");

/// Deepest a list nests before its indent stops growing, so a malformed document
/// cannot walk `list` off its end.
const max_list_depth = 16;
/// Columns a fenced or indented code block is set in, so it reads apart from the
/// text around it.
const code_indent = "    ";
/// The line a horizontal rule is drawn with.
const rule = "-" ** 40;
/// Most columns a table is read for, so a broken one cannot walk an array off its
/// end.
const max_columns = 32;

/// Writes `text`, read as markdown, as the terminal shows it. `style` decides
/// whether bold, colour and links are written as escape codes or left out, which
/// is what makes a pipe to a file read as plain structured text.
pub fn write(gpa: std.mem.Allocator, text: []const u8, style: Terminal.Style, out: *std.Io.Writer) !void {
    var render = Markdown{ .gpa = gpa, .out = out, .style = style };
    defer render.deinit();
    var parser = Markdown.parser();
    try md.parse(text, &parser, &render);
    // A callback cannot return an error, so a failed write is kept on the
    // renderer and reported here, once md4c has stopped.
    if (render.err) |err| return err;
}

/// Renders one document. It is the `userdata` md4c hands back to every callback,
/// and holds both the writer each piece goes to and the state the text of one
/// piece depends on -- how deep a list is, whether a code block is open, and so
/// on.
const Markdown = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    style: Terminal.Style,
    /// The first failure, kept here because a callback returns a number, not an
    /// error.
    err: ?anyerror = null,

    /// Newlines seen but not yet written. They are held back so a style or colour
    /// code that ends a block is written before the newline that closes it, and
    /// so the last block leaves no trailing newline for the caller's own to add
    /// to. Writing them is what `flush` does, just before the next text.
    pending_newlines: usize = 0,
    /// Whether the next text goes at the start of a line, where the indent is
    /// written. True at the very beginning, so the first block is indented too.
    at_line_start: bool = true,

    quote_depth: usize = 0,
    list_depth: usize = 0,
    list: [max_list_depth]ListFrame = undefined,
    /// Blocks inside a list or a quote, where the blank line between top-level
    /// blocks does not belong.
    container_depth: usize = 0,
    /// Whether anything has been written, so the first block opens without a
    /// blank line in front of it.
    emitted: bool = false,
    /// Whether a blank line is owed before the next top-level block.
    need_blank: bool = false,
    /// Whether the block being written is a heading, which is followed directly
    /// by what it heads rather than by a blank line.
    block_head: bool = false,
    in_code: bool = false,
    in_head: bool = false,

    /// How deep inside an image label this is: the label is the alt text, and it
    /// is gathered rather than written where it stands.
    image_depth: usize = 0,
    image_label: std.ArrayList(u8) = .empty,
    /// The address of the image being read, from its open to its close.
    image_url: []const u8 = "",
    /// The address of the link being written, from its open to its close: md4c
    /// reports it once, but a hyperlink is opened and closed around the text.
    link_url: []const u8 = "",

    /// Whether a table is being read. Its cells are buffered until all of it is
    /// in, so the columns can be aligned.
    table: bool = false,
    rows: std.ArrayList(Row) = .empty,
    row: std.ArrayList([]u8) = .empty,
    cell: std.ArrayList(u8) = .empty,
    aligns: std.ArrayList(md.c.MD_ALIGN) = .empty,

    /// One open list, so an ordered list can keep counting where it left off.
    const ListFrame = struct {
        ordered: bool = false,
        /// The number the next item of an ordered list is.
        next: usize = 1,
    };

    /// A row of a table while it is buffered, waiting for the column widths to be
    /// known: a table cannot be aligned until all of it has been read.
    const Row = struct {
        header: bool = false,
        cells: std.ArrayList([]u8) = .empty,
    };

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

    fn deinit(self: *Markdown) void {
        self.image_label.deinit(self.gpa);
        self.freeTable();
    }

    /// Writes `bytes` on as they are, keeping the failure if there is one and
    /// returning whether the write worked, so a callback can stop the parse.
    fn raw(self: *Markdown, bytes: []const u8) bool {
        if (self.err != null) return false;
        self.out.writeAll(bytes) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    /// Writes the newlines held back, so the next text starts on a line of its
    /// own. A style code written after a block ends is written before this, so it
    /// closes on the block's last line rather than below it.
    fn flush(self: *Markdown) bool {
        var i: usize = 0;
        while (i < self.pending_newlines) : (i += 1) if (!self.raw("\n")) return false;
        if (self.pending_newlines > 0) self.at_line_start = true;
        self.pending_newlines = 0;
        return true;
    }

    /// Ends the line: the newline is held until the next text, so nothing is
    /// written after the very last one.
    fn newline(self: *Markdown) void {
        self.pending_newlines += 1;
        self.at_line_start = true;
    }

    /// Ends the line the block being written is on, when it left one open. A
    /// block whose text already ended with a newline -- a code block, most of
    /// them -- is owed none, which is what keeps a single blank line between
    /// blocks rather than two.
    fn endLine(self: *Markdown) void {
        if (!self.at_line_start) self.newline();
    }

    /// Writes the prefix of a line: a bar for each quote it is inside, two spaces
    /// for each list, and the code indent inside a code block. Only at the start
    /// of a line, so a block writes its own indent once.
    fn writeIndent(self: *Markdown) bool {
        if (!self.at_line_start) return true;
        self.at_line_start = false;
        var i: usize = 0;
        while (i < self.quote_depth) : (i += 1) if (!self.raw("> ")) return false;
        i = 0;
        while (i < self.list_depth) : (i += 1) if (!self.raw("  ")) return false;
        if (self.in_code and !self.raw(code_indent)) return false;
        return true;
    }

    /// Writes `text` a line at a time, flushing the held newlines and writing the
    /// indent before each line's first character.
    fn put(self: *Markdown, text: []const u8) bool {
        var rest = text;
        while (rest.len > 0) {
            const cut = std.mem.indexOfScalar(u8, rest, '\n');
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

    /// Writes the blank line owed between top-level blocks, on top of the newline
    /// that ended the block before it.
    fn blank(self: *Markdown) bool {
        self.newline();
        return true;
    }

    /// Opens a block, writing the blank line owed before it. Only a top-level
    /// block takes one: inside a list or a quote the blocks run together.
    fn beginBlock(self: *Markdown, heading: bool) bool {
        if (self.container_depth != 0) return true;
        if (self.emitted and self.need_blank and !self.blank()) return false;
        self.emitted = true;
        self.block_head = heading;
        return true;
    }

    /// Closes a block. A heading is owed no blank line, so what it heads follows
    /// it directly.
    fn endBlock(self: *Markdown) void {
        if (self.container_depth != 0) return;
        self.need_blank = !self.block_head;
    }

    // ---- blocks ----

    fn openBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
        switch (block_type) {
            md.c.MD_BLOCK_DOC => {},
            md.c.MD_BLOCK_QUOTE => {
                if (!self.beginBlock(false)) return false;
                self.quote_depth += 1;
                self.container_depth += 1;
                if (!self.raw(self.style.on("2"))) return false;
            },
            md.c.MD_BLOCK_UL => return self.openList(false, 1),
            md.c.MD_BLOCK_OL => {
                const list: *const md.c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail.?));
                return self.openList(true, list.start);
            },
            md.c.MD_BLOCK_LI => return self.openItem(@ptrCast(@alignCast(detail.?))),
            md.c.MD_BLOCK_HR => {
                if (!self.beginBlock(false)) return false;
                if (!self.put(rule)) return false;
            },
            md.c.MD_BLOCK_H => {
                if (!self.beginBlock(true)) return false;
                // A heading is its text in bold; the `#` is not shown.
                if (!self.raw(self.style.on("1"))) return false;
            },
            md.c.MD_BLOCK_CODE => {
                if (!self.beginBlock(false)) return false;
                self.in_code = true;
                if (!self.raw(self.style.on("2"))) return false;
            },
            md.c.MD_BLOCK_P => {
                if (!self.beginBlock(false)) return false;
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
            // Raw HTML never reaches here (`md.flags` turns it off), and a block
            // of an extension billy does not read is ignored.
            else => {},
        }
        return true;
    }

    fn closeBlock(self: *Markdown, block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque) bool {
        _ = detail;
        switch (block_type) {
            md.c.MD_BLOCK_DOC => {},
            md.c.MD_BLOCK_QUOTE => {
                if (!self.raw(self.style.off())) return false;
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
                if (!self.raw(self.style.off())) return false;
                self.endLine();
                self.endBlock();
            },
            md.c.MD_BLOCK_CODE => {
                if (!self.raw(self.style.off())) return false;
                self.in_code = false;
                self.endLine();
                self.endBlock();
            },
            md.c.MD_BLOCK_P => {
                // A paragraph keeps its own lines; the block ends with one more,
                // which the held newlines turn into the blank line before what
                // follows.
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

    /// Opens a list: remembers whether it is ordered and where its numbering
    /// starts, so an item can write its own marker.
    fn openList(self: *Markdown, ordered: bool, start: usize) bool {
        if (!self.beginBlock(false)) return false;
        if (self.list_depth >= max_list_depth) return self.fail();
        self.list[self.list_depth] = .{ .ordered = ordered, .next = start };
        self.list_depth += 1;
        self.container_depth += 1;
        return true;
    }

    /// Opens a list item: writes its marker and lets what follows write on the
    /// same line, indented to where the item's text begins.
    fn openItem(self: *Markdown, detail: *const md.c.MD_BLOCK_LI_DETAIL) bool {
        // Start on a line of the item's own, ending the one before it if it left
        // one open: a tight item has no paragraph to write the closing newline.
        self.endLine();
        if (!self.flush()) return false;
        // The item's own marker is one level in from the list's indent.
        self.at_line_start = true;
        var i: usize = 0;
        while (i < self.quote_depth) : (i += 1) if (!self.raw("> ")) return false;
        i = 0;
        while (i + 1 < self.list_depth) : (i += 1) if (!self.raw("  ")) return false;
        self.at_line_start = false;

        const frame = &self.list[self.list_depth - 1];
        var buffer: [24]u8 = undefined;
        const marker: []const u8 = if (frame.ordered) blk: {
            const written = std.fmt.bufPrint(&buffer, "{d}. ", .{frame.next}) catch return self.fail();
            frame.next += 1;
            break :blk written;
        } else if (detail.is_task != 0) blk: {
            break :blk if (detail.task_mark == 'x' or detail.task_mark == 'X') "- [x] " else "- [ ] ";
        } else "- ";
        if (!self.raw(marker)) return false;
        self.container_depth += 1;
        return true;
    }

    fn openTable(self: *Markdown) bool {
        if (!self.beginBlock(false)) return false;
        self.table = true;
        self.rows = .empty;
        self.row = .empty;
        self.cell = .empty;
        self.aligns = .empty;
        return true;
    }

    /// Writes the buffered table, aligned, and frees what was held for it. The
    /// header is underlined with a rule, so it reads as a header without a border.
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
                widths[column] = @max(widths[column], cell.len);
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

    /// Writes the line under a table's header: dashes the width of each column.
    fn writeRule(self: *Markdown, widths: []const usize, columns: usize) bool {
        if (!self.flush()) return false;
        self.at_line_start = true;
        if (!self.writeIndent()) return false;
        for (0..columns) |column| {
            if (column > 0 and !self.raw("  ")) return false;
            var i: usize = 0;
            while (i < widths[column]) : (i += 1) if (!self.raw("-")) return false;
        }
        self.endLine();
        return true;
    }

    fn writeCell(self: *Markdown, text: []const u8, width: usize, alignment: md.c.MD_ALIGN, pad_right: bool) bool {
        const pad = width - text.len;
        const before = switch (alignment) {
            md.c.MD_ALIGN_RIGHT => pad,
            md.c.MD_ALIGN_CENTER => pad / 2,
            else => 0,
        };
        const after = if (pad_right) pad else before;
        var i: usize = 0;
        while (i < before) : (i += 1) if (!self.raw(" ")) return false;
        if (!self.raw(text)) return false;
        i = before;
        while (i < after) : (i += 1) if (!self.raw(" ")) return false;
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

    // ---- spans ----

    fn openSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        if (span_type == md.c.MD_SPAN_IMG) {
            const img: *const md.c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail.?));
            self.image_url = attribute(img.src);
            self.image_depth += 1;
            return true;
        }
        // Inside a table cell only the text is kept: a code of colour would make
        // the column widths wrong.
        if (self.table) return true;
        return switch (span_type) {
            md.c.MD_SPAN_EM => self.raw(self.style.on("3")),
            md.c.MD_SPAN_STRONG => self.raw(self.style.on("1")),
            md.c.MD_SPAN_CODE => self.raw(self.style.on("2")),
            md.c.MD_SPAN_DEL => self.raw(self.style.on("9")),
            md.c.MD_SPAN_A => self.openA(@ptrCast(@alignCast(detail.?))),
            // An image is its alt text, written when the label has been read.
            else => true,
        };
    }

    fn closeSpan(self: *Markdown, span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque) bool {
        _ = detail;
        if (span_type == md.c.MD_SPAN_IMG) return self.closeImg();
        if (self.table) return true;
        return switch (span_type) {
            md.c.MD_SPAN_EM, md.c.MD_SPAN_STRONG, md.c.MD_SPAN_CODE, md.c.MD_SPAN_DEL => self.raw(self.style.off()),
            md.c.MD_SPAN_A => self.closeA(),
            else => true,
        };
    }

    /// Opens a link: a terminal that takes escape codes shows it as a hyperlink
    /// over its own text, with the address kept for the close. In plain text the
    /// address is written after the text instead (see `closeA`).
    fn openA(self: *Markdown, detail: *const md.c.MD_SPAN_A_DETAIL) bool {
        self.link_url = attribute(detail.href);
        if (self.style != .ansi) return true;
        if (!self.raw("\x1b]8;;") or !self.raw(self.link_url) or !self.raw("\x1b\\")) return false;
        return true;
    }

    fn closeA(self: *Markdown) bool {
        if (self.style == .ansi) {
            if (!self.raw("\x1b]8;;\x1b\\")) return false;
        } else if (self.link_url.len > 0) {
            // With no escape codes the address has to be visible, or the link is
            // lost; it follows the text the way a printed markdown note would.
            if (!self.put(" (")) return false;
            if (!self.put(self.link_url)) return false;
            if (!self.put(")")) return false;
        }
        self.link_url = "";
        return true;
    }

    /// Writes an image as its alt text, taken from the label just read, or its
    /// address when there is none. In a terminal that takes escape codes the text
    /// opens the image's address.
    fn closeImg(self: *Markdown) bool {
        self.image_depth -= 1;
        if (self.image_depth > 0) return true;

        // The label was gathered as text; an image with no label is shown by its
        // address, so something is written either way.
        const label = self.image_label.items;
        const has_label = std.mem.trim(u8, label, " \t\r\n").len > 0;
        const shown: []const u8 = if (has_label) label else self.image_url;
        const opens = self.style == .ansi and self.image_url.len > 0;
        if (opens and !self.raw("\x1b]8;;")) return false;
        if (opens and !self.raw(self.image_url)) return false;
        if (opens and !self.raw("\x1b\\")) return false;
        if (!self.put(shown)) return false;
        if (opens and !self.raw("\x1b]8;;\x1b\\")) return false;
        self.image_label.clearRetainingCapacity();
        self.image_url = "";
        return true;
    }

    // ---- text ----

    fn writeRun(self: *Markdown, text_type: md.c.MD_TEXTTYPE, text: []const u8) bool {
        // Inside an image label every run is the alt text, gathered for the close.
        if (self.image_depth > 0) {
            self.image_label.appendSlice(self.gpa, text) catch return self.fail();
            return true;
        }
        return switch (text_type) {
            // A NULL is replaced the way CommonMark says, rather than written.
            md.c.MD_TEXT_NULLCHAR => self.emit("\u{FFFD}"),
            // A break of any kind is a newline: nothing here is re-wrapped, so
            // the text is shown where it was written and left to the terminal.
            md.c.MD_TEXT_BR, md.c.MD_TEXT_SOFTBR => self.emit("\n"),
            md.c.MD_TEXT_ENTITY => self.writeEntity(text),
            // A code block's text is written as it is: the newline that ends its
            // last line is held like any other, so the colour code that closes
            // the block lands on that line rather than below it.
            else => self.emit(text),
        };
    }

    /// Writes a decoded entity, so `&amp;` reads back as `&`.
    fn writeEntity(self: *Markdown, text: []const u8) bool {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.gpa);
        md.decodeEntity(self.gpa, text, &value) catch return self.fail();
        return self.emit(value.items);
    }

    /// Hands `bytes` to the table cell being read, or writes them where they
    /// stand.
    fn emit(self: *Markdown, bytes: []const u8) bool {
        if (self.table) {
            self.cell.appendSlice(self.gpa, bytes) catch return self.fail();
            return true;
        }
        return self.put(bytes);
    }

    /// Stops the parse by returning a failure; the error itself is already on
    /// `err`.
    fn fail(self: *Markdown) bool {
        if (self.err == null) self.err = error.OutOfMemory;
        return false;
    }

    /// The bytes of an md4c attribute, which is empty when it has no text.
    fn attribute(value: md.c.MD_ATTRIBUTE) []const u8 {
        if (value.text == null or value.size == 0) return "";
        return value.text[0..value.size];
    }

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
};

/// Renders `text` and compares it to `expected`, so a test reads as the text a
/// terminal shows rather than as the buffer around it.
fn expectRendered(expected: []const u8, text: []const u8, style: Terminal.Style) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, text, style, &out.writer);
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
    // Its own line breaks are kept, not re-wrapped.
    try expectPlain("one\ntwo", "one\ntwo");
}

test "inline markdown is set in the style of the terminal" {
    // Plain text keeps the text and drops the style, so a pipe to a file reads.
    try expectPlain("bold and italic and code", "**bold** and *italic* and `code`");
    // A terminal that takes escape codes shows each as it is meant.
    try expectAnsi(
        "\x1b[1mbold\x1b[0m and \x1b[3mitalic\x1b[0m and \x1b[2mcode\x1b[0m",
        "**bold** and *italic* and `code`",
    );
    // Strike-through, which the model reaches for.
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
    // A list that starts at another number keeps it.
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
    try expectPlain("-" ** 40, "---");
}

test "a link is clickable where the terminal takes escape codes, else its address is shown" {
    // Plain text has no escape codes, so the address has to be written out.
    try expectPlain("the spec (https://example.com)", "[the spec](https://example.com)");
    // A terminal that takes escape codes gets a hyperlink over the text alone.
    try expectAnsi(
        "\x1b]8;;https://example.com\x1b\\the spec\x1b]8;;\x1b\\",
        "[the spec](https://example.com)",
    );
}

test "an image is shown as its alt text" {
    try expectPlain("a cat", "![a cat](cat.png)");
    // With no alt text the address stands in, so something is shown.
    try expectPlain("cat.png", "![](cat.png)");
}

test "a table is aligned in columns" {
    try expectPlain(
        "name  age\n----  ---\nana   3\nbo    12",
        "| name | age |\n| --- | --- |\n| ana | 3 |\n| bo | 12 |",
    );
}

test "a block is set off from the one before it" {
    try expectPlain("one\n\ntwo", "one\n\ntwo");
    // A heading is followed directly by what it heads, with no blank line.
    try expectPlain("Title\nthe body", "# Title\nthe body");
}
