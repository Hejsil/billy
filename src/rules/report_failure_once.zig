//! Disallows logging a failure and then returning it. The layer that explains a
//! failure says it once: `main` prints whatever comes back from it, so an error
//! that was already written to the log is written a second time, and a stack
//! trace with it. What such a layer returns is `report.Reported`, which `main`
//! counts as a failure and stays quiet about.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "report_failure_once", .run = &run };
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

    // `std.log.err("...", ...); return <error>;` -- the log, the whole call of
    // it, then the statement that hands the same failure on.
    var i: Ast.TokenIndex = 0;
    while (i + 4 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), "log")) continue;
        if (tags[i + 1] != .period or tags[i + 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 2), "err")) continue;
        if (tags[i + 3] != .l_paren) continue;

        const after_call = matchingParen(tree, i + 3) orelse continue;
        if (after_call + 2 >= tags.len) continue;
        if (tags[after_call + 1] != .semicolon) continue;
        if (tags[after_call + 2] != .keyword_return) continue;

        const reported = returnedFailure(tree, tags, after_call + 3) orelse continue;
        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, reported.first),
            .end = .endOfToken(tree, reported.last),
            .message = "logged and returned: the failure is reported twice, so return `report.Reported`",
        });
        i = reported.last;
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// The token of the `)` that closes the `(` at `open`.
fn matchingParen(tree: Ast, open: Ast.TokenIndex) ?Ast.TokenIndex {
    const tags = tree.tokens.items(.tag);
    var depth: usize = 0;
    var i = open;
    while (i < tags.len) : (i += 1) {
        switch (tags[i]) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The failure a `return` starting at `start` hands back, if it hands back one
/// that was just logged: an error literal such as `error.Unreadable`, or the
/// error a `catch` captured. A `return` of a value that is not a failure -- a
/// `false`, a `null`, a call -- is not this rule's business.
/// Where a failure is written in the source: the first and last token of it.
const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

fn returnedFailure(tree: Ast, tags: []const std.zig.Token.Tag, start: Ast.TokenIndex) ?Span {
    if (start >= tags.len) return null;
    if (tags[start] == .keyword_error and start + 2 < tags.len and tags[start + 1] == .period) {
        var last = start + 2;
        while (last + 1 < tags.len and tags[last + 1] != .semicolon) : (last += 1) {}
        return .{ .first = start, .last = last };
    }
    if (tags[start] != .identifier) return null;
    if (start + 1 >= tags.len or tags[start + 1] != .semicolon) return null;
    // An identifier that names a value rather than a failure is not reported
    // here: `false` and `null` are answers, not errors handed on.
    const name = tree.tokenSlice(start);
    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) return null;
    if (std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined")) return null;
    return .{ .first = start, .last = start };
}

test "a failure that is logged and handed back is reported, and one that is only logged is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn run(file: File) !void {
        \\    file.open() catch |err| {
        \\        std.log.err("cannot open: {s}", .{@errorName(err)});
        \\        return err;
        \\    };
        \\    file.read() catch {
        \\        std.log.err("cannot read", .{});
        \\        return error.Unreadable;
        \\    };
        \\    file.close() catch |err| {
        \\        std.log.err("cannot close: {s}", .{@errorName(err)});
        \\        return report.Reported;
        \\    };
        \\    file.seek() catch |err| {
        \\        std.log.err("cannot seek: {s}", .{@errorName(err)});
        \\        return null;
        \\    };
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "report_failure_once",
                .severity = .@"error",
                .slice = "err",
                .message = "logged and returned: the failure is reported twice, so return `report.Reported`",
            },
            .{
                .rule_id = "report_failure_once",
                .severity = .@"error",
                .slice = "error.Unreadable",
                .message = "logged and returned: the failure is reported twice, so return `report.Reported`",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
