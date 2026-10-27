//! Disallows comparing against `true` or `false`, which is a test written the
//! long way round: `x == false` is `!x`, `x == true` is `x`, and `x != false` is
//! `x`. The negation is easier to read than a comparison with a constant, and it
//! cannot be misread as two changing things being compared.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_bool_compare", .run = &run };
}

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
    // The problems are taken from the session's own arena, which frees them
    // once this rule has had its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        switch (tree.nodeTag(node)) {
            .equal_equal, .bang_equal => {},
            else => continue,
        }
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        // Whichever side the constant is on, the token it sits on is what is
        // pointed at: it is the part that says nothing.
        const literal = boolLiteral(tree, lhs) orelse boolLiteral(tree, rhs) orelse continue;
        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, literal),
            .end = .endOfToken(tree, literal),
            .message = "a comparison with a constant says the same as `x` or `!x`",
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// The token of `node`, if it is `true` or `false` and nothing else, so that
/// `x.false` or a field named `true` is not mistaken for the literal.
fn boolLiteral(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression)
        current = tree.nodeData(current).node_and_token[0];
    if (tree.nodeTag(current) != .identifier) return null;

    const token = tree.nodeMainToken(current);
    const text = tree.tokenSlice(token);
    if (!std.mem.eql(u8, text, "true") and !std.mem.eql(u8, text, "false")) return null;
    return token;
}

test "a comparison with a constant is reported, and one between two values is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn check(flag: bool, other: *bool) bool {
        \\    if (flag == false) return true;
        \\    if ((flag) == (false)) return true;
        \\    return flag == other.*;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_bool_compare",
                .severity = .@"error",
                .slice = "false",
                .message = "a comparison with a constant says the same as `x` or `!x`",
            },
            .{
                .rule_id = "no_bool_compare",
                .severity = .@"error",
                .slice = "false",
                .message = "a comparison with a constant says the same as `x` or `!x`",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
