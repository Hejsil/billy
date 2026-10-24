//! The block a tool call shows as on the terminal: a header naming the tool and
//! what it acts on, and the result under it. The terminal's own rendering; the
//! web draws the same call as HTML, and the two share only the `Tools`
//! vocabulary they are built from.
const std = @import("std");
const Tools = @import("../Tools.zig");
const llm = @import("../llm.zig");
const diff = @import("../diff.zig");
const Writer = @import("Writer.zig");

const max_block_lines = 5;

/// Prints the block for a tool call and its result: a header naming the tool and
/// what it acts on, then its output. The transcript reuses it so a replay matches
/// the run. `scratch` is the caller's, for what the block builds, such as an
/// edit's diff.
pub fn describe(scratch: std.mem.Allocator, call: Tools.Call, result: []const u8, writer: Writer) !void {
    try printHead(scratch, call, writer);
    try printResult(call, result, writer);
    try writer.write("\n");
}

/// Prints the header block of a call: which tool it is and what it acts on. An
/// edit is shown as the diff of the strings it works on, a bash call as the
/// command it runs, and a search as the query it ran.
pub fn printHead(scratch: std.mem.Allocator, call: Tools.Call, writer: Writer) !void {
    const head = Tools.Heading.of(call);
    const mark = Writer.Mark{ .glyph = head.glyph, .hue = head.hue };
    try mark.header(head.name, head.target, writer);
    // What a call shows under its header: the change it means to make, or the
    // command it runs. Every other call is its header alone.
    switch (call) {
        .edit => |args| try printDiff(scratch, args.old_string, args.new_string, writer),
        .bash => |args| {
            // The command is shown as the model wrote it, with only the newline
            // that ends it dropped, so the block ends where the command does.
            try writer.write(std.mem.trimEnd(u8, args.command, "\n"));
            try writer.write("\n");
        },
        else => {},
    }
}

/// Prints an edit as the diff of the strings it asked to change: what was there
/// and what replaces it. The diff is built from the call, so it shows the model's
/// intent and a replay recomputes the same one. An edit that changes nothing
/// shows no diff at all.
fn printDiff(scratch: std.mem.Allocator, old: []const u8, new: []const u8, writer: Writer) !void {
    const lines = try diff.lines(scratch, old, new);
    defer scratch.free(lines);
    if (lines.len == 0) return;

    try printLabel("diff", writer);
    try diff.print(lines, writer);
}

/// The mark in front of the labels that break a block into sections, such as
/// `▾ stdout`. It points down at the lines under it, where the glyph of a tool
/// points at the call it names.
const label_mark = "▾";

/// How a section of a block is printed. The label line is bold, so it reads as
/// the heading of what follows, and the output under it is dim, so it stays
/// readable without competing with it.
const Ink = union(enum) {
    plain,
    dim,
    hue: Writer.Color,
};

/// Prints a label such as `▾ stdout` in bold, so it reads as the heading of the
/// lines under it rather than as the first of them.
fn printLabel(name: []const u8, writer: Writer) !void {
    try writer.print("{s}{s} {s}{s}\n", .{ writer.bold(), label_mark, name, writer.reset() });
}

/// Prints `text` in the way `ink` asks for.
fn printInk(text: []const u8, ink: Ink, writer: Writer) !void {
    switch (ink) {
        .plain => try writer.write(text),
        .dim => try writer.print("{s}{s}{s}", .{ writer.dim(), text, writer.reset() }),
        .hue => |hue| try writer.print("{s}{s}{s}", .{ writer.color(hue), text, writer.reset() }),
    }
}

/// Prints what a call produced under the `output` label. A write shows the content
/// it put in the file; an edit shows nothing, since its result would only repeat
/// the change shown above it. Anything that failed shows why instead, whatever
/// it was asked to do.
pub fn printResult(call: Tools.Call, result: []const u8, writer: Writer) !void {
    // A call that failed reports why, whatever it was asked to do. The whole
    // result is billy's own message, so it is shown the way billy shows a
    // failure.
    if (std.mem.startsWith(u8, result, "error: ")) {
        try printLabel("output", writer);
        return printTruncated(result, .{ .hue = .red }, writer);
    }
    switch (call) {
        // A write succeeds by putting the content in the file, so that content
        // is what it produced. It is on the call rather than in the result, so a
        // replayed session shows it without it having to be stored twice.
        .write => |args| {
            try printLabel("output", writer);
            return printTruncated(args.content, .dim, writer);
        },
        // An edit's result would only repeat the diff shown above it.
        .edit => {},
        .bash => return printBash(result, writer),
        else => {
            try printLabel("output", writer);
            return printTruncated(result, .dim, writer);
        },
    }
}

/// Prints the output of a bash call: the status the command exited with, and
/// then whatever it printed, one stream at a time. A command that printed
/// nothing shows its status alone, and each stream that has anything follows on
/// its own lines under a label naming it.
///
/// The status and the split are read back from the result, which is what billy
/// stored and handed the model, so a replayed session shows the same block.
fn printBash(result: []const u8, writer: Writer) !void {
    const parts = Tools.bashOutput(result) orelse {
        // A result that is not one billy wrote is shown as it is, so a session
        // saved before the status was written still shows everything.
        try printLabel("output", writer);
        return printTruncated(result, .dim, writer);
    };
    try printExit(parts.exit, writer);
    const streams = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "stdout", .text = parts.stdout },
        .{ .name = "stderr", .text = parts.stderr },
    };
    for (streams) |stream| {
        if (stream.text.len == 0) continue;
        try printLabel(stream.name, writer);
        try printTruncated(stream.text, .dim, writer);
    }
}

/// Prints the status a bash result opens with, on a line of its own: `✓ exit 0`
/// in green when the command succeeded, `✗ exit 1` and the rest in red when it
/// did not. The stored line reads `exit code: N` for the model; only the line
/// the user sees is marked and shortened.
fn printExit(exit: Tools.Exit, writer: Writer) !void {
    const mark = if (exit.ok) Tools.exit_marks.ok else Tools.exit_marks.failed;
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} exit {s}", .{ mark, exit.code }) catch exit.code;
    const hue: Writer.Color = if (exit.ok) .green else .red;
    try writer.print("{s}{s}{s}\n", .{ writer.boldColor(hue), line, writer.reset() });
}

/// Prints `text`, keeping at most `max_block_lines` lines. When it had more, a
/// count of the rest is printed in place of them, so the block stays short
/// without hiding that there was more. Every line is printed in `ink`, which is
/// dim for a tool's output and a colour for billy's own message.
fn printTruncated(text: []const u8, ink: Ink, writer: Writer) !void {
    const body = std.mem.trimEnd(u8, text, "\n");
    if (body.len == 0) return;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (shown == max_block_lines) continue;
        try printInk(line, ink, writer);
        try writer.write("\n");
        shown += 1;
    }
    if (total > shown) {
        try writer.print("{s}… {d} more lines{s}\n", .{ writer.dim(), total - shown, writer.reset() });
    }
}

test "describe frames a call and its output" {
    try expectDescribe(
        "▸ read a.zig\n▾ output\nfile content\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "file content",
        .plain,
    );
    // A write shows the content it put in the file, not its result.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nhello\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "wrote 5 bytes to a.zig",
        .plain,
    );
    // A write that failed shows why instead of the content it never wrote.
    try expectDescribe(
        "◂ write a.zig\n▾ output\nerror: cannot write a.zig: AccessDenied\n\n",
        "write",
        "{\"path\":\"a.zig\",\"content\":\"hello\"}",
        "error: cannot write a.zig: AccessDenied",
        .plain,
    );
    // An edit shows the diff of the strings it worked on, not its result.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-old text\n+new text\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"old text\",\"new_string\":\"new text\"}",
        "replaced 1 occurrence(s) in a.zig",
        .plain,
    );
    // The command of a bash call is printed whole.
    try expectDescribe(
        "❯ bash\nls -la\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"ls -la\"}",
        "exit code: 0\n(no output)\n",
        .plain,
    );
    // A web search shows the query it ran, and its results under the output
    // label like any other text a tool returned.
    try expectDescribe(
        "⌕ web_search zig lang\n▾ output\n1. Zig\n   https://ziglang.org\n\n",
        "web_search",
        "{\"query\":\"zig lang\"}",
        "1. Zig\n   https://ziglang.org",
        .plain,
    );
    // A web fetch shows the url it fetched, and the content it got back.
    try expectDescribe(
        "⇣ web_fetch https://ziglang.org\n▾ output\n# Zig\n\nA language.\n\n",
        "web_fetch",
        "{\"url\":\"https://ziglang.org\"}",
        "# Zig\n\nA language.",
        .plain,
    );
    // A tool that is not implemented shows its name, and the reason it could not
    // run reaches the user as the output.
    try expectDescribe(
        "? frobnicate\n▾ output\nerror: unknown tool 'frobnicate'\n\n",
        "frobnicate",
        "{}",
        "error: unknown tool 'frobnicate'",
        .plain,
    );
    // A known tool with broken arguments shows its name too.
    try expectDescribe(
        "? read\n▾ output\nerror: invalid arguments for read: SyntaxError\n\n",
        "read",
        "{",
        "error: invalid arguments for read: SyntaxError",
        .plain,
    );
    // A failed edit still shows the change it meant to make, then why it did not.
    try expectDescribe(
        "✎ edit a.zig\n▾ diff\n-x\n+y\n▾ output\n" ++
            "error: old_string not found in a.zig\n\n",
        "edit",
        "{\"path\":\"a.zig\",\"old_string\":\"x\",\"new_string\":\"y\"}",
        "error: old_string not found in a.zig",
        .plain,
    );
}

test "a block header names the tool, its colour, the bold name and the target" {
    // On a terminal that takes an escape code, the glyph carries the colour of
    // the tool, only the name is bold, and the target and the label are dimmed.
    try expectDescribe(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n\n",
        "read",
        "{\"path\":\"a.zig\"}",
        "",
        .ansi,
    );
    // A terminal that takes no escape code gets the same text without them.
    try expectDescribe("▸ read a.zig\n▾ output\n\n", "read", "{\"path\":\"a.zig\"}", "", .plain);
}

test "a bash call's description is shown in its header" {
    // The description the model gave is the header's target, and the command it
    // describes is still shown whole under it.
    try expectDescribe(
        "❯ bash run the test suite\ncargo test\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"cargo test\",\"description\":\"run the test suite\"}",
        "exit code: 0\n",
        .plain,
    );
    // A call from before the tool asked for a description has none, so the header
    // names only the tool; the command is still shown under it.
    try expectDescribe(
        "❯ bash\ncargo test\n✓ exit 0\n\n",
        "bash",
        "{\"command\":\"cargo test\"}",
        "exit code: 0\n",
        .plain,
    );
    // A description that runs over several lines is shown by its first line only,
    // since a header is one line.
    try expectHead(
        "❯ bash build the project\nmake\n",
        "bash",
        "{\"command\":\"make\",\"description\":\"build the project\\nand its docs\"}",
        .plain,
    );
}

test "the exit status of a bash call is shown green or red" {
    // A command that succeeded.
    try expectDescribe(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;32m✓ exit 0\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mbuilt\x1b[0m\n\n",
        "bash",
        "{\"command\":\"make\"}",
        "exit code: 0\nbuilt\n",
        .ansi,
    );
    // One that did not, whose output the terminal still shows as it is.
    try expectDescribe(
        "\x1b[36m❯\x1b[0m \x1b[1mbash\x1b[0m\nmake\n\x1b[1;31m✗ exit 2\x1b[0m\n\x1b[1m▾ stdout\x1b[0m\n\x1b[2mboom\x1b[0m\n\n",
        "bash",
        "{\"command\":\"make\"}",
        "exit code: 2\nboom\n",
        .ansi,
    );
}

test "a bash block shows only the streams the command filled" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var tool_set = try Tools.init(.{
        .io = io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .http = &http_client,
        .settings = .{ .bash_timeout_s = 120 },
    });
    const cases = [_]struct { command: []const u8, expected: []const u8 }{
        // Nothing printed: the status is all there is.
        .{ .command = "true", .expected = "❯ bash\ntrue\n✓ exit 0\n\n" },
        // One stream: it follows the status under a label of its own.
        .{ .command = "echo hi", .expected = "❯ bash\necho hi\n✓ exit 0\n▾ stdout\nhi\n\n" },
        .{ .command = "echo oops >&2", .expected = "❯ bash\necho oops >&2\n✓ exit 0\n▾ stderr\noops\n\n" },
        // Both, each under its own label, standard output first.
        .{ .command = "echo out; echo err >&2", .expected = "❯ bash\necho out; echo err >&2\n" ++
            "✓ exit 0\n▾ stdout\nout\n▾ stderr\nerr\n\n" },
        // A command that failed is the same shape with the status in red.
        .{ .command = "exit 3", .expected = "❯ bash\nexit 3\n✗ exit 3\n\n" },
    };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    for (cases) |case| {
        log.clearRetainingCapacity();
        result.clearRetainingCapacity();
        const arguments = try std.fmt.allocPrint(arena, "{{\"command\":{f}}}", .{
            std.json.fmt(case.command, .{}),
        });
        const parsed = try Tools.runCall(
            arena,
            &tool_set,
            .{ .id = "1", .function = .{ .name = "bash", .arguments = arguments } },
            &result.writer,
        );
        // `run` writes the result but shows nothing, so what a call and its
        // result look like is rendered here the way the terminal renders it.
        const shown: Writer = .{ .out = &log.writer };
        try describe(gpa, parsed, result.written(), shown);
        try std.testing.expectEqualStrings(case.expected, log.written());
    }
}

test "a bash result with no status line is shown as it is" {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"make\"}",
    } };

    // A session saved before the status was written into the result has none,
    // so nothing is claimed about the call and the whole result is shown.
    const shown: Writer = .{ .out = &out.writer };
    try describe(gpa, Tools.parse(arena, call), "built\nnothing to do", shown);
    try std.testing.expectEqualStrings(
        "❯ bash\nmake\n▾ output\nbuilt\nnothing to do\n\n",
        out.written(),
    );
    // The split a frontend showing the status apart reads it with is null for
    // the same result, so such a frontend falls back to showing it whole.
    try std.testing.expect(Tools.bashOutput("built\nnothing to do") == null);
}

test "what a call failed with is shown red, and what it left out is dimmed" {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer: Writer = .{ .style = .ansi, .out = &out.writer };

    // A failure is billy's own message, so the whole result is shown as one.
    try describe(gpa, Tools.parse(arena, .{ .id = "1", .function = .{
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    } }), "error: cannot read a.zig: FileNotFound", writer);
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n" ++
            "\x1b[31merror: cannot read a.zig: FileNotFound\x1b[0m\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The count of the lines left out is structure too, so it is dimmed.
    const ansi: Writer = .{ .style = .ansi, .out = &out.writer };
    try describe(
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        ansi,
    );
    try std.testing.expectEqualStrings(
        "\x1b[34m▸\x1b[0m \x1b[1mread\x1b[0m \x1b[2ma.zig\x1b[0m\n\x1b[1m▾ output\x1b[0m\n" ++
            "\x1b[2m1\x1b[0m\n\x1b[2m2\x1b[0m\n\x1b[2m3\x1b[0m\n\x1b[2m4\x1b[0m\n\x1b[2m5\x1b[0m\n" ++
            "\x1b[2m… 2 more lines\x1b[0m\n\n",
        out.written(),
    );
}

test "describe keeps a block short and says how much it left out" {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Exactly the limit: nothing is left out.
    const plain: Writer = .{ .out = &out.writer };
    try describe(
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5",
        plain,
    );
    try std.testing.expectEqualStrings(
        "▸ read a.zig\n▾ output\n1\n2\n3\n4\n5\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // Past the limit: the rest is replaced by a count of the lines left out. The
    // trailing newline of a result is not a line of its own.
    try describe(
        arena_state.allocator(),
        .{ .read = .{ .path = "a.zig" } },
        "1\n2\n3\n4\n5\n6\n7\n",
        plain,
    );
    try std.testing.expectEqualStrings(
        "▸ read a.zig\n▾ output\n1\n2\n3\n4\n5\n… 2 more lines\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // An empty result leaves the header with nothing under it.
    try describe(arena_state.allocator(), .{ .read = .{ .path = "a.zig" } }, "", plain);
    try std.testing.expectEqualStrings("▸ read a.zig\n▾ output\n\n", out.written());
    out.clearRetainingCapacity();

    // An edit shows the diff of the strings it worked on: the whole old side,
    // then the new, each line marked.
    try describe(
        arena_state.allocator(),
        .{ .edit = .{
            .path = "a.zig",
            .old_string = "1\n2\n3\n4\n5\n6",
            .new_string = "b",
        } },
        "replaced 1 occurrence(s) in a.zig",
        plain,
    );
    try std.testing.expectEqualStrings(
        "✎ edit a.zig\n▾ diff\n-1\n-2\n-3\n-4\n-5\n-6\n+b\n\n",
        out.written(),
    );
}

test "run logs exactly what describe prints" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var tool_set = try Tools.init(.{
        .io = io,
        .dir = std.Io.Dir.cwd(),
        .gpa = gpa,
        .http = &http_client,
        .settings = .{ .bash_timeout_s = 120 },
    });
    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"true\"}",
    } };
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    const parsed = try Tools.runCall(arena, &tool_set, call, &result.writer);

    const shown: Writer = .{ .out = &log.writer };
    try describe(gpa, parsed, result.written(), shown);
    try std.testing.expectEqualStrings(
        "❯ bash\ntrue\n✓ exit 0\n\n",
        log.written(),
    );
}

/// Renders a call named `name` with `arguments` and the `result` it produced,
/// and checks it against `expected`. One call is one line of the test.
fn expectDescribe(
    expected: []const u8,
    name: []const u8,
    arguments: []const u8,
    result: []const u8,
    style: Writer.Style,
) !void {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer: Writer = .{ .style = style, .out = &out.writer };
    try describe(arena_state.allocator(), Tools.parse(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), result, writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Writes the header of a call named `name` with `arguments`, and checks it
/// against `expected`. A header alone, without a result under it.
fn expectHead(expected: []const u8, name: []const u8, arguments: []const u8, style: Writer.Style) !void {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer: Writer = .{ .style = style, .out = &out.writer };
    try printHead(arena_state.allocator(), Tools.parse(arena_state.allocator(), .{ .id = "1", .function = .{
        .name = name,
        .arguments = arguments,
    } }), writer);
    try std.testing.expectEqualStrings(expected, out.written());
}
