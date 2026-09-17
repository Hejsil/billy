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
                .enter => {
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
                    dirty = true;
                },
                .up => {
                    if (try ed.recall(&line, &cursor, &recalled, -1)) dirty = true;
                },
                .down => {
                    if (try ed.recall(&line, &cursor, &recalled, 1)) dirty = true;
                },
                .interrupt => {
                    try ed.out.writeAll("^C\r\n");
                    line.clearRetainingCapacity();
                    cursor = 0;
                    recalled = null;
                    try ed.out.writeAll(prompt);
                    try ed.out.flush();
                },
                .eof => if (line.items.len == 0) {
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

    fn redraw(ed: *LineEditor, prompt: []const u8, line: []const u8, cursor: usize) !void {
        try ed.out.print("\r\x1b[K{s}{s}", .{ prompt, line });
        if (line.len > cursor) try ed.out.print("\x1b[{d}D", .{line.len - cursor});
        try ed.out.flush();
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

    /// Decodes the `CSI`/`SS3` sequences for the arrow and navigation keys.
    fn nextEscape(ed: *LineEditor) !Key {
        const introducer = (try ed.nextByte()) orelse return .none;
        if (introducer != '[' and introducer != 'O') return .none;
        const final = (try ed.nextByte()) orelse return .none;
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '1'...'9' => ed.nextTildeKey(final),
            else => .none,
        };
    }

    fn nextTildeKey(ed: *LineEditor, first: u8) !Key {
        var number: [2]u8 = .{ first, 0 };
        var len: usize = 1;
        while (len < number.len) {
            const byte = (try ed.nextByte()) orelse return .none;
            if (byte == '~') break;
            number[len] = byte;
            len += 1;
        }
        if (len == number.len) return .none;
        return switch (number[0]) {
            '1', '7' => .home,
            '4', '8' => .end,
            '3' => .delete,
            else => .none,
        };
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

test "wordStart skips trailing whitespace then the word" {
    try std.testing.expectEqual(0, wordStart("hello", 5));
    try std.testing.expectEqual(0, wordStart("hello  ", 7));
    try std.testing.expectEqual(6, wordStart("hello world", 11));
    try std.testing.expectEqual(5, wordStart("hello world", 6));
    try std.testing.expectEqual(0, wordStart("", 0));
}
