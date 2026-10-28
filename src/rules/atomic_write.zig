//! Disallows writing a file in place: a file is written beside itself and moved
//! over itself, so a write that does not finish leaves the old one whole.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "atomic_write", .run = &run };
}

const writes = [_][]const u8{ "writeFile", "writeFileAlloc", "createFile" };

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
    const fixtures = try spansOf(arena, tags, .keyword_test);
    const functions = try spansOf(arena, tags, .keyword_fn);

    // The problems come from the session's arena, which frees them itself.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 2;
    while (i + 1 < tags.len) : (i += 1) {
        if (tags[i] != .identifier or tags[i - 1] != .period or tags[i + 1] != .l_paren) continue;
        if (!isWrite(tree.tokenSlice(i))) continue;
        // `Tools.writeFile` is the atomic writer the user's files go through.
        if (std.mem.eql(u8, tree.tokenSlice(i - 2), "Tools")) continue;
        if (inAny(fixtures, i)) continue;
        if (inTestHelper(tree, tags, functions, i)) continue;

        try problems.append(arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, i - 1),
            .end = .endOfToken(tree, i),
            .message = "written in place: write beside it and `replace`, so a failed write keeps the old file",
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

fn isWrite(name: []const u8) bool {
    for (writes) |write| {
        if (std.mem.eql(u8, write, name)) return true;
    }
    return false;
}

const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

fn inAny(spans: []const Span, token: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (token > span.first and token < span.last) return true;
    }
    return false;
}

/// Whether the function holding `token` reaches for `std.testing`.
fn inTestHelper(tree: Ast, tags: []const std.zig.Token.Tag, functions: []const Span, token: Ast.TokenIndex) bool {
    for (functions) |span| {
        if (token < span.first or token > span.last) continue;
        var i = span.first;
        while (i + 2 < span.last) : (i += 1) {
            if (tags[i] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(i), "std")) continue;
            if (tags[i + 1] != .period or tags[i + 2] != .identifier) continue;
            if (std.mem.eql(u8, tree.tokenSlice(i + 2), "testing")) return true;
        }
        return false;
    }
    return false;
}

/// The token range of every block opened by `keyword`.
/// The block runs from the `{` after `keyword` -- past a test's name, or a
/// function's parameters and return type -- to the `}` that closes it.
fn spansOf(arena: std.mem.Allocator, tags: []const std.zig.Token.Tag, keyword: std.zig.Token.Tag) ![]Span {
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var spans: std.ArrayList(Span) = .empty;
    var i: Ast.TokenIndex = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != keyword) continue;
        var depth: usize = 0;
        var j = i + 1;
        while (j < tags.len) : (j += 1) {
            switch (tags[j]) {
                .l_paren => depth += 1,
                .r_paren => depth -= 1,
                .l_brace => if (depth == 0) break,
                else => {},
            }
        }
        if (j >= tags.len) return spans.toOwnedSlice(arena);
        const open = j;
        depth = 0;
        while (j < tags.len) : (j += 1) {
            switch (tags[j]) {
                .l_brace => depth += 1,
                .r_brace => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        try spans.append(arena, .{ .first = open, .last = j });
        i = j;
    }
    return spans.toOwnedSlice(arena);
}

test "a file written in place is reported, and a fixture is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn save(dir: std.Io.Dir, io: std.Io) !void {
        \\    try dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
        \\    var atomic = try dir.createFileAtomic(io, "b", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    try atomic.replace(io);
        \\}
        \\
        \\fn expectFile(dir: std.Io.Dir, io: std.Io) !void {
        \\    try dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
        \\    try std.testing.expectEqual(@as(usize, 1), @as(usize, 1));
        \\}
        \\
        \\test "a fixture" {
        \\    try dir.writeFile(io, .{ .sub_path = "a", .data = "x" });
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "atomic_write",
            .severity = .@"error",
            .slice = ".writeFile",
            .message = "written in place: write beside it and `replace`, so a failed write keeps the old file",
        }},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
