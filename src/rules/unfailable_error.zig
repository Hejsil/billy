//! Disallows an error union a function cannot fail with: with no `try`, no
//! `catch` and no error of its own nothing can fill the `!`, so every caller
//! writes a `try` that cannot fail. Forwarding is `return try other()`; the
//! body is asked as a whole, as a token says nothing of whether a call fails.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "unfailable_error", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.tree(session);
    const tags = tree.tokens.items(.tag);
    // The problems come from the session's arena, which frees them itself.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .keyword_fn) continue;
        const bang = unproducible(tags, i) orelse continue;
        try problems.append(session.runtime.sessionArena(), .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, bang),
            .end = .endOfToken(tree, bang),
            .message = "nothing in this function can fail, so the `!` is a `try` every caller cannot fail",
        });
    }

    if (problems.items.len == 0) return null;
    return try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(session.runtime.sessionArena()));
}

/// The `!` of the function's return type, when the body cannot produce an error.
fn unproducible(tags: []const std.zig.Token.Tag, fn_token: Ast.TokenIndex) ?Ast.TokenIndex {
    const parameters_open = find(tags, fn_token, .l_paren) orelse return null;
    const parameters_close = closing(tags, parameters_open) orelse return null;
    var i = parameters_close + 1;
    var bang: ?Ast.TokenIndex = null;
    while (i < tags.len and !(tags[i] == .l_brace and bang != null)) : (i += 1) {
        if (tags[i] == .bang) bang = i;
        // a return type with a call in it, `!@TypeOf(...)`, is not this rule's business
        if (tags[i] == .l_paren or tags[i] == .semicolon) return null;
    }
    const wanted = bang orelse return null;
    if (i >= tags.len) return null;

    const body_end = closing(tags, i) orelse return null;
    // An empty body is a stub, whose signature is the type's rather than its own.
    if (body_end == i + 1) return null;
    var j = i + 1;
    while (j < body_end) : (j += 1) {
        switch (tags[j]) {
            .keyword_try, .keyword_catch, .keyword_error => return null,
            else => {},
        }
    }
    return wanted;
}

fn find(tags: []const std.zig.Token.Tag, from: Ast.TokenIndex, tag: std.zig.Token.Tag) ?Ast.TokenIndex {
    var i = from;
    while (i < tags.len and i < from + 8) : (i += 1) {
        if (tags[i] == tag) return i;
    }
    return null;
}

/// The token that closes the `(`, `{` or `[` at `open`, or null when nothing does.
fn closing(tags: []const std.zig.Token.Tag, open: Ast.TokenIndex) ?Ast.TokenIndex {
    const close: std.zig.Token.Tag = switch (tags[open]) {
        .l_paren => .r_paren,
        .l_brace => .r_brace,
        .l_bracket => .r_bracket,
        else => return null,
    };
    var depth: usize = 0;
    var i = open;
    while (i < tags.len) : (i += 1) {
        if (tags[i] == tags[open]) depth += 1;
        if (tags[i] == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "an error a function cannot produce is reported, and one it can is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn init(a: u8) !u8 {
        \\    return a;
        \\}
        \\
        \\pub fn returnsACall() !u8 {
        \\    return other();
        \\}
        \\
        \\pub fn forwards() !u8 {
        \\    return try other();
        \\}
        \\
        \\pub fn catches() !u8 {
        \\    return other() catch 0;
        \\}
        \\
        \\pub fn own() !u8 {
        \\    return error.Nope;
        \\}
        \\
        \\pub fn plain(a: u8) u8 {
        \\    return a;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "unfailable_error",
                .severity = .@"error",
                .slice = "!",
                .message = "nothing in this function can fail, so the `!` is a `try` every caller cannot fail",
            },
            .{
                .rule_id = "unfailable_error",
                .severity = .@"error",
                .slice = "!",
                .message = "nothing in this function can fail, so the `!` is a `try` every caller cannot fail",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
