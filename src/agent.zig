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
    /// How full the context window must be, as a whole percentage, before the
    /// conversation is compacted into a summary. Zero turns compaction off.
    /// Nothing is compacted for a model whose window is unknown, since there is
    /// then no threshold to measure the conversation against. The value mirrors
    /// the configuration's, so a test can leave it out.
    compact_at: usize = 80,
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

/// One unit of what a run shows: the pieces a conversation is made of, each
/// finished before the next begins. A block is what the run says happened; how it
/// looks is the frontend's, so nothing here is text. A tool call and the result
/// that answered it are one block, since that is one thing the model did.
/// One unit of what a run shows: the pieces a conversation is made of, in the
/// order they happened. A block is what the run says happened; how it looks is
/// the frontend's, so nothing here is text.
///
/// A tool call is two blocks, the call as it begins and the call with its result
/// as it ends, so a frontend can show a slow command while it runs. A frontend
/// that shows only finished work ignores the first.
pub const Block = union(enum) {
    /// What the user typed.
    prompt: []const u8,
    /// What the model answered.
    answer: []const u8,
    /// A tool call as it begins, before it runs.
    tool_begin: Tools.Call,
    /// A tool call and the result that answered it.
    tool_end: Tool,
    /// A compaction: the prompt that asked for it and the summary it produced,
    /// which a request carries in place of the conversation before it. A frontend
    /// may show them, or stand them in with a line of its own.
    compacted: Compacted,
    /// A line billy writes itself, such as why a run stopped.
    notice: []const u8,
    /// How many blocks a shortened conversation left out, shown where they would
    /// have been. Zero is never shown, since a conversation with nothing left out
    /// has nothing to say.
    elided: usize,

    pub const Tool = struct {
        /// The call as it was parsed, which is what a frontend shows to say what
        /// ran. It belongs to the tool set's scratch, so it lasts until the next
        /// call; a frontend that keeps one has to copy what it keeps.
        call: Tools.Call,
        /// The text of the result, capped by `Tools.run`. The copy `run` wrote,
        /// which is the caller's for as long as it keeps it.
        result: []const u8,
    };

    pub const Compacted = struct {
        /// What was asked of the model: summarize the conversation so far.
        prompt: []const u8,
        /// What it answered, which is what a request now carries in place of the
        /// messages before it. Owned by the caller until the next block.
        summary: []const u8,
    };
};

/// Where a run's blocks go. The run says what happened and the emitter decides
/// how it looks, which is what lets the same run be shown in a terminal or over
/// the web without the run knowing which it is talking to.
pub const Emitter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Shows one block. Blocks arrive in the order they happened, and a
        /// frontend gets each one whole; nothing is half-shown.
        block: *const fn (context: *anyopaque, block: Block) anyerror!void,
    };

    /// Shows one block.
    pub fn show(emitter: Emitter, block: Block) !void {
        return emitter.vtable.block(emitter.context, block);
    }
};

/// Shows blocks on the terminal, the way billy always has: the block headers, a
/// reply's markdown laid out by the format script, and the tools laid out by
/// theirs.
const Terminal = struct {
    out: *Io.Writer,
    display: Display,
    /// For what showing a block builds, such as an edit's diff. Each block frees
    /// what it takes, so nothing is kept between them.
    scratch: std.mem.Allocator,
    /// Whether a prompt opens with the blank line that sets it off from what came
    /// before. Replaying a stored conversation wants it; a live prompt does not,
    /// since the line editor has already ended the line the prompt is typed on.
    replay: bool = false,

    fn emitter(self: *Terminal) Emitter {
        return .{ .context = self, .vtable = &.{ .block = show } };
    }

    fn show(context: *anyopaque, block: Block) anyerror!void {
        const self = selfOf(context);
        switch (block) {
            .prompt => |text| {
                if (self.replay) try self.out.writeAll("\n");
                try printPrompt(self.out, text, self.display);
            },
            .answer => |content| try printAnswer(self.out, content, self.display),
            // The header goes out as the call begins, so a command that runs
            // long has it on screen while it runs.
            .tool_begin => |call| {
                try Tools.printHead(self.scratch, call, self.display.formats, self.display.style, self.out);
                try self.out.flush();
            },
            // The header is out already, so only the result is left; the blank
            // line ends the block as it always has.
            .tool_end => |tool| {
                try Tools.printResult(tool.call, tool.result, self.display.style, self.out);
                try self.out.writeAll("\n");
                try self.out.flush();
            },
            // The terminal stands the two in with one line rather than showing
            // them, which is what a compaction has always looked like here.
            .compacted => try printCompacted(self.out, self.display.style),
            .notice => |text| {
                try self.out.print("{s}\n", .{text});
                try self.out.flush();
            },
            .elided => |count| try printElided(count, self.display.style, self.out),
        }
    }

    fn selfOf(context: *anyopaque) *Terminal {
        return @ptrCast(@alignCast(context));
    }
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

/// The marks the messages of the transcript are headed by. None of them is a
/// tool, so none carries a tool's glyph.
/// The marks the blocks of a run are headed by, which is the vocabulary both
/// frontends show a block in: the terminal colours them and the web gives them
/// classes, but a prompt is a prompt in either.
pub const marks = struct {
    pub const prompt = styling.Mark{ .glyph = "»", .hue = .blue };
    pub const answer = styling.Mark{ .glyph = "◆", .hue = .green };
    /// The line a compaction shows as, standing in for the prompt that asked for
    /// it and the summary it produced.
    pub const compacted = styling.Mark{ .glyph = "⊟", .hue = .yellow };
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
/// decimals. Shared with the web header, so both show a count the same way.
pub fn formatTokens(out: *Io.Writer, count: usize) !void {
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
/// does not read as empty. Shared with the web header, so both read it the same
/// way.
pub fn formatPercent(out: *Io.Writer, used: usize, total: usize) !void {
    if (total == 0) return out.writeAll("0%");
    const percent = used * 100 / total;
    if (percent == 0 and used > 0) return out.writeAll("<1%");
    try out.print("{d}%", .{percent});
}

/// Writes a dollar amount, rounded to the cent with the trailing zeros dropped,
/// so that `$1.5` and `$0` read the same way `1.5k` does, without padding to a
/// fixed number of places. The digits are formatted into a stack buffer first,
/// since the trimmed amount is written before the ones it dropped are known.
/// Shared with the web header, so both show the cost the same way.
pub fn formatMoney(out: *Io.Writer, amount: f64) !void {
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

/// Writes the working directory as shown in the header: shortened to `~` when it
/// is inside the home directory, so a long path stays readable. Shared with the
/// web header.
pub fn displayPath(out: *Io.Writer, cwd: []const u8, home: ?[]const u8) !void {
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
        .formats = config.display.formats,
        .bash_timeout_s = config.bash_timeout_s,
        .style = config.display.style,
        .search = config.search,
        .http = &http,
    });
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

    // The blocks of the run are shown on the terminal, the way billy has always
    // shown them.
    var terminal = Terminal{ .out = out, .display = config.display, .scratch = gpa };
    const emitter = terminal.emitter();

    // The header is rebuilt for every prompt, so it reflects the tokens and cost
    // of the turns run so far. One buffer holds it for the whole loop; each pass
    // clears it and writes the header into it.
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        // The conversation is compacted here, between prompts: the turn before
        // has finished and the one about to be typed has not started, so the
        // summary lands where the history it stands in for ended. It runs before
        // the header is built, so the header then reports the smaller
        // conversation. Doing nothing is not an error: the prompt goes on with
        // the conversation as it is.
        maybeCompact(io, &client, emitter, config, session) catch |err|
            std.log.warn("compaction failed: {s}", .{@errorName(err)});
        header.clearRetainingCapacity();
        try sessionHeader(&header.writer, config, session.id(), session.context_tokens, session.cost);
        const line = (try editor.readLine(header.written(), prompt)) orelse break;
        if (line.len == 0) continue;
        try session.append(.{ .role = "user", .content = line });
        // The line editor has erased the prompt it was typed behind, so the
        // prompt is written out now as the block a replay shows: the `> ` belongs
        // to the input, not to what was said. Flushed before the request, which
        // may take a while, so the user sees what was sent.
        try emitter.show(.{ .prompt = line });
        try out.flush();
        // A failed request must not end the session: report it and take the
        // next request from the user.
        turn(io, &client, &tool_set, emitter, config, session) catch |err|
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
/// Only the last `blocks` blocks are shown, so resuming a long session is quick
/// rather than replaying every block it ever printed; what came before is counted
/// on a line of its own. Zero shows the whole session. A block is one printed
/// unit: a prompt, a reply, or a tool call with its result.
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
    blocks: usize,
) !void {
    // A replay is what the terminal is shown when a session is picked up again,
    // so a prompt opens with the blank line a live one does not need.
    var terminal = Terminal{ .out = out, .display = display, .scratch = gpa, .replay = true };
    try walk(gpa, session, blocks, terminal.emitter());
    try out.flush();
}

/// Shows the blocks of a stored conversation, oldest first, through `emitter`.
/// This is what a replay and a web page are both made of, so a conversation reads
/// the same however it is shown.
///
/// Only the last `blocks` blocks are shown, and the count of what was left out is
/// shown where they would have been; zero shows the whole conversation. A block is
/// one unit: a prompt, a reply, a tool call with its result, or a compaction.
///
/// `gpa` is for the scratch the parsed arguments of a call need, which is dropped
/// between messages, so walking a long conversation costs no more than the largest
/// message in it.
pub fn walk(gpa: std.mem.Allocator, session: *const Session, blocks: usize, emitter: Emitter) !void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const trim = transcriptTrim(session, blocks);
    // A conversation with nothing left out has nothing to count.
    if (trim.elided > 0) try emitter.show(.{ .elided = trim.elided });

    for (session.messages.items[trim.index..], trim.index..) |message, index| {
        const skip = if (index == trim.index) trim.skip else 0;
        try emitMessage(scratch, session, index, message, skip, emitter);
        _ = scratch_state.reset(.retain_capacity);
    }
}

/// Shows the blocks one stored message is made of. The system prompt is never
/// shown while running, so it is left out here too. A tool result is shown as the
/// output of the call that produced it, and not as a block of its own.
///
/// `skip` leaves out the leading that many tool calls of the message, which only
/// a shortened conversation does, so a trim can fall inside a message that asks
/// for several tools; it is zero for every message that is shown whole.
///
/// The message is the one the session stores, so every string shown is read out
/// of the pool as it is shown and no message is built to show it.
fn emitMessage(
    arena: std.mem.Allocator,
    session: *const Session,
    index: usize,
    message: Session.Message,
    skip: usize,
    emitter: Emitter,
) !void {
    // A compaction shows as the summary that stands in for the messages before
    // it, with the prompt that asked for it; the prompt shows nothing of its own.
    if (session.isCompaction(index)) {
        const asked = if (index > 0) session.messages.items[index - 1] else null;
        return emitter.show(.{ .compacted = .{
            .prompt = if (asked) |before| session.contentOf(before) orelse "" else "",
            .summary = session.contentOf(message) orelse "",
        } });
    }
    if (session.isCompaction(index + 1)) return;

    const role = session.roleOf(message);
    if (std.mem.eql(u8, role, "user")) {
        return emitter.show(.{ .prompt = session.contentOf(message) orelse "" });
    }
    if (!std.mem.eql(u8, role, "assistant")) return;

    const calls = session.callCount(message);
    if (calls == 0) return emitter.show(.{ .answer = session.contentOf(message) orelse "" });
    for (skip..calls) |i| {
        const call = session.callAt(message, i);
        const parsed = Tools.parseCallNamed(arena, call.name, call.arguments);
        // The result belongs to the message just after the one that asked for
        // it, so the search starts from there.
        const result = session.toolResult(index + 1, call.id);
        // A call is shown as it begins and again with what it produced, which is
        // what lets a frontend show a slow call's header while it runs.
        try emitter.show(.{ .tool_begin = parsed });
        try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result } });
    }
}

/// Which message a trimmed transcript starts at, and how much of it to leave out,
/// so that the last `blocks` blocks are shown. A block is a prompt, a reply, or a
/// tool call with its result; an assistant message that asks for several tools is
/// several blocks, so a trim can fall inside one and leave out the calls before
/// it.
const Trim = struct {
    /// The first message to show.
    index: usize,
    /// How many of that message's leading tool calls to leave out.
    skip: usize,
    /// How many blocks were left out in all, for the count printed in their place.
    elided: usize,
};

/// The trim that shows the last `blocks` blocks. Zero shows the whole session,
/// and so does a count larger than the conversation: either way nothing is left
/// out.
fn transcriptTrim(session: *const Session, blocks: usize) Trim {
    if (blocks == 0) return .{ .index = 0, .skip = 0, .elided = 0 };

    const messages = session.messages.items;
    var index = messages.len;
    var skip: usize = 0;
    var remaining = blocks;
    while (index > 0 and remaining > 0) {
        index -= 1;
        const count = blocksIn(session, messages, index);
        if (count <= remaining) {
            remaining -= count;
        } else {
            // The trim falls inside this message, which only a tool-calling
            // message can, so its later calls are kept and the ones before them
            // are counted.
            skip = count - remaining;
            remaining = 0;
        }
    }

    var elided = skip;
    for (0..index) |earlier| elided += blocksIn(session, messages, earlier);
    return .{ .index = index, .skip = skip, .elided = elided };
}

/// How many blocks one message prints: a prompt or a reply is one, a
/// tool-calling message is one per call, and a tool result is none, since it
/// shows as part of the call it answers. A system prompt is never shown.
///
/// A compaction shows as one block, at the summary that stands in for it, so the
/// prompt that asked for it counts as nothing.
fn blocksIn(session: *const Session, messages: []const Session.Message, index: usize) usize {
    if (session.isCompaction(index)) return 1;
    // The message before a summary is the prompt that asked for the compaction
    // it produced, which shares the summary's one block.
    if (session.isCompaction(index + 1)) return 0;
    const role = session.roleOf(messages[index]);
    if (std.mem.eql(u8, role, "user")) return 1;
    if (!std.mem.eql(u8, role, "assistant")) return 0;
    const calls = session.callCount(messages[index]);
    return if (calls == 0) 1 else calls;
}

/// Prints how many blocks a trimmed transcript left out, dimmed, so a resume does
/// not read as the whole session. It is the count a short block gives of the
/// lines it cut, standing where the blocks it names would have been.
fn printElided(count: usize, style: styling.Style, out: *Io.Writer) !void {
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "… {d} earlier blocks", .{count}) catch "… earlier blocks";
    try style.dim(line, out);
    try out.writeAll("\n");
}

/// Runs the model until it replies with text instead of tool calls, showing what
/// happens as blocks as it goes.
fn turn(
    io: Io,
    client: *llm.Client,
    tool_set: *Tools,
    emitter: Emitter,
    config: Config,
    session: *Session,
) !void {
    // Holds the parsed call of each tool call the model asks for, which is read
    // until that call has been run and shown. Reset per call, so a turn that
    // makes many calls holds only the one it is on.
    var scratch_state = std.heap.ArenaAllocator.init(tool_set.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var remaining: usize = config.max_turns;
    // A compaction that failed is not tried again within the same turn, so a
    // provider that will not summarize cannot turn every request of a long turn
    // into a second failed one. The next turn tries afresh.
    var compact_failed = false;
    while (remaining > 0) : (remaining -= 1) {
        // A conversation that has outgrown the context window is compacted
        // before the request that would carry it, so a long session goes on
        // instead of failing on an overlong request. A failure to compact is not
        // the turn's: the request goes out with the conversation as it is.
        if (!compact_failed) {
            maybeCompact(io, client, emitter, config, session) catch |err| {
                std.log.warn("compaction failed: {s}", .{@errorName(err)});
                compact_failed = true;
            };
        }

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
        const calls = message.tool_calls orelse {
            return emitter.show(.{ .answer = message.content orelse "" });
        };
        if (calls.len == 0) return emitter.show(.{ .answer = message.content orelse "" });

        for (calls) |call| {
            // The call is parsed and shown before it runs, so a command that
            // runs long has its header on screen while it runs, and then the
            // result once it is in. The parsed call lives in the turn's scratch,
            // which the next call resets, so it is used before then.
            _ = scratch_state.reset(.retain_capacity);
            const parsed = Tools.parse(scratch, call);
            try emitter.show(.{ .tool_begin = parsed });

            var result: std.Io.Writer.Allocating = .init(tool_set.gpa);
            defer result.deinit();
            try tool_set.run(parsed, &result.writer);

            try session.append(.{
                .role = "tool",
                .tool_call_id = call.id,
                .content = result.written(),
            });
            try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });
        }
    }
    var buffer: [96]u8 = undefined;
    const stopped = std.fmt.bufPrint(
        &buffer,
        "stopped after {d} turns without a final answer",
        .{config.max_turns},
    ) catch "stopped without a final answer";
    try emitter.show(.{ .notice = stopped });
}

/// The rates in effect right now. Zero for a model billy does not know, which
/// has no prices to cost its tokens at.
fn rateNow(io: Io, config: Config) models.Price {
    const info = config.model_info orelse return .{};
    return info.priceAt(@intCast(Io.Clock.now(.real, io).toSeconds()));
}

/// Sent as the last message of a compaction request, and stored with the summary
/// it produces so the pair reads as a question and its answer. It is never sent
/// to the model again: a request starts at the summary, not at the prompt.
const compact_prompt =
    \\The conversation above is being compacted to free room in the context
    \\window. Write a summary of it that lets the work continue as if the
    \\earlier messages were still here. Cover the user's goals, what was decided
    \\and why, the files and functions that were changed and their current
    \\state, anything that was tried and did not work, and what is still to be
    \\done. Be specific: name the files, the functions and the commands. Reply
    \\with the summary alone, as plain text.
;

/// The number of tokens the conversation may reach before it is compacted. Zero
/// when compaction is off, or when the model's window is unknown and there is
/// then no threshold to measure a conversation against.
fn compactThreshold(config: Config) usize {
    if (config.compact_at == 0) return 0;
    const info = config.model_info orelse return 0;
    return info.context_window * config.compact_at / 100;
}

/// Compacts the conversation into a summary when it has filled the context
/// window past the threshold, so that a long session goes on rather than failing
/// on the next request.
///
/// The summary is added to the end of the session and recorded in its list of
/// compactions, and every request from then on carries only that summary and
/// what follows it (`Session.sentFrom`). The session itself keeps every message,
/// so the transcript still shows the whole history. Doing nothing here is not an
/// error: the conversation is left as it was and the request goes out with it,
/// which is what would have happened without compaction at all.
fn maybeCompact(
    io: Io,
    client: *llm.Client,
    emitter: Emitter,
    config: Config,
    session: *Session,
) !void {
    const threshold = compactThreshold(config);
    if (threshold == 0 or session.context_tokens < threshold) return;

    // Nothing has been added since the last compaction, so there is nothing new
    // to fold in: compacting again would only summarize the summary, and would
    // do so on every request.
    const start = session.sentFrom();
    if (session.messages.items.len - start <= 1) return;

    const summary = try summarize(io, client, config, session) orelse return;
    defer client.gpa.free(summary);

    // The conversation a request now carries is the summary and little else, so
    // its size is not known until the next request reports one. Clearing the
    // gauge before the compaction is written means the file records the cleared
    // size, so a resumed session does not read a stale one and compact again off
    // it.
    session.context_tokens = 0;
    try session.appendCompaction(compact_prompt, summary);
    try emitter.show(.{ .compacted = .{ .prompt = compact_prompt, .summary = summary } });
}

/// One request that asks the model to summarize the conversation it is being
/// sent, returning the summary text, owned by the caller, or null when the model
/// answered with no text.
///
/// The conversation is sent as a request would carry it, system prompt and tool
/// calls and results included, so the model reads what actually happened, with
/// the compacting prompt after it. The request cost real tokens, so it is billed
/// like any other, but it must not move the context gauge: the conversation it
/// was sent is about to be replaced by something far smaller.
fn summarize(
    io: Io,
    client: *llm.Client,
    config: Config,
    session: *Session,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(client.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const sent = try session.resolveSend(scratch);
    const request = try scratch.alloc(llm.Message, sent.len + 1);
    @memcpy(request[0..sent.len], sent);
    request[sent.len] = .{ .role = "user", .content = compact_prompt };

    const completion = try client.complete(client.gpa, request, session.toolSet());
    defer completion.deinit();
    session.recordCost(completion.usage, costOf(rateNow(io, config), completion.usage));

    const content = completion.message.content orelse return null;
    if (content.len == 0) return null;
    return try client.gpa.dupe(u8, content);
}

/// Prints the one line that stands in for a compaction: the prompt that asked
/// for it and the summary it produced are both kept in the session, so a run
/// that compacts shows the event rather than the two messages. It is headed like
/// every other block, with its own mark, and opens with the blank line that
/// separates it from the block before it.
fn printCompacted(out: *Io.Writer, style: styling.Style) !void {
    try out.writeAll("\n");
    try styling.header(marks.compacted, "compacted", "", style, out);
    try out.flush();
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
    // which the tool format does not touch. Zero shows the whole conversation.
    try printTranscript(gpa, &out.writer, &session, .{ .markdown = markdown, .style = style }, 0);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "printTranscript shows only the last blocks and counts the rest" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    // A prompt, one assistant message that asks for two tools, their results, and
    // a reply: four blocks, with two of them in the one tool-calling message.
    try session.append(.{ .role = "user", .content = "one" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
    } });
    try session.append(.{ .role = "tool", .tool_call_id = "call_1", .content = "contents a" });
    try session.append(.{ .role = "tool", .tool_call_id = "call_2", .content = "contents b" });
    try session.append(.{ .role = "assistant", .content = "done" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The last two blocks are the second call and the reply, so the trim falls
    // inside the tool-calling message: its first call and everything before it is
    // counted, and only its second call shows.
    try printTranscript(gpa, &out.writer, &session, .{}, 2);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n" ++
            "▸ read b.zig\n▾ output\ncontents b\n\n" ++
            "◆ answer\ndone\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A count larger than the conversation leaves nothing out, so nothing is
    // counted and the whole session shows.
    try printTranscript(gpa, &out.writer, &session, .{}, 10);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\n» prompt\none\n\n"));
    out.clearRetainingCapacity();

    // Zero shows the whole session too.
    try printTranscript(gpa, &out.writer, &session, .{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\n» prompt\none\n\n"));
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

test "printTranscript shows a compaction as a single line" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "one" });
    try session.append(.{ .role = "assistant", .content = "a1" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = "user", .content = "two" });
    try session.append(.{ .role = "assistant", .content = "a2" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The prompt that asked for the compaction and the summary it produced show
    // as one line, headed like every other block, and the rest of the history
    // shows as it always did.
    try printTranscript(gpa, &out.writer, &session, .{}, 0);
    try std.testing.expectEqualStrings(
        "\n» prompt\none\n\n" ++
            "◆ answer\na1\n" ++
            "\n⊟ compacted\n" ++
            "\n» prompt\ntwo\n\n" ++
            "◆ answer\na2\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The pair counts as one block, so a trim that keeps the last three blocks
    // starts at the compaction and counts what came before it.
    try printTranscript(gpa, &out.writer, &session, .{}, 3);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n" ++
            "\n⊟ compacted\n" ++
            "\n» prompt\ntwo\n\n" ++
            "◆ answer\na2\n",
        out.written(),
    );
}

test "a compaction is headed by its own mark, and hides what it stands for" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "s" });
    try session.append(.{ .role = "user", .content = "hi" });
    try session.appendCompaction("ASKEDFORTHEcompaction", "THESUMMARYTEXT");
    try session.append(.{ .role = "user", .content = "next" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try printTranscript(gpa, &out.writer, &session, .{ .style = .ansi }, 0);

    // The line carries the compaction mark: the glyph in its colour and the name
    // in bold, the way every other block header is written.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[33m⊟\x1b[0m \x1b[1mcompacted\x1b[0m") != null);
    // Neither the prompt that asked for the compaction nor the summary it
    // produced is shown: the one line stands in for both.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ASKEDFORTHEcompaction") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "THESUMMARYTEXT") == null);
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

/// A terminal a test can show blocks through and read back from `out`. The
/// returned value has to outlive the emitter taken from it, since the emitter
/// borrows it.
fn testTerminal(out: *Io.Writer, display: Display) Terminal {
    return .{ .out = out, .display = display, .scratch = std.testing.allocator };
}

/// Off-peak on a Friday, so the rates are the published base rates.
const off_peak_utc = 1789732800; // Friday 2026-09-18 12:00 UTC
/// Peak on a Friday, when DeepSeek doubles its rates.
const peak_utc = 1789696800; // Friday 2026-09-18 02:00 UTC

/// The id the header tests run under. A real one is a ULID, but the header only
/// prints it, so the same id serves every test.
const test_session_id = "01HF7YAT000000000000000000";

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
        "billy · 01HF7YAT000000000000000000 · deepseek-flash · /work",
        testConfig("deepseek-flash", "/work", null),
        0,
        0,
    );
}

test "header shortens a path inside the home directory" {
    try expectHeader(
        "billy · 01HF7YAT000000000000000000 · m · ~/repo/billy",
        testConfig("m", "/home/user/repo/billy", "/home/user"),
        0,
        0,
    );
    // The home directory itself becomes just `~`.
    try expectHeader(
        "billy · 01HF7YAT000000000000000000 · m · ~",
        testConfig("m", "/home/user", "/home/user"),
        0,
        0,
    );
    // A sibling that merely shares the prefix is left alone.
    try expectHeader(
        "billy · 01HF7YAT000000000000000000 · m · /home/user2",
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
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 0/128k (0%) · $0", config, 0, 0);
    // A rounded-to-zero percentage still shows the conversation is not empty.
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 500/128k (<1%) · $0", config, 500, 0);
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 16k/128k (12%) · $0", config, 16_000, 0);
    // A full window, and a count that rounds to a whole thousand.
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 128k/128k (100%) · $0", config, 128_000, 0);
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 13k/128k (9%) · $0", config, 12_500, 0);
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
    try expectHeader("billy · 01HF7YAT000000000000000000 · deepseek-flash · /work · 3M/4M (75%) · $0.75", config, 3_000_000, off_peak_cost);
    // A request made in peak hours cost double, which stays on the total even if
    // the header is shown later, off-peak.
    const peak_cost = costOf(info.priceAt(peak_utc), usage);
    try expectHeader("billy · 01HF7YAT000000000000000000 · deepseek-flash · /work · 3M/4M (75%) · $1.51", config, 3_000_000, peak_cost);
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
    try expectHeader("billy · 01HF7YAT000000000000000000 · who-knows · /work", config, 5000, 12.34);
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

test "the compaction threshold is the configured share of the window, or off" {
    // A model without a known window has nothing to measure a conversation
    // against, so there is no threshold even with compaction on.
    try std.testing.expectEqual(0, compactThreshold(testConfig("m", "/work", null)));

    var config = testConfig("m", "/work", null);
    config.model_info = .{
        .provider = .deepseek,
        .model = "m",
        .context_window = 1000,
        .price = .{},
    };

    // The default is a share of the window, not the whole of it.
    try std.testing.expectEqual(800, compactThreshold(config));

    // Zero turns it off.
    config.compact_at = 0;
    try std.testing.expectEqual(0, compactThreshold(config));

    // Any share the file names, whether or not it divides the window evenly.
    config.compact_at = 50;
    try std.testing.expectEqual(500, compactThreshold(config));
    config.compact_at = 33;
    try std.testing.expectEqual(330, compactThreshold(config));
}

test "maybeCompact folds the conversation into a summary at its end" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "be terse" });
    try session.append(.{ .role = "user", .content = "OLDPROMPT" });
    try session.append(.{ .role = "assistant", .tool_calls = &.{.{
        .id = "call_x",
        .function = .{ .name = "bash", .arguments = "{}" },
    }} });
    try session.append(.{ .role = "tool", .tool_call_id = "call_x", .content = "OLDTOOLOUTPUT" });
    try session.append(.{ .role = "assistant", .content = "OLDANSWER" });

    var config = testConfig("m", "/work", null);
    config.model_info = .{
        .provider = .deepseek,
        .model = "m",
        .context_window = 1000,
        .price = .{},
    };
    config.compact_at = 80;
    // A conversation that has filled the window past the threshold.
    session.context_tokens = 900;

    // A server standing in for the model, answering the compaction request with
    // a fixed summary and recording the body it was sent.
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var provider: SummaryProvider = .{};
    defer if (provider.body) |body| gpa.free(body);

    var group: Io.Group = .init;
    try group.concurrent(io, SummaryProvider.serve, .{ io, &listener, &provider });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/chat/completions", .{
        listener.socket.address.getPort(),
    });
    defer gpa.free(url);

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: llm.Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = url,
        .model = "m",
        .http = &http,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try maybeCompact(io, &client, terminal.emitter(), config, &session);

    try group.await(io);
    if (provider.err) |err| return err;

    // The request carried the whole conversation, tool call and result included,
    // with the compacting prompt after it.
    const body = provider.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDPROMPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_x") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDTOOLOUTPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDANSWER") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "free room in the context") != null);

    // The prompt and the summary are added to the end of the session, which keeps
    // every message it had. The summary is a user message.
    try std.testing.expectEqual(7, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[5]));
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[6]));
    try std.testing.expectEqualStrings("the summary", session.contentOf(session.messages.items[6]).?);
    // A request now starts at the summary, skipping the prompt and everything
    // the summary stands in for.
    try std.testing.expectEqual(6, session.sentFrom());
    try std.testing.expect(session.isCompaction(6));

    // The compaction request was billed, but the gauge it would set is dropped
    // since the conversation it measured has just been replaced.
    try std.testing.expectEqual(105, session.usage.total_tokens);
    try std.testing.expectEqual(0, session.context_tokens);

    // The user is told, in one line, that the conversation was compacted.
    try std.testing.expectEqualStrings("\n⊟ compacted\n", out.written());
}

test "maybeCompact does nothing below the threshold, off, or with nothing new" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "s" });
    try session.append(.{ .role = "user", .content = "hello" });

    var config = testConfig("m", "/work", null);
    config.model_info = .{ .provider = .deepseek, .model = "m", .context_window = 1000, .price = .{} };

    // There is no client: the function must return before it reaches for one.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    const emitter = terminal.emitter();

    // Below the threshold.
    session.context_tokens = 100;
    try maybeCompact(io, undefined, emitter, config, &session);
    // Turned off.
    session.context_tokens = 999;
    config.compact_at = 0;
    try maybeCompact(io, undefined, emitter, config, &session);
    // A model with no known window has no threshold to measure against.
    config.compact_at = 80;
    config.model_info = null;
    try maybeCompact(io, undefined, emitter, config, &session);

    // Nothing was added, and nothing was printed.
    try std.testing.expectEqual(2, session.messages.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

test "maybeCompact does not compact a summary that stands alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.append(.{ .role = "system", .content = "s" });
    try session.appendCompaction("p", "a summary");

    var config = testConfig("m", "/work", null);
    config.model_info = .{ .provider = .deepseek, .model = "m", .context_window = 1000, .price = .{} };

    // Over the threshold, but the last message is the summary itself, so there is
    // nothing new to fold in and a request would only re-summarize it.
    session.context_tokens = 999;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try maybeCompact(io, undefined, terminal.emitter(), config, &session);

    try std.testing.expectEqual(3, session.messages.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

/// A stand-in for the model on the wire, for the compaction tests: it answers
/// the one summarization request with a fixed summary, recording the body so the
/// test can check what was sent. It mirrors the provider the client tests use.
const SummaryProvider = struct {
    /// The request body as it arrived, owned by `std.testing.allocator`.
    body: ?[]u8 = null,
    /// The first failure the server ran into, so the test reports it rather than
    /// hanging on the connection.
    err: ?anyerror = null,

    fn serve(io: Io, listener: *std.Io.net.Server, self: *SummaryProvider) Io.Cancelable!void {
        self.run(io, listener) catch |err| {
            self.err = err;
        };
    }

    fn run(self: *SummaryProvider, io: Io, listener: *std.Io.net.Server) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);

        var in_buffer: [4096]u8 = undefined;
        var out_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);

        var request = try server.receiveHead();
        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        self.body = try body_reader.allocRemaining(std.testing.allocator, .unlimited);

        try request.respond(
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"the summary\"}}]," ++
                "\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"total_tokens\":105}}",
            .{ .keep_alive = false },
        );
    }
};

test "the terminal shows a tool call the way a replay does" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };

    // Live: the call is parsed and its header written before it runs, and the
    // result once it is in, exactly as the turn does it.
    var live: std.Io.Writer.Allocating = .init(gpa);
    defer live.deinit();
    var terminal = testTerminal(&live.writer, .{});
    const emitter = terminal.emitter();

    const parsed = Tools.parse(arena, call);
    try emitter.show(.{ .tool_begin = parsed });
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    try tool_set.run(parsed, &result.writer);
    try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });

    // A replay renders the stored call on its own.
    var replayed: std.Io.Writer.Allocating = .init(gpa);
    defer replayed.deinit();
    try Tools.describe(arena, parsed, result.written(), .{}, .plain, &replayed.writer);

    // The two paths show the same bytes, which is what keeps a run and a resume
    // of it reading alike. The header before the result is what a slow command
    // needs on screen while it runs.
    try std.testing.expectEqualStrings("❯ bash\necho hi\n✓ exit 0\n▾ stdout\nhi\n\n", live.written());
    try std.testing.expectEqualStrings(replayed.written(), live.written());
}

/// An emitter that records what a run shows, copying what it keeps, so a test
/// can read a run back with no terminal in the way. Nothing here is shaped like
/// a terminal, which is the point: it is the second frontend the emitter exists
/// for.
const Recorder = struct {
    /// Owns the names and text it records, since a block borrows the tool set's
    /// scratch and the caller's buffers, neither of which outlives the run.
    arena: std.mem.Allocator,
    seen: std.ArrayList(Seen) = .empty,

    const Seen = union(enum) {
        prompt: []const u8,
        answer: []const u8,
        tool_begin: []const u8,
        tool_end: struct { name: []const u8, result: []const u8 },
        compacted: Block.Compacted,
        notice: []const u8,
        elided: usize,
    };

    fn emitter(self: *Recorder) Emitter {
        return .{ .context = self, .vtable = &.{ .block = show } };
    }

    fn show(context: *anyopaque, block: Block) anyerror!void {
        const self = selfOf(context);
        const seen: Seen = switch (block) {
            .prompt => |text| .{ .prompt = try self.keeper(text) },
            .answer => |text| .{ .answer = try self.keeper(text) },
            .tool_begin => |call| .{ .tool_begin = try self.keeper(callName(call)) },
            .tool_end => |tool| .{ .tool_end = .{
                .name = try self.keeper(callName(tool.call)),
                .result = try self.keeper(tool.result),
            } },
            .compacted => |compaction| .{ .compacted = .{
                .prompt = try self.keeper(compaction.prompt),
                .summary = try self.keeper(compaction.summary),
            } },
            .notice => |text| .{ .notice = try self.keeper(text) },
            .elided => |count| .{ .elided = count },
        };
        try self.seen.append(self.arena, seen);
    }

    /// A copy of `text` in the recorder's arena, so what it records lasts as long
    /// as the recorder rather than as long as the block.
    fn keeper(self: *Recorder, text: []const u8) ![]const u8 {
        return self.arena.dupe(u8, text);
    }

    /// The name of the tool a call names, so a test can say which one ran.
    fn callName(call: Tools.Call) []const u8 {
        return switch (call) {
            .read => "read",
            .write => "write",
            .edit => "edit",
            .bash => "bash",
            .web_search => "web_search",
            .unknown => |name| name,
            .malformed => |bad| bad.name,
        };
    }

    fn selfOf(context: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(context));
    }
};

test "a turn shows the tool it runs and then the answer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.appendSystemPrompt("be terse");

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var provider: TurnProvider = .{};
    var group: Io.Group = .init;
    try group.concurrent(io, TurnProvider.serve, .{ io, &listener, &provider });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/chat/completions", .{
        listener.socket.address.getPort(),
    });
    defer gpa.free(url);

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: llm.Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = url,
        .model = "m",
        .http = &http,
    };
    var tool_set = try Tools.init(.{
        .io = io,
        .dir = Io.Dir.cwd(),
        .gpa = gpa,
        .bash_timeout_s = 120,
        .http = &http,
    });

    var recorder = Recorder{ .arena = arena_state.allocator() };
    try turn(io, &client, &tool_set, recorder.emitter(), testConfig("m", "/work", null), &session);

    try group.await(io);
    if (provider.err) |err| return err;

    // The call is shown as it begins, so its header could go up while it ran,
    // and again with the result it produced. The answer follows.
    try std.testing.expectEqual(3, recorder.seen.items.len);
    try std.testing.expectEqualStrings("bash", recorder.seen.items[0].tool_begin);
    const tool = recorder.seen.items[1].tool_end;
    try std.testing.expectEqualStrings("bash", tool.name);
    try std.testing.expectEqualStrings("exit code: 0\nhi\n", tool.result);
    try std.testing.expectEqualStrings("all done", recorder.seen.items[2].answer);

    // What was shown is what the session kept, so a resume replays the turn.
    try std.testing.expectEqualStrings(
        "exit code: 0\nhi\n",
        session.contentOf(session.messages.items[session.messages.items.len - 2]).?,
    );
    try std.testing.expectEqualStrings(
        "all done",
        session.contentOf(session.messages.items[session.messages.items.len - 1]).?,
    );
}

/// A stand-in for the model that asks for one bash command and then answers, so a
/// test can watch a whole turn without the network. It answers as many requests
/// as it is told to, since a turn makes one per round trip.
const TurnProvider = struct {
    /// Requests left to answer.
    remaining: usize = 2,
    /// The first failure the server ran into, so the test reports it rather than
    /// hanging on the connection.
    err: ?anyerror = null,

    fn serve(io: Io, listener: *std.Io.net.Server, self: *TurnProvider) Io.Cancelable!void {
        self.run(io, listener) catch |err| {
            self.err = err;
        };
    }

    fn run(self: *TurnProvider, io: Io, listener: *std.Io.net.Server) !void {
        while (self.remaining > 0) : (self.remaining -= 1) {
            var stream = try listener.accept(io);
            defer stream.close(io);

            var in_buffer: [4096]u8 = undefined;
            var out_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &in_buffer);
            var writer = stream.writer(io, &out_buffer);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);

            var request = try server.receiveHead();
            var body_buffer: [8192]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_buffer);
            const body = try body_reader.allocRemaining(std.testing.allocator, .unlimited);
            defer std.testing.allocator.free(body);

            // The first request is answered with a call; once the result is in
            // the conversation, the next answers with text.
            const answered = std.mem.indexOf(u8, body, "\"tool\"") != null;
            const reply = if (answered)
                "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"all done\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}"
            else
                "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\"," ++
                    "\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":" ++
                    "\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]," ++
                    "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}";
            try request.respond(reply, .{ .keep_alive = false });
        }
    }
};
