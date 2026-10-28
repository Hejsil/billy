//! Where the blocks of a run go, and where the escape codes billy writes for decoration are named:
//! a style around the writer the text goes to.

const std = @import("std");

const Writer = @This();

/// What a terminal takes of the decoration billy writes: nothing, or the escape codes every
/// terminal understands.
pub const Style = enum {
    plain,
    ansi,

    pub fn detect(io: std.Io, file: std.Io.File) Style {
        const supported = file.supportsAnsiEscapeCodes(io) catch return .plain;
        return if (supported) .ansi else .plain;
    }
};

pub const Color = enum(u8) {
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
};

style: Style = .plain,
out: *std.Io.Writer,

pub fn detect(file_writer: *std.Io.File.Writer) Writer {
    return .{
        .style = Style.detect(file_writer.io, file_writer.file),
        .out = &file_writer.interface,
    };
}

pub fn write(writer: Writer, text: []const u8) !void {
    try writer.out.writeAll(text);
}

pub fn print(writer: Writer, comptime format: []const u8, args: anytype) !void {
    try writer.out.print(format, args);
}

pub fn flush(writer: Writer) !void {
    try writer.out.flush();
}

pub fn bold(writer: Writer) []const u8 {
    return writer.code("1");
}

pub fn dim(writer: Writer) []const u8 {
    return writer.code("2");
}

pub fn italic(writer: Writer) []const u8 {
    return writer.code("3");
}

pub fn strike(writer: Writer) []const u8 {
    return writer.code("9");
}

pub fn color(writer: Writer, hue: Color) []const u8 {
    return writer.hueCode(hue, .plain);
}

pub fn boldColor(writer: Writer, hue: Color) []const u8 {
    return writer.hueCode(hue, .bold);
}

pub fn reset(writer: Writer) []const u8 {
    return writer.code("0");
}

pub fn linkOpen(writer: Writer) []const u8 {
    return switch (writer.style) {
        .plain => "",
        .ansi => "\x1b]8;;",
    };
}

pub fn linkClose(writer: Writer) []const u8 {
    return switch (writer.style) {
        .plain => "",
        .ansi => "\x1b\\",
    };
}

fn code(writer: Writer, comptime codes: []const u8) []const u8 {
    return switch (writer.style) {
        .plain => "",
        .ansi => "\x1b[" ++ codes ++ "m",
    };
}

const Weight = enum { plain, bold };

fn hueCode(writer: Writer, hue: Color, comptime weight: Weight) []const u8 {
    if (writer.style == .plain) return "";
    return switch (hue) {
        inline else => |known| comptime std.fmt.comptimePrint("\x1b[" ++ (if (weight == .bold) "1;" else "") ++ "{d}m", .{@backingInt(known)}),
    };
}

fn writeText(writer: Writer, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(bytes[at]) catch {
            at += 1;
            continue;
        };
        if (at + len > bytes.len) break;
        // zlinter-disable-next-line no_deprecated - std has no replacement yet
        const codepoint = std.unicode.utf8Decode(bytes[at..][0..len]) catch {
            at += 1;
            continue;
        };
        at += len;
        if (control(codepoint)) continue;
        try writer.write(bytes[at - len .. at]);
    }
}

fn control(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

/// The mark a block header opens with: a glyph and the colour it is shown in, so a block is
/// recognisable from its first character.
pub const Mark = struct {
    glyph: []const u8,
    hue: Color,

    pub fn header(mark: Mark, name: []const u8, target: []const u8, writer: Writer) !void {
        try writer.print("{s}{s}{s} {s}", .{
            writer.color(mark.hue), mark.glyph, writer.reset(), writer.bold(),
        });
        try writer.writeText(name);
        try writer.write(writer.reset());
        if (target.len > 0) {
            try writer.write(" ");
            try writer.write(writer.dim());
            try writer.writeText(target);
            try writer.write(writer.reset());
        }
        try writer.write("\n");
    }
};

test "a plain writer names no decoration, so the text is the same without them" {
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).bold());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).dim());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).italic());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).strike());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).color(.red));
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).boldColor(.red));
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).reset());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).linkOpen());
    try std.testing.expectEqualStrings("", (Writer{ .out = undefined }).linkClose());
}

test "an ansi writer names each decoration, and the text it prints is unchanged" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const ansi: Writer = .{ .style = .ansi, .out = &out.writer };
    try ansi.print("{s}bold{s} {s}red{s} {s}loud red{s}", .{
        ansi.bold(),          ansi.reset(),
        ansi.color(.red),     ansi.reset(),
        ansi.boldColor(.red), ansi.reset(),
    });
    try std.testing.expectEqualStrings(
        "\x1b[1mbold\x1b[0m \x1b[31mred\x1b[0m \x1b[1;31mloud red\x1b[0m",
        out.written(),
    );
}

test "a block header is the same text in either style" {
    const mark: Mark = .{ .glyph = "▸", .hue = .blue };

    var plain_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain_out.deinit();
    try mark.header("read", "a.zig", .{ .out = &plain_out.writer });
    try std.testing.expectEqualStrings("▸ read a.zig\n", plain_out.written());

    var ansi_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ansi_out.deinit();
    try mark.header("read", "a.zig", .{ .style = .ansi, .out = &ansi_out.writer });
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n",
        ansi_out.written(),
    );
}

test "a header writes what a model named as text, so none of it is an instruction" {
    const gpa = std.testing.allocator;
    const mark: Mark = .{ .glyph = "▸", .hue = .blue };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const ansi: Writer = .{ .style = .ansi, .out = &out.writer };
    try mark.header("re\x1b[31mad", "a\tb\x7fc", ansi);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mre[31mad\x1b[0m \x1b[2mabc\x1b[0m\n",
        out.written(),
    );

    // A control the terminal reads as one character in its own right, such as the C1 CSI, is a
    // control too, and is dropped where it is decoded rather than where its bytes happen to be.
    out.clearRetainingCapacity();
    const plain: Writer = .{ .out = &out.writer };
    try mark.header("x\u{9b}2Jy", "", plain);
    try std.testing.expectEqualStrings("▸ x2Jy\n", out.written());

    // A byte that is not part of a character is not text either, and a terminal that read it as a
    // control would act on it.
    out.clearRetainingCapacity();
    try mark.header("a\xffb", "", plain);
    try std.testing.expectEqualStrings("▸ ab\n", out.written());

    out.clearRetainingCapacity();
    try mark.header("café", "日本", plain);
    try std.testing.expectEqualStrings("▸ café 日本\n", out.written());
}
