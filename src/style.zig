//! How billy decorates the lines it prints itself: the header that opens a
//! block, the label over a section of one, and the exit status of a command.
//!
//! Only those lines are decorated. What a tool returned, what a session stores
//! and what the model is sent are printed exactly as they are, which is also
//! what leaves the command of a bash call to the format script that lays it out.

const std = @import("std");
const Io = std.Io;

pub const Style = enum {
    plain,
    ansi,

    /// The style to use on the terminal billy prints to. Escape codes are for a
    /// terminal, which a pipe or a redirection is not: `supportsAnsiEscapeCodes`
    /// answers whether stdout is one.
    pub fn detect(io: Io) Style {
        const supported = Io.File.stdout().supportsAnsiEscapeCodes(io) catch return .plain;
        return if (supported) .ansi else .plain;
    }

    /// `text` in bold.
    pub fn bold(style: Style, text: []const u8, out: *Io.Writer) !void {
        try out.print("{s}{s}{s}", .{ style.on("1"), text, style.off() });
    }

    /// `text` dimmed, for structure that should sit behind the content.
    pub fn dim(style: Style, text: []const u8, out: *Io.Writer) !void {
        try out.print("{s}{s}{s}", .{ style.on("2"), text, style.off() });
    }

    /// `text` in `hue`.
    pub fn color(style: Style, hue: Color, text: []const u8, out: *Io.Writer) !void {
        switch (style) {
            .plain => try out.writeAll(text),
            .ansi => try out.print("\x1b[{d}m{s}\x1b[0m", .{ @intFromEnum(hue), text }),
        }
    }

    /// `text` in `hue` and bold, for the one thing on a line that is the point
    /// of the line.
    pub fn boldColor(style: Style, hue: Color, text: []const u8, out: *Io.Writer) !void {
        switch (style) {
            .plain => try out.writeAll(text),
            .ansi => try out.print("\x1b[1;{d}m{s}\x1b[0m", .{ @intFromEnum(hue), text }),
        }
    }

    /// The escape code that turns `code` on. Empty when the terminal takes no
    /// escape codes, so a caller that has to format decorated text around it can
    /// do so without a branch of its own.
    pub fn on(style: Style, comptime code: []const u8) []const u8 {
        return switch (style) {
            .plain => "",
            .ansi => "\x1b[" ++ code ++ "m",
        };
    }

    /// The escape code that turns every decoration back off.
    pub fn off(style: Style) []const u8 {
        return switch (style) {
            .plain => "",
            .ansi => "\x1b[0m",
        };
    }
};

/// A foreground colour, named by the escape code that selects it. Only the
/// colours every terminal has are used, so they read as part of the terminal
/// rather than as a theme of billy's own competing with the one a format script
/// paints the text in.
pub const Color = enum(u8) {
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
};

/// The mark a block header opens with: a glyph and the colour it is shown in, so
/// a block is recognisable from its first character.
pub const Mark = struct {
    glyph: []const u8,
    hue: Color,
};

/// Prints a block header: the glyph in its colour, the name in bold and, when
/// there is one, what the block acts on, dimmed: `▸ read a.zig`.
pub fn header(mark: Mark, name: []const u8, target: []const u8, style: Style, out: *Io.Writer) !void {
    try style.color(mark.hue, mark.glyph, out);
    try out.writeAll(" ");
    try style.bold(name, out);
    if (target.len > 0) {
        try out.writeAll(" ");
        try style.dim(target, out);
    }
    try out.writeAll("\n");
}
