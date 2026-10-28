//! Caps how much of a file may be comment: a few lines to begin with, plus one more for every
//! `code_per_line` lines of code.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .@"error",

    allowance: u32 = 5,

    code_per_line: u32 = 20,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "comment_budget", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    // The lines are counted from the source rather than from the tokens: a multi-line string covers
    // lines no token starts on, and those are code.
    const source = doc.tree(session).source;
    var comment_lines: u32 = 0;
    var code_lines: u32 = 0;
    var first: ?Span = null;
    var offset: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        defer offset += line.len + 1;
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        if (!std.mem.startsWith(u8, text, "//")) {
            code_lines += 1;
            continue;
        }
        comment_lines += 1;
        if (first == null) {
            const start = offset + (line.len - std.mem.trimStart(u8, line, " \t").len);
            first = .{ .start = start, .end = start + text.len - 1 };
        }
    }

    const budget = config.allowance + code_lines / config.code_per_line;
    if (comment_lines <= budget) return null;

    const span = first orelse return null;
    const arena = session.runtime.sessionArena();
    return try zlinter.results.LintResult.init(doc.file_id, try arena.dupe(zlinter.results.LintProblem, &.{.{
        .rule_id = rule.rule_id,
        .severity = config.severity,
        .start = .{ .byte_offset = span.start },
        .end = .{ .byte_offset = span.end },
        .message = try arena.print(
            "{d} comment lines of a budget of {d}: keep the ones that say why",
            .{ comment_lines, budget },
        ),
    }}));
}

const Span = struct { start: usize, end: usize };

test "a file over its budget is reported, and one that fits is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\//! One.
        \\// Two.
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ,
        .{},
        Config{ .allowance = 1, .code_per_line = 100 },
        &.{.{
            .rule_id = "comment_budget",
            .severity = .@"error",
            .slice = "//! One.",
            .message = "2 comment lines of a budget of 1: keep the ones that say why",
        }},
    );
}

test "lines of code buy comment lines" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\//! One.
        \\// Two.
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ,
        .{},
        Config{ .allowance = 0, .code_per_line = 1 },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
