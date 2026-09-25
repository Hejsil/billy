//! The md4c binding: billy's whole contact with the C markdown library.
//!
//! md4c reads the markdown; `html.zig` drives it through the parser callbacks
//! and writes the HTML. This module only names the library, the dialect billy
//! reads, and how a document is handed to it, so that what is C-shaped stays
//! here and what is HTML-shaped stays in `html.zig`.

const std = @import("std");
const Io = std.Io;

/// md4c, its entity table, and its own HTML renderer. The table is needed
/// because a link address is decoded before it is trusted: a `javascript:`
/// scheme can be spelled with entities, and the decoded address is the one the
/// browser will follow. The HTML renderer is only for the oracle test below.
pub const c = @cImport({
    @cInclude("md4c.h");
    @cInclude("entity.h");
    @cInclude("md4c-html.h");
});

/// The dialect billy reads, on top of plain CommonMark: the GitHub extensions a
/// model reaches for -- tables, strikethrough, task lists, links written as bare
/// addresses -- and no raw HTML, so a `<` in a reply is a `<` on the page.
pub const flags: c_uint = c.MD_FLAG_TABLES |
    c.MD_FLAG_STRIKETHROUGH |
    c.MD_FLAG_TASKLISTS |
    c.MD_FLAG_PERMISSIVEAUTOLINKS |
    c.MD_FLAG_NOHTMLBLOCKS |
    c.MD_FLAG_NOHTMLSPANS;

/// Reads `text`, calling `parser`'s callbacks as each block, span and run of text
/// goes by, with `userdata` handed back to every one of them. Fails only when
/// md4c itself does; a callback that stops the parse (by returning non-zero) is
/// the caller's to notice, which `html.zig` uses to stop on a failed write.
pub fn parse(text: []const u8, parser: *const c.MD_PARSER, userdata: ?*anyopaque) !void {
    if (c.md_parse(text.ptr, @intCast(text.len), parser, userdata) < 0) return error.MarkdownFailed;
}

/// Appends the character the entity `text` stands for to `value`: a number with
/// its digits, or a name looked up in md4c's table. An entity that is neither,
/// which md4c passes through as text, is kept as it is.
pub fn decodeEntity(gpa: std.mem.Allocator, text: []const u8, value: *std.ArrayList(u8)) !void {
    if (std.mem.startsWith(u8, text, "&#")) {
        var digits = text[2..];
        if (std.mem.endsWith(u8, digits, ";")) digits = digits[0 .. digits.len - 1];
        const base: u8 = if (digits.len > 0 and (digits[0] == 'x' or digits[0] == 'X')) blk: {
            digits = digits[1..];
            break :blk 16;
        } else 10;
        const codepoint = std.fmt.parseInt(u21, digits, base) catch
            return value.appendSlice(gpa, text);
        return appendCodepoint(value, gpa, codepoint);
    }
    const entity = c.entity_lookup(text.ptr, text.len);
    if (entity == null) return value.appendSlice(gpa, text);
    try appendCodepoint(value, gpa, @intCast(entity[0].codepoints[0]));
    if (entity[0].codepoints[1] != 0) try appendCodepoint(value, gpa, @intCast(entity[0].codepoints[1]));
}

/// Appends `codepoint` to `value` as UTF-8, or the replacement character when it
/// is not one that may appear in text.
pub fn appendCodepoint(value: *std.ArrayList(u8), gpa: std.mem.Allocator, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const encoded = std.unicode.utf8Encode(codepoint, &buffer) catch
        return value.appendSlice(gpa, "\u{FFFD}");
    return value.appendSlice(gpa, buffer[0..encoded]);
}

/// Renders `text` with md4c's *own* HTML renderer, so a test can check billy's
/// renderer against it (see the oracle test in `html.zig`).
///
/// billy does not use this to render: md4c's renderer writes a link's address
/// unchecked, which is the whole reason billy drives the parser itself. It is
/// here as an independent implementation to compare against.
pub fn oracleHtml(text: []const u8, out: *Io.Writer) !void {
    var sink = Sink{ .out = out };
    _ = c.md_html(text.ptr, @intCast(text.len), emit, &sink, flags, 0);
    if (sink.err) |err| return err;
}

/// Where the oracle renderer's output goes, and the first failure of writing it.
const Sink = struct {
    out: *Io.Writer,
    err: ?Io.Writer.Error = null,
};

/// Writes one chunk of the oracle renderer's output; the failure, if any, is kept
/// on the sink, since a C callback cannot return one.
fn emit(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(userdata.?));
    if (sink.err != null) return;
    sink.out.writeAll(text[0..size]) catch |err| {
        sink.err = err;
    };
}
