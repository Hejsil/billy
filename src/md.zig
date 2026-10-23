//! The md4cs binding: billy's whole contact with the C markdown parser, the
//! callbacks its renderers are driven through, and the streaming state the
//! terminal reads a reply with.
//!
//! md4cs is mdflow's streaming fork of md4c. It keeps md4c's parser API and
//! dialects, and adds `md_stream_*` for a document that arrives a piece at a
//! time. It is the only markdown parser billy builds. The same source is built
//! in its batch mode for a whole document -- a stored block for the page, or a
//! replayed reply -- and in its streaming mode for a reply the terminal shows as
//! it arrives. The two modes are the upstream split: the streaming build does
//! not carry a working `md_parse`, and the batch build does not carry the
//! streaming entry points.

const std = @import("std");

pub const c = @import("md4cs");

/// The batch entry point, built from the same source without
/// `MD4C_STREAMING`. It is named apart from the streaming copy's `md_parse` so
/// there is no doubt which one a whole document goes through.
extern fn md4cs_parse_batch(
    text: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
    parser: [*c]const c.MD_PARSER,
    userdata: ?*anyopaque,
) c_int;

/// The dialect billy reads, on top of plain CommonMark: the GitHub extensions a
/// model reaches for -- tables, strikethrough, task lists, links written as bare
/// addresses -- and no raw HTML, so a `<` in a reply is a `<` on the page.
pub const flags: c_uint = c.MD_FLAG_TABLES |
    c.MD_FLAG_STRIKETHROUGH |
    c.MD_FLAG_TASKLISTS |
    c.MD_FLAG_PERMISSIVEAUTOLINKS |
    c.MD_FLAG_NOHTMLBLOCKS |
    c.MD_FLAG_NOHTMLSPANS;

/// Reads a whole document, calling `parser`'s callbacks as each block, span and
/// run of text goes by, with `userdata` handed back to every one of them. Fails
/// only when the parser itself does; a callback that stops the parse (by
/// returning non-zero) is the caller's to notice, which a renderer uses to stop
/// on a failed write.
pub fn parse(text: []const u8, callbacks: *const c.MD_PARSER, userdata: ?*anyopaque) !void {
    if (md4cs_parse_batch(text.ptr, @intCast(text.len), callbacks, userdata) < 0)
        return error.MarkdownFailed;
}

/// Appends the character the entity `text` stands for to `value`: a number with
/// its digits, or a name looked up in the parser's table. An entity that is
/// neither, which the parser passes through as text, is kept as it is.
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

// ---- parser callbacks ----

/// The parser a renderer of type `T` is read with. `T` is the renderer itself,
/// which is what the parser hands back to every callback as `userdata`.
///
/// The same description is used by the batch entry point for a whole document
/// and by `Stream.init` for one that arrives in pieces; only how it is driven
/// differs.
pub fn parser(comptime T: type) c.MD_PARSER {
    return .{
        .abi_version = 0,
        .flags = flags,
        .enter_block = enterBlock(T),
        .leave_block = leaveBlock(T),
        .enter_span = enterSpan(T),
        .leave_span = leaveSpan(T),
        .text = writeText(T),
        .debug_log = null,
        .syntax = null,
    };
}

/// One callback per kind of node, each for the renderer `T`. A callback returns
/// zero to carry on and non-zero to stop the parse, which is how a renderer
/// stops on a failed write; the failure itself is kept on the renderer, since a
/// C callback has no way to return an error.
fn enterBlock(comptime T: type) *const fn (c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.enterBlock(block_type, detail));
        }
    }.callback;
}

fn leaveBlock(comptime T: type) *const fn (c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.leaveBlock(block_type, detail));
        }
    }.callback;
}

fn enterSpan(comptime T: type) *const fn (c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.enterSpan(span_type, detail));
        }
    }.callback;
}

fn leaveSpan(comptime T: type) *const fn (c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.leaveSpan(span_type, detail));
        }
    }.callback;
}

fn writeText(comptime T: type) *const fn (c.MD_TEXTTYPE, [*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(
            text_type: c.MD_TEXTTYPE,
            text: [*c]const c.MD_CHAR,
            size: c.MD_SIZE,
            userdata: ?*anyopaque,
        ) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.writeText(text_type, text[0..size]));
        }
    }.callback;
}

/// A document being read a piece at a time.
///
/// The parser owns a copy of the parser description and keeps the `userdata`
/// pointer it was given for as long as it lives, so the renderer must outlive
/// this and must not move. `deinit` frees everything the parser holds; `flush`
/// ends the document first, and is what a caller does when the last piece has
/// arrived.
pub const Stream = struct {
    ctx: *c.MD_PARSER_CTX,
    /// Whether a feed failed, so the parser is not asked to finish a document
    /// it may have stopped in the middle of.
    failed: bool = false,

    pub fn init(callbacks: *const c.MD_PARSER, userdata: ?*anyopaque) !Stream {
        var ctx: ?*c.MD_PARSER_CTX = null;
        if (c.md_stream_init(callbacks, userdata, &ctx) != 0)
            return error.MarkdownFailed;
        return .{ .ctx = ctx orelse return error.MarkdownFailed };
    }

    /// Reads `text` as more of the document. A callback that stopped the parse
    /// is reported as a failure; the renderer keeps the reason.
    pub fn feed(self: *Stream, text: []const u8) !void {
        var rest = text;
        while (rest.len > 0) {
            const count: c_uint = @intCast(@min(rest.len, std.math.maxInt(c_uint)));
            if (c.md_stream_feed(self.ctx, rest.ptr, count) != 0) {
                self.failed = true;
                return error.MarkdownFailed;
            }
            rest = rest[count..];
        }
    }

    /// Ends the document, so the last line and the blocks still open are
    /// written.
    pub fn flush(self: *Stream) !void {
        if (c.md_stream_flush(self.ctx) != 0)
            return error.MarkdownFailed;
    }

    pub fn deinit(self: *Stream) void {
        c.md_stream_finish(self.ctx);
    }
};
