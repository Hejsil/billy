//! How wide text is on a terminal, how long its characters are, and how it is broken to fit.

const std = @import("std");

/// Where the width billy lays a block out at comes from.
pub const Source = union(enum) {
    /// A terminal, asked each time because it can be resized while a run is going on.
    terminal: std.Io,
    /// Columns that do not change: a stream that is not a terminal, or a test's.
    fixed: usize,

    pub fn columns(source: Source) usize {
        return switch (source) {
            .terminal => |io| terminal(io),
            .fixed => |width| width,
        };
    }
};

/// The width of the terminal, in columns, or zero when there is no terminal to ask.
pub fn terminal(io: std.Io) usize {
    for ([_]std.Io.File{ std.Io.File.stdout(), std.Io.File.stdin(), std.Io.File.stderr() }) |file| {
        if (ofTty(io, file)) |width| return width;
    }
    return 0;
}

fn ofTty(io: std.Io, file: std.Io.File) ?usize {
    const tty = file.isTty(io) catch return null;
    if (!tty) return null;
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return null;
    if (result.device_io_control < 0) return null;
    if (size.col == 0) return null;
    return size.col;
}

/// What a piece of text took of the screen, which is what has to be taken back to write it again.
pub const Laid = struct {
    /// The rows the cursor moved down, which is how far up it has to go back to the start.
    rows: usize = 0,
};

/// Writes `text` with its lines broken to `width` columns, so that billy knows what it takes of the
/// screen; only the columns a terminal shows are counted, and an escape is never broken by a break.
pub fn wrap(text: []const u8, out: *std.Io.Writer, width: usize) !Laid {
    var laid: Laid = .{};
    var rest = text;
    while (rest.len > 0) {
        const cut = std.mem.findScalar(u8, rest, '\n');
        const line = if (cut) |at| rest[0..at] else rest;
        laid.rows += try broken(line, out, width);
        if (cut) |at| {
            try out.writeAll("\n");
            laid.rows += 1;
            rest = rest[at + 1 ..];
            continue;
        }
        return laid;
    }
    return laid;
}

/// The rows `text` takes in `width` columns: what `wrap` counts, without writing any of it.
pub fn rows(text: []const u8, width: usize) !usize {
    var discard: std.Io.Writer.Discarding = .init("");
    return (try wrap(text, &discard.writer, width)).rows;
}

fn broken(line: []const u8, out: *std.Io.Writer, width: usize) !usize {
    var breaks: usize = 0;
    var rest = line;
    while (width > 0 and columns(rest) > width) {
        // A character wider than the line is a line of its own, so that a break always takes one.
        var at = breakAt(rest, width);
        if (at == 0) at = if (escaped(rest, 0)) |len| len else charLen(rest);
        try out.writeAll(rest[0..at]);
        try out.writeAll("\n");
        breaks += 1;
        rest = rest[at..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    }
    try out.writeAll(rest);
    return breaks;
}

/// Where a line is broken: after the last space before `width`, or at the column if no space fits.
fn breakAt(line: []const u8, width: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    var space: ?usize = null;
    while (i < line.len) {
        if (escaped(line, i)) |len| {
            i += len;
            continue;
        }
        const length = charLen(line[i..]);
        if (seen + charWidth(line[i..]) > width) break;
        seen += charWidth(line[i..]);
        i += length;
        if (line[i - 1] == ' ' or line[i - 1] == '\t') space = i - 1;
    }
    return space orelse i;
}

/// Columns `text` takes on a terminal: none for a control, or a codepoint that only extends
/// another, or an ANSI escape; two for a wide character; one otherwise.
pub fn columns(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (escaped(text, i)) |len| {
            i += len;
            continue;
        }
        width += charWidth(text[i..]);
        i += charLen(text[i..]);
    }
    return width;
}

/// Byte offset of the column `count` columns into `text`, clamped to its end: the walk `columns`
/// takes, stopped once `count` columns are behind it.
pub fn columnOffset(text: []const u8, count: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < text.len and seen < count) {
        if (escaped(text, i)) |len| {
            i += len;
            continue;
        }
        seen += charWidth(text[i..]);
        i += charLen(text[i..]);
    }
    return i;
}

/// Bytes the character at the start of `text` takes, at least one; zero only for empty text.
pub fn charLen(text: []const u8) usize {
    const base = decode(text);
    if (base.len == 0) return 0;
    var len = base.len;
    var regional = isRegional(base.cp);
    while (len < text.len) {
        const next = decode(text[len..]);
        if (isJoiner(next.cp)) {
            if (len + next.len >= text.len) break;
            len += next.len + decode(text[len + next.len ..]).len;
        } else if (extends(next.cp)) {
            len += next.len;
        } else if (regional and isRegional(next.cp)) {
            regional = false;
            len += next.len;
        } else break;
    }
    return len;
}

/// Bytes the character at the end of `text` takes, at least one; zero only for empty text.
pub fn prevLen(text: []const u8) usize {
    if (text.len == 0) return 0;
    var end = text.len;
    var last = decodeBack(text, end);
    var len = last.len;
    end -= last.len;
    while (end > 0) {
        const before = decodeBack(text, end);
        if (before.len == 0) break;
        if (isJoiner(before.cp)) {
            len += before.len;
            end -= before.len;
            last = decodeBack(text, end);
            len += last.len;
            end -= last.len;
        } else if (extends(last.cp)) {
            len += before.len;
            end -= before.len;
            last = before;
        } else if (isRegional(last.cp) and isRegional(before.cp)) {
            len += before.len;
            end -= before.len;
            break;
        } else break;
    }
    return len;
}

fn charWidth(text: []const u8) usize {
    const cp = decode(text).cp;
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (extends(cp) or isJoiner(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn escaped(text: []const u8, i: usize) ?usize {
    if (text[i] != 0x1b or i + 1 >= text.len or text[i + 1] != '[') return null;
    var j = i + 2;
    while (j < text.len) : (j += 1) {
        if (text[j] >= 0x40 and text[j] <= 0x7e) return j + 1 - i;
    }
    return text.len - i;
}

const Codepoint = struct { cp: u21, len: usize };

fn decode(text: []const u8) Codepoint {
    if (text.len == 0) return .{ .cp = 0, .len = 0 };
    const len = @min(std.unicode.utf8ByteSequenceLength(text[0]) catch 1, text.len);
    // Decoding a codepoint of known width has no replacement yet, and std calls `utf8Decode` itself
    // still: ziglang/zig#23096. The suppressions find these places again when that API lands.
    // zlinter-disable-next-line no_deprecated - std has no replacement yet
    const cp = std.unicode.utf8Decode(text[0..len]) catch return .{ .cp = text[0], .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn decodeBack(text: []const u8, end: usize) Codepoint {
    if (end == 0) return .{ .cp = 0, .len = 0 };
    var start = end - 1;
    while (start > 0 and end - start < 4 and isContinuation(text[start])) start -= 1;
    const len = end - start;
    // zlinter-disable-next-line no_deprecated - std has no replacement yet
    const cp = std.unicode.utf8Decode(text[start..end]) catch text[start];
    return .{ .cp = cp, .len = len };
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn extends(cp: u21) bool {
    return cp == 0xfe0e or cp == 0xfe0f or
        (cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0x1f3fb and cp <= 0x1f3ff);
}

fn isJoiner(cp: u21) bool {
    return cp == 0x200d;
}

fn isRegional(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

fn isWide(cp: u21) bool {
    return cp >= 0x1100 and (cp <= 0x115f or
        cp == 0x2329 or cp == 0x232a or
        (cp >= 0x231a and cp <= 0x231b) or
        (cp >= 0x23e9 and cp <= 0x23f3) or
        (cp >= 0x23f8 and cp <= 0x23fa) or
        (cp >= 0x25aa and cp <= 0x25ab) or
        (cp >= 0x25b6 and cp <= 0x25c0) or
        (cp >= 0x25fb and cp <= 0x25fe) or
        (cp >= 0x2600 and cp <= 0x26ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x2934 and cp <= 0x2935) or
        (cp >= 0x2b05 and cp <= 0x2b07) or
        (cp >= 0x2b1b and cp <= 0x2b1c) or
        cp == 0x2b50 or cp == 0x2b55 or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe1f) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f1e6 and cp <= 0x1f1ff) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f680 and cp <= 0x1f6ff) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x1fa00 and cp <= 0x1faff) or
        (cp >= 0x20000 and cp <= 0x2ffff));
}

test "a column is a character, and malformed text counts bytes" {
    try std.testing.expectEqual(0, columns(""));
    try std.testing.expectEqual(4, columns("a\u{e9}\u{20ac}b"));
    try std.testing.expectEqual(2, columns("\xff\xff"));
}

test "a wide character is two columns, a narrow one is one" {
    try std.testing.expectEqual(2, columns("漢"));
    try std.testing.expectEqual(4, columns("漢字"));
    try std.testing.expectEqual(2, columns("\u{1f600}"));
    try std.testing.expectEqual(3, columns("a漢"));
    try std.testing.expectEqual(2, columns("\u{3042}"));
    try std.testing.expectEqual(2, columns("\u{ff21}"));
    try std.testing.expectEqual(1, columns("·"));
}

test "an ANSI escape takes no column" {
    try std.testing.expectEqual(0, columns("\x1b[31m\x1b[0m"));
    try std.testing.expectEqual(5, columns("\x1b[1mbilly\x1b[0m"));
}

test "columnOffset is the inverse of columns" {
    const cases = [_][]const u8{
        "",
        "abc",
        "a漢b",
        "\u{1f600}x",
        "e\u{0301}x",
        "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}!",
        "a\u{1f44d}\u{1f3fd}b",
        "\x1b[1mbilly\x1b[0m",
        "\x1b[31m漢\x1b[0m",
    };
    for (cases) |text| {
        try std.testing.expectEqual(@as(usize, 0), columnOffset(text, 0));
        try std.testing.expectEqual(text.len, columnOffset(text, columns(text) + 1));

        var i: usize = 0;
        var col: usize = 0;
        while (i < text.len) {
            if (escaped(text, i)) |len| {
                i += len;
                continue;
            }
            const next = i + charLen(text[i..]);
            const width = charWidth(text[i..]);
            var c = col + 1;
            while (c <= col + width) : (c += 1) {
                try std.testing.expectEqual(next, columnOffset(text, c));
            }
            i = next;
            col += width;
        }
        try std.testing.expectEqual(col, columns(text));
    }
}

test "a character is a grapheme cluster, not a codepoint" {
    try std.testing.expectEqual(1, columns("e\u{0301}"));
    try std.testing.expectEqual("e\u{0301}".len, charLen("e\u{0301}x"));
    try std.testing.expectEqual(2, columns("\u{1f44d}\u{1f3fd}"));
    try std.testing.expectEqualStrings("\u{1f44d}\u{1f3fd}", "\u{1f44d}\u{1f3fd}"[0..charLen("\u{1f44d}\u{1f3fd}")]);
    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try std.testing.expectEqual(family.len, charLen(family ++ "x"));
    try std.testing.expectEqual(2, columns(family));
    const flag = "\u{1f1ee}\u{1f1f9}";
    try std.testing.expectEqual(flag.len, charLen(flag ++ "x"));
}

test "stepping back is the mirror of stepping forward" {
    const cases = [_][]const u8{
        "a",
        "\u{e9}",
        "漢字",
        "\u{1f600}\u{1f44d}",
        "e\u{0301}x",
        "\u{1f44d}\u{1f3fd}!",
        "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}",
        "\u{1f1ee}\u{1f1f9}",
        "a漢\u{1f600}",
    };
    for (cases) |text| {
        var i: usize = 0;
        while (i < text.len) {
            const forward = i + charLen(text[i..]);
            try std.testing.expectEqual(i, forward - prevLen(text[0..forward]));
            i = forward;
        }
        try std.testing.expectEqual(text.len, i);
    }
}

fn expectWrapped(expected: []const u8, text: []const u8, width: usize) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const laid = try wrap(text, &out.writer, width);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(std.mem.count(u8, expected, "\n"), laid.rows);
    try std.testing.expectEqual(laid.rows, try rows(text, width));
}

test "a line that fits is written as it stands" {
    try expectWrapped("hello", "hello", 20);
    try expectWrapped("one\ntwo", "one\ntwo", 3);
    try expectWrapped("", "", 20);
}

test "a line that does not fit is broken at its last space" {
    try expectWrapped("one two\nthree", "one two three", 8);
    try expectWrapped("one\ntwo\nthr\nee", "one two three", 3);
    try expectWrapped("one two", "one two", 0);
}

test "a word wider than the line is broken at the column" {
    try expectWrapped("abcde\nfghij", "abcdefghij", 5);
}

test "an escape is not counted, and is never broken by a break" {
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";
    const expected = bold ++ "one two\nthree" ++ reset;
    try expectWrapped(expected, bold ++ "one two three" ++ reset, 8);
}

test "a break does not split a wide character" {
    try expectWrapped("\u{4e2d}\n\u{4e2d}\n", "\u{4e2d}\u{4e2d}", 1);
}
