//! The md4c callbacks, shared by the two renderers that drive the parser.
//!
//! md4c calls back into C, so each callback is one thin shim: it recovers the
//! renderer from `userdata`, calls the renderer's own method for what it was
//! told, and turns the answer into the number md4c reads. A renderer writes the
//! markdown for one target -- HTML for a page, styled text for a terminal -- and
//! the shims are the same for both, so they live here rather than in each.

const md = @import("md.zig");

const Callbacks = @This();

/// The parser a renderer of type `T` is read with. `T` is the renderer itself,
/// which is what md4c hands back to every callback as `userdata`.
pub fn parser(comptime T: type) md.c.MD_PARSER {
    return .{
        .abi_version = 0,
        .flags = md.flags,
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
fn enterBlock(comptime T: type) *const fn (md.c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.openBlock(block_type, detail));
        }
    }.callback;
}

fn leaveBlock(comptime T: type) *const fn (md.c.MD_BLOCKTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(block_type: md.c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.closeBlock(block_type, detail));
        }
    }.callback;
}

fn enterSpan(comptime T: type) *const fn (md.c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.openSpan(span_type, detail));
        }
    }.callback;
}

fn leaveSpan(comptime T: type) *const fn (md.c.MD_SPANTYPE, ?*anyopaque, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(span_type: md.c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.closeSpan(span_type, detail));
        }
    }.callback;
}

fn writeText(comptime T: type) *const fn (md.c.MD_TEXTTYPE, [*c]const md.c.MD_CHAR, md.c.MD_SIZE, ?*anyopaque) callconv(.c) c_int {
    return struct {
        fn callback(
            text_type: md.c.MD_TEXTTYPE,
            text: [*c]const md.c.MD_CHAR,
            size: md.c.MD_SIZE,
            userdata: ?*anyopaque,
        ) callconv(.c) c_int {
            const renderer: *T = @ptrCast(@alignCast(userdata.?));
            return @intFromBool(!renderer.writeRun(text_type, text[0..size]));
        }
    }.callback;
}
