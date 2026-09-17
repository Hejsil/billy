//! Interactive line editor for the user prompt.
//!
//! The terminal is put into raw mode so the user can move the cursor and fix
//! typos before submitting. When stdin is not a terminal the line is read
//! without editing, which keeps the harness usable from a pipe.

const std = @import("std");
const Io = std.Io;

/// A decoded key press. Bytes that are not printable or bound to an action are
/// reported as `.none` and ignored.
const Key = union(enum) {
    byte: u8,
    enter,
    /// Shift+Enter: insert a line break instead of submitting.
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

pub const LineEditor = struct {
    io: Io,
    /// Destination for the prompt, the echoed line and the redraws.
    out: *Io.Writer,
    /// Owns the returned lines, which outlive the call.
    arena: std.mem.Allocator,
    /// Submitted lines, most recent last.
    history: std.ArrayList([]const u8) = .empty,
    /// Bytes read from stdin but not yet consumed by the key decoder.
    in_buf: [256]u8 = undefined,
    in_pos: usize = 0,
    in_len: usize = 0,
    /// Terminal rows painted by the last redraw, and the row the cursor was left
    /// on within that region. They are used to erase and repaint a prompt that
    /// may span several lines.
    last_rows: usize = 0,
    last_cursor_row: usize = 0,

    pub fn init(io: Io, out: *Io.Writer, arena: std.mem.Allocator) LineEditor {
        return .{ .io = io, .out = out, .arena = arena };
    }

    /// Reads one line, echoing and editing it in the terminal.
    ///
    /// `prompt` is printed in front of the line and must not contain a newline,
    /// so that redraws can repaint it in place.
    ///
    /// Returns null when stdin is exhausted: end of a piped stdin, or Ctrl-D on
    /// an empty line. The returned slice is allocated with the arena.
    pub fn readLine(ed: *LineEditor, prompt: []const u8) !?[]const u8 {
        try ed.out.writeAll("\n");
        try ed.out.writeAll(prompt);
        try ed.out.flush();

        if (!try Io.File.stdin().isTty(ed.io)) return ed.readLinePiped();

        const saved = try ed.enterRaw();
        defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};

        ed.last_rows = 0;
        ed.last_cursor_row = 0;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(ed.arena);
        var cursor: usize = 0;
        var recalled: ?usize = null;
        var dirty = false;

        while (true) {
            const key = try ed.nextKey();
            switch (key) {
                .none => {},
                .byte => |b| {
                    try line.insert(ed.arena, cursor, b);
                    cursor += 1;
                    recalled = null;
                    dirty = true;
                },
                .newline => {
                    try line.insert(ed.arena, cursor, '\n');
                    cursor += 1;
                    recalled = null;
                    dirty = true;
                },
                .enter => {
                    try ed.moveToRegionBottom();
                    try ed.out.writeAll("\r\n");
                    try ed.out.flush();
                    return @as(?[]const u8, try ed.submit(line.items));
                },
                .backspace => if (cursor > 0) {
                    _ = line.orderedRemove(cursor - 1);
                    cursor -= 1;
                    recalled = null;
                    dirty = true;
                },
                .delete => if (cursor < line.items.len) {
                    _ = line.orderedRemove(cursor);
                    recalled = null;
                    dirty = true;
                },
                .left => if (cursor > 0) {
                    cursor -= 1;
                    dirty = true;
                },
                .right => if (cursor < line.items.len) {
                    cursor += 1;
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
                    try line.replaceRange(ed.arena, 0, cursor, "");
                    cursor = 0;
                    recalled = null;
                    dirty = true;
                },
                .kill_to_end => if (cursor < line.items.len) {
                    line.shrinkRetainingCapacity(cursor);
                    recalled = null;
                    dirty = true;
                },
                .kill_word => {
                    const start = wordStart(line.items, cursor);
                    if (start < cursor) {
                        try line.replaceRange(ed.arena, start, cursor - start, "");
                        cursor = start;
                        recalled = null;
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
                    if (try ed.recall(&line, &cursor, &recalled, -1)) dirty = true;
                },
                .down => {
                    if (try ed.recall(&line, &cursor, &recalled, 1)) dirty = true;
                },
                .interrupt => {
                    try ed.moveToRegionBottom();
                    try ed.out.writeAll("\x1b[K^C\r\n");
                    line.clearRetainingCapacity();
                    cursor = 0;
                    recalled = null;
                    ed.last_rows = 0;
                    ed.last_cursor_row = 0;
                    dirty = true;
                    try ed.out.flush();
                },
                .eof => if (line.items.len == 0) {
                    try ed.moveToRegionBottom();
                    try ed.out.writeAll("\r\n");
                    try ed.out.flush();
                    return null;
                } else if (cursor < line.items.len) {
                    _ = line.orderedRemove(cursor);
                    recalled = null;
                    dirty = true;
                },
            }
            // Redraw only once the typed-ahead bytes are consumed, so pasting a
            // long line does not repaint the terminal for every byte.
            if (dirty and ed.drained()) {
                try ed.redraw(prompt, line.items, cursor);
                dirty = false;
            }
        }
    }

    fn readLinePiped(ed: *LineEditor) !?[]const u8 {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(ed.arena);

        while (true) {
            const byte = (try ed.nextByte()) orelse break;
            if (byte == '\n') break;
            try line.append(ed.arena, byte);
        }
        if (line.items.len == 0 and ed.in_len == 0) return null;
        if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
            _ = line.pop();
        }
        return @as(?[]const u8, try ed.submit(line.items));
    }

    fn submit(ed: *LineEditor, line: []const u8) ![]const u8 {
        const owned = try ed.arena.dupe(u8, line);
        if (owned.len > 0) try ed.history.append(ed.arena, owned);
        return owned;
    }

    /// Repaints the prompt and the current line, which may contain embedded
    /// newlines (from Shift+Enter). The whole region is erased and rewritten so
    /// that edits on any row are reflected.
    fn redraw(ed: *LineEditor, prompt: []const u8, line: []const u8, cursor: usize) !void {
        // Return to the top-left corner of the previously painted region and
        // erase it row by row.
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

        // Continuation rows are indented to line up under the first row.
        const prompt_width = visibleWidth(prompt);
        var spaces: [64]u8 = @splat(' ');
        const indent = spaces[0..@min(prompt_width, spaces.len)];

        // Locate the cursor and count the terminal rows the new render needs.
        var rows: usize = 1;
        var cursor_row: usize = 0;
        var cursor_col: usize = prompt_width;
        var row_start: usize = 0;
        while (true) {
            const newline = std.mem.indexOfScalarPos(u8, line, row_start, '\n');
            const row_end = newline orelse line.len;
            if (cursor <= row_end) {
                const prefix_width = if (cursor_row == 0) prompt_width else indent.len;
                cursor_col = prefix_width + (cursor - row_start);
                break;
            }
            if (newline == null) break;
            row_start = row_end + 1;
            cursor_row += 1;
        }
        for (line) |byte| {
            if (byte == '\n') rows += 1;
        }

        // Paint the prompt and the content, one terminal row per source line.
        row_start = 0;
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            if (row > 0) try ed.out.writeAll("\r\n");
            try ed.out.writeAll(if (row == 0) prompt else indent);
            const newline = std.mem.indexOfScalarPos(u8, line, row_start, '\n');
            const row_end = newline orelse line.len;
            try ed.out.writeAll(line[row_start..row_end]);
            row_start = row_end + 1;
        }

        // Move from the end of the render back to the cursor.
        const up = rows - 1 - cursor_row;
        if (up > 0) try ed.out.print("\x1b[{d}A", .{up});
        try ed.out.writeAll("\r");
        if (cursor_col > 0) try ed.out.print("\x1b[{d}C", .{cursor_col});

        ed.last_rows = rows;
        ed.last_cursor_row = cursor_row;
        try ed.out.flush();
    }

    /// Moves the cursor to the first column of the last row of the render, so a
    /// following newline lands below the whole prompt.
    fn moveToRegionBottom(ed: *LineEditor) !void {
        if (ed.last_rows == 0) return;
        const down = ed.last_rows - 1 - ed.last_cursor_row;
        if (down > 0) try ed.out.print("\x1b[{d}B", .{down});
        try ed.out.writeAll("\r");
    }

    /// Replaces the line with a history entry. `direction` is -1 for older, 1
    /// for newer. Returns whether the line changed.
    fn recall(
        ed: *LineEditor,
        line: *std.ArrayList(u8),
        cursor: *usize,
        recalled: *?usize,
        direction: i8,
    ) !bool {
        const history = ed.history.items;
        if (history.len == 0) return false;
        const next: ?usize = if (recalled.*) |i|
            if (direction < 0) (if (i > 0) i - 1 else 0) else (if (i + 1 < history.len) i + 1 else null)
        else if (direction < 0) history.len - 1 else null;
        if (next == null and recalled.* == null) return false;

        recalled.* = next;
        line.clearRetainingCapacity();
        if (next) |i| try line.appendSlice(ed.arena, history[i]);
        cursor.* = line.items.len;
        return true;
    }

    fn drained(ed: *const LineEditor) bool {
        return ed.in_pos == ed.in_len;
    }

    fn nextKey(ed: *LineEditor) !Key {
        const byte = (try ed.nextByte()) orelse return .none;
        return switch (byte) {
            0x1b => ed.nextEscape(),
            '\r', '\n' => .enter,
            0x7f, 0x08 => .backspace,
            0x01 => .home,
            0x05 => .end,
            0x0b => .kill_to_end,
            0x15 => .kill_to_start,
            0x17 => .kill_word,
            0x0c => .clear,
            0x03 => .interrupt,
            0x04 => .eof,
            else => if (byte >= 0x20) .{ .byte = byte } else .none,
        };
    }

    /// Decodes the `CSI`/`SS3` sequences for the arrow and navigation keys, as
    /// well as the encodings terminals use for Shift+Enter.
    fn nextEscape(ed: *LineEditor) !Key {
        const introducer = (try ed.nextByte()) orelse return .none;
        // Some terminals report Shift+Enter as ESC followed by a carriage return.
        if (introducer == '\r' or introducer == '\n') return .newline;
        if (introducer != '[' and introducer != 'O') return .none;

        // Collect the parameter/intermediate bytes up to the final byte.
        var params: [16]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const byte = (try ed.nextByte()) orelse return .none;
            if (byte >= 0x40 and byte <= 0x7e) return finalKey(params[0..len], byte);
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
        // Shift+Enter under the kitty keyboard protocol (CSI 13;2u) and xterm's
        // modifyOtherKeys (CSI 27;2;13~).
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
            // Raw mode is configured with VMIN=0/VTIME=1, so a zero-length read
            // means "no input within the timeout" rather than end of file.
            const len = try std.posix.read(std.posix.STDIN_FILENO, &ed.in_buf);
            ed.in_pos = 0;
            ed.in_len = len;
            if (len == 0) return null;
        }
        defer ed.in_pos += 1;
        return ed.in_buf[ed.in_pos];
    }

    /// Disables canonical mode and echo. Returns the previous settings, which
    /// the caller must restore.
    fn enterRaw(ed: *LineEditor) !std.posix.termios {
        _ = ed;
        const fd = std.posix.STDIN_FILENO;
        const saved = try std.posix.tcgetattr(fd);
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        try std.posix.tcsetattr(fd, .NOW, raw);
        return saved;
    }
};

/// Start of the word that ends at `cursor`, skipping trailing whitespace.
fn wordStart(line: []const u8, cursor: usize) usize {
    var start = cursor;
    while (start > 0 and std.ascii.isWhitespace(line[start - 1])) start -= 1;
    while (start > 0 and !std.ascii.isWhitespace(line[start - 1])) start -= 1;
    return start;
}

/// Number of terminal columns `text` occupies, ignoring ANSI escape sequences.
fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len) {
            i += 1;
            if (text[i] == '[') {
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            }
            i += 1;
            continue;
        }
        width += 1;
        i += 1;
    }
    return width;
}

test "wordStart skips trailing whitespace then the word" {
    try std.testing.expectEqual(0, wordStart("hello", 5));
    try std.testing.expectEqual(0, wordStart("hello  ", 7));
    try std.testing.expectEqual(6, wordStart("hello world", 11));
    try std.testing.expectEqual(5, wordStart("hello world", 6));
    try std.testing.expectEqual(0, wordStart("", 0));
}

test "visibleWidth ignores ANSI escapes" {
    try std.testing.expectEqual(2, visibleWidth("> "));
    try std.testing.expectEqual(0, visibleWidth("\x1b[31m\x1b[0m"));
    try std.testing.expectEqual(6, visibleWidth("\x1b[1mbilly\x1b[0m"));
}
