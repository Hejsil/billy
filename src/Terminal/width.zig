//! How wide text is on a terminal, and how long its characters are.

const std = @import("std");

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
    // Decoding the codepoint a sequence of known width spells has no replacement yet:
    // ziglang/zig#23096 leaves `utf8Decode` alone because it "needs a new API first",
    // and std still calls it itself. The suppression is what finds these two places
    // again when that API lands.
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
