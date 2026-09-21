//! The agent loop: read a request from the user, ask the model, run the tools
//! it asks for, and repeat until it answers with text.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const models = @import("models.zig");
const Tools = @import("Tools.zig");
const search = @import("search.zig");
const LineEditor = @import("LineEditor.zig");
const Session = @import("Session.zig");
const formatting = @import("format.zig");
const styling = @import("style.zig");

pub const Config = struct {
    api_key: []const u8,
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    model: []const u8,
    /// Model turns allowed for one request before the harness gives up on it.
    max_turns: usize,
    /// Longest a bash command may run before it is killed, in seconds, from the
    /// configuration. The tools are given it so a runaway command cannot hang
    /// the agent forever.
    bash_timeout_s: usize,
    /// Working directory, shown in the header.
    cwd: []const u8,
    /// Home directory, so the header can shorten a path inside it; null when unset.
    home: ?[]const u8,
    /// What is known about the provider and model: the context window and the
    /// prices. Null for a model billy does not know, in which case the header
    /// leaves out the context gauge and the cost.
    model_info: ?models.Metadata,
    /// How what billy shows is laid out and decorated, from the configuration.
    display: Display = .{},
    /// Web search, when the configuration names a backend and its key is set.
    /// Null leaves `web_search` out of the tools the model is offered.
    search: ?search.Config = null,
};

/// How billy lays out and decorates what it shows: the formatter scripts for a
/// tool's block, the markdown formatter and the terminal style. They travel
/// together through the printing, so they are gathered here rather than passed
/// apart as a run of arguments that had grown hard to read.
///
/// The layout is presentation only: the command that runs, what a session stores
/// and what the model is sent keep the text as it was written.
pub const Display = struct {
    /// How a tool's block is laid out before it is shown: a bash command and an
    /// edit's diff. Null shows each as it was written.
    formats: Tools.Formats = .{},
    /// How the markdown of a reply and a prompt is laid out before it is shown.
    /// Null shows the text as written.
    markdown: formatting.Format = null,
    /// How billy decorates the lines it prints itself, such as a block header.
    /// Plain everywhere the terminal does not take escape codes.
    style: styling.Style = .plain,
};

const system_prompt =
    \\You are a coding agent working in the user's project directory.
    \\Inspect the code before you change it, and use the tools to do the work.
    \\Reply with plain text when the task is done.
;

/// The files a project's own instructions are read from, in the order they are
/// tried. `AGENTS.md` is the open convention; `CLAUDE.md` is accepted after it so
/// that a project which wrote one for another tool need not rename it.
const instruction_files = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
/// Longest project instructions read back, so an outsize file cannot exhaust
/// memory.
const max_instructions_len = 1 << 20;

/// The project's own instructions, read from `dir` or the nearest parent that
/// has them, and null when the project has none. The walk stops at the
/// repository root, so a file above the project is not read, and at the
/// filesystem root when there is no repository above it.
///
/// The instructions join the system prompt rather than the conversation, so they
/// are sent with every request and survive whatever context trimming happens
/// later. That is what keeps the rules a project cares about from being dropped
/// partway through a long session.
///
/// The result is owned by `gpa`; the caller frees it once the prompt is built.
fn projectInstructions(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !?[]const u8 {
    var current = dir;
    // The directory the caller passed is theirs to close; every one opened here
    // while walking up is this function's.
    var owned = false;
    defer if (owned) current.close(io);

    while (true) {
        for (instruction_files) |name| {
            const text = current.readFileAlloc(io, name, gpa, .limited(max_instructions_len)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer gpa.free(text);
            // An empty file is nothing to say, so the search carries on rather
            // than putting a blank heading in the prompt.
            const body = std.mem.trimEnd(u8, text, " \t\r\n");
            if (body.len == 0) continue;
            return try std.fmt.allocPrint(
                gpa,
                "The project's instructions follow, read from {s}.\n\n{s}",
                .{ name, body },
            );
        }
        // The repository root is the last directory searched.
        if (dirHas(io, current, ".git")) return null;

        // The parent is opened rather than derived from a path, so the walk
        // keeps no path string and follows the filesystem's own notion of a
        // parent.
        const parent = current.openDir(io, "..", .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        // At the filesystem root, `..` is the directory itself, which is what
        // ends the walk when no repository root was found above.
        if (sameDir(io, current, parent)) {
            parent.close(io);
            return null;
        }
        if (owned) current.close(io);
        current = parent;
        owned = true;
    }
}

/// Whether `dir` holds an entry named `name`.
fn dirHas(io: Io, dir: Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

/// Whether two handles name the same directory. This is how the walk up knows it
/// has reached the filesystem root, where `..` names the root itself. Both are
/// on the same filesystem, being a directory and its own parent, so the inode
/// tells them apart.
fn sameDir(io: Io, a: Io.Dir, b: Io.Dir) bool {
    const one = a.statFile(io, ".", .{}) catch return false;
    const two = b.statFile(io, ".", .{}) catch return false;
    return one.inode == two.inode;
}

/// Printed in front of every line the user types. The transcript reuses it so a
/// replayed session looks like the run it continues.
const prompt = "> ";

/// The marks the two halves of the conversation are headed by. Neither is a
/// tool, so neither carries a tool's glyph.
const marks = struct {
    const prompt = styling.Mark{ .glyph = "»", .hue = .blue };
    const answer = styling.Mark{ .glyph = "◆", .hue = .green };
};

/// Writes the header line shown above the input prompt: the session id, the
/// model, the working directory, how much of the context window the
/// conversation fills, and what the session has cost so far. The id is shown so
/// that a run can be named by what it prints, which is what `--resume` takes to
/// continue it. The window size and the prices are not reported by the API, so
/// they come from the model table. `cost` is the session total the loop has
/// accumulated, so it does not move as the clock passes a rate change.
///
/// It is written to `out` rather than returned, so building the header
/// allocates nothing; the caller holds the buffer, which it already has for
/// the line editor.
pub fn sessionHeader(
    out: *Io.Writer,
    config: Config,
    session_id: []const u8,
    context_tokens: usize,
    cost: f64,
) !void {
    try out.print("billy · {s} · {s} · ", .{ session_id, config.model });
    try displayPath(out, config.cwd, config.home);
    if (config.model_info) |info| {
        try out.writeAll(" · ");
        try formatTokens(out, context_tokens);
        try out.writeAll("/");
        try formatTokens(out, info.context_window);
        try out.writeAll(" (");
        try formatPercent(out, context_tokens, info.context_window);
        try out.writeAll(") · ");
        try formatMoney(out, cost);
    }
}

/// What a usage costs at the given prices, in USD.
pub fn costOf(price: models.Price, usage: llm.Usage) f64 {
    const million = @as(f64, 1_000_000);
    const hit: f64 = @floatFromInt(usage.cache_hit_tokens);
    const miss: f64 = @floatFromInt(usage.cache_miss_tokens);
    const output: f64 = @floatFromInt(usage.completion_tokens);
    return (hit * price.cache_hit_input +
        miss * price.cache_miss_input +
        output * price.output) / million;
}

/// Writes a token count in a short form, such as `16k` or `128k`, with no
/// decimals.
fn formatTokens(out: *Io.Writer, count: usize) !void {
    if (count < 1000) return out.print("{d}", .{count});
    if (count < 1_000_000) return formatScaled(out, count, 1000, 'k');
    return formatScaled(out, count, 1_000_000, 'M');
}

/// Writes `count` divided by `unit`, rounded to a whole number, with a trailing
/// unit letter. The rounding is what makes a count readable without a decimal:
/// half a thousand reads as the next thousand.
fn formatScaled(out: *Io.Writer, count: usize, unit: usize, suffix: u8) !void {
    try out.print("{d:.0}{c}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(unit)),
        suffix,
    });
}

/// Writes how full the context window is, as a whole percentage. A conversation
/// that has started but is under one percent is reported as `<1%`, so the gauge
/// does not read as empty.
fn formatPercent(out: *Io.Writer, used: usize, total: usize) !void {
    if (total == 0) return out.writeAll("0%");
    const percent = used * 100 / total;
    if (percent == 0 and used > 0) return out.writeAll("<1%");
    try out.print("{d}%", .{percent});
}

/// Writes a dollar amount, rounded to the cent with the trailing zeros dropped,
/// so that `$1.5` and `$0` read the same way `1.5k` does, without padding to a
/// fixed number of places. The digits are formatted into a stack buffer first,
/// since the trimmed amount is written before the ones it dropped are known.
fn formatMoney(out: *Io.Writer, amount: f64) !void {
    var buffer: [64]u8 = undefined;
    var formatted: std.Io.Writer = .fixed(&buffer);
    try formatted.print("{d:.2}", .{amount});
    const digits = formatted.buffered();

    // Drop the trailing zeros of the hundredths, then a bare decimal point.
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    if (end > 0 and digits[end - 1] == '.') end -= 1;

    try out.print("${s}", .{digits[0..end]});
}

/// Writes the working directory as shown in the header. A path inside the home
/// directory is shortened to `~` so a long path stays readable.
fn displayPath(out: *Io.Writer, cwd: []const u8, home: ?[]const u8) !void {
    if (home) |dir| {
        // Require a component boundary, so `/home/user2` is not shortened by a
        // `/home/user` home directory.
        if (dir.len > 0 and std.mem.startsWith(u8, cwd, dir)) {
            const rest = cwd[dir.len..];
            if (rest.len == 0) return out.writeAll("~");
            if (rest[0] == '/') return out.print("~{s}", .{rest});
        }
    }
    return out.writeAll(cwd);
}

pub fn run(
    io: Io,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    config: Config,
    session: *Session,
) !void {
    // The tools work in the session's own directory, which for a resumed session
    // is the one it was started in, wherever billy is run from now. The project's
    // instructions are read from there too, so they are the ones of the project
    // the session belongs to.
    var work_dir = Io.Dir.openDirAbsolute(io, session.cwd, .{}) catch |err| {
        std.log.err("cannot work in {s}: {s}", .{ session.cwd, @errorName(err) });
        return err;
    };
    defer work_dir.close(io);

    // One HTTP client for the run, shared by the model requests and the search
    // backend, so both reuse its connections and share the certificates it scans
    // once.
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    // The editor holds the lines it returns and its history in an arena of its
    // own, over `gpa`, so the run need not keep an allocator for them.
    var editor = LineEditor.init(io, out, gpa);
    defer editor.deinit();
    var tool_set = try Tools.init(.{
        .io = io,
        .dir = work_dir,
        .gpa = gpa,
        .log = out,
        .formats = config.display.formats,
        .bash_timeout_s = config.bash_timeout_s,
        .style = config.display.style,
        .search = config.search,
        .http = &http,
    });
    defer tool_set.deinit();
    var client: llm.Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = config.api_key,
        .url = config.url,
        .model = config.model,
        .http = &http,
    };

    // The prompt and the tool definitions are stored with the session and reused
    // on a resume, so the request sent then matches the earlier run byte for byte
    // and hits the prompt cache. They are set only on a session that has none, so
    // a new session gets the current ones while a resumed one keeps what it was
    // saved with. The project's own instructions are part of the prompt, so they
    // are sent with every request. Both are dropped once the session has copied
    // them.
    const instructions = try projectInstructions(io, gpa, work_dir);
    defer if (instructions) |text| gpa.free(text);
    const prompt_text = if (instructions) |text|
        try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ system_prompt, text })
    else
        try gpa.dupe(u8, system_prompt);
    defer gpa.free(prompt_text);
    try session.appendSystemPrompt(prompt_text);
    try session.ensureTools(tool_set.definitions());

    // The header is rebuilt for every prompt, so it reflects the tokens and cost
    // of the turns run so far. One buffer holds it for the whole loop; each pass
    // clears it and writes the header into it.
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        header.clearRetainingCapacity();
        try sessionHeader(&header.writer, config, session.id(), session.context_tokens, session.cost);
        const line = (try editor.readLine(header.written(), prompt)) orelse break;
        if (line.len == 0) continue;
        try session.append(.{ .role = "user", .content = line });
        // The line editor has erased the prompt it was typed behind, so the
        // prompt is written out now as the block a replay shows: the `> ` belongs
        // to the input, not to what was said. Flushed before the request, which
        // may take a while, so the user sees what was sent.
        try printPrompt(out, line, config.display);
        try out.flush();
        // A failed request must not end the session: report it and take the
        // next request from the user.
        turn(io, &client, &tool_set, out, config, session) catch |err|
            std.log.err("request failed: {s}", .{@errorName(err)});
    }
    try out.flush();
}

/// Replays a stored conversation as the blocks it was made of, so that
/// remembering the context of an earlier run is not left to the user. The tool
/// calls go through `Tools.parseCall` and `Tools.describe`, and the replies
/// through `printAnswer`, the same as the ones the loop printed.
///
/// A prompt is headed and laid out by `printPrompt` here and in the loop alike,
/// so a replayed one reads exactly as the one that was typed, without the `> `
/// the input is typed behind.
///
/// The conversation is read where it is stored, a message at a time, so replaying
/// a long session costs no more than the largest message in it. `gpa` is for the
/// scratch the parsed arguments of a call need, which is dropped between
/// messages.
pub fn printTranscript(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    session: *const Session,
    display: Display,
) !void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    for (session.messages.items, 0..) |message, index| {
        try printMessage(scratch, out, session, index, message, display);
        _ = scratch_state.reset(.retain_capacity);
    }
    try out.flush();
}

/// Prints one message the way a live session shows it. The system prompt is never
/// shown while running, so it is left out here too. A tool result is shown as the
/// output of the call that produced it, and not as a message of its own.
///
/// The message is the one the session stores, so every string printed is read
/// out of the pool as it is printed and no message is built to print it.
fn printMessage(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    session: *const Session,
    index: usize,
    message: Session.Message,
    display: Display,
) !void {
    const role = session.roleOf(message);
    if (std.mem.eql(u8, role, "user")) {
        // A prompt from the session opens a block like everything else in the
        // transcript, after the blank line that separates it from what came
        // before. The loop prints the same block, without that line, since the
        // prompt it just erased already stood on its own row.
        try out.writeAll("\n");
        return printPrompt(out, session.contentOf(message) orelse "", display);
    }
    if (!std.mem.eql(u8, role, "assistant")) return;

    const calls = session.callCount(message);
    if (calls == 0) return printAnswer(out, session.contentOf(message), display);
    for (0..calls) |i| {
        const call = session.callAt(message, i);
        // The result belongs to the message just after the one that asked for
        // it, so the search starts from there.
        try Tools.describe(
            arena,
            Tools.parseCallNamed(arena, call.name, call.arguments),
            session.toolResult(index + 1, call.id),
            display.formats,
            display.style,
            out,
        );
    }
}

/// Runs the model until it replies with text instead of tool calls.
fn turn(
    io: Io,
    client: *llm.Client,
    tool_set: *Tools,
    out: *Io.Writer,
    config: Config,
    session: *Session,
) !void {
    var remaining: usize = config.max_turns;
    while (remaining > 0) : (remaining -= 1) {
        // The completion owns its parsed reply, and each tool result lives in the
        // tool set's scratch, so the turn allocates nothing of its own: the
        // conversation is written straight onto the connection out of the pool,
        // the reply is freed when the turn ends, and the session interns what it
        // keeps.
        const completion = try client.complete(client.gpa, session.conversation(), session.toolSet());
        defer completion.deinit();

        // The totals are recorded first, so the save inside `append` stores them
        // along with the message. Each request is priced as it is made, at the
        // rates in effect then, so a session running through a rate change is
        // billed for what it actually cost.
        session.recordUsage(completion.usage, costOf(rateNow(io, config), completion.usage));
        try session.append(completion.message);

        const message = completion.message;
        const calls = message.tool_calls orelse
            return printAnswer(out, message.content, config.display);
        if (calls.len == 0) return printAnswer(out, message.content, config.display);

        for (calls) |call| {
            try session.append(.{
                .role = "tool",
                .tool_call_id = call.id,
                .content = try tool_set.run(call),
            });
        }
    }
    try out.print("stopped after {d} turns without a final answer\n", .{config.max_turns});
    try out.flush();
}

/// The rates in effect right now. Zero for a model billy does not know, which
/// has no prices to cost its tokens at.
fn rateNow(io: Io, config: Config) models.Price {
    const info = config.model_info orelse return .{};
    return info.priceAt(@intCast(Io.Clock.now(.real, io).toSeconds()));
}

/// Prints a prompt as its own block: the `» prompt` header, then the text, laid
/// out by `markdown` when one is set, and a blank line after it. A live prompt
/// and a replayed one are both printed by this, so the two read the same. The
/// `> ` the line is typed behind is not part of the prompt and is not printed.
///
/// The blank line keeps the prompt from reading as the label of the answer or
/// the tool block that follows it, which begin on the very next row otherwise.
fn printPrompt(out: *Io.Writer, text: []const u8, display: Display) !void {
    try styling.header(marks.prompt, "prompt", "", display.style, out);
    if (!try formatting.apply(display.markdown, text, out)) try out.writeAll(text);
    try out.writeAll("\n\n");
}

/// Prints a reply under its own header, the markdown laid out by `markdown` when
/// one is set and as it was written when there is none or it cannot be used.
/// Only the display changes; the session and the model keep the text itself.
fn printAnswer(out: *Io.Writer, content: ?[]const u8, display: Display) !void {
    try styling.header(marks.answer, "answer", "", display.style, out);
    const text = content orelse "";
    if (text.len == 0) {
        try display.style.dim("(empty reply)", out);
    } else if (!try formatting.apply(display.markdown, text, out)) {
        try out.writeAll(text);
    }
    try out.writeAll("\n");
    try out.flush();
}

/// Prints `messages` the way a resumed session replays them, from a session
/// built to hold exactly them, and compares the blocks to `expected`. The
/// transcript reads the conversation where a session stores it, so the messages
/// have to go through a session to be replayed at all.
fn expectTranscript(
    expected: []const u8,
    messages: []const llm.Message,
    markdown: formatting.Format,
    style: styling.Style,
) !void {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // No bash format: what these cover is how a message is headed and laid out,
    // which the tool format does not touch.
    try printTranscript(gpa, &out.writer, &session, .{ .markdown = markdown, .style = style });
    try std.testing.expectEqualStrings(expected, out.written());
}

test "printTranscript replays a conversation as the blocks it was made of" {
    // The system prompt is never shown while running, the tool result only as
    // the output of the call it belongs to.
    try expectTranscript(
        "\n» prompt\nhello\n\n" ++
            "▸ read a.zig\n▾ output\n1\tconst x = 1;\n\n" ++
            "◆ answer\ndone\n",
        &.{
            .{ .role = "system", .content = "ignore me" },
            .{ .role = "user", .content = "hello" },
            .{ .role = "assistant", .tool_calls = &.{.{
                .id = "call_1",
                .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
            }} },
            .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
            .{ .role = "assistant", .content = "done" },
        },
        null,
        .plain,
    );
}

test "printTranscript leaves out the system prompt and an unpaired tool result" {
    // A result whose call is not in the session has nothing to belong to, and a
    // system prompt is never shown at all.
    try expectTranscript(
        "",
        &.{
            .{ .role = "system", .content = "ignore me" },
            .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
        },
        null,
        .plain,
    );
}

test "a reply is headed by its own header, and its markdown laid out" {
    // `tr` stands in for a markdown formatter: it reads the reply and writes it
    // back upper case, so what the display shows is plainly not the text itself.
    const markdown: formatting.Format = .{
        .script = "tr a-z A-Z",
        .io = std.testing.io,
        .gpa = std.testing.allocator,
    };
    try expectTranscript(
        "◆ answer\nHELLO\n",
        &.{.{ .role = "assistant", .content = "hello" }},
        markdown,
        .plain,
    );

    // No formatter, and one that fails, both leave the reply as it was written.
    try expectTranscript(
        "◆ answer\nhello\n",
        &.{.{ .role = "assistant", .content = "hello" }},
        null,
        .plain,
    );
    const broken: formatting.Format = .{
        .script = "exit 1",
        .io = std.testing.io,
        .gpa = std.testing.allocator,
    };
    try expectTranscript(
        "◆ answer\nhello\n",
        &.{.{ .role = "assistant", .content = "hello" }},
        broken,
        .plain,
    );
}

test "a prompt from the session is headed and laid out like a reply" {
    // The same stand-in formatter as a reply: a prompt is markdown too, so it is
    // laid out by the same script.
    const markdown: formatting.Format = .{
        .script = "tr a-z A-Z",
        .io = std.testing.io,
        .gpa = std.testing.allocator,
    };
    try expectTranscript(
        "\n» prompt\nHELLO\n\n",
        &.{.{ .role = "user", .content = "hello" }},
        markdown,
        .plain,
    );

    // Without one, the prompt is shown as it was typed.
    try expectTranscript(
        "\n» prompt\nhello\n\n",
        &.{.{ .role = "user", .content = "hello" }},
        null,
        .plain,
    );
}

test "a prompt is headed by the same block live and replayed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The block a replay shows, but with no blank line in front: it is printed
    // where the line editor left the cursor, on the row the header stood on.
    try printPrompt(&out.writer, "hello", .{ .style = .plain });
    try std.testing.expectEqualStrings("» prompt\nhello\n\n", out.written());
    out.clearRetainingCapacity();

    // A prompt is markdown, so it is laid out by the same script as a reply.
    const markdown: formatting.Format = .{
        .script = "tr a-z A-Z",
        .io = std.testing.io,
        .gpa = gpa,
    };
    try printPrompt(&out.writer, "hello", .{ .markdown = markdown, .style = .plain });
    try std.testing.expectEqualStrings("» prompt\nHELLO\n\n", out.written());
    out.clearRetainingCapacity();

    // The `> ` the line was typed behind is not part of the block.
    try printPrompt(&out.writer, "hello", .{ .style = .ansi });
    try std.testing.expectEqualStrings("\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\nhello\n\n", out.written());
}

test "an empty reply is shown under its header, in place of the text" {
    try expectTranscript(
        "◆ answer\n(empty reply)\n",
        &.{.{ .role = "assistant", .content = "" }},
        null,
        .plain,
    );
}

test "a prompt and a reply are headed alike, in the colours of the display" {
    // The user's block opens with the prompt mark and the reply with the answer
    // mark, each bold, and neither carries the `> ` the live input uses.
    try expectTranscript(
        "\n\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\nhello\n\n" ++
            "\x1b[32m◆\x1b[0m \x1b[1manswer\x1b[0m\nhi\n",
        &.{
            .{ .role = "user", .content = "hello" },
            .{ .role = "assistant", .content = "hi" },
        },
        null,
        .ansi,
    );
}

test "printTranscript gives each call the result that names it" {
    try expectTranscript(
        "▸ read a.zig\n▾ output\ncontents of a\n\n" ++
            "▸ read b.zig\n▾ output\ncontents of b\n\n",
        &.{
            .{ .role = "assistant", .tool_calls = &.{
                .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
                .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
            } },
            .{ .role = "tool", .tool_call_id = "call_1", .content = "contents of a" },
            .{ .role = "tool", .tool_call_id = "call_2", .content = "contents of b" },
        },
        null,
        .plain,
    );
}

test "printTranscript rebuilds an edit's diff from the stored call" {
    // The diff is computed from the call, so a replay shows the same one the run
    // did without the diff having been stored.
    try expectTranscript(
        "✎ edit a.zig\n▾ diff\n-old\n+new\n\n",
        &.{
            .{ .role = "assistant", .tool_calls = &.{.{
                .id = "call_1",
                .function = .{
                    .name = "edit",
                    .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
                },
            }} },
            .{ .role = "tool", .tool_call_id = "call_1", .content = "replaced 1 occurrence(s) in a.zig" },
        },
        null,
        .plain,
    );
}

/// A config with no model metadata, so the header is just the model and the
/// directory. Tests that need a gauge fill `model_info` in.
fn testConfig(model: []const u8, cwd: []const u8, home: ?[]const u8) Config {
    return .{
        .api_key = "k",
        .url = "u",
        .model = model,
        .max_turns = 10,
        .bash_timeout_s = 120,
        .cwd = cwd,
        .home = home,
        .model_info = null,
    };
}

/// Off-peak on a Friday, so the rates are the published base rates.
const off_peak_utc = 1789732800; // Friday 2026-09-18 12:00 UTC
/// Peak on a Friday, when DeepSeek doubles its rates.
const peak_utc = 1789696800; // Friday 2026-09-18 02:00 UTC

/// The id the header tests run under. A real one is the UTC timestamp of the
/// session, but the header only prints it, so the same id serves every test.
const test_session_id = "20250131-120000";

/// Writes the header for `config` and compares it to `expected`, so a header
/// test reads as the line it produces rather than as the buffer around it.
fn expectHeader(expected: []const u8, config: Config, context_tokens: usize, cost: f64) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try sessionHeader(&out.writer, config, test_session_id, context_tokens, cost);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Writes a token count and compares it to `expected`.
fn expectTokens(expected: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try formatTokens(&out.writer, count);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Writes a money amount and compares it to `expected`.
fn expectMoney(expected: []const u8, amount: f64) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try formatMoney(&out.writer, amount);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "header names the session, the model and the working directory" {
    try expectHeader(
        "billy · 20250131-120000 · deepseek-flash · /work",
        testConfig("deepseek-flash", "/work", null),
        0,
        0,
    );
}

test "header shortens a path inside the home directory" {
    try expectHeader(
        "billy · 20250131-120000 · m · ~/repo/billy",
        testConfig("m", "/home/user/repo/billy", "/home/user"),
        0,
        0,
    );
    // The home directory itself becomes just `~`.
    try expectHeader(
        "billy · 20250131-120000 · m · ~",
        testConfig("m", "/home/user", "/home/user"),
        0,
        0,
    );
    // A sibling that merely shares the prefix is left alone.
    try expectHeader(
        "billy · 20250131-120000 · m · /home/user2",
        testConfig("m", "/home/user2", "/home/user"),
        0,
        0,
    );
}

test "header shows how full the context window is" {
    // A model with a small window, so the numbers are easy to read.
    var config = testConfig("m", "/work", null);
    config.model_info = .{
        .provider = .deepseek,
        .model = "m",
        .context_window = 128_000,
        .price = .{ .cache_hit_input = 0.003, .cache_miss_input = 0.15, .output = 0.6 },
    };

    // A fresh session has used nothing.
    try expectHeader("billy · 20250131-120000 · m · /work · 0/128k (0%) · $0", config, 0, 0);
    // A rounded-to-zero percentage still shows the conversation is not empty.
    try expectHeader("billy · 20250131-120000 · m · /work · 500/128k (<1%) · $0", config, 500, 0);
    try expectHeader("billy · 20250131-120000 · m · /work · 16k/128k (12%) · $0", config, 16_000, 0);
    // A full window, and a count that rounds to a whole thousand.
    try expectHeader("billy · 20250131-120000 · m · /work · 128k/128k (100%) · $0", config, 128_000, 0);
    try expectHeader("billy · 20250131-120000 · m · /work · 13k/128k (9%) · $0", config, 12_500, 0);
}

test "header shows the accumulated session cost" {
    // The real deepseek-flash rates, off-peak, against a window the totals fit.
    const info = models.lookup(.deepseek, "deepseek-flash").?;
    var config = testConfig("deepseek-flash", "/work", null);
    config.model_info = .{
        .provider = info.provider,
        .model = info.model,
        .context_window = 4_000_000,
        .price = info.price,
    };

    // A million of each token, so the cost is large enough to show in cents:
    // 1000000*0.003 + 1000000*0.15 + 1000000*0.6, all per million.
    const usage: llm.Usage = .{
        .prompt_tokens = 2_000_000,
        .completion_tokens = 1_000_000,
        .total_tokens = 3_000_000,
        .cache_hit_tokens = 1_000_000,
        .cache_miss_tokens = 1_000_000,
    };
    const off_peak_cost = costOf(info.priceAt(off_peak_utc), usage);
    try expectHeader("billy · 20250131-120000 · deepseek-flash · /work · 3M/4M (75%) · $0.75", config, 3_000_000, off_peak_cost);
    // A request made in peak hours cost double, which stays on the total even if
    // the header is shown later, off-peak.
    const peak_cost = costOf(info.priceAt(peak_utc), usage);
    try expectHeader("billy · 20250131-120000 · deepseek-flash · /work · 3M/4M (75%) · $1.51", config, 3_000_000, peak_cost);
}

test "token counts are whole and prices keep at most two decimals" {
    // A count is never shown with a decimal, so half a thousand rounds up.
    try expectTokens("0", 0);
    try expectTokens("999", 999);
    try expectTokens("1k", 1000);
    try expectTokens("13k", 12_500);
    try expectTokens("128k", 128_000);
    try expectTokens("1M", 1_000_000);

    // A price is rounded to the cent, and the zeros it does not need are dropped.
    try expectMoney("$0", 0);
    try expectMoney("$0.01", 0.007);
    try expectMoney("$0.5", 0.5);
    try expectMoney("$1", 1);
    try expectMoney("$1.25", 1.25);
    try expectMoney("$1.51", 1.506);
}

test "header leaves out the gauge and cost for an unknown model" {
    const config = testConfig("who-knows", "/work", null);
    try std.testing.expect(config.model_info == null);
    try expectHeader("billy · 20250131-120000 · who-knows · /work", config, 5000, 12.34);
}

test "cost follows the cache hit, miss and output prices" {
    const price = models.Price{ .cache_hit_input = 0.1, .cache_miss_input = 1, .output = 2 };
    const usage: llm.Usage = .{
        .completion_tokens = 1_000_000,
        .cache_hit_tokens = 1_000_000,
        .cache_miss_tokens = 1_000_000,
    };
    try std.testing.expectEqual(3.1, costOf(price, usage));
}

test "the project's instructions are read from the working directory" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "Write tests.\n" });

    const text = (try projectInstructions(std.testing.io, arena, tmp.dir)).?;
    // The prompt names where the instructions came from and carries them through.
    try std.testing.expect(std.mem.indexOf(u8, text, "AGENTS.md") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Write tests."));
}

test "AGENTS.md is read before CLAUDE.md" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "agents" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude" });

    const text = (try projectInstructions(std.testing.io, arena, tmp.dir)).?;
    try std.testing.expect(std.mem.endsWith(u8, text, "agents"));

    // With no AGENTS.md the other name is read, so a project written for another
    // tool still works.
    try tmp.dir.deleteFile(std.testing.io, "AGENTS.md");
    const claude = (try projectInstructions(std.testing.io, arena, tmp.dir)).?;
    try std.testing.expect(std.mem.indexOf(u8, claude, "CLAUDE.md") != null);
    try std.testing.expect(std.mem.endsWith(u8, claude, "claude"));
}

test "the instructions are found in a parent up to the repository root" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A repository root holding the instructions, and a subdirectory to run from.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "root rules" });
    try tmp.dir.createDirPath(std.testing.io, "a/b");

    var deep = try tmp.dir.openDir(std.testing.io, "a/b", .{});
    defer deep.close(std.testing.io);
    const text = (try projectInstructions(std.testing.io, arena, deep)).?;
    try std.testing.expect(std.mem.endsWith(u8, text, "root rules"));
}

test "a project with no instructions has none" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A repository root, so the search stops here rather than walking above it.
    try tmp.dir.createDirPath(std.testing.io, ".git");

    try std.testing.expect((try projectInstructions(std.testing.io, arena, tmp.dir)) == null);
}

test "an empty instructions file is not used" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "  \n\n" });

    try std.testing.expect((try projectInstructions(std.testing.io, arena, tmp.dir)) == null);
}

test "the nearest instructions win over an ancestor's" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "outer" });
    try tmp.dir.createDirPath(std.testing.io, "inner");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "inner/AGENTS.md", .data = "inner" });

    var inner = try tmp.dir.openDir(std.testing.io, "inner", .{});
    defer inner.close(std.testing.io);

    const text = (try projectInstructions(std.testing.io, arena, inner)).?;
    try std.testing.expect(std.mem.endsWith(u8, text, "inner"));
}

test "sameDir tells a directory from its parent and root from itself" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    var deep = try tmp.dir.openDir(io, "a/b", .{});
    defer deep.close(io);
    var up = try deep.openDir(io, "..", .{});
    defer up.close(io);
    try std.testing.expect(!sameDir(io, deep, up));

    // At the filesystem root, `..` is the root itself, which is what ends a walk
    // that found no repository root above it.
    var root = try Io.Dir.openDirAbsolute(io, "/", .{});
    defer root.close(io);
    var root_up = try root.openDir(io, "..", .{});
    defer root_up.close(io);
    try std.testing.expect(sameDir(io, root, root_up));
}
