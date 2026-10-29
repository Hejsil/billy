//! The md4cs binding: billy's whole contact with the C markdown parser, the callbacks its renderers
//! are driven through, and the streaming state the terminal reads a reply with.

const std = @import("std");

pub const c = @import("md4cs");

extern fn md4cs_parse_batch(
    text: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
    parser: [*c]const c.MD_PARSER,
    userdata: ?*anyopaque,
) c_int;

/// The dialect billy reads, on top of plain CommonMark: the GitHub extensions a model reaches for
/// -- tables, strikethrough, task lists, links written as bare addresses -- and no raw HTML, so a
/// `<` in a reply is a `<` on the page.
pub const flags: c_uint = c.MD_FLAG_TABLES |
    c.MD_FLAG_STRIKETHROUGH |
    c.MD_FLAG_TASKLISTS |
    c.MD_FLAG_PERMISSIVEAUTOLINKS |
    c.MD_FLAG_NOHTMLBLOCKS |
    c.MD_FLAG_NOHTMLSPANS;

pub fn parse(text: []const u8, callbacks: *const c.MD_PARSER, userdata: ?*anyopaque) !void {
    if (md4cs_parse_batch(text.ptr, @intCast(text.len), callbacks, userdata) < 0)
        return error.MarkdownFailed;
}

/// Appends the character the entity `text` stands for to `value`: a number with its digits, or a
/// name looked up in the parser's table.
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

/// Appends `codepoint` to `value` as UTF-8, or the replacement character when it is not one that
/// may appear in text.
pub fn appendCodepoint(value: *std.ArrayList(u8), gpa: std.mem.Allocator, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const encoded = std.unicode.utf8Encode(codepoint, &buffer) catch
        return value.appendSlice(gpa, "\u{FFFD}");
    return value.appendSlice(gpa, buffer[0..encoded]);
}

/// The parser a renderer of type `T` is read with.
pub fn parser(T: type) c.MD_PARSER {
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

fn enterBlock(T: type) *const fn (c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.enterBlock(block_type, detail));
        }
    }.callback;
}

fn leaveBlock(T: type) *const fn (c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.leaveBlock(block_type, detail));
        }
    }.callback;
}

fn enterSpan(T: type) *const fn (c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.enterSpan(span_type, detail));
        }
    }.callback;
}

fn leaveSpan(T: type) *const fn (c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.leaveSpan(span_type, detail));
        }
    }.callback;
}

fn writeText(T: type) *const fn (c.MD_TEXTTYPE, [*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) callconv(.c) c_int {
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

pub const Stream = struct {
    ctx: *c.MD_PARSER_CTX,
    failed: bool = false,

    pub fn init(callbacks: *const c.MD_PARSER, userdata: ?*anyopaque) !Stream {
        var ctx: ?*c.MD_PARSER_CTX = null;
        if (c.md_stream_init(callbacks, userdata, &ctx) != 0)
            return error.MarkdownFailed;
        return .{ .ctx = ctx orelse return error.MarkdownFailed };
    }

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

    pub fn flush(self: *Stream) !void {
        if (c.md_stream_flush(self.ctx) != 0)
            return error.MarkdownFailed;
    }

    pub fn deinit(self: *Stream) void {
        c.md_stream_finish(self.ctx);
    }
};
