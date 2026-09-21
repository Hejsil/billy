//! Interactive line editor for the user prompt.
//!
//! The terminal is put into raw mode so the user can move the cursor and fix
//! typos before submitting. When stdin is not a terminal the line is read
//! without editing, which keeps the harness usable from a pipe.

const std = @import("std");
const Io = std.Io;

const LineEditor = @This();

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

/// Most a continuation row will ever be indented: the prompt is two columns
/// wide in practice, so this only bounds a pathological one.
const max_indent = 64;
/// A content width no row can overflow, used when the terminal width is unknown
/// or too narrow to wrap the line against.
const no_wrap = std.math.maxInt(usize) / 4;

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
/// Column the cursor aims for during a run of up/down presses, so crossing a
/// short row does not lose the horizontal position. Cleared by any other key.
goal_col: ?usize = null,
/// Terminal width in columns, or 0 when it is unknown and the line is left
/// for the terminal to fold. Re-read for every input, so a resize is noticed.
width: usize = 0,
/// The width `last_rows` and `last_cursor_row` were painted at. When it no
/// longer matches `width`, the terminal has reflowed the painted region, and
/// it is measured against `width` instead.
painted_width: usize = 0,
/// Whether the bytes now arriving are a paste rather than typing. The terminal
/// wraps a paste in `ESC[200~` and `ESC[201~`, and everything between is
/// inserted as it is: a newline a user pasted is a line break in the line,
/// where a newline from the keyboard submits it. That is what keeps a pasted
/// block of text from going out as one prompt per line.
pasting: bool = false,
/// Whether the last byte of a paste was a carriage return, so a `\r\n` pair in
/// one is a single line break. A terminal that sends `\r\n` for a pasted line
/// ending would otherwise open a blank line after every line.
paste_cr: bool = false,

pub fn init(io: Io, out: *Io.Writer, arena: std.mem.Allocator) LineEditor {
    return .{ .io = io, .out = out, .arena = arena };
}

/// Reads one line, echoing and editing it in the terminal.
///
/// `header` is shown on its own line above the prompt while the line is being
/// edited. Both it and the `prompt` in front of the line belong to the editing
/// alone: on submit the whole region is erased, leaving the cursor where it
/// stood, so nothing of the input is left in the output. The caller prints
/// what the line was in its place. Neither may contain a newline. When stdin
/// is not a terminal there is no line being typed, so neither is shown, and it
/// is left to the caller to write the line out.
///
/// Returns null when stdin is exhausted: end of a piped stdin, or Ctrl-D on
/// an empty line. The returned slice is allocated with the arena.
pub fn readLine(ed: *LineEditor, header: []const u8, prompt: []const u8) !?[]const u8 {
    const interactive = try Io.File.stdin().isTty(ed.io);
    // The width is only wanted to fold a line being edited, which cannot
    // happen without a terminal.
    ed.width = if (interactive) ed.terminalWidth() else 0;
    // Start on a fresh line, then the header and the prompt the user types
    // behind. The leading newline also ends the previous line after a piped
    // read, which has no echo to do that. With no terminal there is no line
    // being typed, so neither the header nor the prompt is shown: the caller
    // prints the line it read as the block a replay would.
    try ed.out.writeAll("\n");
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
    defer {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};
        // Bracketed paste is a property of the terminal rather than of this
        // process, so it is turned back off when the line is done; left on, it
        // would wrap pastes in whatever the user runs next.
        ed.out.writeAll("\x1b[?2004l") catch {};
        ed.out.flush() catch {};
        ed.pasting = false;
        ed.paste_cr = false;
    }
    // Ask the terminal to mark where a paste begins and ends, so the bytes in
    // one can be told from what the user types.
    try ed.out.writeAll("\x1b[?2004h");
    try ed.out.flush();

    // The prompt alone is what is on screen before any key arrives, and it is
    // one row: an empty line submitted without a redraw is still measured, so
    // the region can be erased from the start.
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    ed.goal_col = null;
    ed.painted_width = ed.width;
    // The text on each row fits the same number of columns, since the prompt
    // and the continuation indent are the same width.
    var content_width = ed.contentWidth(visibleWidth(prompt));

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ed.arena);
    var cursor: usize = 0;
    var recalled: ?usize = null;
    var dirty = false;

    while (true) {
        const key = try ed.nextKey();
        // The width is read again for every input, including the timeout that
        // reports `.none`, so a resize is picked up without a signal handler.
        // A change only asks for a repaint: the redraw below knows to measure
        // the region it is about to erase at the new width.
        ed.width = ed.terminalWidth();
        if (ed.width != ed.painted_width) {
            content_width = ed.contentWidth(visibleWidth(prompt));
            dirty = true;
        }
        // A run of up/down presses aims for one column; any other key ends it.
        // Timeouts report `.none` and must not break the run.
        switch (key) {
            .up, .down, .none => {},
            else => ed.goal_col = null,
        }
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
                // The whole prompt is erased, and no newline is written: the
                // caller prints the prompt's own block in its place, and that
                // block ends the line.
                try ed.endPrompt(header);
                // An empty line says nothing, so the row the prompt stood on is
                // given back too and the next prompt draws over the same place,
                // rather than leaving a blank line behind.
                if (line.items.len == 0) try ed.out.print("\x1b[1A", .{});
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
                if (moveCursorVertical(&ed.goal_col, line.items, content_width, &cursor, -1)) {
                    dirty = true;
                } else if (try ed.recall(&line, &cursor, &recalled, -1)) {
                    dirty = true;
                }
            },
            .down => {
                if (moveCursorVertical(&ed.goal_col, line.items, content_width, &cursor, 1)) {
                    dirty = true;
                } else if (try ed.recall(&line, &cursor, &recalled, 1)) {
                    dirty = true;
                }
            },
            .interrupt => {
                // The abandoned line is dropped, header and all, and so is a
                // paste that was still arriving.
                ed.pasting = false;
                ed.paste_cr = false;
                try ed.endPrompt(header);
                try ed.out.writeAll("\x1b[K^C\r\n");
                // The user is still at a prompt, so show the header again;
                // the redraw below repaints the prompt under it.
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
                _ = line.orderedRemove(cursor);
                recalled = null;
                dirty = true;
            },
        }
        // Redraw only once the typed-ahead bytes are consumed, so pasting a
        // long line does not repaint the terminal for every byte.
        if (dirty and ed.drained()) {
            try ed.redraw(prompt, content_width, line.items, cursor);
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

/// Repaints the prompt and the current line. The line may contain embedded
/// newlines (from Shift+Enter) and may be wider than the terminal, in which
/// case it is folded into further rows here rather than left to the terminal.
/// Folding it ourselves is what keeps the row count and the cursor position
/// exact, since a row the terminal folded behind our back would be neither
/// erased nor counted. The whole region is erased and rewritten so that edits
/// on any row are reflected.
fn redraw(
    ed: *LineEditor,
    prompt: []const u8,
    content_width: usize,
    line: []const u8,
    cursor: usize,
) !void {
    // Continuation rows are indented to line up under the first row, so the
    // prompt and the indent are the same width and every row holds the same
    // number of columns of text.
    const prompt_width = visibleWidth(prompt);
    var spaces: [max_indent]u8 = @splat(' ');
    const indent = spaces[0..@min(prompt_width, spaces.len)];

    // Locate the cursor and count the terminal rows the new render needs.
    const rows = rowCount(line, content_width);
    const at = rowAt(line, content_width, cursor);
    const cursor_col = prompt_width + columns(line[at.start..cursor]);

    // After a resize the terminal has reflowed the rows on screen, so they
    // are no longer the rows the last paint laid out. Erasing what is there
    // now is what clears the region; erasing the old layout would leave the
    // parts a fold moved behind. Every other redraw keeps the layout it
    // painted and erases that.
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

    // Paint the prompt and the content, folding a row as soon as it is full.
    var row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        var pos = start;
        while (true) {
            if (row > 0) try ed.out.writeAll("\r\n");
            try ed.out.writeAll(if (row == 0) prompt else indent);
            const from = pos;
            var filled: usize = 0;
            while (filled < content_width and pos < end) {
                if (!isContinuation(line[pos])) filled += 1;
                pos += 1;
            }
            // A fold never cuts a character in half.
            while (pos < end and isContinuation(line[pos])) pos += 1;
            try ed.out.writeAll(line[from..pos]);
            row += 1;
            if (pos >= end) break;
        }
        if (newline == null) break;
        start = end + 1;
    }

    // The prompt is the last thing on the screen, so every row below it is
    // stale and can be cleared. A resize is what leaves such rows: the
    // terminal reflows what it was showing, which is not always what was
    // just painted, and can end up with more rows than this render has. The
    // cursor is at the end of the region here, so this clears exactly the
    // space under it.
    try ed.out.writeAll("\x1b[J");

    // Move from the end of the render back to the cursor.
    const up = rows - 1 - at.index;
    if (up > 0) try ed.out.print("\x1b[{d}A", .{up});
    try ed.out.writeAll("\r");
    if (cursor_col > 0) try ed.out.print("\x1b[{d}C", .{cursor_col});

    ed.last_rows = rows;
    ed.last_cursor_row = at.index;
    ed.painted_width = ed.width;
    try ed.out.flush();
}

/// Ends the editable line by erasing the whole region it painted. The header
/// and the line typed under it are both deleted, and the cursor is left at the
/// start of the first row they occupied, so the caller prints the prompt in
/// their place. What the region held is the editing of the line, not what was
/// said, so none of it is left behind.
fn endPrompt(ed: *LineEditor, header: []const u8) !void {
    // The header sits directly above the prompt region and may itself span
    // several rows on a narrow terminal, so both it and the line are deleted,
    // moving the cursor up into the space they held. The cursor starts within
    // the line, so the walk up is past its own row and then the header's.
    const header_rows = ed.headerRows(header);
    const deleted = header_rows + ed.last_rows;
    if (deleted == 0) return;
    const up = ed.last_cursor_row + header_rows;
    if (up > 0) try ed.out.print("\x1b[{d}A", .{up});
    try ed.out.writeAll("\r");
    try ed.out.print("\x1b[{d}M", .{deleted});
    try ed.out.writeAll("\r");
}

/// The terminal width in columns, asked of whichever standard stream is a
/// terminal. Zero when none of them is, which leaves the line unwrapped
/// rather than folded against a guessed width. The input terminal is among
/// the candidates, and it is a terminal whenever a line is being edited, so
/// in practice the width is known whenever it is wanted.
fn terminalWidth(ed: *LineEditor) usize {
    for ([_]Io.File{ Io.File.stdout(), Io.File.stdin(), Io.File.stderr() }) |file| {
        if (ed.widthOf(file)) |width| return width;
    }
    return 0;
}

/// The columns `file` is, or null when it is not a terminal or its size
/// cannot be read.
fn widthOf(ed: *LineEditor, file: Io.File) ?usize {
    const tty = file.isTty(ed.io) catch return null;
    if (!tty) return null;
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = ed.io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return null;
    if (result.device_io_control < 0) return null;
    if (size.col == 0) return null;
    return size.col;
}

/// Columns of text available on a row once the prompt is taken off, which is
/// where the line is folded. The terminal is too narrow to fold against when
/// it cannot hold the prompt, so the line is left alone then.
fn contentWidth(ed: *const LineEditor, prompt_width: usize) usize {
    return contentWidthFor(ed.width, prompt_width);
}

/// Rows the header takes on the terminal. Unlike the line it is written
/// unindented, so it folds at the full width.
fn headerRows(ed: *const LineEditor, header: []const u8) usize {
    if (header.len == 0) return 0;
    const columns_wide = visibleWidth(header);
    if (ed.width == 0 or columns_wide == 0) return 1;
    return (columns_wide + ed.width - 1) / ed.width;
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
        // A newline from the keyboard submits the line; a newline the user
        // pasted is a line break in it, like Shift+Enter.
        if (!ed.pasting) return .enter;
        if (byte == '\n' and ed.paste_cr) {
            // The LF half of a `\r\n` whose CR already opened the line.
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
        else => if (byte >= 0x20) .{ .byte = byte } else .none,
    };
}

/// Decodes the `CSI`/`SS3` sequences for the arrow and navigation keys, as
/// well as the encodings terminals use for Shift+Enter and the markers that
/// bracket a paste.
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
        if (byte >= 0x40 and byte <= 0x7e) {
            // `ESC[200~` opens a paste and `ESC[201~` closes it. Both are the
            // terminal talking, not the user, so neither is a key of its own.
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

/// The reflowed geometry of a line: how many rows the region the terminal shows
/// now needs, and which of them the cursor is on.
const Reflow = struct { rows: usize, cursor_row: usize };

/// The columns of text a row holds once the prompt is off, for terminal width
/// `width`. A terminal too narrow to hold the prompt leaves the line unfolded.
fn contentWidthFor(width: usize, prompt_width: usize) usize {
    if (width == 0 or width <= prompt_width) return no_wrap;
    if (prompt_width > max_indent) return no_wrap;
    return width - prompt_width;
}

/// How the region is laid out after the terminal is resized. A terminal reflows
/// by wrapping each row already on screen at the new width, and those rows were
/// the folds of `line` at `old_content` columns, so the region after a resize is
/// those same folds wrapped again, not the line folded for the new width. That
/// gap is why the erase has to be measured here after a resize and at the
/// painted width otherwise. Every painted row is `prompt_width` columns of
/// prompt or indent followed by its text, so a fold of `n` columns is a row of
/// `prompt_width + n` columns and wraps into `ceil((prompt_width + n) / width)`.
fn reflowed(line: []const u8, prompt_width: usize, old_content: usize, width: usize, cursor: usize) Reflow {
    const old_at = rowAt(line, old_content, cursor);
    const cursor_col = prompt_width + columns(line[old_at.start..cursor]);

    var rows: usize = 0;
    var cursor_row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        var pos = start;
        while (true) {
            const from = pos;
            var filled: usize = 0;
            while (filled < old_content and pos < end) {
                if (!isContinuation(line[pos])) filled += 1;
                pos += 1;
            }
            while (pos < end and isContinuation(line[pos])) pos += 1;
            const wrapped = rowsFor(prompt_width + columns(line[from..pos]), width);
            if (from == old_at.start) {
                // The cursor is on this painted row; it wrapped `cursor_col` in.
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

/// A visual row of the rendered line: a run of the line that fits on one
/// terminal row, `start..end` in bytes, on row `index` counted from the first.
const Row = struct { index: usize, start: usize, end: usize };

/// Moves `cursor` to the same column on the row above (negative `direction`) or
/// below, where a row is a visual row: a line wider than the terminal has
/// several of them. `goal_col` remembers the column across a run of presses so
/// crossing a short row does not lose it. Returns whether the cursor moved; it
/// does not when there is no row in that direction.
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

/// The row `cursor` falls in. A cursor on the fold between two rows belongs to
/// the later one, so that it points at the character it comes before; at the end
/// of a source row it stays on the last row, which is where the next character
/// will go.
fn rowAt(line: []const u8, content_width: usize, cursor: usize) Row {
    var index: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, line, start, '\n');
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

/// The row `index`, counted from the first.
fn rowRange(line: []const u8, content_width: usize, index: usize) struct { start: usize, end: usize } {
    var row: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, line, start, '\n');
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

/// Number of terminal rows `line` needs, folds and newlines alike.
fn rowCount(line: []const u8, content_width: usize) usize {
    var rows: usize = 0;
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, line, start, '\n');
        const end = newline orelse line.len;
        rows += rowsFor(columns(line[start..end]), content_width);
        if (newline == null) return rows;
        start = end + 1;
    }
}

/// Rows `cols` columns need. A row that fills the width exactly does not open
/// another one, since a terminal only folds once the next character arrives; an
/// empty row takes one.
fn rowsFor(cols: usize, content_width: usize) usize {
    if (cols <= content_width) return 1;
    return (cols + content_width - 1) / content_width;
}

/// Whether `byte` continues a multi-byte character, and so takes no column of
/// its own.
fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Columns `text` takes on the terminal: one per character. A double-width
/// character counts as one too, so a line of them is folded a little wide;
/// everything the prompt and the header are made of is one column.
fn columns(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (!isContinuation(byte)) count += 1;
    }
    return count;
}

/// Byte offset of the character `count` characters into `text`, clamped to its
/// end, so that a slice never splits a character.
fn columnOffset(text: []const u8, count: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len and seen < count) : (i += 1) {
        if (!isContinuation(text[i])) seen += 1;
    }
    while (i < text.len and isContinuation(text[i])) i += 1;
    return i;
}

/// Number of terminal columns `text` occupies: one per character, ignoring ANSI
/// escape sequences and the continuation bytes of multi-byte characters.
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
        if (!isContinuation(text[i])) width += 1;
        i += 1;
    }
    return width;
}

test "wordStart skips trailing whitespace then the word" {
    try std.testing.expectEqual(0, wordStart("hello", 5));
    try std.testing.expectEqual(0, wordStart("hello  ", 7));
    try std.testing.expectEqual(6, wordStart("hello world", 11));
    try std.testing.expectEqual(6, wordStart("hello world", 9));
    // At the start of "world" the whitespace and the word before it are removed.
    try std.testing.expectEqual(0, wordStart("hello world", 6));
    try std.testing.expectEqual(4, wordStart("one two", 7));
    try std.testing.expectEqual(0, wordStart("", 0));
}

/// Decodes `bytes` into the keys the editor would read from them, with no
/// terminal behind it: one character per key, a typed byte as itself, a line
/// break as `\n`, a submit as `E`, a key with no effect as `.` and any other key
/// as `?`. `std.testing.allocator` owns the result. The bytes go in the read
/// buffer, which the decoder drains before it would ask a terminal for more.
fn decodeKeys(bytes: []const u8) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var ed = LineEditor.init(std.testing.io, &sink.writer, std.testing.allocator);

    @memcpy(ed.in_buf[0..bytes.len], bytes);
    ed.in_pos = 0;
    ed.in_len = bytes.len;
    var keys: std.ArrayList(u8) = .empty;
    while (ed.in_pos < ed.in_len) {
        try keys.append(std.testing.allocator, switch (try ed.nextKey()) {
            .byte => |b| b,
            .newline => '\n',
            .enter => 'E',
            .none => '.',
            else => '?',
        });
    }
    return keys.toOwnedSlice(std.testing.allocator);
}

test "a newline in a paste is a line break and only enter submits" {
    // Text pasted between the markers: its newlines break the line, and the
    // carriage return typed after the paste is what submits it. The end marker is
    // what makes that carriage return a submit, so the markers left no trace.
    const keys = try decodeKeys("\x1b[200~one\ntwo\x1b[201~more\r");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings(".one\ntwo.moreE", keys);
}

test "a carriage return from the keyboard still submits outside a paste" {
    // Typing a line and pressing enter, and the same with a line feed, both
    // submit: neither is inside a paste.
    const keys = try decodeKeys("hi\rhi\n");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("hiEhiE", keys);
}

test "a CRLF in a paste opens a single line, not one and a blank" {
    // The CR opens the line and the LF that follows it is the same line ending,
    // so the CRLF pair is one break, not two.
    const keys = try decodeKeys("\x1b[200~a\r\nb\x1b[201~");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings(".a\n.b.", keys);
}

test "a shifted enter and the arrow keys still decode" {
    // Shift+Enter is a line break outside a paste, as before, and an arrow key is
    // its own key rather than the digits of its escape sequence.
    const keys = try decodeKeys("a\x1b[13;2ub\x1b[Du\r");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("a\nb?uE", keys);
}

test "visibleWidth ignores ANSI escapes" {
    try std.testing.expectEqual(2, visibleWidth("> "));
    try std.testing.expectEqual(0, visibleWidth("\x1b[31m\x1b[0m"));
    try std.testing.expectEqual(5, visibleWidth("\x1b[1mbilly\x1b[0m"));
    // A multi-byte character is one column, not one per byte. The header uses
    // the middle dot between its parts, so this is the width it is measured by.
    try std.testing.expectEqual(1, visibleWidth("·"));
    try std.testing.expectEqual(3, visibleWidth("a·b"));
}

test "endPrompt erases the header and the line it heads" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ed = LineEditor.init(std.testing.io, &out.writer, gpa);

    // One row of input: up to the header, delete it and the line, back to column
    // zero where the prompt's own block is printed.
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.endPrompt("billy · m · /w");
    try std.testing.expectEqualStrings("\x1b[1A\r\x1b[2M\r", out.written());
    out.clearRetainingCapacity();

    // Three rows of input with the cursor on the last: the whole region is taken
    // back, five rows counting the header, from the cursor up to the top.
    ed.last_rows = 3;
    ed.last_cursor_row = 2;
    try ed.endPrompt("billy · m · /w");
    try std.testing.expectEqualStrings("\x1b[3A\r\x1b[4M\r", out.written());
    out.clearRetainingCapacity();

    // A header wider than the terminal folds, so its rows count too; the ten
    // column terminal folds the 16 column header in two, and both are erased
    // along with the line below them.
    ed.width = 10;
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.endPrompt("billy · m · /work");
    try std.testing.expectEqualStrings("\x1b[2A\r\x1b[3M\r", out.written());
    out.clearRetainingCapacity();
    ed.width = 0;

    // Without a header only the line is erased.
    ed.last_rows = 3;
    ed.last_cursor_row = 1;
    try ed.endPrompt("");
    try std.testing.expectEqualStrings("\x1b[1A\r\x1b[3M\r", out.written());
    out.clearRetainingCapacity();

    // Nothing painted, nothing to erase.
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
    // The cursor after the newline is on the empty row; the one before it is at
    // the end of the row that came first.
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

    // A cursor on the fold points at the character after it.
    try std.testing.expectEqual(1, rowAt(line, 10, 10).index);
    try std.testing.expectEqual(10, rowAt(line, 10, 10).start);
    // One at the very end has no row after it to move to, so it stays put.
    try std.testing.expectEqual(2, rowAt(line, 10, 26).index);

    // A row that fills the width exactly does not open another one.
    try std.testing.expectEqual(2, rowCount("z" ** 20, 10));
    try std.testing.expectEqual(1, rowAt("z" ** 20, 10, 20).index);
}

test "folding repeats within every source row" {
    // A newline starts a new row even when the row before it happened to fold.
    const line = "abcd\nefghij";
    try std.testing.expectEqual(3, rowCount(line, 4));
    try std.testing.expectEqual(1, rowAt(line, 4, 5).index); // just past the newline
    try std.testing.expectEqual(5, rowAt(line, 4, 5).start);
    try std.testing.expectEqual(2, rowAt(line, 4, 11).index); // the tail of the fold
}

test "a multi-byte character is never cut by a fold" {
    // Two characters per row: the middle dot is two bytes but one column.
    const line = "a·b·c·d";
    try std.testing.expectEqual(4, rowCount(line, 2));
    try std.testing.expectEqual(0, rowRange(line, 2, 0).start);
    try std.testing.expectEqual(3, rowRange(line, 2, 0).end); // "a·", whole
    try std.testing.expectEqual(3, rowRange(line, 2, 1).start);
    try std.testing.expectEqual(6, rowRange(line, 2, 1).end); // "b·"
    // The cursor between the dot and the following character is on the next row.
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

    // Four columns of text per row, which is a six column terminal for "> ".
    try ed.redraw("> ", 4, "abcdefgh", 8);
    try std.testing.expectEqualStrings(
        "\r\x1b[K" ++ // nothing painted yet: clear the line the prompt is on
            "> abcd" ++
            "\r\n  efgh" ++
            "\x1b[J" ++ // clear whatever is under the prompt
            "\r\x1b[6C", // the cursor at the end of the second row
        out.written(),
    );
    // Both rows are remembered, so the next redraw can erase them.
    try std.testing.expectEqual(2, ed.last_rows);
    try std.testing.expectEqual(1, ed.last_cursor_row);

    // Three rows now: up one, erase both old rows, and paint the three.
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

    const line = "abcdefghijklmnopqrstuvwxyz0123456789"; // 36 characters
    // One row at 78 columns wide was painted, and the cursor is on it.
    ed.width = 78;
    ed.painted_width = 78;
    ed.last_rows = 1;
    ed.last_cursor_row = 0;
    try ed.redraw("> ", 76, line, 36);
    // The old row is erased and the line repainted on one row, cursor at its end.
    try std.testing.expectEqualStrings(
        "\r\x1b[K\r" ++
            "> abcdefghijklmnopqrstuvwxyz0123456789" ++
            "\x1b[J" ++
            "\r\x1b[38C",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The terminal is resized to 20 columns. Its reflow makes the painted row two
    // rows, so the erase has to measure the region at that width; erasing the one
    // row of the old geometry would leave the folded remainder behind.
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
    // 62 characters, folded into two rows of 38 and 24 at the old width.
    const line = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const prompt_width = 2;
    // Shrunk to 24 columns: each painted row, being 40 and 26 columns with the
    // prompt, wraps into two, so the region is four rows and the cursor, at the
    // end, is on the last of them.
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, prompt_width, 38, 24, line.len));
    // Grown to 60: each painted row still fits, so they stay as they were.
    try std.testing.expectEqual(Reflow{ .rows = 2, .cursor_row = 1 }, reflowed(line, prompt_width, 38, 60, line.len));
    // The same line folded at 22 columns makes three painted rows.
    try std.testing.expectEqual(Reflow{ .rows = 3, .cursor_row = 2 }, reflowed(line, prompt_width, 22, 60, line.len));
}

test "reflowed keeps the cursor on the painted row it was on" {
    // "abcd\nefgh" at four columns is two painted rows, each "  abcd" wide once
    // the two column prompt is on. At four columns of terminal each of those
    // wraps into two rows, so the region is four rows with the cursor at its end.
    const line = "abcd\nefgh";
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, 2, 4, 4, line.len));
    // A cursor two characters into the last painted row lands one row down, in
    // the row the wrap made of it.
    try std.testing.expectEqual(Reflow{ .rows = 4, .cursor_row = 3 }, reflowed(line, 2, 4, 4, 7));
}
