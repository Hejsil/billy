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
            // Everything billy offers but `bash` and `write`. Edit is left in.
            .ask => !std.mem.eql(u8, name, "bash") and !std.mem.eql(u8, name, "write"),
        };
    }

    /// What a session's first prompt asks for: the mode to start in, and the
    /// prompt with any leading command taken off. `/ask` starts an ask session,
    /// so a mode need not be chosen before the first thing is typed.
    pub fn start(text: []const u8) Start {
        const rest = std.mem.trimStart(u8, text, " \t");
        if (std.mem.startsWith(u8, rest, ask_command)) {
            const after = rest[ask_command.len..];
            if (after.len == 0 or after[0] == ' ' or after[0] == '\t' or after[0] == '\n') {
                return .{ .mode = .ask, .text = std.mem.trimStart(u8, after, " \t\n") };
            }
        }
        return .{ .mode = .general, .text = text };
    }
};

/// What a first prompt asks for: the mode it names and the prompt itself.
pub const Start = struct {
    mode: Mode,
    text: []const u8,
};

/// The command that opens the ask mode from the first prompt.
const ask_command = "/ask";

const general_prompt =
    \\You are a coding agent working in the user's project directory.
    \\Inspect the code before you change it, and use the tools to do the work.
    \\Reply with plain text when the task is done.
;
const ask_prompt =
    \\You are answering questions about the user's project.
    \\Read what you need and search the web when it helps; do not change anything.
    \\Reply with plain text when the question is answered.
;

test "ask allows the tools that read and search, and no others" {
    try std.testing.expect(Mode.general.allows("bash"));
    try std.testing.expect(Mode.general.allows("write"));

    try std.testing.expect(Mode.ask.allows("read"));
    try std.testing.expect(Mode.ask.allows("edit"));
    try std.testing.expect(Mode.ask.allows("web_search"));
    try std.testing.expect(!Mode.ask.allows("bash"));
    try std.testing.expect(!Mode.ask.allows("write"));
}

test "ask does not read the instruction files" {
    try std.testing.expect(Mode.general.instructions());
    try std.testing.expect(!Mode.ask.instructions());
}

test "a first prompt opens the mode it names" {
    // `/ask` on its own names the mode with nothing left to ask.
    try std.testing.expectEqual(Mode.ask, Mode.start("/ask").mode);
    try std.testing.expectEqualStrings("", Mode.start("/ask").text);
    try std.testing.expectEqualStrings("what is x", Mode.start("/ask what is x").text);

    // Anything else is a general prompt, kept as it is.
    try std.testing.expectEqual(Mode.general, Mode.start("hello").mode);
    try std.testing.expectEqualStrings("hello", Mode.start("hello").text);
    // A word that merely starts with the command is not it.
    try std.testing.expectEqual(Mode.general, Mode.start("/asking around").mode);
}
