//! The md4c binding: billy's whole contact with the C markdown library.
//!
//! md4c reads the markdown; `html.zig` drives it through the parser callbacks
//! and writes the HTML. This module only names the library, the dialect billy
//! reads, and how a document is handed to it, so that what is C-shaped stays
//! here and what is HTML-shaped stays in `html.zig`.

/// md4c, and its entity table. The table is needed because a link address is
/// decoded before it is trusted: a `javascript:` scheme can be spelled with
/// entities, and an entity-decoded address is the one the browser will follow.
pub const c = @cImport({
    @cInclude("md4c.h");
    @cInclude("entity.h");
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
