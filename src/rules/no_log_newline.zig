//! Disallows a log message that ends in a newline. The log format ends the line
//! itself, so a message that carries one of its own leaves a blank line under
//! every entry, and the entries stop reading as one list.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_log_newline", .run = &run };
}

/// The levels `std.log` takes. `scoped` is not one of them: it takes a scope and
/// answers a logger, whose own calls are not spelled `log.<level>`.
const levels = [_][]const u8{ "err", "warn", "info", "debug" };

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const arena = session.runtime.sessionArena();
    const tree = doc.tree(session);
    const tags = tree.tokens.items(.tag);
    // The problems are taken from the session's own arena, which frees them
    // once this rule has had its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    // `log.<level>("...", ...)`, read as tokens: the level is one of the four,
    // and what follows it is the format string.
    var i: Ast.TokenIndex = 0;
    while (i + 4 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), "log")) continue;
        if (tags[i + 1] != .period or tags[i + 2] != .identifier) continue;
        if (!isLevel(tree.tokenSlice(i + 2))) continue;
        if (tags[i + 3] != .l_paren or tags[i + 4] != .string_literal) continue;
        if (!endsWithNewline(tree.tokenSlice(i + 4))) continue;

        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, i + 4),
            .end = .endOfToken(tree, i + 4),
            .message = "a log message carries no newline of its own; the log format adds one",
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

fn isLevel(name: []const u8) bool {
    for (levels) |level| {
        if (std.mem.eql(u8, level, name)) return true;
    }
    return false;
}

/// Whether a string literal token ends with a newline, written as an escape in a
/// quoted literal or as the line break that ends a multi-line one.
fn endsWithNewline(literal: []const u8) bool {
    if (std.mem.endsWith(u8, literal, "\n")) return true;
    return std.mem.endsWith(u8, literal, "\\n\"");
}

test "a log message that ends in a newline is reported, and one that does not is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn logThings(err: anyerror) void {
        \\    std.log.warn("started\n", .{});
        \\    std.log.warn("started", .{});
        \\    std.log.err("failed: {s}\n", .{@errorName(err)});
        \\    std.log.info("done {}", .{1});
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_log_newline",
                .severity = .@"error",
                .slice = "\"started\\n\"",
                .message = "a log message carries no newline of its own; the log format adds one",
            },
            .{
                .rule_id = "no_log_newline",
                .severity = .@"error",
                .slice = "\"failed: {s}\\n\"",
                .message = "a log message carries no newline of its own; the log format adds one",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
