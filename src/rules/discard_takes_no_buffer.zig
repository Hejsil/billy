//! Disallows a `Discarding` writer built around a buffer: it drops every byte it is given, so the
//! buffer is a byte kept for nothing. It is built as `.init("")`.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "discard_takes_no_buffer", .run = &run };
}

const message = "a discarding writer takes an empty buffer: `.init(\"\")`";

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

    var i: Ast.TokenIndex = 0;
    while (i + 4 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), "Discarding")) continue;
        const open = initOpen(tree, tags, i) orelse continue;
        const close = closingParen(tags, open) orelse continue;
        // A call with nothing in it is not worth a second report: the compiler wants an argument.
        if (close <= open + 1) continue;
        if (emptyBuffer(tree, tags, open, close)) continue;

        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, open + 1),
            .end = .endOfToken(tree, close - 1),
            .message = message,
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// The `(` of the `init` that builds the writer named at `named`: `Discarding.init(`, or the
/// `.init(` a declaration of one is written with.
fn initOpen(tree: Ast, tags: []const std.zig.Token.Tag, named: Ast.TokenIndex) ?Ast.TokenIndex {
    var at = named + 1;
    if (at < tags.len and tags[at] == .equal) at += 1;
    if (at + 2 >= tags.len) return null;
    if (tags[at] != .period) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(at + 1), "init")) return null;
    if (tags[at + 2] != .l_paren) return null;
    return at + 2;
}

/// The `)` that ends the call whose `(` is at `open`, so the arguments are the tokens between.
fn closingParen(tags: []const std.zig.Token.Tag, open: Ast.TokenIndex) ?Ast.TokenIndex {
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

fn emptyBuffer(tree: Ast, tags: []const std.zig.Token.Tag, open: Ast.TokenIndex, close: Ast.TokenIndex) bool {
    if (close != open + 2) return false;
    if (tags[open + 1] != .string_literal) return false;
    return std.mem.eql(u8, tree.tokenSlice(open + 1), "\"\"");
}

test "a discarding writer around a buffer is reported, and one around nothing is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn sinks(scratch: []u8) void {
        \\    var a: std.Io.Writer.Discarding = .init(&scratch_two);
        \\    var b: std.Io.Writer.Discarding = .init("");
        \\    var c: std.Io.Writer.Discarding = .init(scratch[0..]);
        \\    var d = std.Io.Writer.Discarding.init("");
        \\    var e = std.Io.Writer.Discarding.init(&scratch_two);
        \\    var f = std.Io.Writer.Discarding{ .count = 0 };
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "discard_takes_no_buffer",
                .severity = .@"error",
                .slice = "&scratch_two",
                .message = message,
            },
            .{
                .rule_id = "discard_takes_no_buffer",
                .severity = .@"error",
                .slice = "scratch[0..]",
                .message = message,
            },
            .{
                .rule_id = "discard_takes_no_buffer",
                .severity = .@"error",
                .slice = "&scratch_two",
                .message = message,
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
