//! The agent loop: read a request from the user, ask the model, run the tools
//! it asks for, and repeat until it answers with text.
const std = @import("std");
const llm = @import("llm.zig");
const models = @import("models.zig");
const Tools = @import("Tools.zig");
const Mock = @import("Mock.zig");
const Health = @import("Health.zig");
const LineEditor = @import("LineEditor.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");

pub const Mode = @import("Agent/mode.zig").Mode;

const Agent = @This();

/// A command a prompt can be on its own, which billy runs itself rather than
/// sending to the model. A command is the whole line, so a prompt that merely
/// starts with one is still a prompt.
///
/// Private: a frontend hands the agent what was typed and is told what came of
/// it, so which commands there are and what they do is the agent's own business.
const Command = enum {
    /// Fold the conversation into a summary now, whatever its size.
    compact,

    /// Reads `text` as a command, or null when it is an ordinary prompt.
    pub fn of(text: []const u8) ?Command {
        if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "/compact")) return .compact;
        return null;
    }
};

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
    /// Directory holding the user's own instructions file, read into every
    /// session's prompt ahead of the project's; null in a test, or when there is
    /// no such file. Borrowed from the setup, which owns it and outlives the
    /// agent, so nothing here closes it.
    user_instructions_dir: ?std.Io.Dir = null,
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
    /// Whether the model is asked for a short title for a session, after its
    /// first turn, so a frontend can list it by name. Mirrors the configuration.
    title: bool = true,
    /// What the request asks of the model's thinking, from the configuration.
    reasoning: llm.Reasoning = .provider_default,
    /// What the session may do and what its prompt says, decided when it starts.
    /// See `mode.zig`.
    mode: Mode = .general,
    /// How what billy shows is laid out and decorated, from the configuration.
    display: Display = .{},
    /// Web search, when the configuration names a backend and its key is set.
    /// Null leaves `web_search` out of the tools the model is offered.
    search: ?Tools.web.Search.Config = null,
    /// Web fetch, on the same terms, with its own backends.
    fetch: ?Tools.web.Fetch.Config = null,
    /// The waits of every web backend, so one that just failed is skipped.
    health: ?*Health = null,
};

/// How billy lays out and decorates what it shows: the formatter scripts for a
/// tool's block and the terminal style. They travel together through the
/// printing, so they are gathered here rather than passed apart as a run of
/// arguments that had grown hard to read.
///
/// The layout is presentation only: the command that runs, what a session stores
/// and what the model is sent keep the text as it was written.
pub const Display = struct {
    /// How a tool's block is laid out before it is shown: a bash command and an
    /// edit's diff. Null shows each as it was written.
    formats: Tools.Formats = .{},
    /// How billy decorates the lines it prints itself, such as a block header.
    /// Plain everywhere the terminal does not take escape codes.
    style: Terminal.Style = .plain,
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

/// The files a project's own instructions are read from, in the order they are
/// tried. `AGENTS.md` is the open convention; `CLAUDE.md` is accepted after it so
/// that a project which wrote one for another tool need not rename it.
const instruction_files = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
/// Longest instructions read back, so an outsize file cannot exhaust memory.
const max_instructions_len = 1 << 20;

/// Writes the instructions `dir` itself holds to `out`, as a section a blank
/// line below whatever came before: the first non-empty file of `names`, under a
/// heading naming where they came from. Writes nothing and returns false when it
/// holds none of them. Only `dir` is read; a caller that wants a walk up does it
/// around this.
///
/// The file is streamed to `out` as it is, so nothing of it is held in memory
/// whole and nothing of it is changed. Only a file with no bytes at all is
/// skipped, so a file of whitespace alone still heads a section.
fn instructionsIn(
    io: std.Io,
    out: *std.Io.Writer,
    dir: std.Io.Dir,
    names: []const []const u8,
    what: []const u8,
) !bool {
    for (names) |name| {
        var file = dir.openFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io);

        // A file with no bytes is nothing to say, so the search carries on
        // rather than putting a blank heading in the prompt.
        const size = try file.length(io);
        if (size == 0) continue;

        // The blank line before the heading stands the section apart from the
        // prompt above it, which every section has: billy's own text, or another
        // section.
        try out.print("\n\n{s} instructions follow, read from {s}.\n\n", .{ what, name });
        var buffer: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buffer);
        try file_reader.interface.streamExact(out, @intCast(@min(size, max_instructions_len)));
        return true;
    }
    return false;
}

/// Writes the project's own instructions, read from `dir` or the nearest parent
/// that has them, and returns whether it wrote any. The walk stops at the
/// repository root, so a file above the project is not read, and at the
/// filesystem root when there is no repository above it.
///
/// The instructions join the system prompt rather than the conversation, so they
/// are sent with every request and survive whatever context trimming happens
/// later. That is what keeps the rules a project cares about from being dropped
/// partway through a long session.
fn projectInstructions(io: std.Io, out: *std.Io.Writer, dir: std.Io.Dir) !bool {
    var current = dir;
    // The directory the caller passed is theirs to close; every one opened here
    // while walking up is this function's.
    var owned = false;
    defer if (owned) current.close(io);

    while (true) {
        if (try instructionsIn(io, out, current, &instruction_files, "The project's"))
            return true;
        // The repository root is the last directory searched.
        if (dirHas(io, current, ".git")) return false;

        // The parent is opened rather than derived from a path, so the walk
        // keeps no path string and follows the filesystem's own notion of a
        // parent.
        const parent = current.openDir(io, "..", .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };
        // At the filesystem root, `..` is the directory itself, which is what
        // ends the walk when no repository root was found above.
        if (sameDir(io, current, parent)) {
            parent.close(io);
            return false;
        }
        if (owned) current.close(io);
        current = parent;
        owned = true;
    }
}

/// Writes the user's own instructions, read from the configuration directory
/// alone, and returns whether it wrote any. Unlike the project's there is no
/// parent to walk up to: the configuration directory is a single directory,
/// wherever it is, so this is one read.
///
/// They join every session's prompt, ahead of the project's own, so a rule that
/// holds everywhere is set once rather than copied into each project.
fn globalInstructions(io: std.Io, out: *std.Io.Writer, dir: std.Io.Dir) !bool {
    return instructionsIn(io, out, dir, &instruction_files, "The user's");
}

/// Whether `dir` holds an entry named `name`.
fn dirHas(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

/// Whether two handles name the same directory. This is how the walk up knows it
/// has reached the filesystem root, where `..` names the root itself. Both are
/// on the same filesystem, being a directory and its own parent, so the inode
/// tells them apart.
fn sameDir(io: std.Io, a: std.Io.Dir, b: std.Io.Dir) bool {
    const one = a.statFile(io, ".", .{}) catch return false;
    const two = b.statFile(io, ".", .{}) catch return false;
    return one.inode == two.inode;
}

/// Printed in front of every line the user types. The transcript reuses it so a
/// replayed session looks like the run it continues.
const prompt = "> ";

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
    out: *std.Io.Writer,
    config: Config,
    session_id: []const u8,
    context_tokens: usize,
    cost: f64,
) !void {
    try out.print("billy · {s} · {s} · {s} · ", .{ @tagName(config.mode), session_id, config.model });
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
pub fn formatTokens(out: *std.Io.Writer, count: usize) !void {
    if (count < 1000) return out.print("{d}", .{count});
    if (count < 1_000_000) return formatScaled(out, count, 1000, 'k');
    return formatScaled(out, count, 1_000_000, 'M');
}

/// Writes `count` divided by `unit`, rounded to a whole number, with a trailing
/// unit letter. The rounding is what makes a count readable without a decimal:
/// half a thousand reads as the next thousand.
fn formatScaled(out: *std.Io.Writer, count: usize, unit: usize, suffix: u8) !void {
    try out.print("{d:.0}{c}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(unit)),
        suffix,
    });
}

/// Writes how full the context window is, as a whole percentage. A conversation
/// that has started but is under one percent is reported as `<1%`, so the gauge
/// does not read as empty. Shared with the web header, so both read it the same
/// way.
pub fn formatPercent(out: *std.Io.Writer, used: usize, total: usize) !void {
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
pub fn formatMoney(out: *std.Io.Writer, amount: f64) !void {
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
pub fn displayPath(out: *std.Io.Writer, cwd: []const u8, home: ?[]const u8) !void {
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

/// A session being asked things: the model client and the tools it runs with,
/// working in the session's own directory. Both frontends need the same of this,
/// so it is built in one place and neither can drift from the other.
///
/// The HTTP client is the run's own, borrowed by pointer, so every request of
/// every session shares its connections and the certificates it scanned once.
io: std.Io,
gpa: std.mem.Allocator,
config: Config,
/// The directory the session works in. For a resumed session it is the one
/// the session was started in, wherever billy runs from now.
work_dir: std.Io.Dir,
/// The tools, working in `work_dir`.
tool_set: Tools,
/// The model client, sending the conversation to `config.url`.
client: llm.Client,

/// Opens a session for asking things, working in `cwd` and sharing `http`.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    config: Config,
    cwd: []const u8,
    http: *std.http.Client,
) !Agent {
    var work_dir = std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| {
        std.log.err("cannot work in {s}: {s}", .{ cwd, @errorName(err) });
        return err;
    };
    errdefer work_dir.close(io);

    const tool_set = try Tools.init(.{
        .io = io,
        .dir = work_dir,
        .gpa = gpa,
        .formats = config.display.formats,
        .bash_timeout_s = config.bash_timeout_s,
        .style = config.display.style,
        .search = config.search,
        .fetch = config.fetch,
        .http = http,
        .health = config.health,
    });

    return .{
        .io = io,
        .gpa = gpa,
        .config = config,
        .work_dir = work_dir,
        .tool_set = tool_set,
        .client = .{
            .gpa = gpa,
            .io = io,
            .api_key = config.api_key,
            .url = config.url,
            .model = config.model,
            .http = http,
            .reasoning = config.reasoning,
        },
    };
}

pub fn deinit(agent: *Agent) void {
    agent.work_dir.close(agent.io);
}

/// Gives `session` the system prompt and the tools it runs with, if it has
/// none of its own.
///
/// The prompt and the tools are stored with the session and reused on a
/// resume, so the request sent then matches the earlier run byte for byte and
/// hits the prompt cache. Both are therefore set only on a session that has
/// neither, so a new session gets the current ones while a resumed one keeps
/// what it was saved with. The user's instructions are read from the
/// configuration directory and the project's from the session's directory,
/// and both are part of the prompt, so they are sent with every request.
pub fn prepare(agent: *Agent, session: *Session) !void {
    // A session with a conversation keeps the mode and prompt it was saved
    // with, so its request matches the earlier run; a new one takes the mode
    // the frontend chose, which its first prompt may have named with
    // `/chat`. Either way the agent's mode matches the session's, so the
    // tool set it offers and the guard it runs are the session's own.
    if (session.messages.items.len > 0) {
        agent.config.mode = session.mode;
    } else {
        session.setMode(agent.config.mode);
        const prompt_text = try leadPrompt(
            agent.io,
            agent.gpa,
            agent.work_dir,
            agent.config.user_instructions_dir,
            agent.config.mode,
        );
        defer agent.gpa.free(prompt_text);
        // A mode with no prompt of its own sends no system message, so the
        // request is the conversation alone.
        if (prompt_text.len > 0) try session.setSystemPrompt(prompt_text);
    }
    try session.ensureTools(agent.tool_set.definitions(agent.config.mode));
}

/// What asking `agent` to start a session with a first prompt came to.
pub const Started = union(enum) {
    /// What to ask. The prompt with any mode command taken off it, which is the
    /// text the turn carries.
    prompt: []const u8,
    /// The prompt named only a mode, so there is nothing to ask yet: the session
    /// is set up for that mode and waits for the next prompt.
    mode_only,
    /// The session has been asked something before, so this prompt is not its
    /// first and the mode it runs in is the one it was saved with.
    asked_before,
};

/// What a line typed into a session came to.
pub const Waiting = union(enum) {
    /// The line is asked of the model, with any mode command taken off it.
    ask: []const u8,
    /// The line named a mode and nothing else, so the session is set up for it
    /// and there is nothing to ask yet.
    ready,
    /// The line was a command, which the agent has already run. Everything it
    /// had to say has gone out through the emitter.
    ran,
};

/// Takes a line typed into `session` and does what it asks for, except asking
/// the model, which is left to `ask`.
///
/// This is the whole of what a frontend has to know about a line: a command is
/// run here and reported through the emitter, the first prompt settles the mode
/// and gives the session its prompt and tools, and anything else comes back as
/// the text to ask. Compaction is the agent's own business, so neither frontend
/// names it, calls it, or words what it says when there is nothing to fold.
pub fn take(agent: *Agent, emitter: Emitter, session: *Session, line: []const u8, default: Mode) !Waiting {
    // A command comes first: it is run rather than asked, and the session is not
    // touched by it beyond what the command does.
    if (Command.of(line)) |cmd| {
        switch (cmd) {
            .compact => {
                // A session that has been asked nothing has nothing to fold in,
                // and neither has one with nothing new since the last compaction.
                if (!agent.compact(emitter, session))
                    try emitter.show(.{ .notice = "nothing to compact" });
            },
        }
        return .ran;
    }

    // The conversation is compacted before a request that would carry it, so a
    // long session goes on rather than failing on an overlong request. It is
    // done here, before the prompt is added, so the prompt is not folded into
    // the summary it triggers.
    agent.compactIfNeeded(emitter, session);

    const started = try agent.start(session, line, default);
    return switch (started) {
        .prompt => |text| .{ .ask = text },
        .mode_only => .ready,
        // A session that has been asked something keeps the mode it was saved
        // with, so the line is asked as it was typed.
        .asked_before => .{ .ask = line },
    };
}

/// Settles the mode a session runs in from its first prompt, and gives a new
/// session the system prompt and tools it needs before its first request.
///
/// This is the one place the "first prompt" rules live, so both frontends get
/// them the same way: `/chat` and `/general` name the mode and the rest of the
/// line is what is asked; a prompt naming only a mode sets the session up and
/// asks nothing; and anything else is the mode `default`, which is each
/// frontend's own (see `Mode.start`).
///
/// A session that has been asked before keeps what it was saved with, so this
/// only reports that its prompt is not the first.
pub fn start(agent: *Agent, session: *Session, text: []const u8, default: Mode) !Started {
    if (session.messages.items.len > 0) return .asked_before;

    const choice = Mode.start(text, default);
    agent.config.mode = choice.mode;
    try agent.prepare(session);
    if (choice.text.len == 0) return .mode_only;
    return .{ .prompt = choice.text };
}

/// Compacts the conversation if it has outgrown the context window, so that
/// a long session goes on rather than failing on an overlong request. When it
/// compacts, the session's prompt and tools are refreshed, so the next
/// request carries the current ones (see `refreshLead`).
///
/// A frontend calls this before it adds a prompt and, on a terminal, before
/// it shows the header, so the prompt is not folded into the summary it
/// triggers and the header reports the smaller conversation. A failure is
/// not fatal: the conversation is left as it is and the request goes out with
/// it, which is what would have happened without compaction at all.
fn compactIfNeeded(agent: *Agent, emitter: Emitter, session: *Session) void {
    const compacted = agent.maybeCompact(emitter, session) catch |err| {
        std.log.warn("compaction failed: {s}", .{@errorName(err)});
        return;
    };
    if (compacted) agent.refresh(session);
}

/// Compacts the conversation now, whatever it has grown to, because the user
/// asked with `/compact` rather than because a request would not fit. Says
/// whether it compacted anything: a conversation with nothing new since the
/// last compaction has nothing to fold in, and neither has one that has not
/// been asked anything. A failure is logged and reads as nothing compacted.
fn compact(agent: *Agent, emitter: Emitter, session: *Session) bool {
    const compacted = agent.fold(emitter, session) catch |err| {
        std.log.warn("compaction failed: {s}", .{@errorName(err)});
        return false;
    };
    if (compacted) agent.refresh(session);
    return compacted;
}

/// Re-reads the prompt and the tools into the session, so a session that has
/// been running a while picks up a changed prompt, instruction files or tool
/// set. A compaction is the one moment replacing the front of a request costs
/// no cache that was not already being thrown away.
///
/// A refresh that fails is not the turn's: the session keeps the prompt and
/// tools it had, which are the ones its last request was sent with, and the
/// run goes on.
fn refresh(agent: *Agent, session: *Session) void {
    const mode = agent.config.mode;
    refreshLead(agent, mode, agent.tool_set.definitions(mode), session) catch |err|
        std.log.warn("could not refresh the prompt and tools: {s}", .{@errorName(err)});
}

/// Asks `session` one thing and shows how the answer is reached: the prompt,
/// the tool calls it makes, and the reply. This is what one prompt of a
/// session is, whether it was typed at a terminal or sent from a page.
///
/// On the first turn the session is given a title: first one derived from
/// what was asked, so it is named at once, and then, when the model is asked
/// for titles, one it writes, which replaces the first.
pub fn ask(agent: *Agent, emitter: Emitter, session: *Session, text: []const u8) !void {
    // The first turn is the session's first message; the system prompt is
    // kept apart from the conversation, so a session that has been asked
    // nothing has none.
    const first_turn = session.messages.items.len == 0;
    _ = try nameFromPrompt(session, text);

    try session.append(.{ .role = .user, .content = text });
    try emitter.show(.{ .prompt = text });
    try turn(agent, emitter, session);

    if (first_turn and agent.config.title) {
        titleSession(agent, session) catch |err|
            std.log.warn("could not title the session: {s}", .{@errorName(err)});
    }
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    config: Config,
    session: *Session,
) !void {
    // One HTTP client for the run, shared by the model requests and the search
    // backend, so both reuse its connections and share the certificates it scans
    // once. Every session asked in this run borrows it.
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var agent = try Agent.init(io, gpa, config, session.cwd(), &http);
    defer agent.deinit();
    // A resumed session keeps the prompt and tools it was saved with, so it is
    // prepared here; a new one gets them from its first prompt, through `start`.
    const resumed = session.messages.items.len > 0;
    if (resumed) try agent.prepare(session);

    // The editor holds the lines it returns and its history in an arena of its
    // own, over `gpa`, so the run need not keep an allocator for them.
    var editor = LineEditor.init(io, out, gpa);
    defer editor.deinit();

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
        header.clearRetainingCapacity();
        // The header is built from the agent's config, so the mode it shows is
        // the one the session is running in, which the first prompt may have set.
        try sessionHeader(&header.writer, agent.config, session.id(), session.context_tokens, session.cost);
        const line = (try editor.readLine(header.written(), prompt)) orelse break;
        if (line.len == 0) continue;
        // What the line came to is the agent's to decide: a command is run and
        // reported through the emitter, a first prompt settles the mode, and
        // anything else is what is asked.
        const waiting = try agent.take(emitter, session, line, .general);
        if (waiting == .ran) {
            try out.flush();
            continue;
        }
        const text = switch (waiting) {
            .ask => |text| text,
            else => continue,
        };
        // The line editor has erased the prompt it was typed behind, so the
        // prompt is written out now as the block a replay shows: the `> ` belongs
        // to the input, not to what was said. Flushed before the request, which
        // may take a while, so the user sees what was sent.
        //
        // A failed request must not end the session: report it and take the next
        // request from the user.
        agent.ask(emitter, session, text) catch |err|
            std.log.err("request failed: {s}", .{@errorName(err)});
        try out.flush();
    }
    try out.flush();
}

/// Replays a stored conversation on the terminal as the blocks it was made of,
/// so remembering the context of an earlier run is not left to the user. The
/// blocks come from `walk`, and each is shown as the run showed it, so a
/// replayed prompt reads as the one that was typed.
pub fn printTranscript(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
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

    const calls = message.tool_calls.len;
    if (calls == 0)
        return emitter.show(.{ .answer = session.contentOf(message) orelse "" });

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
    const calls = messages[index].tool_calls.len;
    return if (calls == 0) 1 else calls;
}

/// Runs the model until it replies with text instead of tool calls, showing what
/// happens as blocks as it goes.
fn turn(agent: *Agent, emitter: Emitter, session: *Session) !void {
    // Holds the parsed call of each tool call the model asks for, which is read
    // until that call has been run and shown. Reset per call, so a turn that
    // makes many calls holds only the one it is on.
    var scratch_state = std.heap.ArenaAllocator.init(agent.tool_set.gpa);
    defer scratch_state.deinit();

    var remaining: usize = agent.config.max_turns;
    // A compaction that failed is not tried again within the same turn, so a
    // provider that will not summarize cannot turn every request of a long turn
    // into a second failed one. The next turn tries afresh.
    var compact_failed = false;
    while (remaining > 0) : (remaining -= 1) {
        // A conversation that has outgrown the context window is compacted
        // before the request that would carry it, so a long session goes on
        // instead of failing on an overlong request. A failure to compact is not
        // the turn's: the request goes out with the conversation as it is. A
        // compaction refreshes the prompt and tools before the next request, so
        // the turn picks up the current ones.
        if (!compact_failed) {
            const compacted = agent.maybeCompact(emitter, session) catch |err| blk: {
                std.log.warn("compaction failed: {s}", .{@errorName(err)});
                compact_failed = true;
                break :blk false;
            };
            if (compacted) refresh(agent, session);
        }

        // The completion owns its parsed reply, and each tool result lives in the
        // tool set's scratch, so the turn allocates nothing of its own: the
        // conversation is written straight onto the connection out of the pool,
        // the reply is freed when the turn ends, and the session interns what it
        // keeps.
        const completion = try agent.client.complete(agent.gpa, session.conversation(&.{}), session.toolSet());
        defer completion.deinit();

        // The totals are recorded first, so the save inside `append` stores them
        // along with the message. Each request is priced as it is made, at the
        // rates in effect then, so a session running through a rate change is
        // billed for what it actually cost.
        session.recordUsage(completion.usage, costOf(agent.rateNow(), completion.usage));
        try session.append(completion.message);

        const message = completion.message;
        const calls = message.tool_calls orelse &.{};
        // No calls means the model answered, which ends the turn.
        if (calls.len == 0) return emitter.show(.{ .answer = message.content orelse "" });

        try runCalls(&agent.tool_set, emitter, &scratch_state, session, agent.config.mode, calls);
    }
    var buffer: [96]u8 = undefined;
    const stopped = std.fmt.bufPrint(
        &buffer,
        "stopped after {d} turns without a final answer",
        .{agent.config.max_turns},
    ) catch "stopped without a final answer";
    try emitter.show(.{ .notice = stopped });
}

/// Runs the tool calls of one answer, showing each as it runs and recording its
/// result, so the next request carries them.
///
/// The call is parsed and shown before it runs, so a command that runs long has
/// its header on screen while it runs, and then the result once it is in. The
/// parsed call lives in the turn's scratch, which the next call resets, so it is
/// used before then.
fn runCalls(
    tool_set: *Tools,
    emitter: Emitter,
    scratch_state: *std.heap.ArenaAllocator,
    session: *Session,
    mode: Mode,
    calls: []const llm.ToolCall,
) !void {
    for (calls) |call| {
        _ = scratch_state.reset(.retain_capacity);
        const parsed = Tools.parse(scratch_state.allocator(), call);
        try emitter.show(.{ .tool_begin = parsed });

        var result: std.Io.Writer.Allocating = .init(tool_set.gpa);
        defer result.deinit();
        // The mode's tools are what the model is offered, but a session file or
        // a crafted request can still name one it is not allowed, so the call is
        // refused here as well as filtered out of the offer.
        const name = Tools.callName(parsed);
        if (!mode.allows(name)) {
            try result.writer.print("error: the {s} mode does not allow the {s} tool", .{ @tagName(mode), name });
        } else {
            try tool_set.run(parsed, &result.writer);
        }

        try session.append(.{
            .role = .tool,
            .tool_call_id = call.id,
            .content = result.written(),
        });
        try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });
    }
}

/// The system prompt a session runs with: billy's own, the user's own
/// instructions when the configuration directory holds any, and the project's
/// instructions when it has them, which are read from the session's directory.
/// The user's come first, then the project's, so the more particular rules are
/// read last.
///
/// All of it is the prompt rather than the conversation, so it is sent with every
/// request and survives whatever context trimming happens later. That is what
/// keeps the rules the user and the project care about from being dropped
/// partway through a long session. The caller owns the text and frees it.
fn leadPrompt(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, user_dir: ?std.Io.Dir, mode: Mode) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    // The mode's text first, then each section of instructions as it is found,
    // so the whole prompt is written once into one buffer with no part of it
    // built apart and then copied in.
    try text.writer.writeAll(mode.prompt());
    // Ask mode answers questions rather than changing code, so the instruction
    // files, which say how to change it, are left out.
    if (mode.instructions()) {
        if (user_dir) |config_dir| _ = try globalInstructions(io, &text.writer, config_dir);
        _ = try projectInstructions(io, &text.writer, dir);
    }
    return text.toOwnedSlice();
}

/// Refreshes the prompt and the tools a session opens its requests with, so a
/// session that has been running a while picks up a changed prompt, the user's
/// instructions, the project's instructions or tool set. The refreshed session is
/// written out, since a compaction is the only caller and the file has just been
/// rewritten with the summary.
///
/// This runs after a compaction, which is the one moment replacing the front of a
/// request costs no cache that was not already being thrown away: the
/// conversation before the compaction is being replaced by a summary in any case,
/// so the only shared prefix left to lose is the prompt and the tools
/// themselves.
fn refreshLead(
    agent: *const Agent,
    mode: Mode,
    definitions: []const Session.Definition,
    session: *Session,
) !void {
    const prompt_text = try leadPrompt(
        agent.io,
        agent.gpa,
        agent.tool_set.dir,
        agent.config.user_instructions_dir,
        mode,
    );
    defer agent.gpa.free(prompt_text);
    if (prompt_text.len > 0) try session.setSystemPrompt(prompt_text);
    try session.setTools(definitions);
    try session.save();
}

/// Sent to ask for a title, after a session's first turn: the conversation with
/// this as the message after it. Like the compacting prompt it is never part of
/// the conversation -- it is written onto the request on its own (see
/// `Session.Conversation.extra`) -- so the model reads it as the latest message
/// while the session keeps only what was really said.
const title_prompt =
    \\The conversation above is the start of a session. Write a short title for
    \\it, so the user can find it again in a list: a few words, no more than
    \\about eight, naming what the session is about. Reply with the title alone,
    \\as plain text, with no quotes, no trailing punctuation and no explanation.
;

/// Asks the model for a short title for `session` and records it, so a frontend
/// can list the session by name. It is called after the session's first turn, so
/// there is an answer to name.
///
/// As with compaction, the conversation is sent as a request would carry it with
/// the titling prompt after it, so the model reads exactly what happened and the
/// request shares the conversation's cache. A model that answers with nothing
/// usable leaves the session as it is, so the title it already has (the one
/// derived from the first prompt) stands.
fn titleSession(agent: *Agent, session: *Session) !void {
    const extra = [_]llm.Message{.{ .role = .user, .content = title_prompt }};
    const completion = try agent.client.complete(agent.gpa, session.conversation(&extra), session.toolSet());
    defer completion.deinit();
    session.recordCost(completion.usage, costOf(agent.rateNow(), completion.usage));

    const raw = completion.message.content orelse return;
    const title = try cleanTitle(agent.gpa, raw) orelse return;
    defer agent.gpa.free(title);
    try session.setTitle(title);
    try session.save();
}

/// The title `raw` holds, cut down to one clean line, or null when nothing
/// usable is left: the first line, trimmed, with any quotes or backticks the
/// model wrapped it in taken off.
fn cleanTitle(gpa: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const line = std.mem.sliceTo(raw, '\n');
    const unquoted = std.mem.trim(u8, std.mem.trim(u8, line, " \t\r"), "\"'`");
    const text = std.mem.trim(u8, unquoted, " \t\r");
    if (text.len == 0) return null;
    return try gpa.dupe(u8, text);
}

/// A title derived from the first thing asked, so a session is named the moment
/// it is created, before the model has named it. The model's title replaces it
/// after the first turn. It is the first line, trimmed, which for a coding
/// session is usually already a serviceable name.
fn provisionalTitle(text: []const u8) []const u8 {
    const line = std.mem.sliceTo(text, '\n');
    return std.mem.trim(u8, line, " \t\r");
}

/// Names `session` from `text`, the first thing asked, if it has no title yet,
/// so a session is named the moment it starts rather than only once the model has
/// answered. Returns whether it named it.
///
/// This is the name the model's title later replaces; a frontend calls it at the
/// start of the first turn, so its list shows a name at once, and `ask` calls it
/// too so a session named anywhere is named the same way.
pub fn nameFromPrompt(session: *Session, text: []const u8) !bool {
    if (session.title() != null) return false;
    try session.setTitle(provisionalTitle(text));
    return true;
}

/// The rates in effect right now. Zero for a model billy does not know, which
/// has no prices to cost its tokens at.
fn rateNow(agent: *const Agent) models.Price {
    const info = agent.config.model_info orelse return .{};
    return info.priceAt(@intCast(std.Io.Clock.real.now(agent.io).toSeconds()));
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
fn compactThreshold(agent: *const Agent) usize {
    if (agent.config.compact_at == 0) return 0;
    const info = agent.config.model_info orelse return 0;
    return info.context_window * agent.config.compact_at / 100;
}

/// Compacts the conversation into a summary when it has filled the context
/// window past the threshold, so that a long session goes on rather than failing
/// on the next request. Says whether it compacted.
///
/// This is the automatic compaction, which waits for the threshold; a caller
/// that wants the conversation folded now, whatever it has grown to, asks for
/// `compact` instead.
fn maybeCompact(agent: *Agent, emitter: Emitter, session: *Session) !bool {
    // Nothing is compacted for a model whose window is unknown, since there is
    // then no threshold to measure the conversation against; and a conversation
    // that has not reached it is left alone for the next request to fold, if it
    // ever does.
    const threshold = agent.compactThreshold();
    if (threshold == 0 or session.context_tokens < threshold) return false;
    return agent.fold(emitter, session);
}

/// Compacts the conversation into a summary now, whatever it has grown to, and
/// says whether there was anything to fold in.
///
/// The summary is added to the end of the session and recorded in its list of
/// compactions, and every request from then on carries only that summary and
/// what follows it (`Session.sentFrom`). The session itself keeps every message,
/// so the transcript still shows the whole history. Doing nothing here is not an
/// error: the conversation is left as it was and the request goes out with it,
/// which is what would have happened without compaction at all. The caller
/// refreshes the session's prompt and tools when it did compact, which is why
/// the answer is reported rather than swallowed.
fn fold(agent: *Agent, emitter: Emitter, session: *Session) !bool {
    // Nothing has been added since the last compaction, so there is nothing new
    // to fold in: compacting again would only summarize the summary, and would
    // do so on every request.
    const sent_from = session.sentFrom();
    if (session.messages.items.len - sent_from <= 1) return false;

    const summary = try agent.summarize(session) orelse return false;
    defer agent.gpa.free(summary);

    // The conversation a request now carries is the summary and little else, so
    // its size is not known until the next request reports one. Clearing the
    // gauge before the compaction is written means the file records the cleared
    // size, so a resumed session does not read a stale one and compact again off
    // it.
    session.context_tokens = 0;
    try session.appendCompaction(compact_prompt, summary);
    try emitter.show(.{ .compacted = .{ .prompt = compact_prompt, .summary = summary } });
    return true;
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
fn summarize(agent: *Agent, session: *Session) !?[]const u8 {
    // The conversation the model has been given, with the compacting prompt as
    // the message after it: the same request a turn would send, with one more
    // message on the end, so the model reads exactly what happened. Nothing is
    // added to the session: the prompt is written straight out of the local
    // array and is gone when this returns.
    const extra = [_]llm.Message{.{ .role = .user, .content = compact_prompt }};
    const completion = try agent.client.complete(agent.gpa, session.conversation(&extra), session.toolSet());
    defer completion.deinit();
    session.recordCost(completion.usage, costOf(agent.rateNow(), completion.usage));

    const content = completion.message.content orelse return null;
    if (content.len == 0) return null;
    return try agent.gpa.dupe(u8, content);
}

/// Prints `messages` the way a resumed session replays them, from a session
/// built to hold exactly them, and compares the blocks to `expected`. The
/// transcript reads the conversation where a session stores it, so the messages
/// have to go through a session to be replayed at all.
fn expectTranscript(
    expected: []const u8,
    messages: []const llm.Message,
    style: Terminal.Style,
) !void {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // No bash format: what these cover is how a message is headed and laid out,
    // which the tool format does not touch. Zero shows the whole conversation.
    try printTranscript(gpa, &out.writer, &session, .{ .style = style }, 0);
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
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{
        .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
    } });
    try session.append(.{ .role = .tool, .tool_call_id = "call_1", .content = "contents a" });
    try session.append(.{ .role = .tool, .tool_call_id = "call_2", .content = "contents b" });
    try session.append(.{ .role = .assistant, .content = "done" });

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
            .{ .role = .system, .content = "ignore me" },
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "call_1",
                .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
            }} },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
            .{ .role = .assistant, .content = "done" },
        },
        .plain,
    );
}

test "printTranscript leaves out the system prompt and an unpaired tool result" {
    // A result whose call is not in the session has nothing to belong to, and a
    // system prompt is never shown at all.
    try expectTranscript(
        "",
        &.{
            .{ .role = .system, .content = "ignore me" },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;" },
        },
        .plain,
    );
}

test "a reply is headed by its own header, and its markdown laid out" {
    // A reply is markdown, laid out by the built-in renderer: the marks are taken
    // off and the text is set as a terminal shows it.
    try expectTranscript(
        "◆ answer\nhi\n",
        &.{.{ .role = .assistant, .content = "**hi**" }},
        .plain,
    );

    // An empty reply is said to be empty rather than shown blank.
    try expectTranscript(
        "◆ answer\n(empty reply)\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt from the session is headed and laid out like a reply" {
    // A prompt is markdown too, so it is laid out by the same renderer.
    try expectTranscript(
        "\n» prompt\nhi\n\n",
        &.{.{ .role = .user, .content = "**hi**" }},
        .plain,
    );
}

test "an empty reply is shown under its header, in place of the text" {
    try expectTranscript(
        "◆ answer\n(empty reply)\n",
        &.{.{ .role = .assistant, .content = "" }},
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
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi" },
        },
        .ansi,
    );
}

test "printTranscript shows a compaction as a single line" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "one" });
    try session.append(.{ .role = .assistant, .content = "a1" });
    try session.appendCompaction("summarize this", "the summary");
    try session.append(.{ .role = .user, .content = "two" });
    try session.append(.{ .role = .assistant, .content = "a2" });

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
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "hi" });
    try session.appendCompaction("ASKEDFORTHEcompaction", "THESUMMARYTEXT");
    try session.append(.{ .role = .user, .content = "next" });

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
            .{ .role = .assistant, .tool_calls = &.{
                .{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
                .{ .id = "call_2", .function = .{ .name = "read", .arguments = "{\"path\":\"b.zig\"}" } },
            } },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "contents of a" },
            .{ .role = .tool, .tool_call_id = "call_2", .content = "contents of b" },
        },
        .plain,
    );
}

test "printTranscript rebuilds an edit's diff from the stored call" {
    // The diff is computed from the call, so a replay shows the same one the run
    // did without the diff having been stored.
    try expectTranscript(
        "✎ edit a.zig\n▾ diff\n-old\n+new\n\n",
        &.{
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "call_1",
                .function = .{
                    .name = "edit",
                    .arguments = "{\"path\":\"a.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}",
                },
            }} },
            .{ .role = .tool, .tool_call_id = "call_1", .content = "replaced 1 occurrence(s) in a.zig" },
        },
        .plain,
    );
}

/// A config with no model metadata, so the header is just the model and the
/// directory. Tests that need a gauge fill `model_info` in.
/// An agent for a test, working in a directory that exists.
///
/// The HTTP client is borrowed by the agent and by the tools that make requests,
/// so a test that makes one passes the client it points at a mock; a test that
/// only drives the loop passes null, and the client it is given is never read.
/// That is what keeps the setup of an unused client out of every test: the field
/// is a pointer, so a null is only a null until a web tool is called.
fn testAgent(io: std.Io, gpa: std.mem.Allocator, config: Config, http: ?*std.http.Client) !Agent {
    const work_dir = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(work_dir);
    return testAgentIn(io, gpa, config, work_dir, http);
}

/// An agent for a test working in `work_dir`, which is where the project's
/// instructions are looked for. A test that cares which directory that is names
/// one; the rest work in the directory the tests run from.
fn testAgentIn(
    io: std.Io,
    gpa: std.mem.Allocator,
    config: Config,
    work_dir: []const u8,
    http: ?*std.http.Client,
) !Agent {
    if (http) |client| return Agent.init(io, gpa, config, work_dir, client);

    var unused: std.http.Client = undefined;
    return Agent.init(io, gpa, config, work_dir, &unused);
}

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
fn testTerminal(out: *std.Io.Writer, display: Display) Terminal {
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
        "billy · general · 01HF7YAT000000000000000000 · deepseek-flash · /work",
        testConfig("deepseek-flash", "/work", null),
        0,
        0,
    );
}

test "header names the mode the session runs in" {
    var config = testConfig("m", "/work", null);
    config.mode = .chat;
    try expectHeader("billy · chat · 01HF7YAT000000000000000000 · m · /work", config, 0, 0);
}

test "header shortens a path inside the home directory" {
    try expectHeader(
        "billy · general · 01HF7YAT000000000000000000 · m · ~/repo/billy",
        testConfig("m", "/home/user/repo/billy", "/home/user"),
        0,
        0,
    );
    // The home directory itself becomes just `~`.
    try expectHeader(
        "billy · general · 01HF7YAT000000000000000000 · m · ~",
        testConfig("m", "/home/user", "/home/user"),
        0,
        0,
    );
    // A sibling that merely shares the prefix is left alone.
    try expectHeader(
        "billy · general · 01HF7YAT000000000000000000 · m · /home/user2",
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
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 0/128k (0%) · $0", config, 0, 0);
    // A rounded-to-zero percentage still shows the conversation is not empty.
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 500/128k (<1%) · $0", config, 500, 0);
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 16k/128k (12%) · $0", config, 16_000, 0);
    // A full window, and a count that rounds to a whole thousand.
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 128k/128k (100%) · $0", config, 128_000, 0);
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 13k/128k (9%) · $0", config, 12_500, 0);
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
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · deepseek-flash · /work · 3M/4M (75%) · $0.75", config, 3_000_000, off_peak_cost);
    // A request made in peak hours cost double, which stays on the total even if
    // the header is shown later, off-peak.
    const peak_cost = costOf(info.priceAt(peak_utc), usage);
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · deepseek-flash · /work · 3M/4M (75%) · $1.51", config, 3_000_000, peak_cost);
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
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · who-knows · /work", config, 5000, 12.34);
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

/// Writes the section an instruction reader (`globalInstructions` or
/// `projectInstructions`) produces for `dir` and compares it to `expected`, so a
/// test reads as the section it lands in the prompt.
fn expectInstructions(expected: []const u8, read: anytype, dir: std.Io.Dir) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try read(std.testing.io, &out.writer, dir));
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Checks that an instruction reader writes nothing for `dir`.
fn expectNoInstructions(read: anytype, dir: std.Io.Dir) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try read(std.testing.io, &out.writer, dir));
}

test "the project's instructions are read from the working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "Write tests.\n" });

    // The section names where the instructions came from and carries them
    // through, a blank line below the prompt above it, exactly as written.
    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\nWrite tests.\n",
        projectInstructions,
        tmp.dir,
    );
}

test "AGENTS.md is read before CLAUDE.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "agents" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CLAUDE.md", .data = "claude" });

    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\nagents",
        projectInstructions,
        tmp.dir,
    );

    // With no AGENTS.md the other name is read, so a project written for another
    // tool still works.
    try tmp.dir.deleteFile(std.testing.io, "AGENTS.md");
    try expectInstructions(
        "\n\nThe project's instructions follow, read from CLAUDE.md.\n\nclaude",
        projectInstructions,
        tmp.dir,
    );
}

test "the instructions are found in a parent up to the repository root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A repository root holding the instructions, and a subdirectory to run from.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "root rules" });
    try tmp.dir.createDirPath(std.testing.io, "a/b");

    var deep = try tmp.dir.openDir(std.testing.io, "a/b", .{});
    defer deep.close(std.testing.io);
    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\nroot rules",
        projectInstructions,
        deep,
    );
}

test "a project with no instructions has none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A repository root, so the search stops here rather than walking above it.
    try tmp.dir.createDirPath(std.testing.io, ".git");

    try expectNoInstructions(projectInstructions, tmp.dir);
}

test "an empty instructions file is not used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "" });

    try expectNoInstructions(projectInstructions, tmp.dir);
}

test "the nearest instructions win over an ancestor's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "outer" });
    try tmp.dir.createDirPath(std.testing.io, "inner");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "inner/AGENTS.md", .data = "inner" });

    var inner = try tmp.dir.openDir(std.testing.io, "inner", .{});
    defer inner.close(std.testing.io);

    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\ninner",
        projectInstructions,
        inner,
    );
}

test "the user's instructions are read from the configuration directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "Be terse.\n" });

    // The heading names the user rather than the project, so the two sections of
    // a prompt read apart, and the file is carried through as it was written.
    try expectInstructions(
        "\n\nThe user's instructions follow, read from AGENTS.md.\n\nBe terse.\n",
        globalInstructions,
        tmp.dir,
    );
}

test "the user's instructions are read from the directory alone, not above it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A file above the directory handed in is not found: the configuration
    // directory is read on its own, with no project above it to walk up to.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "outer" });
    try tmp.dir.createDirPath(std.testing.io, "nested");
    var nested = try tmp.dir.openDir(std.testing.io, "nested", .{});
    defer nested.close(std.testing.io);

    try expectNoInstructions(globalInstructions, nested);
}

test "a user's instructions file that is missing or empty is not used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectNoInstructions(globalInstructions, tmp.dir);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "" });
    try expectNoInstructions(globalInstructions, tmp.dir);
}

test "a large instructions file is streamed whole" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Longer than the 4 KiB the file is streamed at a time, so it crosses
    // chunks, and the newline at the end is kept as written.
    var file_text: std.Io.Writer.Allocating = .init(gpa);
    defer file_text.deinit();
    const long_text: [5000]u8 = @splat('x');
    try file_text.writer.writeAll(&long_text);
    try file_text.writer.writeAll("\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = file_text.written() });

    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    try expected.writer.writeAll("\n\nThe project's instructions follow, read from AGENTS.md.\n\n");
    try expected.writer.writeAll(&long_text);
    try expected.writer.writeAll("\n");

    try expectInstructions(expected.written(), projectInstructions, tmp.dir);
}

test "the prompt is billy's own, the user's instructions, then the project's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Two directories: the configuration one holding the user's file, and the
    // project one the session works in, which is separate so neither search can
    // wander into the other.
    var config = std.testing.tmpDir(.{});
    defer config.cleanup();
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    // A repository root, so the project search stops here rather than walking up
    // into whatever holds the test's temporary directory.
    try project.dir.createDirPath(io, ".git");

    // With neither file, the prompt is billy's own text alone.
    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir, .general);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(Mode.general.prompt(), text);
    }

    // The user's instructions are read from the configuration directory and
    // joined after billy's own text, with no project file needed for them.
    try config.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "USER RULES" });
    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir, .general);
        defer gpa.free(text);
        const expected = try std.fmt.allocPrint(
            gpa,
            "{s}\n\nThe user's instructions follow, read from AGENTS.md.\n\nUSER RULES",
            .{Mode.general.prompt()},
        );
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, text);
    }

    // The project's follow the user's, so the more particular rules are read
    // last, and all three are there.
    try project.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "PROJECT RULES" });
    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir, .general);
        defer gpa.free(text);
        const user = std.mem.indexOf(u8, text, "USER RULES") orelse return error.TestUnexpectedResult;
        const local = std.mem.indexOf(u8, text, "PROJECT RULES") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, text, Mode.general.prompt()) != null);
        try std.testing.expect(user < local);
    }

    // A project on its own still works, when the configuration holds no file.
    try config.dir.deleteFile(io, "AGENTS.md");
    {
        const text = try leadPrompt(io, gpa, project.dir, null, .general);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "PROJECT RULES") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "USER RULES") == null);
    }
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
    var root = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    defer root.close(io);
    var root_up = try root.openDir(io, "..", .{});
    defer root_up.close(io);
    try std.testing.expect(sameDir(io, root, root_up));
}

test "the compaction threshold is the configured share of the window, or off" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A model without a known window has nothing to measure a conversation
    // against, so there is no threshold even with compaction on.
    var agent = try testAgent(io, gpa, testConfig("m", "/work", null), null);
    defer agent.deinit();
    try std.testing.expectEqual(0, agent.compactThreshold());

    agent.config.model_info = .{
        .provider = .deepseek,
        .model = "m",
        .context_window = 1000,
        .price = .{},
    };

    // The default is a share of the window, not the whole of it.
    try std.testing.expectEqual(800, agent.compactThreshold());

    // Zero turns it off.
    agent.config.compact_at = 0;
    try std.testing.expectEqual(0, agent.compactThreshold());

    // Any share the file names, whether or not it divides the window evenly.
    agent.config.compact_at = 50;
    try std.testing.expectEqual(500, agent.compactThreshold());
    agent.config.compact_at = 33;
    try std.testing.expectEqual(330, agent.compactThreshold());
}

test "maybeCompact folds the conversation once it has filled the window" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "OLDPROMPT" });
    try session.append(.{ .role = .assistant, .tool_calls = &.{.{
        .id = "call_x",
        .function = .{ .name = "bash", .arguments = "{}" },
    }} });
    try session.append(.{ .role = .tool, .tool_call_id = "call_x", .content = "OLDTOOLOUTPUT" });
    try session.append(.{ .role = .assistant, .content = "OLDANSWER" });

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

    // A server standing in for the model, answering the compaction request with a
    // fixed summary and recording the body it was sent.
    var mock = try Mock.start("/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"the summary\"}}]," ++
            "\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"total_tokens\":105}}",
    ));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    config.url = mock.url;
    config.api_key = "k";

    var agent = try testAgent(io, gpa, config, &http);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try std.testing.expect(try agent.maybeCompact(terminal.emitter(), &session));

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The request carried the whole conversation, tool call and result included,
    // with the compacting prompt after it.
    const body = mock.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDPROMPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_x") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDTOOLOUTPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "OLDANSWER") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "free room in the context") != null);

    // The prompt and the summary are added to the end of the session, which keeps
    // every message it had. The summary is a user message.
    try std.testing.expectEqual(6, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[4]));
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[5]));
    try std.testing.expectEqualStrings("the summary", session.contentOf(session.messages.items[5]).?);
    // A request now starts at the summary, skipping everything the summary stands
    // in for.
    try std.testing.expectEqual(5, session.sentFrom());
    try std.testing.expect(session.isCompaction(5));

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
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "hello" });

    var config = testConfig("m", "/work", null);
    config.model_info = .{ .provider = .deepseek, .model = "m", .context_window = 1000, .price = .{} };

    // Nothing is listening on this address, so a request made where the function
    // should have returned first would fail the test rather than pass it.
    config.url = "http://127.0.0.1:1/chat/completions";

    var agent = try testAgent(io, gpa, config, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    const emitter = terminal.emitter();

    // Below the threshold.
    session.context_tokens = 100;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session));
    // Turned off.
    session.context_tokens = 999;
    agent.config.compact_at = 0;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session));
    // A model with no known window has no threshold to measure against.
    agent.config.compact_at = 80;
    agent.config.model_info = null;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session));

    // Nothing was added, and nothing was printed.
    try std.testing.expectEqual(1, session.messages.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

test "a compaction asked for now folds the conversation in whatever its size" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "hello" });
    try session.append(.{ .role = .assistant, .content = "hi" });

    var config = testConfig("m", "/work", null);
    config.model_info = .{ .provider = .deepseek, .model = "m", .context_window = 1000, .price = .{} };
    // Compaction is off, so only a manual one runs.
    config.compact_at = 0;

    var mock = try Mock.start("/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"the summary\"}}]," ++
            "\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"total_tokens\":105}}",
    ));
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    config.url = mock.url;
    config.api_key = "k";

    var agent = try testAgent(io, gpa, config, &http);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    // Asked for now, so the threshold and the setting are ignored: the
    // conversation is folded whatever size it has grown to.
    try std.testing.expect(try agent.fold(terminal.emitter(), &session));
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The summary is folded in, and the pair reads as one line.
    try std.testing.expectEqual(4, session.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "compacted") != null);

    // Asking again does nothing: the summary is the last message, so there is
    // nothing new to fold in, and a request would only re-summarize it.
    out.clearRetainingCapacity();
    try std.testing.expect(!try agent.fold(terminal.emitter(), &session));
    try std.testing.expectEqualStrings("", out.written());
}

test "the compact command is read from a prompt" {
    try std.testing.expectEqual(Command.compact, Command.of("/compact").?);
    // The whitespace around a pasted line does not matter.
    try std.testing.expectEqual(Command.compact, Command.of("  /compact\n").?);
    // Only the whole line is a command: a prompt that starts with one is a
    // prompt, and so is anything else.
    try std.testing.expect(Command.of("/compact this") == null);
    try std.testing.expect(Command.of("hello") == null);
    try std.testing.expect(Command.of("/chat") == null);
}

test "maybeCompact does not compact a summary that stands alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.appendCompaction("p", "a summary");

    var config = testConfig("m", "/work", null);
    config.model_info = .{ .provider = .deepseek, .model = "m", .context_window = 1000, .price = .{} };

    // Over the threshold, but the last message is the summary itself, so there is
    // nothing new to fold in and a request would only re-summarize it.
    session.context_tokens = 999;
    // Nothing is listening there, so a request made where this should have
    // returned first would fail the test.
    config.url = "http://127.0.0.1:1/chat/completions";
    var agent = try testAgent(io, gpa, config, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try std.testing.expect(!try agent.maybeCompact(terminal.emitter(), &session));

    try std.testing.expectEqual(2, session.messages.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

test "refreshLead replaces the prompt, the project instructions and the tools" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The project has instructions of its own, which are part of the prompt.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "PROJECT RULES" });

    const old_tools = [_]Session.Definition{.{
        .name = "old",
        .description = "A tool from when the session started.",
        .parameters = "{}",
    }};
    const new_tools = [_]Session.Definition{
        .{ .name = "read", .description = "Read a file.", .parameters = "{}" },
        .{ .name = "bash", .description = "Run a command.", .parameters = "{}" },
    };

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    // A session that has been running a while, carrying the prompt and tools it
    // started with.
    try session.setSystemPrompt("OLD PROMPT");
    try session.setTools(&old_tools);

    // The lead is read out of the directory the agent works in, which is where
    // the project's instructions are looked for: the session's own directory,
    // which is the temporary one holding them.
    // The lead is read out of the directory the agent works in, which is where
    // the project's instructions are looked for: the temporary directory holding
    // them. No client is given, since this reads no model.
    const work_dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(work_dir);
    var agent = try testAgentIn(io, gpa, testConfig("m", "/work", null), work_dir, null);
    defer agent.deinit();

    try refreshLead(&agent, .general, &new_tools, &session);

    // The prompt is the current one: billy's own text with the project's
    // instructions after it, and none of the old prompt left.
    const prompt_text = session.systemPrompt().?;
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, Mode.general.prompt()) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, "PROJECT RULES") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, "OLD PROMPT") == null);

    // The tools are the current set, replacing the one the session started with.
    var tools: std.Io.Writer.Allocating = .init(gpa);
    defer tools.deinit();
    try std.json.Stringify.value(session.toolSet(), .{}, &tools.writer);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"old\"") == null);

    // The refreshed session is written out, so a resume carries the current lead.
    var resumed = try Session.open(io, tmp.dir, gpa, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings(prompt_text, resumed.systemPrompt().?);
    try std.testing.expectEqual(2, resumed.tools.len);
}

test "prepare gives a fresh session the user's instructions from the configuration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The configuration directory holds the user's file; the session works
    // elsewhere, so the instructions can only have come from the configuration.
    var config_dir = std.testing.tmpDir(.{});
    defer config_dir.cleanup();
    try config_dir.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "USER RULES" });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var config = testConfig("m", "/work", null);
    config.user_instructions_dir = config_dir.dir;
    // `Agent.init` opens the directory it works in, so it has to be one that
    // exists; the session's recorded directory is separate.
    var agent = try testAgent(io, gpa, config, null);
    defer agent.deinit();

    try agent.prepare(&session);

    // The prompt the session runs with carries the user's instructions, so the
    // configuration directory is read for every session and not only a project.
    try std.testing.expect(std.mem.indexOf(u8, session.systemPrompt().?, Mode.general.prompt()) != null);
    try std.testing.expect(std.mem.indexOf(u8, session.systemPrompt().?, "USER RULES") != null);
}

test "prepare gives a chat session no prompt and only the tools it allows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A configuration directory with instructions, to check chat mode reads none:
    // they say how to change code, which chat mode does not do.
    var config_dir = std.testing.tmpDir(.{});
    defer config_dir.cleanup();
    try config_dir.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "USER RULES" });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var config = testConfig("m", "/work", null);
    config.mode = .chat;
    config.user_instructions_dir = config_dir.dir;
    var agent = try testAgent(io, gpa, config, null);
    defer agent.deinit();

    try agent.prepare(&session);

    // The mode is recorded, no system prompt is set at all (a chat request is the
    // conversation alone, so the instructions never reach it), and the tools
    // stored are the ones chat allows.
    try std.testing.expectEqual(Mode.chat, session.mode);
    try std.testing.expect(!session.hasSystemPrompt());

    const defs = agent.tool_set.definitions(.chat);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("read", defs[0].name);
    try std.testing.expectEqual(defs.len, session.tools.len);
}

test "a first prompt names the mode and says what to ask" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A prompt that names no mode runs in the one the frontend asked for, and is
    // asked as it was typed.
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    var agent = try testAgent(io, gpa, testConfig("m", "/work", null), null);
    defer agent.deinit();

    const plain = try agent.start(&session, "do the thing", .general);
    try std.testing.expectEqualStrings("do the thing", plain.prompt);
    try std.testing.expectEqual(Mode.general, agent.config.mode);
    // The session was prepared, so it now carries the tools it will offer.
    try std.testing.expect(session.tools.len > 0);

    // A first prompt may name the mode itself, which wins over what the frontend
    // asked for, and the rest of the line is what is asked.
    var named = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer named.deinit();
    const chat = try agent.start(&named, "/chat what is a hash map?", .general);
    try std.testing.expectEqualStrings("what is a hash map?", chat.prompt);
    try std.testing.expectEqual(Mode.chat, agent.config.mode);
    try std.testing.expectEqual(Mode.chat, named.mode);
}

test "a first prompt that names only a mode asks nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    var agent = try testAgent(io, gpa, testConfig("m", "/work", null), null);
    defer agent.deinit();

    // `/chat` on its own opens that mode: the session is set up and ready, and
    // there is nothing to send to the model yet.
    const started = try agent.start(&session, "/chat", .general);
    try std.testing.expectEqual(Started.mode_only, started);
    try std.testing.expectEqual(Mode.chat, session.mode);
    // Set up anyway, so the next prompt is asked without being looked at again.
    try std.testing.expect(session.tools.len > 0);
}

test "a prompt after the first leaves the session as it was set up" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    var agent = try testAgent(io, gpa, testConfig("m", "/work", null), null);
    defer agent.deinit();

    _ = try agent.start(&session, "the first thing", .general);
    try session.append(.{ .role = .assistant, .content = "done" });

    // A session that has been asked something is not started again: its mode is
    // the one it was saved with, and a mode command in a later prompt is part of
    // what is asked rather than a command, since only the first prompt can name
    // one.
    const later = try agent.start(&session, "/chat is this a command?", .general);
    try std.testing.expectEqual(Started.asked_before, later);
}

test "the terminal shows a tool call the way a replay does" {
    const gpa = std.testing.allocator;
    // The parsed call's text is left in an allocator the caller drops in one go
    // (`Tools.parse`), so it gets an arena of its own; everything else is built
    // with the testing allocator, which reports anything not freed.
    var call_state = std.heap.ArenaAllocator.init(gpa);
    defer call_state.deinit();

    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var tool_set = try Tools.init(.{
        .io = std.testing.io,
        .dir = std.Io.Dir.cwd(),
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

    const parsed = Tools.parse(call_state.allocator(), call);
    try emitter.show(.{ .tool_begin = parsed });
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    try tool_set.run(parsed, &result.writer);
    try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });

    // A replay renders the stored call on its own.
    var replayed: std.Io.Writer.Allocating = .init(gpa);
    defer replayed.deinit();
    try Tools.describe(gpa, parsed, result.written(), .{}, .plain, &replayed.writer);

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
    gpa: std.mem.Allocator,
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
            .tool_begin => |call| .{ .tool_begin = try self.keeper(Tools.callName(call)) },
            .tool_end => |tool| .{ .tool_end = .{
                .name = try self.keeper(Tools.callName(tool.call)),
                .result = try self.keeper(tool.result),
            } },
            .compacted => |compaction| .{ .compacted = .{
                .prompt = try self.keeper(compaction.prompt),
                .summary = try self.keeper(compaction.summary),
            } },
            .notice => |text| .{ .notice = try self.keeper(text) },
            .elided => |count| .{ .elided = count },
        };
        try self.seen.append(self.gpa, seen);
    }

    /// A copy of `text` in the recorder's gpa, so what it records lasts as long
    /// as the recorder rather than as long as the block.
    fn keeper(self: *Recorder, text: []const u8) ![]const u8 {
        return self.gpa.dupe(u8, text);
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
    try session.setSystemPrompt("be terse");

    // The first request is answered with a tool call; once the result is in the
    // conversation, the next is answered with text.
    const answering = struct {
        fn answer(_: usize, body: []const u8) Mock.Answer {
            if (std.mem.indexOf(u8, body, "\"tool\"") != null) {
                return .{ .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"all done\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}" };
            }
            return .{ .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\"," ++
                "\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":" ++
                "\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]," ++
                "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}" };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 2, answering);
    defer mock.deinit();
    try mock.serve();

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var config = testConfig("m", "/work", null);
    config.url = mock.url;
    config.api_key = "k";
    var agent = try testAgent(io, gpa, config, &http);
    defer agent.deinit();

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    try turn(&agent, recorder.emitter(), &session);

    try mock.group.await(io);
    if (mock.err) |err| return err;

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

test "the first turn names the session, and the naming is not part of it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");

    // The turn is answered with text, and the request that asks for a title --
    // the one whose body carries the titling prompt -- with a title.
    const answering = struct {
        fn answer(_: usize, body: []const u8) Mock.Answer {
            if (std.mem.indexOf(u8, body, "short title") != null) {
                return .{ .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Fix the flaky test\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}" };
            }
            return .{ .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"all done\"}}]," ++
                "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}" };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 2, answering);
    defer mock.deinit();
    try mock.serve();

    var config = testConfig("m", "/work", null);
    config.title = true;
    // The agent builds the model client from the config, so the config carries
    // the address of the mock.
    config.url = mock.url;
    // `Agent.init` opens the directory it works in, so it has to be one that
    // exists; the session's recorded directory is separate and stays "/work".
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var agent = try testAgent(io, gpa, config, &http);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try agent.ask(terminal.emitter(), &session, "the flaky test keeps failing, please fix it");

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The model's title is kept, and the session was saved with it.
    try std.testing.expectEqualStrings("Fix the flaky test", session.title().?);
    var resumed = try Session.open(io, tmp.dir, gpa, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("Fix the flaky test", resumed.title().?);

    // The request that asked for the title is not part of the conversation, and
    // neither is its answer: the session holds the prompt and the reply alone.
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.roleOf(session.messages.items[0]));
    try std.testing.expectEqualStrings("assistant", session.roleOf(session.messages.items[1]));
    for (session.messages.items) |message| {
        const text = session.contentOf(message) orelse "";
        try std.testing.expect(std.mem.indexOf(u8, text, "short title") == null);
    }
}

test "a title is cut to one clean line, or dropped when there is none" {
    const gpa = std.testing.allocator;

    // The first line is all that is kept, trimmed, with the quotes or backticks
    // a model wrapped it in taken off. Each result is `gpa`'s, so it is freed.
    try expectCleanTitle(gpa, "Fix the parser", "Fix the parser\nand more");
    try expectCleanTitle(gpa, "Fix it", "  \"Fix it\"  ");
    try expectCleanTitle(gpa, "Fix it", "`Fix it`");
    try expectCleanTitle(gpa, "just one line", "just one line\nextra");

    // Nothing usable is no title, so the provisional one stands.
    try std.testing.expect((try cleanTitle(gpa, "")) == null);
    try std.testing.expect((try cleanTitle(gpa, "   \n  ")) == null);

    // A long title is kept whole: there is no limit.
    const too_long: [200]u8 = @splat('x');
    const long = (try cleanTitle(gpa, &too_long)).?;
    defer gpa.free(long);
    try std.testing.expectEqual(@as(usize, 200), long.len);

    // A provisional title is the first line of what was asked, trimmed.
    try std.testing.expectEqualStrings(
        "add a title to sessions",
        provisionalTitle("add a title to sessions\nand lots of detail follows"),
    );
    try std.testing.expectEqualStrings("short", provisionalTitle("   short   "));
}

/// Checks what `cleanTitle` makes of `raw`, freeing what it allocates.
fn expectCleanTitle(gpa: std.mem.Allocator, expected: []const u8, raw: []const u8) !void {
    const title = (try cleanTitle(gpa, raw)).?;
    defer gpa.free(title);
    try std.testing.expectEqualStrings(expected, title);
}
