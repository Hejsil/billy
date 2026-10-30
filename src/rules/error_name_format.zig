//! Disallows a name through `@errorName` or `@tagName` inside `{s}`: `{t}` writes it itself.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "error_name_format", .run = &run };
}

const error_message = "a name written with `{s}`: `{t}` writes the error's name itself";
const tag_message = "a name written with `{s}`: `{t}` writes the tag's name itself";

const braces = [2]std.zig.Token.Tag{ .l_brace, .r_brace };
const parens = [2]std.zig.Token.Tag{ .l_paren, .r_paren };

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
    // The problems come from the session's arena, which frees them once this rule has had its say.
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var i: Ast.TokenIndex = 0;
    while (i + 4 < tags.len) : (i += 1) {
        if (tags[i] != .string_literal) continue;
        // A format may be written as literals joined by `++`, and the tuple fills the whole of it.
        var last = i;
        while (last + 2 < tags.len and tags[last + 1] == .plus_plus and tags[last + 2] == .string_literal) {
            last += 2;
        }
        if (last + 3 >= tags.len) continue;
        if (tags[last + 1] != .comma or tags[last + 2] != .period or tags[last + 3] != .l_brace) continue;
        const open = last + 3;
        const close = closing(tags, open, braces) orelse continue;

        var placeholders: Placeholders = .{ .literal = try formatText(arena, tree, i, last) };
        while (placeholders.next()) |placeholder| {
            if (!placeholder.text) continue;
            const index = placeholder.arg orelse continue;
            const span = argumentAt(tags, open, close, index) orelse continue;
            const name = builtinName(tree, tags, span) orelse continue;

            try problems.append(arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, span.first),
                .end = .endOfToken(tree, span.last),
                .message = if (std.mem.eql(u8, name, "@errorName")) error_message else tag_message,
            });
        }
        i = last;
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(arena))
    else
        null;
}

/// The literals from `first` to `last` as one text: the format the tuple after them fills.
fn formatText(arena: std.mem.Allocator, tree: Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) ![]const u8 {
    if (first == last) return tree.tokenSlice(first);
    // zlinter-disable-next-line require_errdefer_dealloc - the session's arena owns it
    var text: std.ArrayList(u8) = .empty;
    var i = first;
    while (i <= last) : (i += 2) try text.appendSlice(arena, tree.tokenSlice(i));
    return text.toOwnedSlice(arena);
}

/// Walks the format's placeholders in order, so that each one names the argument that fills it.
const Placeholders = struct {
    literal: []const u8,
    at: usize = 0,
    next_arg: usize = 0,

    const Placeholder = struct {
        /// The argument that fills it, and null when the format names one that a tuple's numbered
        /// fields do not read.
        arg: ?usize,
        /// Whether the argument is written as text, which is the one specifier `{t}` replaces.
        text: bool,
    };

    fn next(self: *Placeholders) ?Placeholder {
        while (std.mem.findScalarPos(u8, self.literal, self.at, '{')) |open| {
            // `{{` writes one brace and fills no argument, so it moves nothing after it.
            if (open + 1 < self.literal.len and self.literal[open + 1] == '{') {
                self.at = open + 2;
                continue;
            }
            const close = std.mem.findScalarPos(u8, self.literal, open + 1, '}') orelse return null;
            self.at = close + 1;
            return self.placeholder(self.literal[open + 1 .. close]);
        }
        return null;
    }

    fn placeholder(self: *Placeholders, spelling: []const u8) Placeholder {
        var rest = spelling;
        var arg: ?usize = null;
        if (rest.len > 0 and rest[0] == '[') {
            const name_end = std.mem.findScalar(u8, rest, ']') orelse return .{ .arg = null, .text = false };
            arg = std.fmt.parseInt(usize, rest[1..name_end], 10) catch null;
            rest = rest[name_end + 1 ..];
        } else if (rest.len > 0 and std.ascii.isDigit(rest[0])) {
            const digits = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;
            arg = std.fmt.parseInt(usize, rest[0..digits], 10) catch null;
            rest = rest[digits..];
        } else {
            arg = self.next_arg;
            self.next_arg += 1;
        }
        const specifier_end = std.mem.findScalar(u8, rest, ':') orelse rest.len;
        return .{ .arg = arg, .text = std.mem.eql(u8, rest[0..specifier_end], "s") };
    }
};

/// The token that closes the bracket of `pair` at `open`, or null when nothing does.
fn closing(tags: []const std.zig.Token.Tag, open: Ast.TokenIndex, pair: [2]std.zig.Token.Tag) ?Ast.TokenIndex {
    var depth: usize = 0;
    var i = open;
    while (i < tags.len) : (i += 1) {
        if (tags[i] == pair[0]) depth += 1;
        if (tags[i] == pair[1]) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

/// The tokens of the `index`th argument of the tuple between `open` and `close`.
fn argumentAt(tags: []const std.zig.Token.Tag, open: Ast.TokenIndex, close: Ast.TokenIndex, index: usize) ?Span {
    var depth: usize = 0;
    var found: usize = 0;
    var first = open + 1;
    var i = open + 1;
    while (i < close) : (i += 1) {
        switch (tags[i]) {
            .l_paren, .l_brace, .l_bracket => depth += 1,
            // Saturating: a file with a parse error may close a bracket it never opened.
            .r_paren, .r_brace, .r_bracket => depth -|= 1,
            .comma => if (depth == 0) {
                if (found == index) return .{ .first = first, .last = i - 1 };
                found += 1;
                first = i + 1;
            },
            else => {},
        }
    }
    return if (found == index and first < close) .{ .first = first, .last = close - 1 } else null;
}

/// The `@errorName` or `@tagName` call that `span` holds, when it holds one whole call.
fn builtinName(tree: Ast, tags: []const std.zig.Token.Tag, span: Span) ?[]const u8 {
    if (span.last < span.first + 3) return null;
    if (tags[span.first] != .builtin or tags[span.first + 1] != .l_paren) return null;
    if (closing(tags, span.first + 1, parens) != span.last) return null;
    const name = tree.tokenSlice(span.first);
    if (!std.mem.eql(u8, name, "@errorName") and !std.mem.eql(u8, name, "@tagName")) return null;
    return name;
}

test "a name written through a builtin into `{s}` is reported, and one written with `{t}` is not" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn report(err: anyerror, tag: Tag, held: []const u8, out: *std.Io.Writer) !void {
        \\    std.log.err("cannot read: {s}", .{@errorName(err)});
        \\    std.log.err("cannot read: {t}", .{err});
        \\    std.log.err("{{ {s} is {s}", .{ @errorName(err), @tagName(tag) });
        \\    std.log.warn("a failed ({s}) at {s}", .{ held, @tagName(tag) });
        \\    try out.print("{s:>8}", .{@errorName(err)});
        \\    try out.print("{s}", .{@as([]const u8, @tagName(tag))});
        \\    try out.print("held: {s}", .{held});
        \\    try out.print("a failed: {s} " ++ "at {s}", .{ held, @errorName(err) });
        \\    try out.print("{[0]s}", .{@errorName(err)});
        \\}
        \\
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@errorName(err)",
                .message = error_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@errorName(err)",
                .message = error_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@tagName(tag)",
                .message = tag_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@tagName(tag)",
                .message = tag_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@errorName(err)",
                .message = error_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@errorName(err)",
                .message = error_message,
            },
            .{
                .rule_id = "error_name_format",
                .severity = .@"error",
                .slice = "@errorName(err)",
                .message = error_message,
            },
        },
    );
}

test "a format that names its arguments by number still finds them" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn report(err: anyerror, held: []const u8) void {
        \\    std.log.err("{1s} at {0s}", .{ held, @errorName(err) });
        \\}
        \\
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "error_name_format",
            .severity = .@"error",
            .slice = "@errorName(err)",
            .message = error_message,
        }},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
