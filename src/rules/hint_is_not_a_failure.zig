//! Disallows `try` on the waits `Health` keeps.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "hint_is_not_a_failure", .run = &run };
}

const hints = [_][]const u8{ "record", "clear", "recordFailure", "recordAnswer" };

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
    // The problems are taken from the session's own arena, which frees them once this rule has had
    // its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 1;
    while (i + 3 < tags.len) : (i += 1) {
        if (tags[i] != .keyword_try) continue;
        var j = i + 1;
        while (j < tags.len and tags[j] != .l_paren) : (j += 1) {
            switch (tags[j]) {
                .semicolon, .l_brace, .r_brace, .comma => break,
                else => {},
            }
        }
        if (j + 1 > tags.len or tags[j] != .l_paren) continue;
        if (tags[j - 1] != .identifier or tags[j - 2] != .period) continue;
        if (!isHint(tree.tokenSlice(j - 1))) continue;

        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, i),
            .end = .endOfToken(tree, j - 1),
            .message = "a wait that cannot be kept is a hint, not a failure: record it and carry on",
        });
        i = j;
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

fn isHint(name: []const u8) bool {
    for (hints) |hint| {
        if (std.mem.eql(u8, hint, name)) return true;
    }
    return false;
}

test "a wait whose failure is returned is reported, and one that is only recorded is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn search(health: *Health, waiting: ?*Health) !Results {
        \\    try health.record("tavily", 2000, 0);
        \\    health.clear("tavily");
        \\    try waiting.?.recordFailure("brave", 500, 0);
        \\    const found = try searchWith(health);
        \\    return found;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "hint_is_not_a_failure",
                .severity = .@"error",
                .slice = "try health.record",
                .message = "a wait that cannot be kept is a hint, not a failure: record it and carry on",
            },
            .{
                .rule_id = "hint_is_not_a_failure",
                .severity = .@"error",
                .slice = "try waiting.?.recordFailure",
                .message = "a wait that cannot be kept is a hint, not a failure: record it and carry on",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
