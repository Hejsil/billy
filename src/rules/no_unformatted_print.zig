//! Disallows `print` of a string with nothing to format.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_unformatted_print", .run = &run };
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
    const tags = tree.tokens.items(.tag);
    // The problems are taken from the session's own arena, which frees them once this rule has had
    // its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 2;
    while (i + 5 < tags.len) : (i += 1) {
        if (tags[i] != .identifier or tags[i - 1] != .period) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), "print")) continue;
        if (tags[i + 1] != .l_paren or tags[i + 2] != .string_literal) continue;
        if (std.mem.findScalar(u8, tree.tokenSlice(i + 2), '{') != null) continue;
        if (tags[i + 3] != .comma) continue;
        const empty_braces = tags[i + 4] == .l_brace and tags[i + 5] == .r_brace;
        const empty_dot_braces = tags[i + 4] == .period and
            tags[i + 5] == .l_brace and i + 6 < tags.len and tags[i + 6] == .r_brace;
        if (!empty_braces and !empty_dot_braces) continue;

        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, i + 2),
            .end = .endOfToken(tree, i + 2),
            .message = "nothing is formatted here: `writeAll` writes a constant",
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

test "a print of a constant is reported, and one that formats is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn write(out: *std.Io.Writer) !void {
        \\    try out.print("done\n", .{});
        \\    try out.print("{d} left", .{3});
        \\    try out.print("a{{b", .{});
        \\    try out.writeAll("plain");
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "no_unformatted_print",
            .severity = .@"error",
            .slice = "\"done\\n\"",
            .message = "nothing is formatted here: `writeAll` writes a constant",
        }},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
