//! Disallows flushing a writer from a `defer`. A `defer` runs while whatever
//! brought the scope to an end is still on its way out, so a flush that fails
//! there has no one left to tell: the failure is either swallowed by a `catch`
//! that can do nothing with it, or it replaces the failure that got there first.
//! Flushing where the work ends puts the failure in a place that can answer for
//! it. `errdefer` is the same shape with less to say, so it is checked too.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_flush_in_defer", .run = &run };
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
    // The problems are taken from the session's own arena, which frees them
    // once this rule has had its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 1;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .keyword_defer and tags[i] != .keyword_errdefer) continue;
        const end = bodyEnd(tags, i + 1) orelse continue;

        // The first `flush(` in the body is enough: one is one too many.
        var j = i + 1;
        while (j < end) : (j += 1) {
            if (tags[j] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(j), "flush")) continue;
            if (tags[j - 1] != .period or tags[j + 1] != .l_paren) continue;

            try problems.append(arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, i),
                .end = .endOfToken(tree, j),
                .message = "a flush here has nowhere to report a failure: flush where the work ends",
            });
            i = j;
            break;
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// The last token of the statement `defer` governs at `start`: the `}` that
/// closes its block, or the `;` that ends the one statement it defers.
fn bodyEnd(tags: []const std.zig.Token.Tag, start: Ast.TokenIndex) ?Ast.TokenIndex {
    if (start >= tags.len) return null;
    var depth: usize = 0;
    var i = start;
    while (i < tags.len) : (i += 1) {
        switch (tags[i]) {
            .l_brace, .l_paren, .l_bracket => depth += 1,
            .r_brace, .r_paren, .r_bracket => {
                depth -= 1;
                if (depth == 0 and tags[i] == .r_brace) return i;
            },
            .semicolon => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

test "a flush in a defer is reported, and one where the work ends is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const std = @import("std");
        \\
        \\pub fn write(out: *std.Io.Writer) !void {
        \\    defer out.flush() catch {};
        \\    try out.writeAll("x");
        \\}
        \\
        \\pub fn finish(out: *std.Io.Writer) !void {
        \\    try out.writeAll("x");
        \\    out.flush() catch {};
        \\}
        \\
        \\pub fn last(out: *std.Io.Writer) !void {
        \\    defer {
        \\        out.writeAll("y") catch {};
        \\        out.flush() catch {};
        \\    }
        \\}
        \\
        \\pub fn failed(out: *std.Io.Writer) !void {
        \\    errdefer out.flush() catch {};
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_flush_in_defer",
                .severity = .@"error",
                .slice = "defer out.flush",
                .message = "a flush here has nowhere to report a failure: flush where the work ends",
            },
            .{
                .rule_id = "no_flush_in_defer",
                .severity = .@"error",
                .slice = "defer {\n        out.writeAll(\"y\") catch {};\n        out.flush",
                .message = "a flush here has nowhere to report a failure: flush where the work ends",
            },
            .{
                .rule_id = "no_flush_in_defer",
                .severity = .@"error",
                .slice = "errdefer out.flush",
                .message = "a flush here has nowhere to report a failure: flush where the work ends",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
