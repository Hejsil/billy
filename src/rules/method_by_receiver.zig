//! Disallows calling a function by its first argument when that argument is its
//! own receiver. A function declared in this file whose first parameter is the
//! file's own type is a method: `turn(agent, ...)` reads as a free function and
//! makes every reader check which it is, where `agent.turn(...)` says so.
//!
//! The check is per file, since a rule reads one document at a time: a call from
//! another file, `Session.writeMessage(session, ...)`, is not seen here.

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "method_by_receiver", .run = &run };
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
    // A file that names no type of its own holds functions, not methods.
    const self_name = selfTypeName(tree, tags) orelse return null;

    // The problems are taken from the session's own arena, which frees them
    // once this rule has had its say, so the list needs no cleanup of its own.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    // Every call of a method by its name alone, and every call of it through the
    // type's name, `Counter.bump(counter, ...)`: both pass the receiver by hand.
    var i: Ast.TokenIndex = 1;
    while (i + 2 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (tags[i + 1] != .l_paren) continue;
        if (tags[i - 1] == .keyword_fn) continue;
        // A receiver has to be a value. `run(.{ .url = ... }, ...)` has a struct
        // literal where the receiver would go, and a literal has no call through
        // it, so there is nothing here to write the other way round.
        switch (tags[i + 2]) {
            .identifier, .ampersand => {},
            else => continue,
        }
        if (tags[i - 1] != .period) {
            // A bare call, which is the method passed by its first argument.
            if (!isMethod(tree, tags, tree.tokenSlice(i), self_name)) continue;
            try report(arena, &problems, rule, config, tree, i, tree.tokenSlice(i));
            continue;
        }
        // `Self.name(...)`: the type named as the namespace of its own method.
        if (!isMethod(tree, tags, tree.tokenSlice(i), self_name)) continue;
        if (i < 2 or tags[i - 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i - 2), self_name)) continue;
        try report(arena, &problems, rule, config, tree, i - 2, tree.tokenSlice(i));
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

fn report(
    arena: std.mem.Allocator,
    problems: *std.ArrayList(zlinter.results.LintProblem),
    rule: zlinter.rules.LintRule,
    config: Config,
    tree: Ast,
    first: Ast.TokenIndex,
    name: []const u8,
) !void {
    try problems.append(arena, .{
        .rule_id = rule.rule_id,
        .severity = config.severity,
        .start = .startOfToken(tree, first),
        .end = .endOfToken(tree, first),
        .message = try arena.print("`{s}` takes its own type first, so it is called by its receiver", .{name}),
    });
}

/// The name the file gives its own type, from `const Name = @This();`.
fn selfTypeName(tree: Ast, tags: []const std.zig.Token.Tag) ?[]const u8 {
    var i: Ast.TokenIndex = 0;
    while (i + 5 < tags.len) : (i += 1) {
        if (tags[i] != .keyword_const or tags[i + 1] != .identifier) continue;
        if (tags[i + 2] != .equal or tags[i + 3] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 3), "@This")) continue;
        if (tags[i + 4] != .l_paren or tags[i + 5] != .r_paren) continue;
        return tree.tokenSlice(i + 1);
    }
    return null;
}

/// Whether the file declares `name` as a function whose first parameter is
/// `self_name`, bare or behind a pointer, `const` or an optional.
fn isMethod(tree: Ast, tags: []const std.zig.Token.Tag, name: []const u8, self_name: []const u8) bool {
    var i: Ast.TokenIndex = 0;
    while (i + 3 < tags.len) : (i += 1) {
        if (tags[i] != .keyword_fn or tags[i + 1] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 1), name)) continue;
        if (tags[i + 2] != .l_paren) continue;
        return firstParameterIs(tree, tags, i + 3, self_name);
    }
    return false;
}

/// Whether the parameter list starting at `open` takes `self_name` first, with
/// only `*` and `const` in front of it.
fn firstParameterIs(tree: Ast, tags: []const std.zig.Token.Tag, open: Ast.TokenIndex, self_name: []const u8) bool {
    var i = open;
    while (i < tags.len and (tags[i] == .keyword_comptime or tags[i] == .keyword_noalias)) i += 1;
    if (i + 1 >= tags.len or tags[i] != .identifier or tags[i + 1] != .colon) return false;
    i += 2;

    var names: usize = 0;
    var found = false;
    while (i < tags.len) : (i += 1) {
        switch (tags[i]) {
            // An optional has no call through it, so `?*Self` is a parameter the
            // caller passes by name: there is no `opt.?.method(...)` to write.
            .question_mark => return false,
            .asterisk, .keyword_const => continue,
            .identifier => {
                names += 1;
                found = std.mem.eql(u8, tree.tokenSlice(i), self_name);
            },
            .comma, .r_paren => break,
            // A type written some other way -- `anytype`, a slice, a function --
            // is not this file's own type.
            else => return false,
        }
    }
    return found and names == 1;
}

test "a method passed by its argument is reported, and a method call is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Counter = @This();
        \\
        \\value: usize = 0,
        \\
        \\fn bump(counter: *Counter, by: usize) void {
        \\    counter.value += by;
        \\}
        \\
        \\fn free(by: usize) void {
        \\    _ = by;
        \\}
        \\
        \\fn make() Counter {
        \\    return bump2(.{}, 1);
        \\}
        \\
        \\fn bump2(counter: Counter, by: usize) Counter {
        \\    var made = counter;
        \\    made.value += by;
        \\    return made;
        \\}
        \\
        \\fn twice(counter: *Counter) void {
        \\    bump(counter, 1);
        \\    counter.bump(1);
        \\    Counter.bump(counter, 2);
        \\    free(1);
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "method_by_receiver",
                .severity = .@"error",
                .slice = "bump",
                .message = "`bump` takes its own type first, so it is called by its receiver",
            },
            .{
                .rule_id = "method_by_receiver",
                .severity = .@"error",
                .slice = "Counter",
                .message = "`bump` takes its own type first, so it is called by its receiver",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
