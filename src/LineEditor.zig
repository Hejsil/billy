//! Interactive line editor for the user prompt.

const std = @import("std");

const settings = @import("Terminal/settings.zig");
const terminal_width = @import("Terminal/width.zig");

const LineEditor = @This();

const Key = union(enum) {
    char: [4]u8,
    enter,
    newline,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    up,
    down,
    interrupt,
    eof,
    kill_to_start,
    kill_to_end,
    kill_word,
    clear,
    none,
};

const max_indent = 64;
const no_wrap = std.math.maxInt(usize) / 4;

io: std.Io,
out: *std.Io.Writer,
gpa: std.mem.Allocator,
strings: std.ArrayList(u8) = .empty,
history: std.ArrayList(usize) = .empty,
in_buf: [256]u8 = undefined,
in_pos: usize = 0,
in_len: usize = 0,
last_rows: usize = 0,
last_cursor_row: usize = 0,
goal_col: ?usize = null,
width: usize = 0,
painted_width: usize = 0,
pasting: bool = false,
paste_cr: bool = false,
quiet: bool = false,

/// `gpa` backs the line pool and the history the editor keeps; both are the editor's own and are
/// freed by `deinit`.
pub fn init(io: std.Io, out: *std.Io.Writer, gpa: std.mem.Allocator) LineEditor {
    return .{ .io = io, .out = out, .gpa = gpa };
}

/// Frees the pool and the history the editor holds.
pub fn deinit(ed: *LineEditor) void {
    ed.strings.deinit(ed.gpa);
    ed.history.deinit(ed.gpa);
}

fn historyLine(ed: *const LineEditor, index: usize) []const u8 {
    return std.mem.sliceTo(ed.strings.items[ed.history.items[index]..], 0);
}

/// Reads one line for the caller to act on, above the run's `header` and behind `prompt`: the
/// header is shown on its own line while the line is being edited.
pub fn readLine(ed: *LineEditor, header: []const u8, prompt: []const u8) !?[]const u8 {
    ed.quiet = false;
    return try ed.read(header, prompt);
}

/// Reads a secret behind `prompt`: what is typed is not shown, so a key is not left on the screen
/// or in the scrollback.
pub fn readSecret(ed: *LineEditor, prompt: []const u8) !?[]const u8 {
    ed.quiet = true;
    return try ed.read("", prompt);
}

fn read(ed: *LineEditor, header: []const u8, prompt: []const u8) !?[]const u8 {
    const interactive = try std.Io.File.stdin().isTty(ed.io);
    // The width is only wanted to fold a line being edited, which cannot happen without a terminal.
    ed.width = if (interactive) terminal_width.terminal(ed.io) else 0;
    if (interactive) {
        if (header.len > 0) {
            try ed.out.writeAll(header);
            try ed.out.writeAll("\n");
        }
        try ed.out.writeAll(prompt);
    }
    try ed.out.flush();

    if (!interactive) return ed.readLinePiped();

    const saved = try ed.enterRaw();
    // The line is read raw and the terminal given back here rather than from a `defer`: the restore
    // is the same handful of writes either way, and one place that says so runs it after the read
    // on both of the read's paths.
    const line = ed.readKeys(header, prompt);
    try ed.restore(saved);
    return line;
}

fn readKeys(ed: *LineEditor, header: []const u8, prompt: []const u8) !?[]const u8 {
    try ed.out.writeAll("\x1b[?2004h");
    try ed.out.flush();

    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    ed.goal_col = null;
    ed.painted_width = ed.width;
    var content_width = ed.contentWidth(columns(prompt));

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ed.gpa);
    // The line being edited, kept aside while a history walk is on a stored entry, so stepping back
    // to the start returns to it rather than an empty line.
    var draft: std.ArrayList(u8) = .empty;
    defer draft.deinit(ed.gpa);
    var cursor: usize = 0;
    var recalled: ?usize = null;
    var dirty = false;

    while (true) {
        const key = try ed.nextKey();
        // Asked again on every key, since the terminal can be resized while the line is edited.
        ed.width = terminal_width.terminal(ed.io);
        if (ed.width != ed.painted_width) {
            content_width = ed.contentWidth(columns(prompt));
            dirty = true;
        }
        // A run of up/down presses aims for one column; any other key ends it.
        switch (key) {
            .up, .down, .none => {},
            else => ed.goal_col = null,
        }
        switch (key) {
            .none => {},
            .char => |char| {
                const text = std.mem.sliceTo(&char, 0);
                try line.insertSlice(ed.gpa, cursor, text);
                cursor += text.len;
                dirty = true;
            },
            .newline => {
                try line.insert(ed.gpa, cursor, '\n');
                cursor += 1;
                dirty = true;
            },
            .enter => {
                // The whole prompt is erased, and no newline is written: the caller prints the
                // prompt's own block in its place, and that block ends the line.
                if (ed.quiet) {
                    try ed.out.writeAll("\n");
                } else {
                    try ed.endPrompt(header);
                }
                try ed.out.flush();
                return @as(?[]const u8, try ed.submit(line.items));
            },
            .backspace => if (cursor > 0) {
                const start = prevChar(line.items, cursor);
                try line.replaceRange(ed.gpa, start, cursor - start, "");
                cursor = start;
                dirty = true;
            },
            .delete => if (cursor < line.items.len) {
                try line.replaceRange(ed.gpa, cursor, nextChar(line.items, cursor) - cursor, "");
                dirty = true;
            },
            .left => if (cursor > 0) {
                cursor = prevChar(line.items, cursor);
                dirty = true;
            },
            .right => if (cursor < line.items.len) {
                cursor = nextChar(line.items, cursor);
                dirty = true;
            },
            .home => {
                cursor = 0;
                dirty = true;
            },
            .end => {
                cursor = line.items.len;
                dirty = true;
            },
            .kill_to_start => if (cursor > 0) {
                try line.replaceRange(ed.gpa, 0, cursor, "");
                cursor = 0;
                dirty = true;
            },
            .kill_to_end => if (cursor < line.items.len) {
                line.shrinkRetainingCapacity(cursor);
                dirty = true;
            },
            .kill_word => {
                const start = wordStart(line.items, cursor);
                if (start < cursor) {
                    try line.replaceRange(ed.gpa, start, cursor - start, "");
                    cursor = start;
                    dirty = true;
                }
            },
            .clear => {
                try ed.out.writeAll("\x1b[2J\x1b[H");
                ed.last_rows = 0;
                ed.last_cursor_row = 0;
                dirty = true;
            },
            .up => {
                if (moveCursorVertical(&ed.goal_col, line.items, content_width, &cursor, -1)) {
                    dirty = true;
                } else if (try ed.recall(&line, &cursor, &draft, &recalled, -1)) {
                    dirty = true;
                }
            },
            .down => {
                if (moveCursorVertical(&ed.goal_col, line.items, content_width, &cursor, 1)) {
                    dirty = true;
                } else if (try ed.recall(&line, &cursor, &draft, &recalled, 1)) {
                    dirty = true;
                }
            },
            .interrupt => {
                ed.pasting = false;
                ed.paste_cr = false;
                try ed.endPrompt(header);
                try ed.out.writeAll("\x1b[K^C\r\n");
                if (header.len > 0) {
                    try ed.out.writeAll(header);
                    try ed.out.writeAll("\n");
                }
                line.clearRetainingCapacity();
                cursor = 0;
                recalled = null;
                ed.last_rows = 0;
                ed.last_cursor_row = 0;
                dirty = true;
                try ed.out.flush();
            },
            .eof => if (line.items.len == 0) {
                try ed.endPrompt(header);
                try ed.out.writeAll("\r\n");
                try ed.out.flush();
                return null;
            } else if (cursor < line.items.len) {
                try line.replaceRange(ed.gpa, cursor, nextChar(line.items, cursor) - cursor, "");
                dirty = true;
            },
        }
        if (dirty and ed.drained()) {
            try ed.redraw(prompt, content_width, if (ed.quiet) "" else line.items, if (ed.quiet) 0 else cursor);
            dirty = false;
        }
    }
}

fn restore(ed: *LineEditor, saved: std.posix.termios) !void {
    const settings_err = settings.set(std.posix.STDIN_FILENO, saved);

    // Bracketed paste is a property of the terminal rather than of this process, so it is turned
    // back off when the line is done; left on, it would wrap pastes in whatever the user runs next.
    const write_err = ed.out.writeAll("\x1b[?2004l");
    const flush_err = ed.out.flush();
    ed.pasting = false;
    ed.paste_cr = false;

    try settings_err;
    try write_err;
    try flush_err;
}

fn readLinePiped(ed: *LineEditor) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ed.gpa);

    while (true) {
        const byte = (try ed.nextByte()) orelse break;
        if (byte == '\n') break;
        try line.append(ed.gpa, byte);
    }
    if (line.items.len == 0 and ed.in_len == 0) return null;
    if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
        _ = line.pop();
    }
    return @as(?[]const u8, try ed.submit(line.items));
}

fn submit(ed: *LineEditor, line: []const u8) ![]const u8 {
    const start = ed.strings.items.len;
    if (line.len > 0) {
        try ed.strings.appendSlice(ed.gpa, line);
        try ed.strings.append(ed.gpa, 0);
        try ed.history.append(ed.gpa, start);
    }
    return ed.strings.items[start..][0..line.len];
}

fn redraw(
    ed: *LineEditor,
    prompt: []const u8,
    content_width: usize,
    line: []const u8,
    cursor: usize,
) !void {
    const prompt_width = columns(prompt);
    var spaces: [max_indent]u8 = @splat(' ');
    const indent = spaces[0..@min(prompt_width, spaces.len)];

    const rows = rowCount(line, content_width);
    const at = rowAt(line, content_width, cursor);
    const cursor_col = prompt_width + columns(line[at.start..cursor]);

    // After a resize the terminal has reflowed the rows on screen, so they are no longer the rows
    // the last paint laid out.
    if (ed.width != ed.painted_width) {
        if (ed.width != 0 and ed.painted_width != 0) {
            const shown = reflowed(
                line,
                prompt_width,
                contentWidthFor(ed.painted_width, prompt_width),
                ed.width,
                cursor,
            );
            ed.last_rows = shown.rows;
            ed.last_cursor_row = shown.cursor_row;
        } else {
            ed.last_rows = rows;
            ed.last_cursor_row = at.index;
        }
    }

    if (ed.last_cursor_row > 0) try ed.out.print("\x1b[{d}A", .{ed.last_cursor_row});
    try ed.out.writeAll("\r");
    if (ed.last_rows == 0) {
        try ed.out.writeAll("\x1b[K");
    } else {
        var row: usize = 0;
        while (row < ed.last_rows) : (row += 1) {
            try ed.out.writeAll("\x1b[K");
            if (row + 1 < ed.last_rows) try ed.out.writeAll("\r\n");
        }
        if (ed.last_rows > 1) try ed.out.print("\x1b[{d}A", .{ed.last_rows - 1});
        try ed.out.writeAll("\r");
    }

    var row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        var pos = start;
        while (true) {
            if (row > 0) try ed.out.writeAll("\r\n");
            try ed.out.writeAll(if (row == 0) prompt else indent);
            const from = pos;
            pos = from + columnOffset(line[from..end], content_width);
            try ed.out.writeAll(line[from..pos]);
            row += 1;
            if (pos >= end) break;
        }
        if (newline == null) break;
        start = end + 1;
    }

    try ed.out.writeAll("\x1b[J");

    const up = rows - 1 - at.index;
    if (up > 0) try ed.out.print("\x1b[{d}A", .{up});
    try ed.out.writeAll("\r");
    if (cursor_col > 0) try ed.out.print("\x1b[{d}C", .{cursor_col});

    ed.last_rows = rows;
    ed.last_cursor_row = at.index;
    ed.painted_width = ed.width;
    try ed.out.flush();
}

fn endPrompt(ed: *LineEditor, header: []const u8) !void {
    const header_rows = ed.headerRows(header);
    const deleted = header_rows + ed.last_rows;
    if (deleted == 0) return;
    const up = ed.last_cursor_row + header_rows;
    if (up > 0) try ed.out.print("\x1b[{d}A", .{up});
    try ed.out.writeAll("\r");
    try ed.out.print("\x1b[{d}M", .{deleted});
    try ed.out.writeAll("\r");
}

fn contentWidth(ed: *const LineEditor, prompt_width: usize) usize {
    return contentWidthFor(ed.width, prompt_width);
}

fn headerRows(ed: *const LineEditor, header: []const u8) usize {
    if (header.len == 0) return 0;
    const columns_wide = columns(header);
    if (ed.width == 0 or columns_wide == 0) return 1;
    return (columns_wide + ed.width - 1) / ed.width;
}

fn recall(
    ed: *LineEditor,
    line: *std.ArrayList(u8),
    cursor: *usize,
    draft: *std.ArrayList(u8),
    recalled: *?usize,
    direction: i8,
) !bool {
    const history = ed.history.items;
    if (history.len == 0) return false;

    const landing: ?usize = land: {
        if (recalled.*) |here| {
            if (direction < 0) {
                if (here == 0) return false;
                break :land here - 1;
            }
            break :land if (here + 1 < history.len) here + 1 else null;
        }
        if (direction > 0) return false;
        break :land history.len - 1;
    };

    if (recalled.* == null) {
        draft.clearRetainingCapacity();
        try draft.appendSlice(ed.gpa, line.items);
    }

    line.clearRetainingCapacity();
    try line.appendSlice(ed.gpa, if (landing) |i| ed.historyLine(i) else draft.items);
    cursor.* = line.items.len;
    recalled.* = landing;
    ed.goal_col = null;
    return true;
}

fn drained(ed: *const LineEditor) bool {
    return ed.in_pos == ed.in_len;
}

fn nextKey(ed: *LineEditor) !Key {
    const byte = (try ed.nextByte()) orelse return .none;
    if (byte == 0x1b) {
        ed.paste_cr = false;
        return ed.nextEscape();
    }
    if (byte == '\r' or byte == '\n') {
        if (!ed.pasting) return .enter;
        if (byte == '\n' and ed.paste_cr) {
            ed.paste_cr = false;
            return .none;
        }
        ed.paste_cr = byte == '\r';
        return .newline;
    }
    ed.paste_cr = false;
    return switch (byte) {
        0x7f, 0x08 => .backspace,
        0x01 => .home,
        0x05 => .end,
        0x0b => .kill_to_end,
        0x15 => .kill_to_start,
        0x17 => .kill_word,
        0x0c => .clear,
        0x03 => .interrupt,
        0x04 => .eof,
        else => if (byte >= 0x20) try ed.readChar(byte) else .none,
    };
}

fn readChar(ed: *LineEditor, first: u8) !Key {
    const len = std.unicode.utf8ByteSequenceLength(first) catch return .none;
    var char: [4]u8 = @splat(0);
    char[0] = first;
    for (char[1..len]) |*byte| byte.* = (try ed.nextByte()) orelse return .none;
    if (!std.unicode.utf8ValidateSlice(char[0..len])) return .none;
    return .{ .char = char };
}

fn nextEscape(ed: *LineEditor) !Key {
    const introducer = (try ed.nextByte()) orelse return .none;
    if (introducer == '\r' or introducer == '\n') return .newline;
    if (introducer != '[' and introducer != 'O') return .none;

    var params: [16]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const byte = (try ed.nextByte()) orelse return .none;
        if (byte >= 0x40 and byte <= 0x7e) {
            if (byte == '~') {
                if (std.mem.eql(u8, params[0..len], "200")) {
                    ed.pasting = true;
                    ed.paste_cr = false;
                    return .none;
                }
                if (std.mem.eql(u8, params[0..len], "201")) {
                    ed.pasting = false;
                    ed.paste_cr = false;
                    return .none;
                }
            }
            return finalKey(params[0..len], byte);
        }
        if (len < params.len) {
            params[len] = byte;
            len += 1;
        }
    }
}

fn finalKey(params: []const u8, final: u8) Key {
    if (params.len == 0) {
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .none,
        };
    }
    if (final == 'u' and std.mem.eql(u8, params, "13;2")) return .newline;
    if (final == '~' and std.mem.eql(u8, params, "27;2;13")) return .newline;

    if (final == '~') {
        const code = std.fmt.parseInt(u16, params, 10) catch return .none;
        return switch (code) {
            1, 7 => .home,
            4, 8 => .end,
            3 => .delete,
            else => .none,
        };
    }
    return .none;
}

fn nextByte(ed: *LineEditor) !?u8 {
    if (ed.in_pos == ed.in_len) {
        // Raw mode is configured with VMIN=0/VTIME=1, so a zero-length read means "no input within
        // the timeout" rather than end of file.
        const len = try std.posix.read(std.posix.STDIN_FILENO, &ed.in_buf);
        ed.in_pos = 0;
        ed.in_len = len;
        if (len == 0) return null;
    }
    defer ed.in_pos += 1;
    return ed.in_buf[ed.in_pos];
}

fn enterRaw(ed: *LineEditor) !std.posix.termios {
    _ = ed;
    const fd = std.posix.STDIN_FILENO;
    const saved = try settings.get(fd);
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 0;
    raw.cc[@backingInt(std.posix.V.TIME)] = 1;
    try settings.set(fd, raw);
    return saved;
}

const Reflow = struct { rows: usize, cursor_row: usize };

fn contentWidthFor(width: usize, prompt_width: usize) usize {
    if (width == 0 or width <= prompt_width) return no_wrap;
    if (prompt_width > max_indent) return no_wrap;
    return width - prompt_width;
}

fn reflowed(line: []const u8, prompt_width: usize, old_content: usize, width: usize, cursor: usize) Reflow {
    const old_at = rowAt(line, old_content, cursor);
    const cursor_col = prompt_width + columns(line[old_at.start..cursor]);

    var rows: usize = 0;
    var cursor_row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        var pos = start;
        while (true) {
            const from = pos;
            pos = from + columnOffset(line[from..end], old_content);
            const wrapped = rowsFor(prompt_width + columns(line[from..pos]), width);
            if (from == old_at.start) {
                cursor_row = rows + @min(cursor_col / width, wrapped - 1);
            }
            rows += wrapped;
            if (pos >= end) break;
        }
        if (newline == null) return .{ .rows = rows, .cursor_row = cursor_row };
        start = end + 1;
    }
}

fn wordStart(line: []const u8, cursor: usize) usize {
    var start = cursor;
    while (start > 0 and std.ascii.isWhitespace(line[start - 1])) start -= 1;
    while (start > 0 and !std.ascii.isWhitespace(line[start - 1])) start -= 1;
    return start;
}

fn prevChar(line: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    return cursor - terminal_width.prevLen(line[0..cursor]);
}

fn nextChar(line: []const u8, cursor: usize) usize {
    if (cursor >= line.len) return line.len;
    return @min(line.len, cursor + terminal_width.charLen(line[cursor..]));
}

const Row = struct { index: usize, start: usize, end: usize };

fn moveCursorVertical(
    goal_col: *?usize,
    line: []const u8,
    content_width: usize,
    cursor: *usize,
    direction: i8,
) bool {
    const current = rowAt(line, content_width, cursor.*);
    if (direction < 0) {
        if (current.index == 0) return false;
    } else if (current.index + 1 >= rowCount(line, content_width)) {
        return false;
    }
    const goal = goal_col.* orelse columns(line[current.start..cursor.*]);
    const target_index = if (direction < 0) current.index - 1 else current.index + 1;
    const target = rowRange(line, content_width, target_index);
    const text = line[target.start..target.end];
    cursor.* = target.start + columnOffset(text, @min(goal, columns(text)));
    goal_col.* = goal;
    return true;
}

fn rowAt(line: []const u8, content_width: usize, cursor: usize) Row {
    var index: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        if (cursor <= end) {
            const text = line[start..end];
            const columns_wide = columns(text);
            const rows = rowsFor(columns_wide, content_width);
            const within = @min(columns(line[start..cursor]) / content_width, rows - 1);
            const row_start = start + columnOffset(text, within * content_width);
            return .{
                .index = index + within,
                .start = row_start,
                .end = start + columnOffset(text, @min((within + 1) * content_width, columns_wide)),
            };
        }
        index += rowsFor(columns(line[start..end]), content_width);
        if (newline == null) return .{ .index = index, .start = line.len, .end = line.len };
        start = end + 1;
    }
}

fn rowRange(line: []const u8, content_width: usize, index: usize) struct { start: usize, end: usize } {
    var row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        const rows = rowsFor(columns(line[start..end]), content_width);
        if (index < row + rows) {
            const text = line[start..end];
            const columns_wide = columns(text);
            const within = index - row;
            return .{
                .start = start + columnOffset(text, within * content_width),
                .end = start + columnOffset(text, @min((within + 1) * content_width, columns_wide)),
            };
        }
        row += rows;
        if (newline == null) return .{ .start = line.len, .end = line.len };
        start = end + 1;
    }
}

fn rowCount(line: []const u8, content_width: usize) usize {
    var rows: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.findScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        rows += rowsFor(columns(line[start..end]), content_width);
        if (newline == null) return rows;
        start = end + 1;
    }
}

fn rowsFor(cols: usize, content_width: usize) usize {
    if (cols <= content_width) return 1;
    return (cols + content_width - 1) / content_width;
}

const columns = terminal_width.columns;
const columnOffset = terminal_width.columnOffset;

test "wordStart skips trailing whitespace then the word" {
    try std.testing.expectEqual(0, wordStart("hello", 5));
    try std.testing.expectEqual(0, wordStart("hello  ", 7));
    try std.testing.expectEqual(6, wordStart("hello world", 11));
    try std.testing.expectEqual(6, wordStart("hello world", 9));
    try std.testing.expectEqual(0, wordStart("hello world", 6));
    try std.testing.expectEqual(4, wordStart("one two", 7));
    try std.testing.expectEqual(0, wordStart("", 0));
}

test "the cursor steps over whole characters, not bytes" {
    const line = "a\u{e9}\u{20ac}\u{1f600}b";
    try std.testing.expectEqual(1, nextChar(line, 0));
    try std.testing.expectEqual(3, nextChar(line, 1));
    try std.testing.expectEqual(6, nextChar(line, 3));
    try std.testing.expectEqual(10, nextChar(line, 6));
    try std.testing.expectEqual(11, nextChar(line, 10));
    try std.testing.expectEqual(11, nextChar(line, 11));

    try std.testing.expectEqual(10, prevChar(line, 11));
    try std.testing.expectEqual(6, prevChar(line, 10));
    try std.testing.expectEqual(3, prevChar(line, 6));
    try std.testing.expectEqual(1, prevChar(line, 3));
    try std.testing.expectEqual(0, prevChar(line, 1));
    try std.testing.expectEqual(0, prevChar(line, 0));
}

fn decodeKeys(bytes: []const u8) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var ed = LineEditor.init(std.testing.io, &sink.writer, std.testing.allocator);
    defer ed.deinit();

    @memcpy(ed.in_buf[0..bytes.len], bytes);
    ed.in_pos = 0;
    ed.in_len = bytes.len;
    var keys: std.ArrayList(u8) = .empty;
    errdefer keys.deinit(std.testing.allocator);
    while (ed.in_pos < ed.in_len) {
        try keys.append(std.testing.allocator, switch (try ed.nextKey()) {
            .char => |c| if (c[1] == 0) c[0] else '#',
            .newline => '\n',
            .enter => 'E',
            .none => '.',
            else => '?',
        });
    }
    return keys.toOwnedSlice(std.testing.allocator);
}

test "a newline in a paste is a line break and only enter submits" {
    const keys = try decodeKeys("\x1b[200~one\ntwo\x1b[201~more\r");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings(".one\ntwo.moreE", keys);
}

test "a carriage return from the keyboard still submits outside a paste" {
    const keys = try decodeKeys("hi\rhi\n");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("hiEhiE", keys);
}

test "a CRLF in a paste opens a single line, not one and a blank" {
    const keys = try decodeKeys("\x1b[200~a\r\nb\x1b[201~");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings(".a\n.b.", keys);
}

test "a shifted enter and the arrow keys still decode" {
    // Shift+Enter is a line break outside a paste, as before, and an arrow key is its own key
    // rather than the digits of its escape sequence.
    const keys = try decodeKeys("a\x1b[13;2ub\x1b[Du\r");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("a\nb?uE", keys);
}

test "a multi-byte character is one key, and a malformed byte is none" {
    const keys = try decodeKeys("a\u{e9}b\u{1f600}c");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("a#b#c", keys);

    // A byte no character begins with is dropped rather than put in the line.
    const bad = try decodeKeys("a\xffb");
    defer std.testing.allocator.free(bad);
    try std.testing.expectEqualStrings("a.b", bad);
}

test "columns and offsets count characters, and stay safe on malformed text" {
    const line = "a\u{e9}\u{20ac}b";
    try std.testing.expectEqual(4, columns(line));
    try std.testing.expectEqual(3, columnOffset(line, 2));
    try std.testing.expectEqual(line.len, columnOffset(line, 10));
    try std.testing.expectEqual(2, columns("\xff\xff"));
    try std.testing.expectEqual(1, nextChar("\xff\xff", 0));
}

test "a wide character is two columns and one step, and a grapheme steps whole" {
    const wide = "a漢b";
    try std.testing.expectEqual(4, columns(wide));
    try std.testing.expectEqual(4, columnOffset(wide, 3));
    try std.testing.expectEqual(4, nextChar(wide, 1));
    try std.testing.expectEqual(1, prevChar(wide, 4));

    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    const line = family ++ "!";
    try std.testing.expectEqual(@as(usize, family.len), nextChar(line, 0));
    try std.testing.expectEqual(@as(usize, 0), prevChar(line, family.len));
    try std.testing.expectEqual(@as(usize, family.len), prevChar(line, line.len));
}

test "the history keeps the submitted lines in one pool" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);
    defer ed.deinit();

    try std.testing.expectEqualStrings("hello", try ed.submit("hello"));
    try std.testing.expectEqualStrings("world", try ed.submit("world"));
    try std.testing.expectEqual(@as(usize, 2), ed.history.items.len);
    try std.testing.expectEqualStrings("hello", ed.historyLine(0));
    try std.testing.expectEqualStrings("world", ed.historyLine(1));

    try std.testing.expectEqualStrings("", try ed.submit(""));
    try std.testing.expectEqual(@as(usize, 2), ed.history.items.len);
}

test "recall walks the history, keeping the line it started from" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);
    defer ed.deinit();
    _ = try ed.submit("one");
    _ = try ed.submit("two");

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var draft: std.ArrayList(u8) = .empty;
    defer draft.deinit(gpa);
    var cursor: usize = 0;
    var recalled: ?usize = null;

    try line.appendSlice(gpa, "half typed");
    cursor = line.items.len;

    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, -1));
    try std.testing.expectEqualStrings("two", line.items);
    try std.testing.expectEqual(@as(usize, 3), cursor);
    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, -1));
    try std.testing.expectEqualStrings("one", line.items);
    try std.testing.expect(!try ed.recall(&line, &cursor, &draft, &recalled, -1));
    try std.testing.expectEqualStrings("one", line.items);

    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, 1));
    try std.testing.expectEqualStrings("two", line.items);

    try line.appendSlice(gpa, "!");
    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, -1));
    try std.testing.expectEqualStrings("one", line.items);
    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, 1));
    try std.testing.expectEqualStrings("two", line.items);

    try std.testing.expect(try ed.recall(&line, &cursor, &draft, &recalled, 1));
    try std.testing.expectEqualStrings("half typed", line.items);
    try std.testing.expectEqual(@as(usize, 10), cursor);
    try std.testing.expect(!try ed.recall(&line, &cursor, &draft, &recalled, 1));
}

test "columns ignore ANSI escapes" {
    try std.testing.expectEqual(2, columns("> "));
    try std.testing.expectEqual(0, columns("\x1b[31m\x1b[0m"));
    try std.testing.expectEqual(5, columns("\x1b[1mbilly\x1b[0m"));
    try std.testing.expectEqual(1, columns("·"));
    try std.testing.expectEqual(3, columns("a·b"));
}

test "endPrompt erases the header and the line it heads" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);
    defer ed.deinit();

    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.endPrompt("billy · m · /w");
    try std.testing.expectEqualStrings("\x1b[1A\r\x1b[2M\r", out.written());
    out.clearRetainingCapacity();

    ed.last_rows = 3;
    ed.last_cursor_row = 2;
    try ed.endPrompt("billy · m · /w");
    try std.testing.expectEqualStrings("\x1b[3A\r\x1b[4M\r", out.written());
    out.clearRetainingCapacity();

    ed.width = 10;
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.endPrompt("billy · m · /work");
    try std.testing.expectEqualStrings("\x1b[2A\r\x1b[3M\r", out.written());
    out.clearRetainingCapacity();
    ed.width = 0;

    ed.last_rows = 3;
    ed.last_cursor_row = 1;
    try ed.endPrompt("");
    try std.testing.expectEqualStrings("\x1b[1A\r\x1b[3M\r", out.written());
    out.clearRetainingCapacity();

    ed.last_rows = 0;
    ed.last_cursor_row = 0;
    try ed.endPrompt("");
    try std.testing.expectEqualStrings("", out.written());
}

test "moveCursorVertical keeps its target column across rows" {
    const line = "hello world\nhi\nbeep boop";
    var goal: ?usize = null;
    var cursor: usize = 5;
    try std.testing.expect(moveCursorVertical(&goal, line, no_wrap, &cursor, 1));
    try std.testing.expectEqual(14, cursor); // clamped to the short middle row
    try std.testing.expect(moveCursorVertical(&goal, line, no_wrap, &cursor, 1));
    try std.testing.expectEqual(20, cursor); // column 5 restored on the last row
    try std.testing.expect(moveCursorVertical(&goal, line, no_wrap, &cursor, -1));
    try std.testing.expectEqual(14, cursor);
    try std.testing.expect(moveCursorVertical(&goal, line, no_wrap, &cursor, -1));
    try std.testing.expectEqual(5, cursor); // column 5 restored on the first row
    try std.testing.expect(!moveCursorVertical(&goal, line, no_wrap, &cursor, -1)); // already on the first row
}

test "moveCursorVertical stops at the last row" {
    const line = "one\ntwo";
    var goal: ?usize = null;
    var cursor: usize = 0;
    try std.testing.expect(moveCursorVertical(&goal, line, no_wrap, &cursor, 1));
    try std.testing.expectEqual(4, cursor);
    try std.testing.expect(!moveCursorVertical(&goal, line, no_wrap, &cursor, 1)); // already on the last row
}

test "rowAt and rowCount treat trailing newlines as an empty row" {
    try std.testing.expectEqual(1, rowCount("hi", no_wrap));
    try std.testing.expectEqual(2, rowCount("hi\n", no_wrap));
    try std.testing.expectEqual(3, rowCount("a\nb\nc", no_wrap));
    try std.testing.expectEqual(1, rowAt("hi\n", no_wrap, 3).index);
    try std.testing.expectEqual(3, rowAt("hi\n", no_wrap, 3).start);
    try std.testing.expectEqual(0, rowAt("hi\n", no_wrap, 2).index);
}

test "a line wider than the terminal folds into several rows" {
    const line = "abcdefghijklmnopqrstuvwxyz"; // 26 characters
    try std.testing.expectEqual(3, rowCount(line, 10));
    try std.testing.expectEqual(0, rowRange(line, 10, 0).start);
    try std.testing.expectEqual(10, rowRange(line, 10, 0).end);
    try std.testing.expectEqual(10, rowRange(line, 10, 1).start);
    try std.testing.expectEqual(20, rowRange(line, 10, 1).end);
    try std.testing.expectEqual(20, rowRange(line, 10, 2).start);
    try std.testing.expectEqual(26, rowRange(line, 10, 2).end);

    try std.testing.expectEqual(1, rowAt(line, 10, 10).index);
    try std.testing.expectEqual(10, rowAt(line, 10, 10).start);
    try std.testing.expectEqual(2, rowAt(line, 10, 26).index);

    try std.testing.expectEqual(2, rowCount(&@as([20]u8, @splat('z')), 10));
    try std.testing.expectEqual(1, rowAt(&@as([20]u8, @splat('z')), 10, 20).index);
}

test "folding repeats within every source row" {
    const line = "abcd\nefghij";
    try std.testing.expectEqual(3, rowCount(line, 4));
    try std.testing.expectEqual(1, rowAt(line, 4, 5).index); // just past the newline
    try std.testing.expectEqual(5, rowAt(line, 4, 5).start);
    try std.testing.expectEqual(2, rowAt(line, 4, 11).index); // the tail of the fold
}

test "a multi-byte character is never cut by a fold" {
    const line = "a·b·c·d";
    try std.testing.expectEqual(4, rowCount(line, 2));
    try std.testing.expectEqual(0, rowRange(line, 2, 0).start);
    try std.testing.expectEqual(3, rowRange(line, 2, 0).end); // "a·", whole
    try std.testing.expectEqual(3, rowRange(line, 2, 1).start);
    try std.testing.expectEqual(6, rowRange(line, 2, 1).end); // "b·"
    try std.testing.expectEqual(1, rowAt(line, 2, 3).index);
    try std.testing.expectEqual(3, rowAt(line, 2, 3).start);
}

test "moveCursorVertical walks the folds of a wrapped line" {
    const line = "abcdefghij"; // three rows: four, four, then two columns
    var goal: ?usize = null;
    var cursor: usize = 7; // the last column of the second row
    try std.testing.expect(moveCursorVertical(&goal, line, 4, &cursor, -1));
    try std.testing.expectEqual(3, cursor); // the same column on the first row
    try std.testing.expect(!moveCursorVertical(&goal, line, 4, &cursor, -1));
    try std.testing.expect(moveCursorVertical(&goal, line, 4, &cursor, 1));
    try std.testing.expectEqual(7, cursor); // the column comes back on the second row
    try std.testing.expect(moveCursorVertical(&goal, line, 4, &cursor, 1));
    try std.testing.expectEqual(10, cursor); // clamped to the short last row
    try std.testing.expect(!moveCursorVertical(&goal, line, 4, &cursor, 1));
}

test "redraw folds a line that is wider than the terminal" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);
    defer ed.deinit();

    try ed.redraw("> ", 4, "abcdefgh", 8);
    try std.testing.expectEqualStrings(
        "\r\x1b[K" ++ // nothing painted yet: clear the line the prompt is on
            "> abcd" ++
            "\r\n  efgh" ++
            "\x1b[J" ++ // clear whatever is under the prompt
            "\r\x1b[6C", // the cursor at the end of the second row
        out.written(),
    );
    try std.testing.expectEqual(2, ed.last_rows);
    try std.testing.expectEqual(1, ed.last_cursor_row);

    out.clearRetainingCapacity();
    try ed.redraw("> ", 4, "abcdefghi", 9);
    try std.testing.expectEqualStrings(
        "\x1b[1A\r\x1b[K\r\n\x1b[K\x1b[1A\r" ++
            "> abcd" ++
            "\r\n  efgh" ++
            "\r\n  i" ++
            "\x1b[J" ++
            "\r\x1b[3C",
        out.written(),
    );
    try std.testing.expectEqual(3, ed.last_rows);
    try std.testing.expectEqual(2, ed.last_cursor_row);
}

test "a redraw after a resize erases the rows the new width needs" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);
    defer ed.deinit();

    const line = "abcdefghijklmnopqrstuvwxyz0123456789"; // 36 characters
    ed.width = 78;
    ed.painted_width = 78;
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.redraw("> ", 76, line, 36);
    try std.testing.expectEqualStrings(
        "\r\x1b[K\r" ++
            "> abcdefghijklmnopqrstuvwxyz0123456789" ++
            "\x1b[J" ++
            "\r\x1b[38C",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The terminal is resized to 20 columns.
    ed.width = 20;
    try ed.redraw("> ", 18, line, 36);
    try std.testing.expectEqualStrings(
        "\x1b[1A\r\x1b[K\r\n\x1b[K\x1b[1A\r" ++ // erase the two reflowed rows
            "> abcdefghijklmnopqr" ++
            "\r\n  stuvwxyz0123456789" ++
            "\x1b[J" ++
            "\r\x1b[20C",
        out.written(),
    );
    try std.testing.expectEqual(2, ed.last_rows);
    try std.testing.expectEqual(1, ed.last_cursor_row);
    try std.testing.expectEqual(20, ed.painted_width);
}

test "reflowed measures a shrunk region by its folds and not the whole line" {
    const line = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const prompt_width = 2;
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, prompt_width, 38, 24, line.len));
    try std.testing.expectEqual(Reflow{ .rows = 2, .cursor_row = 1 }, reflowed(line, prompt_width, 38, 60, line.len));
    try std.testing.expectEqual(Reflow{ .rows = 3, .cursor_row = 2 }, reflowed(line, prompt_width, 22, 60, line.len));
}

test "reflowed keeps the cursor on the painted row it was on" {
    const line = "abcd\nefgh";
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, 2, 4, 4, line.len));
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, 2, 4, 4, 7));
}
