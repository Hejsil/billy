//! The modes billy can run in: what its prompt says, whether the instruction
//! files are read, and what it may do.
//!
//! A mode is fixed when a session starts, because the system prompt and the tool
//! set are stored with the session and reused byte for byte so a resume hits the
//! prompt cache. Switching mid-session would throw that prefix away, so the mode
//! is a property of the session rather than of a single prompt.

const std = @import("std");

pub const Mode = enum {
    /// Works in the project and changes it: the mode billy has always had.
    general,
    /// Chats and answers questions, about the project or anything else: reads
    /// and searches, and changes nothing. It has no system prompt of its own, so
    /// the request is the conversation alone.
    chat,

    /// The base text of the system prompt. The user's and the project's
    /// instruction files are added to it when `instructions` says so.
    pub fn prompt(mode: Mode) []const u8 {
        return switch (mode) {
            .general => general_prompt,
            .chat => chat_prompt,
        };
    }

    /// Whether the instruction files are read into the prompt. Chat mode changes
    /// nothing, so rules about how to change the code do not apply to it.
    pub fn instructions(mode: Mode) bool {
        return switch (mode) {
            .general => true,
            .chat => false,
        };
    }

    /// Whether the tool named `name` may run, or be offered to the model.
    pub fn allows(mode: Mode, name: []const u8) bool {
        return switch (mode) {
            .general => true,
            // Everything but the tools that change the system: `bash` runs a
            // command, `write` replaces a file, and `edit` rewrites one.
            .chat => !std.mem.eql(u8, name, "bash") and
                !std.mem.eql(u8, name, "write") and
                !std.mem.eql(u8, name, "edit"),
        };
    }

    /// What a session's first prompt asks for: the mode to start in, and the
    /// prompt with any leading command taken off. `/chat` and `/general` start in
    /// that mode; anything else starts in `default`, which is the frontend's own.
    pub fn start(text: []const u8, default: Mode) Start {
        const trimmed_text = std.mem.trimStart(u8, text, " \t");
        if (command(trimmed_text, chat_command)) |rest|
            return .{ .mode = .chat, .text = rest };
        if (command(trimmed_text, general_command)) |rest|
            return .{ .mode = .general, .text = rest };
        return .{ .mode = default, .text = text };
    }
};

/// `text` with the command `name` taken off its front, or null when it does not
/// open with it. A command is a whole word: `/chatty` is not `/chat`.
fn command(text: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, name))
        return null;

    const after = text[name.len..];
    const res = std.mem.trimStart(u8, after, " \t\n");
    return if (res.len == 0 or res.len != after.len) res else null;
}

/// What a first prompt asks for: the mode it names and the prompt itself.
pub const Start = struct {
    mode: Mode,
    text: []const u8,
};

/// The commands a first prompt can open with to name the mode.
const chat_command = "/chat";
const general_command = "/general";

const general_prompt =
    \\You are a coding agent working in the user's project directory.
    \\Inspect the code before you change it, and use the tools to do the work.
    \\Reply with plain text when the task is done.
;
/// Chat mode has no prompt of its own: the request is the conversation alone.
/// The tools are what keep it read-only.
const chat_prompt = "";

test "chat allows the tools that read and search, and no others" {
    try std.testing.expect(Mode.general.allows("bash"));
    try std.testing.expect(Mode.general.allows("write"));
    try std.testing.expect(Mode.general.allows("edit"));

    try std.testing.expect(Mode.chat.allows("read"));
    try std.testing.expect(Mode.chat.allows("web_search"));
    try std.testing.expect(!Mode.chat.allows("bash"));
    try std.testing.expect(!Mode.chat.allows("write"));
    try std.testing.expect(!Mode.chat.allows("edit"));
}

test "chat has no prompt and does not read the instruction files" {
    try std.testing.expectEqualStrings("", Mode.chat.prompt());
    try std.testing.expect(Mode.general.instructions());
    try std.testing.expect(!Mode.chat.instructions());
}

test "a first prompt opens the mode it names, or the default" {
    // `/chat` and `/general` name the mode; with nothing after them nothing is
    // asked, and with something it is the prompt.
    try std.testing.expectEqual(Mode.chat, Mode.start("/chat", .general).mode);
    try std.testing.expectEqualStrings("", Mode.start("/chat", .general).text);
    try std.testing.expectEqualStrings("what is x", Mode.start("/chat what is x", .general).text);
    try std.testing.expectEqual(Mode.general, Mode.start("/general do it", .chat).mode);
    try std.testing.expectEqualStrings("do it", Mode.start("/general do it", .chat).text);

    // Anything else is the default, kept as it is. The web starts in chat; the
    // terminal starts in general.
    try std.testing.expectEqual(Mode.chat, Mode.start("hello", .chat).mode);
    try std.testing.expectEqualStrings("hello", Mode.start("hello", .chat).text);
    try std.testing.expectEqual(Mode.general, Mode.start("hello", .general).mode);

    // A word that merely starts with a command is not it.
    try std.testing.expectEqual(Mode.general, Mode.start("/chatty around", .general).mode);
    try std.testing.expectEqual(Mode.chat, Mode.start("/generally", .chat).mode);
}
