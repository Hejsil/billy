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
    /// Answers questions: reads and searches, and changes nothing.
    ask,

    /// The base text of the system prompt. The user's and the project's
    /// instruction files are added to it when `instructions` says so.
    pub fn prompt(mode: Mode) []const u8 {
        return switch (mode) {
            .general => general_prompt,
            .ask => ask_prompt,
        };
    }

    /// Whether the instruction files are read into the prompt. Ask mode only
    /// answers, so rules about how to change the code do not apply to it.
    pub fn instructions(mode: Mode) bool {
        return switch (mode) {
            .general => true,
            .ask => false,
        };
    }

    /// Whether the tool named `name` may run, or be offered to the model.
    pub fn allows(mode: Mode, name: []const u8) bool {
        return switch (mode) {
            .general => true,
            // Everything but the tools that change the system: `bash` runs a
            // command, `write` replaces a file, and `edit` rewrites one.
            .ask => !std.mem.eql(u8, name, "bash") and
                !std.mem.eql(u8, name, "write") and
                !std.mem.eql(u8, name, "edit"),
        };
    }

    /// What a session's first prompt asks for: the mode to start in, and the
    /// prompt with any leading command taken off. `/ask` and `/general` start in
    /// that mode; anything else starts in `default`, which is the frontend's own.
    pub fn start(text: []const u8, default: Mode) Start {
        if (command(text, ask_command)) |rest| return .{ .mode = .ask, .text = rest };
        if (command(text, general_command)) |rest| return .{ .mode = .general, .text = rest };
        return .{ .mode = default, .text = text };
    }
};

/// `text` with the command `name` taken off its front, or null when it does not
/// open with it. A command is a whole word: `/asking` is not `/ask`.
fn command(text: []const u8, name: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, text, " \t");
    if (!std.mem.startsWith(u8, rest, name)) return null;
    const after = rest[name.len..];
    if (after.len > 0 and after[0] != ' ' and after[0] != '\t' and after[0] != '\n') return null;
    return std.mem.trimStart(u8, after, " \t\n");
}

/// What a first prompt asks for: the mode it names and the prompt itself.
pub const Start = struct {
    mode: Mode,
    text: []const u8,
};

/// The commands a first prompt can open with to name the mode.
const ask_command = "/ask";
const general_command = "/general";

const general_prompt =
    \\You are a coding agent working in the user's project directory.
    \\Inspect the code before you change it, and use the tools to do the work.
    \\Reply with plain text when the task is done.
;
const ask_prompt =
    \\You answer questions, about this project or anything else.
    \\Read files and search the web when they help; do not change anything.
    \\Reply with plain text when the question is answered.
;

test "ask allows the tools that read and search, and no others" {
    try std.testing.expect(Mode.general.allows("bash"));
    try std.testing.expect(Mode.general.allows("write"));
    try std.testing.expect(Mode.general.allows("edit"));

    try std.testing.expect(Mode.ask.allows("read"));
    try std.testing.expect(Mode.ask.allows("web_search"));
    try std.testing.expect(!Mode.ask.allows("bash"));
    try std.testing.expect(!Mode.ask.allows("write"));
    try std.testing.expect(!Mode.ask.allows("edit"));
}

test "ask does not read the instruction files" {
    try std.testing.expect(Mode.general.instructions());
    try std.testing.expect(!Mode.ask.instructions());
}

test "a first prompt opens the mode it names, or the default" {
    // `/ask` and `/general` name the mode; with nothing after them nothing is
    // asked, and with something it is the prompt.
    try std.testing.expectEqual(Mode.ask, Mode.start("/ask", .general).mode);
    try std.testing.expectEqualStrings("", Mode.start("/ask", .general).text);
    try std.testing.expectEqualStrings("what is x", Mode.start("/ask what is x", .general).text);
    try std.testing.expectEqual(Mode.general, Mode.start("/general do it", .ask).mode);
    try std.testing.expectEqualStrings("do it", Mode.start("/general do it", .ask).text);

    // Anything else is the default, kept as it is. The web starts in ask; the
    // terminal starts in general.
    try std.testing.expectEqual(Mode.ask, Mode.start("hello", .ask).mode);
    try std.testing.expectEqualStrings("hello", Mode.start("hello", .ask).text);
    try std.testing.expectEqual(Mode.general, Mode.start("hello", .general).mode);

    // A word that merely starts with a command is not it.
    try std.testing.expectEqual(Mode.general, Mode.start("/asking around", .general).mode);
    try std.testing.expectEqual(Mode.ask, Mode.start("/generally", .ask).mode);
}
