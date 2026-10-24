//! Where the blocks of a run go, and where the escape codes billy writes for
//! decoration are named: a style around the writer the text goes to.
//!
//! Everything billy decorates itself is written through here -- a block header,
//! the label over a section of one, the status of a command -- and no printer
//! writes a decoration code of its own. Cursor control is not decoration and is
//! written where it is used, in the line editor; keeping the two apart is what
//! lets a plain style drop every colour and attribute without taking the cursor
//! with it. A printer is handed the writer rather than a writer and a style
//! apart, so it cannot decorate anything the style does not cover, and nothing
//! has to be told twice which style is in use.
//!
//! The style itself lives here too, along with the colours and the mark a block
//! header opens with, since they are the vocabulary the writer decorates with.

const std = @import("std");

const Writer = @This();

/// What a terminal takes of the decoration billy writes: nothing, or the escape
/// codes every terminal understands.
pub const Style = enum {
    plain,
    ansi,

    /// The style to use on the terminal billy prints to. Escape codes are for a
    /// terminal, which a pipe or a redirection is not: `supportsAnsiEscapeCodes`
    /// answers whether stdout is one, and says no for a terminal that calls
    /// itself dumb.
    pub fn detect(io: std.Io, file: std.Io.File) Style {
        const supported = file.supportsAnsiEscapeCodes(io) catch return .plain;
        return if (supported) .ansi else .plain;
    }
};

/// A foreground colour. Only the colours every terminal has are used, so they
/// read as part of the terminal rather than as a theme of billy's own.
pub const Color = enum(u8) {
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
};

/// Nothing is decorated unless a terminal is being written to, which is what a
/// writer made without asking for one is for.
style: Style = .plain,
/// The writer the text goes to, borrowed: whoever owns it outlives this.
out: *std.Io.Writer,

/// The writer to use on `file_writer`, which decorates its blocks for the
/// terminal it is on. A pipe or a redirection takes no escape codes, so it is
/// written to plainly.
pub fn detect(file_writer: *std.Io.File.Writer) Writer {
    return .{
        .style = Style.detect(file_writer.io, file_writer.file),
        .out = &file_writer.interface,
    };
}

/// Writes `text` as it is.
pub fn write(writer: Writer, text: []const u8) !void {
    try writer.out.writeAll(text);
}

/// Writes a formatted line.
pub fn print(writer: Writer, comptime format: []const u8, args: anytype) !void {
    try writer.out.print(format, args);
}

/// Sends what has been written to whatever is behind the writer.
pub fn flush(writer: Writer) !void {
    try writer.out.flush();
}

/// The code that opens bold text, which `reset` closes again.
pub fn bold(writer: Writer) []const u8 {
    return writer.code("1");
}

/// The code that opens dim text, for structure that should sit behind the
/// content.
pub fn dim(writer: Writer) []const u8 {
    return writer.code("2");
}

/// The code that opens italic text.
pub fn italic(writer: Writer) []const u8 {
    return writer.code("3");
}

/// The code that opens struck-through text.
pub fn strike(writer: Writer) []const u8 {
    return writer.code("9");
}

/// The code that opens text in `hue`.
pub fn color(writer: Writer, hue: Color) []const u8 {
    return writer.hueCode(hue, false);
}

/// The code that opens text in `hue` and bold, for the one thing on a line that
/// is the point of the line.
pub fn boldColor(writer: Writer, hue: Color) []const u8 {
    return writer.hueCode(hue, true);
}

/// The code that turns every decoration back off.
pub fn reset(writer: Writer) []const u8 {
    return writer.code("0");
}

/// The code that opens a hyperlink over the text that follows it, and the one
/// that closes it again, with the address written between them. Both are empty
/// in plain style, where a caller writes the address out beside the text
/// instead: a terminal that takes no escape codes would show nothing of it.
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

/// The escape code that turns `codes` on, which every named decoration is a
/// spelling of.
fn code(writer: Writer, comptime codes: []const u8) []const u8 {
    return switch (writer.style) {
        .plain => "",
        .ansi => "\x1b[" ++ codes ++ "m",
    };
}

/// The escape code that opens text in `hue`, bold when `loud`. Each colour is
/// written out at comptime, so nothing is formatted to make one.
fn hueCode(writer: Writer, hue: Color, comptime loud: bool) []const u8 {
    if (writer.style == .plain) return "";
    return switch (hue) {
        inline else => |known| comptime std.fmt.comptimePrint("\x1b[" ++ (if (loud) "1;" else "") ++ "{d}m", .{@backingInt(known)}),
    };
}

/// Writes `bytes` as text: the characters a terminal draws, and nothing else.
///
/// A block header carries a tool's name and what the call acted on. For a tool
/// billy implements both are its own strings, but a call naming a tool it has
/// not got is headed by whatever the model wrote, and a path or a query in a
/// target is the model's too. A control character is how an escape sequence is
/// spelled, so none is written: text that reaches a terminal as an instruction
/// is text that runs one. A byte that is not part of a well-formed character is
/// left out for the same reason -- a terminal reading it as a control would act
/// on it -- and every character that is text is written whole, accent and all.
fn writeText(writer: Writer, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(bytes[at]) catch {
            at += 1;
            continue;
        };
        if (at + len > bytes.len) break;
        const codepoint = std.unicode.utf8Decode(bytes[at..][0..len]) catch {
            at += 1;
            continue;
        };
        at += len;
        if (control(codepoint)) continue;
        try writer.write(bytes[at - len .. at]);
    }
}

/// Whether `codepoint` is one a terminal acts on rather than draws: the C0 and
/// C1 control ranges and DEL, which is where an escape sequence lives.
fn control(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

/// The mark a block header opens with: a glyph and the colour it is shown in, so
/// a block is recognisable from its first character.
pub const Mark = struct {
    glyph: []const u8,
    hue: Color,

    /// Writes a block header: `▸ read a.zig`.
    pub fn header(mark: Mark, name: []const u8, target: []const u8, writer: Writer) !void {
        try writer.print("{s}{s}{s} {s}", .{
            writer.color(mark.hue), mark.glyph, writer.reset(), writer.bold(),
        });
        try writeText(writer, name);
        try writer.write(writer.reset());
        if (target.len > 0) {
            try writer.write(" ");
            try writer.write(writer.dim());
            try writeText(writer, target);
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

    // A call naming a tool billy has not got is headed by the model's own
    // string, and so is the path or query it acted on. A control character is
    // how an escape sequence is spelled, so none of them reaches the terminal:
    // the escape, the tab and DEL are taken out, and the codes around the header
    // are still the writer's own.
    const ansi: Writer = .{ .style = .ansi, .out = &out.writer };
    try mark.header("re\x1b[31mad", "a\tb\x7fc", ansi);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mre[31mad\x1b[0m \x1b[2mabc\x1b[0m\n",
        out.written(),
    );

    // A control the terminal reads as one character in its own right, such as
    // the C1 CSI, is a control too, and is dropped where it is decoded rather
    // than where its bytes happen to be.
    out.clearRetainingCapacity();
    const plain: Writer = .{ .out = &out.writer };
    try mark.header("x\u{9b}2Jy", "", plain);
    try std.testing.expectEqualStrings("▸ x2Jy\n", out.written());

    // A byte that is not part of a character is not text either, and a terminal
    // that read it as a control would act on it.
    out.clearRetainingCapacity();
    try mark.header("a\xffb", "", plain);
    try std.testing.expectEqualStrings("▸ ab\n", out.written());

    // What is text is written whole: taking the controls out does not take out
    // the accents, the wide characters or anything else a name may hold.
    out.clearRetainingCapacity();
    try mark.header("café", "日本", plain);
    try std.testing.expectEqualStrings("▸ café 日本\n", out.written());
}
