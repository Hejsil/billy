//! The agent loop: read a request from the user, ask the model, run the tools
//! it asks for, and repeat until it answers with text.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const models = @import("models.zig");
const tools = @import("tools.zig");
const line_editor = @import("line_editor.zig");
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
    /// Working directory, shown in the header.
    cwd: []const u8,
    /// Home directory, so the header can shorten a path inside it; null when unset.
    home: ?[]const u8,
    /// What is known about the provider and model: the context window and the
    /// prices. Null for a model billy does not know, in which case the header
    /// leaves out the context gauge and the cost.
    model_info: ?models.Metadata,
    /// How a bash command is laid out before it is shown to the user, from the
    /// configuration. This is presentation only: the command that runs and
    /// everything stored in the session keep the text the model wrote. Null
    /// shows the command as written.
    format: tools.Format = null,
    /// How the markdown of a reply and a prompt is laid out before it is shown,
    /// from the configuration. Presentation only, like `format`: what a session
    /// stores and what the model is sent keep the text as it was written. Null
    /// shows the text as written.
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

/// Printed in front of every line the user types. The transcript reuses it so a
/// replayed session looks like the run it continues.
const prompt = "> ";

/// The marks the two halves of the conversation are headed by. Neither is a
/// tool, so neither carries a tool's glyph.
const marks = struct {
    const prompt = styling.Mark{ .glyph = "»", .hue = .blue };
    const answer = styling.Mark{ .glyph = "◆", .hue = .green };
};

/// The header line shown above the input prompt: the model, the working
/// directory, how much of the context window the conversation fills, and what
/// the session has cost so far. The window size and the prices are not reported
/// by the API, so they come from the model table. `cost` is the session total
/// the loop has accumulated, so it does not move as the clock passes a rate
/// change.
pub fn sessionHeader(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    config: Config,
    context_tokens: usize,
    cost: f64,
) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const out = &text.writer;

    try out.print("billy · {s} · {s}", .{
        config.model,
        try displayPath(arena, config.cwd, config.home),
    });
    if (config.model_info) |info| {
        try out.print(" · {s}/{s} ({s})", .{
            try formatTokens(arena, context_tokens),
            try formatTokens(arena, info.context_window),
            try formatPercent(arena, context_tokens, info.context_window),
        });
        try out.print(" · {s}", .{try formatMoney(arena, cost)});
    }
    return arena.dupe(u8, text.written());
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

/// A token count in a short form, such as `16k` or `128k`, with no decimals.
fn formatTokens(arena: std.mem.Allocator, count: usize) ![]const u8 {
    if (count < 1000) return std.fmt.allocPrint(arena, "{d}", .{count});
    if (count < 1_000_000) return formatScaled(arena, count, 1000, 'k');
    return formatScaled(arena, count, 1_000_000, 'M');
}

/// `count` divided by `unit`, rounded to a whole number, with a trailing unit
/// letter. The rounding is what makes a count readable without a decimal: half a
/// thousand reads as the next thousand.
fn formatScaled(arena: std.mem.Allocator, count: usize, unit: usize, suffix: u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d:.0}{c}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(unit)),
        suffix,
    });
}

/// How full the context window is, as a whole percentage. A conversation that
/// has started but is under one percent is reported as `<1%`, so the gauge does
/// not read as empty.
fn formatPercent(arena: std.mem.Allocator, used: usize, total: usize) ![]const u8 {
    if (total == 0) return "0%";
    const percent = used * 100 / total;
    if (percent == 0 and used > 0) return "<1%";
    return std.fmt.allocPrint(arena, "{d}%", .{percent});
}

/// A dollar amount, rounded to the cent with the trailing zeros dropped, so that
/// `$1.5` and `$0` read the same way `1.5k` does, without padding to a fixed
/// number of places.
fn formatMoney(arena: std.mem.Allocator, amount: f64) ![]const u8 {
    const digits = try std.fmt.allocPrint(arena, "{d:.2}", .{amount});

    // Drop the trailing zeros of the hundredths, then a bare decimal point.
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    if (end > 0 and digits[end - 1] == '.') end -= 1;

    return std.fmt.allocPrint(arena, "${s}", .{digits[0..end]});
}

/// The working directory as shown in the header. A path inside the home
/// directory is shortened to `~` so a long path stays readable.
fn displayPath(arena: std.mem.Allocator, cwd: []const u8, home: ?[]const u8) ![]const u8 {
    if (home) |dir| {
        // Require a component boundary, so `/home/user2` is not shortened by a
        // `/home/user` home directory.
        if (dir.len > 0 and std.mem.startsWith(u8, cwd, dir)) {
            const rest = cwd[dir.len..];
            if (rest.len == 0) return "~";
            if (rest[0] == '/') return std.fmt.allocPrint(arena, "~{s}", .{rest});
        }
    }
    return cwd;
}

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    config: Config,
    session: *Session,
) !void {
    var editor = line_editor.LineEditor.init(io, out, arena);
    var tool_set = try tools.Tools.init(io, arena, gpa, out, config.format, config.style);
    var client: llm.Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = config.api_key,
        .url = config.url,
        .model = config.model,
    };

    // The prompt and the tool definitions are stored with the session and reused
    // on a resume, so the request sent then matches the earlier run byte for byte
    // and hits the prompt cache. They are set only on a session that has none, so
    // a new session gets the current ones while a resumed one keeps what it was
    // saved with.
    try session.appendSystemPrompt(system_prompt);
    try session.ensureTools(tool_set.definitions);

    while (true) {
        // Rebuilt for every prompt, so it reflects the tokens and cost of the
        // turns run so far.
        const header = try sessionHeader(gpa, arena, config, session.context_tokens, session.cost);
        const line = (try editor.readLine(header, prompt)) orelse break;
        if (line.len == 0) continue;
        try session.append(.{ .role = "user", .content = line });
        // A failed request must not end the session: report it and take the
        // next request from the user.
        turn(io, &client, &tool_set, out, config, session) catch |err|
            std.log.err("request failed: {s}", .{@errorName(err)});
    }
    try out.flush();
}

/// Replays a stored conversation as the blocks it was made of, so that
/// remembering the context of an earlier run is not left to the user. The tool
/// calls go through `tools.parseCall` and `tools.describe`, and the replies
/// through `printAnswer`, the same as the ones the loop printed.
///
/// A prompt is the one thing a replay shows differently from a live run: it is
/// headed `» prompt` and laid out like a reply, without the `> ` the live input
/// is typed behind, which is not part of the prompt.
///
/// The conversation is read where it is stored, a message at a time, so replaying
/// a long session costs no more than the largest message in it. `gpa` is for the
/// scratch the parsed arguments of a call need, which is dropped between
/// messages.
pub fn printTranscript(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    session: *const Session,
    format: tools.Format,
    markdown: formatting.Format,
    style: styling.Style,
) !void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    for (session.messages.items, 0..) |message, index| {
        try printMessage(scratch, out, session, index, message, format, markdown, style);
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
    format: tools.Format,
    markdown: formatting.Format,
    style: styling.Style,
) !void {
    const role = session.roleOf(message);
    if (std.mem.eql(u8, role, "user")) {
        // A prompt from the session is headed like everything else in the
        // transcript, and its markdown is laid out the way a reply's is. The
        // `> ` is not printed: it belongs to the live input alone, and is not
        // part of the prompt until the user sends it.
        try out.writeAll("\n");
        try styling.header(marks.prompt, "prompt", "", style, out);
        const text = session.contentOf(message) orelse "";
        if (!try formatting.apply(markdown, text, out)) try out.writeAll(text);
        return out.writeAll("\n");
    }
    if (!std.mem.eql(u8, role, "assistant")) return;

    const calls = session.callCount(message);
    if (calls == 0) return printAnswer(out, session.contentOf(message), markdown, style);
    for (0..calls) |i| {
        const call = session.callAt(message, i);
        // The result belongs to the message just after the one that asked for
        // it, so the search starts from there.
        try tools.describe(
            tools.parseCallNamed(arena, call.name, call.arguments),
            session.toolResult(index + 1, call.id),
            format,
            style,
            out,
        );
    }
}

/// Runs the model until it replies with text instead of tool calls.
fn turn(
    io: Io,
    client: *llm.Client,
    tool_set: *tools.Tools,
    out: *Io.Writer,
    config: Config,
    session: *Session,
) !void {
    var remaining: usize = config.max_turns;
    while (remaining > 0) : (remaining -= 1) {
        // Everything that only has to last the request is allocated here and
        // dropped when the turn ends: the reply that comes back and the result
        // of every call it asked for. The conversation is written straight onto
        // the connection out of the pool, and the session interns what it keeps,
        // so the pool is the only copy that outlives the turn.
        var request_arena = std.heap.ArenaAllocator.init(client.gpa);
        defer request_arena.deinit();
        const request = request_arena.allocator();

        const completion = try client.complete(request, session.conversation(), session.tools);
        // The totals are recorded first, so the save inside `append` stores them
        // along with the message. Each request is priced as it is made, at the
        // rates in effect then, so a session running through a rate change is
        // billed for what it actually cost.
        session.recordUsage(completion.usage, costOf(rateNow(io, config), completion.usage));
        try session.append(completion.message);

        const message = completion.message;
        const calls = message.tool_calls orelse
            return printAnswer(out, message.content, config.markdown, config.style);
        if (calls.len == 0) return printAnswer(out, message.content, config.markdown, config.style);

        for (calls) |call| {
            try session.append(.{
                .role = "tool",
                .tool_call_id = call.id,
                .content = try tool_set.run(request, call),
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

/// Prints a reply under its own header, the markdown laid out by `markdown` when
/// one is set and as it was written when there is none or it cannot be used.
/// Only the display changes; the session and the model keep the text itself.
fn printAnswer(out: *Io.Writer, content: ?[]const u8, markdown: formatting.Format, style: styling.Style) !void {
    try styling.header(marks.answer, "answer", "", style, out);
    const text = content orelse "";
    if (text.len == 0) {
        try style.dim("(empty reply)", out);
    } else if (!try formatting.apply(markdown, text, out)) {
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

    var session = try Session.open(std.testing.io, tmp.dir, arena_state.allocator(), gpa, null);
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // No bash format: what these cover is how a message is headed and laid out,
    // which the tool format does not touch.
    try printTranscript(gpa, &out.writer, &session, null, markdown, style);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "printTranscript replays a conversation as the blocks it was made of" {
    // The system prompt is never shown while running, the tool result only as
    // the output of the call it belongs to.
    try expectTranscript(
        "\n» prompt\nhello\n" ++
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
        "\n» prompt\nHELLO\n",
        &.{.{ .role = "user", .content = "hello" }},
        markdown,
        .plain,
    );

    // Without one, the prompt is shown as it was typed.
    try expectTranscript(
        "\n» prompt\nhello\n",
        &.{.{ .role = "user", .content = "hello" }},
        null,
        .plain,
    );
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
        "\n\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\nhello\n" ++
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

/// A config with no model metadata, so the header is just the model and the
/// directory. Tests that need a gauge fill `model_info` in.
fn testConfig(model: []const u8, cwd: []const u8, home: ?[]const u8) Config {
    return .{
        .api_key = "k",
        .url = "u",
        .model = model,
        .max_turns = 10,
        .cwd = cwd,
        .home = home,
        .model_info = null,
    };
}

/// Off-peak on a Friday, so the rates are the published base rates.
const off_peak_utc = 1789732800; // Friday 2026-09-18 12:00 UTC
/// Peak on a Friday, when DeepSeek doubles its rates.
const peak_utc = 1789696800; // Friday 2026-09-18 02:00 UTC

test "header names the model and the working directory" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "billy · deepseek-flash · /work",
        try sessionHeader(arena, allocator, testConfig("deepseek-flash", "/work", null), 0, 0),
    );
}

test "header shortens a path inside the home directory" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "billy · m · ~/repo/billy",
        try sessionHeader(arena, allocator, testConfig("m", "/home/user/repo/billy", "/home/user"), 0, 0),
    );
    // The home directory itself becomes just `~`.
    try std.testing.expectEqualStrings(
        "billy · m · ~",
        try sessionHeader(arena, allocator, testConfig("m", "/home/user", "/home/user"), 0, 0),
    );
    // A sibling that merely shares the prefix is left alone.
    try std.testing.expectEqualStrings(
        "billy · m · /home/user2",
        try sessionHeader(arena, allocator, testConfig("m", "/home/user2", "/home/user"), 0, 0),
    );
}

test "header shows how full the context window is" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A model with a small window, so the numbers are easy to read.
    var config = testConfig("m", "/work", null);
    config.model_info = .{
        .provider = .deepseek,
        .model = "m",
        .context_window = 128_000,
        .price = .{ .cache_hit_input = 0.003, .cache_miss_input = 0.15, .output = 0.6 },
    };

    // A fresh session has used nothing.
    try std.testing.expectEqualStrings(
        "billy · m · /work · 0/128k (0%) · $0",
        try sessionHeader(arena, allocator, config, 0, 0),
    );
    // A rounded-to-zero percentage still shows the conversation is not empty.
    try std.testing.expectEqualStrings(
        "billy · m · /work · 500/128k (<1%) · $0",
        try sessionHeader(arena, allocator, config, 500, 0),
    );
    try std.testing.expectEqualStrings(
        "billy · m · /work · 16k/128k (12%) · $0",
        try sessionHeader(arena, allocator, config, 16_000, 0),
    );
    // A full window, and a count that rounds to a whole thousand.
    try std.testing.expectEqualStrings(
        "billy · m · /work · 128k/128k (100%) · $0",
        try sessionHeader(arena, allocator, config, 128_000, 0),
    );
    try std.testing.expectEqualStrings(
        "billy · m · /work · 13k/128k (9%) · $0",
        try sessionHeader(arena, allocator, config, 12_500, 0),
    );
}

test "header shows the accumulated session cost" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

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
    try std.testing.expectEqualStrings(
        "billy · deepseek-flash · /work · 3M/4M (75%) · $0.75",
        try sessionHeader(arena, allocator, config, 3_000_000, off_peak_cost),
    );
    // A request made in peak hours cost double, which stays on the total even if
    // the header is shown later, off-peak.
    const peak_cost = costOf(info.priceAt(peak_utc), usage);
    try std.testing.expectEqualStrings(
        "billy · deepseek-flash · /work · 3M/4M (75%) · $1.51",
        try sessionHeader(arena, allocator, config, 3_000_000, peak_cost),
    );
}

test "token counts are whole and prices keep at most two decimals" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A count is never shown with a decimal, so half a thousand rounds up.
    try std.testing.expectEqualStrings("0", try formatTokens(allocator, 0));
    try std.testing.expectEqualStrings("999", try formatTokens(allocator, 999));
    try std.testing.expectEqualStrings("1k", try formatTokens(allocator, 1000));
    try std.testing.expectEqualStrings("13k", try formatTokens(allocator, 12_500));
    try std.testing.expectEqualStrings("128k", try formatTokens(allocator, 128_000));
    try std.testing.expectEqualStrings("1M", try formatTokens(allocator, 1_000_000));

    // A price is rounded to the cent, and the zeros it does not need are dropped.
    try std.testing.expectEqualStrings("$0", try formatMoney(allocator, 0));
    try std.testing.expectEqualStrings("$0.01", try formatMoney(allocator, 0.007));
    try std.testing.expectEqualStrings("$0.5", try formatMoney(allocator, 0.5));
    try std.testing.expectEqualStrings("$1", try formatMoney(allocator, 1));
    try std.testing.expectEqualStrings("$1.25", try formatMoney(allocator, 1.25));
    try std.testing.expectEqualStrings("$1.51", try formatMoney(allocator, 1.506));
}

test "header leaves out the gauge and cost for an unknown model" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const config = testConfig("who-knows", "/work", null);
    try std.testing.expect(config.model_info == null);
    try std.testing.expectEqualStrings(
        "billy · who-knows · /work",
        try sessionHeader(arena, allocator, config, 5000, 12.34),
    );
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
