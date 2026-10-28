//! Disallows building a file's contents in memory to write them: content goes
//! through a writer over the file's own buffer, so it costs no second copy.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "streamed_write", .run = &run };
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
    const tests = try spansOf(arena, tags, .keyword_test);
    const functions = try spansOf(arena, tags, .keyword_fn);
    // The problems come from the session's arena, which frees them itself.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    // `writeAll(io, <held>.written())`: what the buffer holds is what is written,
    // so the file is written twice, once into memory and once out of it.
    var i: Ast.TokenIndex = 0;
    while (i + 2 < tags.len) : (i += 1) {
        if (tags[i] != .identifier or !isWrite(tree.tokenSlice(i))) continue;
        if (i == 0 or tags[i - 1] != .period or tags[i + 1] != .l_paren) continue;
        if (inAny(tests, i) or inTesting(tree, tags, functions, i)) continue;
        const close = closing(tags, i + 1) orelse continue;

        var j = i + 2;
        while (j + 3 < close) : (j += 1) {
            if (tags[j + 1] != .period or tags[j + 2] != .identifier) continue;
            if (!isDrain(tree.tokenSlice(j + 2))) continue;
            if (tags[j + 3] != .l_paren) continue;
            if (try declarationOf(tree, tags, tree.tokenSlice(j), close)) |token| {
                try problems.append(arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = .startOfToken(tree, token),
                    .end = .endOfToken(tree, token),
                    .message = "built in memory and then written: stream it onto the file's own writer",
                });
            }
        }
    }

    if (problems.items.len == 0) return null;
    return try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena));
}

fn isWrite(name: []const u8) bool {
    return std.mem.eql(u8, name, "writeAll") or std.mem.eql(u8, name, "writeFile") or
        std.mem.eql(u8, name, "writeFileAlloc");
}

fn isDrain(name: []const u8) bool {
    return std.mem.eql(u8, name, "written") or std.mem.eql(u8, name, "toOwnedSlice");
}

/// The `Allocating` token of the declaration that names `held`.
fn declarationOf(tree: Ast, tags: []const std.zig.Token.Tag, held: []const u8, before: Ast.TokenIndex) !?Ast.TokenIndex {
    var i: Ast.TokenIndex = 0;
    while (i + 6 < before) : (i += 1) {
        if (tags[i] != .keyword_var or tags[i + 1] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 1), held)) continue;
        if (tags[i + 2] != .colon) continue;
        var j = i + 3;
        while (j + 1 < before and tags[j] != .semicolon and tags[j] != .equal) : (j += 1) {
            if (tags[j] != .identifier) continue;
            if (std.mem.eql(u8, tree.tokenSlice(j), "Allocating")) return j;
        }
    }
    return null;
}

const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

fn inAny(spans: []const Span, token: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (token > span.first and token < span.last) return true;
    }
    return false;
}

/// Whether the function holding `token` reaches for `std.testing`.
fn inTesting(tree: Ast, tags: []const std.zig.Token.Tag, functions: []const Span, token: Ast.TokenIndex) bool {
    for (functions) |span| {
        if (token < span.first or token > span.last) continue;
        var i = span.first;
        while (i + 2 < span.last) : (i += 1) {
            if (tags[i] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(i), "std")) continue;
            if (tags[i + 1] == .period and tags[i + 2] == .identifier and
                std.mem.eql(u8, tree.tokenSlice(i + 2), "testing")) return true;
        }
        return false;
    }
    return false;
}

/// The span of every block opened by `keyword`, a `test` or a `fn`.
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

/// The token that closes the `(` at `open`, or null when nothing does.
fn closing(tags: []const std.zig.Token.Tag, open: Ast.TokenIndex) ?Ast.TokenIndex {
    var depth: usize = 0;
    var i = open;
    while (i < tags.len) : (i += 1) {
        if (tags[i] == .l_paren) depth += 1;
        if (tags[i] == .r_paren) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "a file written out of a buffer is reported, and one streamed onto its writer is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn buffered(dir: std.Io.Dir, io: std.Io) !void {
        \\    var held: std.Io.Writer.Allocating = .init(gpa);
        \\    defer held.deinit();
        \\    var atomic = try dir.createFileAtomic(io, "a", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    try atomic.file.writeAll(io, held.written());
        \\    try atomic.replace(io);
        \\}
        \\
        \\pub fn streamed(dir: std.Io.Dir, io: std.Io) !void {
        \\    var atomic = try dir.createFileAtomic(io, "a", .{ .replace = true });
        \\    defer atomic.deinit(io);
        \\    var buffer: [64]u8 = undefined;
        \\    var file = atomic.file.writer(io, &buffer);
        \\    try file.interface.writeAll("streamed");
        \\    try file.flush();
        \\    try atomic.replace(io);
        \\}
        \\
        \\fn expectOutline(contents: []const u8) !void {
        \\    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = contents });
        \\    var out: std.Io.Writer.Allocating = .init(gpa);
        \\    defer out.deinit();
        \\    try std.testing.expectEqualStrings("x", out.written());
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "streamed_write",
            .severity = .@"error",
            .slice = "Allocating",
            .message = "built in memory and then written: stream it onto the file's own writer",
        }},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
