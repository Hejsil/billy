//! Disallows finishing the file of an atomic write with `end`: `flush` names the error that failed.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "atomic_write_finish", .run = &run };
}

const message =
    "`flush` finishes the file of an atomic write: it names the error of the write that failed, and " ++
    "the pattern reads the same in every place";

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
    const functions = try spansOf(arena, tags, .keyword_fn);
    // The problems come from the session's arena, which frees them itself.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 0;
    while (i + 1 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), "createFileAtomic")) continue;
        if (tags[i + 1] != .l_paren) continue;

        // One atomic write is one function, so a name bound in it is not the next one's name.
        const span = enclosing(functions, i) orelse continue;
        const atomic = declaredName(tree, tags, i, span) orelse continue;

        var j = i;
        while (j + 3 < span.last) : (j += 1) {
            if (tags[j] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(j), atomic)) continue;
            if (tags[j + 1] != .period or tags[j + 2] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(j + 2), "file")) continue;
            // `atomic.file.writer(...)` and `.init(atomic.file, ...)` make the writer; the rest
            // are uses of the file itself, which `flush` is not the finish of.
            const writer = switch (tags[j + 3]) {
                .period => if (isWriterCall(tree, tags, j)) declaredName(tree, tags, j, span) else null,
                .comma => declaredName(tree, tags, j, span),
                else => null,
            };
            try appendEnds(
                arena,
                &problems,
                tree,
                tags,
                span,
                writer orelse continue,
                rule.rule_id,
                config.severity,
            );
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// Whether `at.file` is followed by `.writer(`: the call that builds the writer over it.
fn isWriterCall(tree: Ast, tags: []const std.zig.Token.Tag, at: Ast.TokenIndex) bool {
    if (at + 5 >= tags.len) return false;
    if (tags[at + 3] != .period or tags[at + 5] != .l_paren) return false;
    return std.mem.eql(u8, tree.tokenSlice(at + 4), "writer");
}

/// The name the declaration that holds `at` binds, walking back to the `var` or `const`.
fn declaredName(tree: Ast, tags: []const std.zig.Token.Tag, at: Ast.TokenIndex, span: Span) ?[]const u8 {
    if (at == 0) return null;
    var i = at;
    while (i > span.first) : (i -= 1) {
        switch (tags[i]) {
            .keyword_var, .keyword_const => {
                if (i + 1 >= tags.len or tags[i + 1] != .identifier) return null;
                return tree.tokenSlice(i + 1);
            },
            .semicolon, .l_brace, .r_brace => return null,
            else => {},
        }
    }
    return null;
}

/// Appends a problem for each `name.end()` in `span`.
fn appendEnds(
    arena: std.mem.Allocator,
    problems: *std.ArrayList(zlinter.results.LintProblem),
    tree: Ast,
    tags: []const std.zig.Token.Tag,
    span: Span,
    name: []const u8,
    rule_id: []const u8,
    severity: zlinter.rules.LintProblemSeverity,
) !void {
    var i = span.first;
    while (i + 3 < span.last) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i), name)) continue;
        if (tags[i + 1] != .period or tags[i + 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 2), "end")) continue;
        if (tags[i + 3] != .l_paren) continue;

        try problems.append(arena, .{
            .rule_id = rule_id,
            .severity = severity,
            .start = .startOfToken(tree, i + 2),
            .end = .endOfToken(tree, i + 2),
            .message = message,
        });
    }
}

const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

/// The block of the function holding `token`.
fn enclosing(spans: []const Span, token: Ast.TokenIndex) ?Span {
    for (spans) |span| {
        if (token > span.first and token < span.last) return span;
    }
    return null;
}

/// The token range of every block opened by `keyword`, from its `{` to the `}` that closes it.
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

test "a file finished with `end` is reported, and one finished with `flush` is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn saved(dir: std.Io.Dir, io: std.Io) !void {
        \\    var atomic = try dir.createFileAtomic(io, "a", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    var buffer: [64]u8 = undefined;
        \\    var file = atomic.file.writer(io, &buffer);
        \\    try file.interface.writeAll("x");
        \\    try file.end();
        \\    try atomic.replace(io);
        \\}
        \\
        \\pub fn inited(dir: std.Io.Dir, io: std.Io) !void {
        \\    var atomic = try dir.createFileAtomic(io, "b", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    var buffer: [64]u8 = undefined;
        \\    var written: std.Io.File.Writer = .init(atomic.file, io, &buffer);
        \\    try written.interface.writeAll("x");
        \\    try written.end();
        \\    try atomic.replace(io);
        \\}
        \\
        \\pub fn flushed(dir: std.Io.Dir, io: std.Io) !void {
        \\    var atomic = try dir.createFileAtomic(io, "c", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    var buffer: [64]u8 = undefined;
        \\    var file = atomic.file.writer(io, &buffer);
        \\    try file.interface.writeAll("x");
        \\    try file.flush();
        \\    try atomic.replace(io);
        \\}
        \\
        \\pub fn closed(stream: *Stream) !void {
        \\    try stream.end();
        \\}
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "atomic_write_finish", .severity = .@"error", .slice = "end", .message = message },
            .{ .rule_id = "atomic_write_finish", .severity = .@"error", .slice = "end", .message = message },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
