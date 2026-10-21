//! The agent loop: read a request from the user, ask the model, run the tools
//! it asks for, and repeat until it answers with text.
const std = @import("std");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Endpoint = @import("Endpoint.zig");
const llm = @import("llm.zig");
const Tools = @import("Tools.zig");
const Mock = @import("Mock.zig");
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

/// Where a request is sent, and how it is asked. Resolved from the session's own
/// model just before each turn, so a session moved to another model is sent
/// there, and asked that provider's way, from the next turn on.
const Target = Endpoint.Target;

/// What a run is given, in one value: what each turn's target is resolved from,
/// how its agent behaves on it, what its tools run with, how its blocks are
/// shown, the mode it starts in, and the home directory and instructions the run
/// reads outside the session. Each part is resolved by the frontend, from the
/// configuration, the credentials and the environment, so the agent is handed the
/// run rather than the file it came from.
pub const Options = struct {
    /// The configuration a session's model is resolved with, and the keys stored
    /// for the providers it names. Borrowed from the frontend, which owns both and
    /// outlives the run: resolving a target needs nothing else.
    config: *const Config,
    store: *const Credentials,
    behaviour: Behaviour,
    tools: Tools.Settings,
    /// How the run's blocks are shown: the formatter scripts and the terminal's
    /// style. A page lays its own blocks out, so it sets this plainly.
    display: Terminal.Display = .{},
    /// The mode the run starts in, which is the frontend's choice until the
    /// session's first prompt settles it.
    mode: Mode = .general,
    /// Home directory, so the header can shorten a path inside it; null when unset.
    home: ?[]const u8 = null,
    /// Directory holding the user's own instructions file, read into every
    /// session's prompt ahead of the project's; null in a test, or when there is
    /// no such file. Borrowed from the frontend, which owns it and outlives the
    /// agent, so nothing here closes it.
    instructions: ?std.Io.Dir = null,
};

/// How the agent behaves on a session: how many turns it gives the model before
/// giving up, how full the window may get before the conversation is folded into
/// a summary, and whether it asks the model for a name for the session.
pub const Behaviour = struct {
    /// Model turns allowed for one request before the harness gives up on it.
    max_turns: usize,
    /// How full the context window must be, as a whole percentage, before the
    /// conversation is compacted into a summary. Zero turns compaction off.
    /// Nothing is compacted for a model whose window is unknown, since there is
    /// then no threshold to measure the conversation against. The value mirrors
    /// the configuration's, so a test can leave it out.
    compact_at: usize = 80,
    /// Whether the model is asked for a short title for a session, after its
    /// first turn, so a frontend can list it by name. Mirrors the configuration.
    title: bool = true,
};

/// One unit of what a run shows: the pieces a conversation is made of, in the
/// order they happened. A block is what the run says happened; how it looks is
/// the frontend's, so nothing here is text.
///
/// A tool call is two blocks, the call as it begins and the call with its result
/// as it ends, so a frontend can show a slow command while it runs. A frontend
/// that shows only finished work ignores the first.
///
/// A reply's text also arrives in fragments through `Emitter.delta` while it is
/// written, before the `answer` block that carries the whole of it.
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

/// A fragment of an answer as the model writes it, on its way to the `answer`
/// block that carries the whole of it. A frontend that streams shows the
/// fragments as they arrive; one that shows a reply whole ignores them and shows
/// the block.
pub const Delta = struct {
    /// More of the reply's text.
    content: ?[]const u8 = null,
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
        /// Shows a fragment of the answer as the model writes it. Optional: a
        /// frontend that shows only whole blocks leaves it null, and the
        /// `answer` block that follows carries the whole reply.
        delta: ?*const fn (context: *anyopaque, delta: Delta) anyerror!void = null,
    };

    /// Shows one block.
    pub fn show(emitter: Emitter, block: Block) !void {
        return emitter.vtable.block(emitter.context, block);
    }

    /// Shows one fragment of the answer. A frontend with no delta handler drops
    /// it, since the whole answer follows as a block.
    pub fn showDelta(emitter: Emitter, delta: Delta) !void {
        if (emitter.vtable.delta) |show_delta| return show_delta(emitter.context, delta);
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

/// The line shown above the input prompt: the mode, the session id, the model,
/// the working directory, and how much of the context window the conversation
/// fills. Its fields are the values printed, so printing it needs nothing of the
/// configuration. The id is shown so that a run can be named by what it prints,
/// which is what `--resume` takes to continue it; the window size is not reported
/// by the API, so it comes from the model table.
pub const SessionHeader = struct {
    mode: Mode,
    id: []const u8,
    /// The provider and model the session runs, as `<provider>/<model>`: the
    /// choice it recorded, which is what a request names and a page shows.
    model: []const u8,
    /// The directory the session works in, shortened to `~` when it is inside
    /// `home`.
    cwd: []const u8,
    /// The home directory a path is shortened against; null when unset.
    home: ?[]const u8 = null,
    /// Tokens in the conversation as of the last request.
    context_tokens: usize = 0,
    /// The model's context window, or null for a model billy knows nothing of,
    /// which has no gauge.
    context_window: ?usize = null,

    /// The header for `session`: what it holds -- its mode, id, directory and
    /// size -- with the model it goes to and the window of that model, and the
    /// `home` a path is shortened against, which the session keeps none of.
    pub fn of(session: *const Session, model: Endpoint.Model, home: ?[]const u8) SessionHeader {
        return .{
            .mode = session.mode,
            .id = session.id(),
            .model = model.choice,
            .cwd = session.cwd(),
            .home = home,
            .context_tokens = session.context_tokens,
            .context_window = if (model.info) |info| info.context_window else null,
        };
    }

    /// Writes the header line to `out`. It is a `{f}` format function, so a
    /// caller writes it with `out.print("{f}", .{header})`. Nothing is allocated;
    /// the caller holds the buffer, which it already has for the line editor.
    pub fn format(self: SessionHeader, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("billy · {s} · {s} · {s} · ", .{ @tagName(self.mode), self.id, self.model });
        try displayPath(out, self.cwd, self.home);
        if (self.context_window) |window| {
            try out.writeAll(" · ");
            try formatTokens(out, self.context_tokens);
            try out.writeAll("/");
            try formatTokens(out, window);
            try out.writeAll(" (");
            try formatPercent(out, self.context_tokens, window);
            try out.writeAll(")");
        }
    }
};

/// Writes a token count in a short form, such as `16k` or `128k`, with no
/// decimals. Shared with the web header, so both show a count the same way.
pub fn formatTokens(out: *std.Io.Writer, count: usize) !void {
    if (count < 1000) return out.print("{d}", .{count});
    // Rounds up to 1000k from here, which reads better as 1M.
    if (count < 999_500) return formatScaled(out, count, 1000, 'k');
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

/// A session being asked things: the model client and the tools it runs with.
/// Both frontends build it here so neither can drift from the other. The HTTP
/// client is the run's own, so every request shares its connections.
io: std.Io,
gpa: std.mem.Allocator,
/// How the agent behaves on the session, which is the configuration's say.
behaviour: Behaviour,
/// What a turn's target is resolved from: the providers the configuration names
/// and the keys stored for them. Borrowed, and read before every turn.
config: *const Config,
store: *const Credentials,
/// The HTTP client every request of the run is sent over, borrowed from the
/// frontend that owns it, so connections and certificates are shared.
http: *std.http.Client,
/// Owns what the target of the current turn names -- the URL and model id of the
/// endpoint it is sent to -- and is emptied when the next turn is resolved.
target_state: std.heap.ArenaAllocator,
/// Directory holding the user's own instructions file, read into every prompt
/// ahead of the project's; null when there is no such file. Borrowed from the
/// frontend, which owns it and outlives the agent.
instructions: ?std.Io.Dir = null,
/// What the session may do and what its prompt says, which is the frontend's
/// choice until the session's first prompt settles it and the session's own
/// from then on. See `mode.zig`.
mode: Mode = .general,
/// The directory the session works in. For a resumed session it is the one the
/// session was started in.
work_dir: std.Io.Dir,
/// The tools, working in `work_dir`.
tool_set: Tools,

/// Opens a session for asking things from `options`, working in `cwd` and
/// sharing `http_client`.
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    cwd: []const u8,
    http_client: *std.http.Client,
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
        .http = http_client,
        .settings = options.tools,
    });

    return .{
        .io = io,
        .gpa = gpa,
        .behaviour = options.behaviour,
        .config = options.config,
        .store = options.store,
        .http = http_client,
        .target_state = std.heap.ArenaAllocator.init(gpa),
        .instructions = options.instructions,
        .mode = options.mode,
        .work_dir = work_dir,
        .tool_set = tool_set,
    };
}

pub fn deinit(agent: *Agent) void {
    agent.target_state.deinit();
    agent.work_dir.close(agent.io);
}

/// Gives `session` the system prompt and tools it runs with, if it has none.
///
/// Both are stored with the session and reused on a resume, so the request
/// matches the earlier run byte for byte and hits the prompt cache. The user's
/// instructions come from the configuration directory and the project's from the
/// session's directory.
pub fn prepare(agent: *Agent, session: *Session) !void {
    // A session with a conversation keeps the mode and prompt it was saved with;
    // a new one takes the mode the frontend chose. Either way the agent's mode
    // ends up the session's own.
    if (session.messages.items.len > 0) {
        agent.mode = session.mode;
    } else {
        session.setMode(agent.mode);
        const prompt_text = try leadPrompt(
            agent.io,
            agent.gpa,
            agent.work_dir,
            agent.instructions,
            agent.mode,
        );
        defer agent.gpa.free(prompt_text);
        // A mode with no prompt sends no system message.
        if (prompt_text.len > 0) try session.setSystemPrompt(prompt_text);
    }
    try session.ensureTools(agent.tool_set.definitions(agent.mode));
}

/// Where `session` is sent right now, resolved from the model it records at this
/// moment: a turn is sent to the provider that model names, so a session moved to
/// another model is sent there from the next turn on, with nothing else told.
///
/// A session that recorded no model yet is given the configured choice, and keeps
/// it: where it was being sent anyway is where it goes from here on.
///
/// What the target names is owned by the agent and replaced when the next turn is
/// resolved, so it must be used, and no more than one turn at a time may hold on
/// to one.
fn targetFor(agent: *Agent, session: *Session) !Target {
    _ = agent.target_state.reset(.retain_capacity);
    const choice = session.modelChoice(agent.config.stored.model);
    if (session.model() == null) try session.setModel(choice);
    return Endpoint.targetFor(agent.config, agent.store, agent.target_state.allocator(), choice);
}

/// The client one turn is sent with, built from where the session's model points
/// now. A client is made per turn rather than kept, so that a model changed
/// between turns is picked up by the next one without anything being updated.
fn clientFor(agent: *Agent, session: *Session) !llm.Client {
    const target = try agent.targetFor(session);
    return .{
        .gpa = agent.gpa,
        .io = agent.io,
        .api_key = target.api_key,
        .url = target.url,
        .model = target.model,
        .http = agent.http,
    };
}

/// The model `session` goes to, as a header shows it: the choice it recorded, or
/// the configured one for a session that recorded none.
fn sessionModel(agent: *const Agent, session: *const Session) Endpoint.Model {
    return Endpoint.modelOf(session.modelChoice(agent.config.stored.model));
}

/// What asking `agent` to start a session with a first prompt came to.
pub const Started = union(enum) {
    /// What to ask: the prompt with any mode command taken off.
    prompt: []const u8,
    /// The prompt named only a mode, so the session is set up for it and waits.
    mode_only,
    /// The session has been asked before, so it keeps the mode it was saved with.
    asked_before,
};

/// What a line typed into a session came to.
pub const Waiting = union(enum) {
    /// The line is asked of the model, with any mode command taken off.
    ask: []const u8,
    /// The line named only a mode, so the session is set up and nothing is asked.
    ready,
    /// The line was a command, already run; what it had to say went out through
    /// the emitter.
    ran,
};

/// Takes a line typed into `session` and does what it asks for, except asking the
/// model, which is left to `ask`. A frontend need know nothing more of a line:
/// commands, the first-prompt rules and compaction are all handled here.
pub fn take(agent: *Agent, emitter: Emitter, session: *Session, line: []const u8) !Waiting {
    // Compaction is a request of its own, made before the prompt is added, so the
    // client for the model the session records now is made before the line is
    // looked at.
    var client = try agent.clientFor(session);

    // A command is run rather than asked.
    if (Command.of(line)) |cmd| {
        switch (cmd) {
            .compact => {
                if (agent.compact(emitter, session, &client, .now) != .done)
                    try emitter.show(.{ .notice = "nothing to compact" });
            },
        }
        return .ran;
    }

    // Before the prompt is added, so the prompt is not folded into the summary
    // it triggers.
    _ = agent.compact(emitter, session, &client, .when_needed);

    const started = try agent.start(session, line);
    return switch (started) {
        .prompt => |text| .{ .ask = text },
        .mode_only => .ready,
        .asked_before => .{ .ask = line },
    };
}

/// Settles the mode from a session's first prompt and gives a new session its
/// system prompt and tools. This is the one place the first-prompt rules live:
/// `/chat` and `/general` name the mode and the rest of the line is asked; a
/// prompt naming only a mode asks nothing; anything else keeps the mode the run
/// is in, which is the frontend's choice until now (see `Mode.start`). A session
/// asked before keeps what it was saved with.
pub fn start(agent: *Agent, session: *Session, text: []const u8) !Started {
    if (session.messages.items.len > 0) return .asked_before;

    const choice = Mode.start(text, agent.mode);
    agent.mode = choice.mode;
    try agent.prepare(session);
    if (choice.text.len == 0) return .mode_only;
    return .{ .prompt = choice.text };
}

/// How a compaction went.
const Compaction = enum { done, nothing, failed };

/// Compacts the conversation, and refreshes the prompt and tools when it did.
/// `.when_needed` waits for the context to pass the threshold, so a long session
/// goes on rather than failing on an overlong request; `.now` is for `/compact`. A
/// failure is logged and the request goes out with the conversation as it is.
fn compact(
    agent: *Agent,
    emitter: Emitter,
    session: *Session,
    client: *llm.Client,
    when: enum { when_needed, now },
) Compaction {
    const compacted = (switch (when) {
        .when_needed => agent.maybeCompact(emitter, session, client),
        .now => agent.fold(emitter, session, client),
    }) catch |err| {
        std.log.warn("compaction failed: {s}", .{@errorName(err)});
        return .failed;
    };
    if (!compacted) return .nothing;
    agent.refresh(session);
    return .done;
}

/// Re-reads the prompt and tools into the session, so one that has been running
/// a while picks up a changed prompt, instruction file or tool set. Done at a
/// compaction, the one moment replacing the front of a request costs no cache
/// that was not already being thrown away. A failure is logged and the session
/// keeps what it had.
fn refresh(agent: *Agent, session: *Session) void {
    const mode = agent.mode;
    refreshLead(agent, mode, agent.tool_set.definitions(mode), session) catch |err|
        std.log.warn("could not refresh the prompt and tools: {s}", .{@errorName(err)});
}

/// Asks `session` one thing and shows how the answer is reached: the prompt, the
/// tool calls it makes, and the reply. This is what one prompt of a
/// conversation comes to, and the same in either frontend.
///
/// A turn that fails is reported through `emitter` as a notice rather than
/// returned: a request that did not go through leaves the conversation as it was
/// and is the user's to try again, which a frontend shows and the run carries
/// on from. Only a failure of the emitter itself, which is the frontend going
/// away, is passed on to the caller.
pub fn ask(agent: *Agent, emitter: Emitter, session: *Session, text: []const u8) !void {
    // The client this turn is sent with is made here, from the model the session
    // records now, so the model it goes to is recorded before the prompt is
    // appended: the message and the provider it went to are written together.
    var client = try agent.clientFor(session);

    // The system prompt is kept apart from the conversation, so the first turn is
    // the session's first message.
    const first_turn = session.messages.items.len == 0;
    _ = try nameFromPrompt(session, text);

    try session.append(.{ .role = .user, .content = text });
    try emitter.show(.{ .prompt = text });

    // A turn that failed is shown where the answer would have been, so the loss
    // is visible in the conversation rather than only in a log. The turn is
    // given up rather than retried: what went wrong is the provider's or the
    // network's, and asking again is the user's decision.
    turn(agent, emitter, session, &client) catch |err| {
        std.log.err("a request failed: {s}", .{@errorName(err)});
        var notice: [256]u8 = undefined;
        return emitter.show(.{ .notice = failureNotice(&notice, err) });
    };

    if (first_turn and agent.behaviour.title) {
        titleSession(agent, session, &client) catch |err|
            std.log.warn("could not title the session: {s}", .{@errorName(err)});
    }
}

/// What a failed turn is reported as, written into `buffer`: the reason the
/// request did not go through, so the user can tell a dropped connection from a
/// provider that refused, and knows the turn is theirs to ask again.
///
/// The buffer is the caller's, since the notice is shown as it is written and
/// nothing keeps it: an allocation here would have to be freed after a call that
/// cannot fail without losing the word the user needs.
fn failureNotice(buffer: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(buffer, "the request failed: {s} — nothing was sent, try again", .{@errorName(err)}) catch
        "the request failed — nothing was sent, try again";
}

/// Runs one session on the terminal, from `options`, until the input ends: each
/// line is taken as the agent decides what it is, and the blocks of the answer
/// are shown as they happen. Each turn is sent where the session's model points
/// when it begins, which is resolved again for every one of them.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    options: Options,
    session: *Session,
) !void {
    // One HTTP client for the run, shared by the model requests and the search
    // backend, so both reuse its connections and share the certificates it scans
    // once. Every session asked in this run borrows it.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var agent = try Agent.init(io, gpa, options, session.cwd(), &http_client);
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
    var terminal = Terminal{ .out = out, .io = io, .display = options.display, .scratch = gpa };
    const emitter = terminal.emitter();

    // The header is rebuilt for every prompt, so it reflects the context size
    // after the turns run so far. One buffer holds it for the whole loop; each pass
    // clears it and writes the header into it.
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    while (true) {
        header.clearRetainingCapacity();
        // The header is built each pass, so it shows the session as it stands: the
        // mode the first prompt may have set, the model it recorded, and the
        // directory, which is read from the session since its pool has grown with
        // the turn and moved every string taken from it before. The gauge is the
        // window of the model the session goes to now, so a model changed since
        // the last turn reads right at once.
        try header.writer.print("{f}", .{SessionHeader.of(
            session,
            agent.sessionModel(session),
            options.home,
        )});
        const line = (try editor.readLine(header.written(), prompt)) orelse break;
        if (line.len == 0) continue;
        // What the line came to is the agent's to decide: a command is run and
        // reported through the emitter, a first prompt settles the mode, and
        // anything else is what is asked.
        const waiting = try agent.take(emitter, session, line);
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
        // A request that failed has been reported through the emitter by `ask`,
        // and the session carries on: a dropped connection is not the end of the
        // conversation. Only a failure of the emitter itself, which is this
        // terminal going away, reaches here.
        agent.ask(emitter, session, text) catch |err|
            std.log.err("could not show the turn: {s}", .{@errorName(err)});
        try out.flush();
    }
    try out.flush();
}

/// Replays a stored conversation on the terminal as the blocks it was made of,
/// so remembering the context of an earlier run is not left to the user. The
/// blocks come from `walk`, and each is shown as the run showed it, so a
/// replayed prompt reads as the one that was typed.
pub fn printTranscript(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    session: *const Session,
    display: Terminal.Display,
    blocks: usize,
) !void {
    // A replay is what the terminal is shown when a session is picked up again,
    // and it goes through the same emitter a live run does, so a prompt reads
    // the same whether it was just typed or stored.
    var terminal = Terminal{ .out = out, .io = io, .display = display, .scratch = gpa };
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

    if (message.role == .user) {
        return emitter.show(.{ .prompt = session.contentOf(message) orelse "" });
    }
    if (message.role != .assistant) return;

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
    const message = messages[index];
    if (message.role == .user) return 1;
    if (message.role != .assistant) return 0;
    const calls = message.tool_calls.len;
    return if (calls == 0) 1 else calls;
}

/// Shows the text of a streamed delta to the frontend. Tool call pieces are not
/// shown: a call is shown whole when it has been parsed, just before it runs.
fn showDeltaText(emitter: Emitter, delta: llm.Delta) !void {
    if (delta.content) |text| try emitter.showDelta(.{ .content = text });
}

/// Runs the model until it replies with text instead of tool calls, showing what
/// happens as blocks as it goes.
fn turn(agent: *Agent, emitter: Emitter, session: *Session, client: *llm.Client) !void {
    // Holds the parsed call of each tool call the model asks for, which is read
    // until that call has been run and shown. Reset per call, so a turn that
    // makes many calls holds only the one it is on.
    var scratch_state = std.heap.ArenaAllocator.init(agent.tool_set.gpa);
    defer scratch_state.deinit();

    var remaining: usize = agent.behaviour.max_turns;
    // A compaction that failed is not tried again within the same turn, so a
    // provider that will not summarize cannot turn every request of a long turn
    // into a second failed one. The next turn tries afresh.
    var compact_failed = false;
    while (remaining > 0) : (remaining -= 1) {
        // A failure to compact is not the turn's, and is not retried within it.
        if (!compact_failed) compact_failed = agent.compact(emitter, session, client, .when_needed) == .failed;

        // The stream hands the reply over a delta at a time. It is added up here,
        // because the session keeps the whole message, and each delta is shown as
        // it arrives so a frontend that streams can show the answer while it is
        // written. Nothing of the conversation or the reply is copied on the way
        // to the wire: the request is written out of the session's pool.
        var stream = try client.complete(
            agent.gpa,
            session.id(),
            session.conversation(&.{}),
            session.toolSet(),
        );
        defer stream.deinit();

        var reply: llm.Reply = .{ .gpa = agent.gpa };
        defer reply.deinit();
        while (try stream.next()) |delta| {
            try reply.add(delta);
            try showDeltaText(emitter, delta);
        }

        // Recorded before the message is appended, so the save inside `append`
        // stores the size along with it.
        session.recordUsage(stream.usage());
        const message = try reply.message();
        try session.append(message);

        const calls = message.tool_calls orelse &.{};
        // No calls means the model answered, which ends the turn.
        if (calls.len == 0) return emitter.show(.{ .answer = message.content orelse "" });

        try runCalls(&agent.tool_set, emitter, &scratch_state, session, agent.mode, calls);
    }
    var buffer: [96]u8 = undefined;
    const stopped = std.fmt.bufPrint(
        &buffer,
        "stopped after {d} turns without a final answer",
        .{agent.behaviour.max_turns},
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
        agent.instructions,
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
fn titleSession(agent: *Agent, session: *Session, client: *llm.Client) !void {
    const raw = try agent.askWith(session, client, title_prompt) orelse return;
    defer agent.gpa.free(raw);
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
fn compactThreshold(agent: *const Agent, session: *const Session) usize {
    if (agent.behaviour.compact_at == 0) return 0;
    // The window is the one of the model the session goes to now, which is what
    // the next request will be measured against.
    const info = agent.sessionModel(session).info orelse return 0;
    return info.context_window * agent.behaviour.compact_at / 100;
}

/// Compacts the conversation into a summary when it has filled the context
/// window past the threshold, so that a long session goes on rather than failing
/// on the next request. Says whether it compacted.
///
/// This is the automatic compaction, which waits for the threshold; a caller
/// that wants the conversation folded now, whatever it has grown to, asks for
/// `compact` instead.
fn maybeCompact(agent: *Agent, emitter: Emitter, session: *Session, client: *llm.Client) !bool {
    // Nothing is compacted for a model whose window is unknown, since there is
    // then no threshold to measure the conversation against; and a conversation
    // that has not reached it is left alone for the next request to fold, if it
    // ever does.
    const threshold = agent.compactThreshold(session);
    if (threshold == 0 or session.context_tokens < threshold) return false;
    return agent.fold(emitter, session, client);
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
fn fold(agent: *Agent, emitter: Emitter, session: *Session, client: *llm.Client) !bool {
    // Nothing has been added since the last compaction, so there is nothing new
    // to fold in: compacting again would only summarize the summary, and would
    // do so on every request.
    const sent_from = session.sentFrom();
    if (session.messages.items.len - sent_from <= 1) return false;

    const summary = try agent.askWith(session, client, compact_prompt) orelse return false;
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

/// Asks the model `question` about the conversation: the conversation is sent as a
/// request would carry it, system prompt and tool calls and results included,
/// with `question` as one more message that is not kept in the session. Returns the
/// reply, owned by the caller, or null when it has no text. The context gauge is
/// not moved, since the conversation it was sent is not what the next request
/// carries.
fn askWith(agent: *Agent, session: *Session, client: *llm.Client, question: []const u8) !?[]u8 {
    const extra = [_]llm.Message{.{ .role = .user, .content = question }};
    var stream = try client.complete(
        agent.gpa,
        session.id(),
        session.conversation(&extra),
        session.toolSet(),
    );
    defer stream.deinit();

    var reply: llm.Reply = .{ .gpa = agent.gpa };
    defer reply.deinit();
    try reply.collect(stream);

    const content = reply.content.items;
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
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    for (messages) |message| try session.append(message);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // No bash format: what these cover is how a message is headed and laid out,
    // which the tool format does not touch. Zero shows the whole conversation.
    try printTranscript(io, gpa, &out.writer, &session, .{ .style = style }, 0);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "printTranscript shows only the last blocks and counts the rest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
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
    try printTranscript(io, gpa, &out.writer, &session, .{}, 2);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n\n" ++
            "▸ read b.zig\n▾ output\ncontents b\n\n" ++
            "◆ answer\ndone\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // A count larger than the conversation leaves nothing out, so nothing is
    // counted and the whole session shows.
    try printTranscript(io, gpa, &out.writer, &session, .{}, 10);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
    out.clearRetainingCapacity();

    // Zero shows the whole session too.
    try printTranscript(io, gpa, &out.writer, &session, .{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
}

test "printTranscript replays a conversation as the blocks it was made of" {
    // The system prompt is never shown while running, the tool result only as
    // the output of the call it belongs to.
    try expectTranscript(
        "» prompt\nhello\n\n" ++
            "▸ read a.zig\n▾ output\n1\tconst x = 1;\n\n" ++
            "◆ answer\ndone\n\n",
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
        "◆ answer\nhi\n\n",
        &.{.{ .role = .assistant, .content = "**hi**" }},
        .plain,
    );

    // An empty reply is said to be empty rather than shown blank.
    try expectTranscript(
        "◆ answer\n(empty reply)\n\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt from the session is headed and laid out like a reply" {
    // A prompt is markdown too, so it is laid out by the same renderer.
    try expectTranscript(
        "» prompt\nhi\n\n",
        &.{.{ .role = .user, .content = "**hi**" }},
        .plain,
    );
}

test "an empty reply is shown under its header, in place of the text" {
    try expectTranscript(
        "◆ answer\n(empty reply)\n\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt and a reply are headed alike, in the colours of the display" {
    // The user's block opens with the prompt mark and the reply with the answer
    // mark, each bold, and neither carries the `> ` the live input uses.
    try expectTranscript(
        "\x1b[34m»\x1b[0m \x1b[1mprompt\x1b[0m\nhello\n\n" ++
            "\x1b[32m◆\x1b[0m \x1b[1manswer\x1b[0m\nhi\n\n",
        &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi" },
        },
        .ansi,
    );
}

test "printTranscript shows a compaction as a single line" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
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
    try printTranscript(io, gpa, &out.writer, &session, .{}, 0);
    try std.testing.expectEqualStrings(
        "» prompt\none\n\n" ++
            "◆ answer\na1\n\n" ++
            "⊟ compacted\n\n" ++
            "» prompt\ntwo\n\n" ++
            "◆ answer\na2\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    // The pair counts as one block, so a trim that keeps the last three blocks
    // starts at the compaction and counts what came before it.
    try printTranscript(io, gpa, &out.writer, &session, .{}, 3);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n\n" ++
            "⊟ compacted\n\n" ++
            "» prompt\ntwo\n\n" ++
            "◆ answer\na2\n\n",
        out.written(),
    );
}

test "a compaction is headed by its own mark, and hides what it stands for" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("s");
    try session.append(.{ .role = .user, .content = "hi" });
    try session.appendCompaction("ASKEDFORTHEcompaction", "THESUMMARYTEXT");
    try session.append(.{ .role = .user, .content = "next" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try printTranscript(io, gpa, &out.writer, &session, .{ .style = .ansi }, 0);

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

/// An agent for a test, working in a directory that exists.
///
/// The HTTP client is borrowed by the agent and by the tools that make requests,
/// so a test that makes one passes the client it points at a mock; a test that
/// only drives the loop passes null, and the client it is given is never read.
/// That is what keeps the setup of an unused client out of every test: the field
/// is a pointer, so a null is only a null until a web tool is called.
fn testAgent(io: std.Io, gpa: std.mem.Allocator, setup: TestSetup, http_client: ?*std.http.Client) !Agent {
    const work_dir = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(work_dir);
    return testAgentIn(io, gpa, setup, work_dir, http_client);
}

/// An agent for a test working in `work_dir`, which is where the project's
/// instructions are looked for. A test that cares which directory that is names
/// one; the rest work in the directory the tests run from.
fn testAgentIn(
    io: std.Io,
    gpa: std.mem.Allocator,
    setup: TestSetup,
    work_dir: []const u8,
    http_client: ?*std.http.Client,
) !Agent {
    // A test that only drives the loop is given a client it never reads, which is
    // left undefined rather than built: nothing touches it unless a tool does.
    var unused: std.http.Client = undefined;
    return Agent.init(io, gpa, setup.options(), work_dir, http_client orelse &unused);
}

/// What a test builds an agent from: the configuration and the keys a turn's
/// target is resolved from, and the settings the run reads.
///
/// The configuration names two providers, `test` and `other`, and stores a key for
/// each. Both sit at a closed port until a test points one at the server it is
/// listening on, so a request that went somewhere a test did not mean it to fails
/// rather than passing. The configured model is `test/<model>`, which is where a
/// session that recorded none is sent.
///
/// The configuration and the keys live in the arena, so a copy of this value still
/// points at them: the run borrows them and outlives the value it was built from.
const TestSetup = struct {
    arena: std.heap.ArenaAllocator,
    config: *Config,
    store: *Credentials,
    /// The provider entries the configuration names, which a test points at its
    /// servers.
    entries: []Config.Providers.Entry,
    /// How the agent behaves, which a test sets only what it is about.
    behaviour: Behaviour = .{ .max_turns = 10 },
    tools: Tools.Settings = .{ .bash_timeout_s = 120 },
    /// The mode the run starts in, which is what a frontend passes before the
    /// session's first prompt settles it.
    mode: Mode = .general,
    home: ?[]const u8 = null,
    instructions: ?std.Io.Dir = null,

    /// A setup whose configured model is `test/<model>`, which is the one thing
    /// every test names, since it is what the session records and the header
    /// shows. A test that needs a gauge names a model billy knows.
    fn init(gpa: std.mem.Allocator, model: []const u8) !TestSetup {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const store = try arena.create(Credentials);
        store.* = .{};
        try store.put(arena, "test", "k");
        try store.put(arena, "other", "k");

        const config = try arena.create(Config);
        config.* = Config.init(gpa);
        errdefer config.deinit();
        config.stored.model = try std.fmt.allocPrint(arena, "test/{s}", .{model});
        // A closed port, so a request that went somewhere a test did not mean it
        // to fails rather than waiting for an answer that never comes.
        const entries = try arena.dupe(Config.Providers.Entry, &.{
            .{ .name = "test", .base_url = "http://127.0.0.1:1" },
            .{ .name = "other", .base_url = "http://127.0.0.1:1" },
        });
        config.stored.providers = .{ .entries = entries };

        return .{
            .arena = arena_state,
            .config = config,
            .store = store,
            .entries = entries,
        };
    }

    fn deinit(setup: *TestSetup) void {
        setup.config.deinit();
        setup.arena.deinit();
    }

    /// Points the provider `name` at `url`, which a test does once the server it
    /// listens on is up.
    fn pointAt(setup: *TestSetup, name: []const u8, url: []const u8) void {
        for (setup.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) entry.base_url = url;
        }
    }

    /// The run a test's agent is built from.
    fn options(setup: TestSetup) Options {
        return .{
            .config = setup.config,
            .store = setup.store,
            .behaviour = setup.behaviour,
            .tools = setup.tools,
            .mode = setup.mode,
            .home = setup.home,
            .instructions = setup.instructions,
        };
    }
};

/// A terminal a test can show blocks through and read back from `out`. The
/// returned value has to outlive the emitter taken from it, since the emitter
/// borrows it.
fn testTerminal(out: *std.Io.Writer, display: Terminal.Display) Terminal {
    return .{ .out = out, .io = std.testing.io, .display = display, .scratch = std.testing.allocator };
}

/// The id the header tests run under. A real one is a ULID, but the header only
/// prints it, so the same id serves every test.
const test_session_id = "01HF7YAT000000000000000000";

/// A header for a test: the id they all share, the given model and directory, the
/// mode they all run in, and nothing else, so a test sets only what it is about.
fn testHeader(model: []const u8, cwd: []const u8) SessionHeader {
    return .{ .mode = .general, .id = test_session_id, .model = model, .cwd = cwd };
}

/// Writes `header` and compares it to `expected`, so a header test reads as the
/// line it produces rather than as the buffer around it.
fn expectHeader(expected: []const u8, header: SessionHeader) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{header});
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Writes a token count and compares it to `expected`.
fn expectTokens(expected: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try formatTokens(&out.writer, count);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "header names the session, the model and the working directory" {
    try expectHeader(
        "billy · general · 01HF7YAT000000000000000000 · deepseek-flash · /work",
        testHeader("deepseek-flash", "/work"),
    );
}

test "header names the mode the session runs in" {
    var header = testHeader("m", "/work");
    header.mode = .chat;
    try expectHeader("billy · chat · 01HF7YAT000000000000000000 · m · /work", header);
}

test "header shortens a path inside the home directory" {
    var header = testHeader("m", "/home/user/repo/billy");
    header.home = "/home/user";
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · ~/repo/billy", header);

    // The home directory itself becomes just `~`.
    header.cwd = "/home/user";
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · ~", header);

    // A sibling that merely shares the prefix is left alone.
    header.cwd = "/home/user2";
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /home/user2", header);
}

test "header shows how full the context window is" {
    // A model with a small window, so the numbers are easy to read.
    var header = testHeader("m", "/work");
    header.context_window = 128_000;

    // A fresh session has used nothing.
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 0/128k (0%)", header);
    // A rounded-to-zero percentage still shows the conversation is not empty.
    header.context_tokens = 500;
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 500/128k (<1%)", header);
    header.context_tokens = 16_000;
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 16k/128k (12%)", header);
    // A full window, and a count that rounds to a whole thousand.
    header.context_tokens = 128_000;
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 128k/128k (100%)", header);
    header.context_tokens = 12_500;
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · m · /work · 13k/128k (9%)", header);
}

test "token counts are whole" {
    // A count is never shown with a decimal, so half a thousand rounds up.
    try expectTokens("0", 0);
    try expectTokens("999", 999);
    try expectTokens("1k", 1000);
    try expectTokens("13k", 12_500);
    try expectTokens("128k", 128_000);
    try expectTokens("1M", 1_000_000);
    try expectTokens("999k", 999_499);
    try expectTokens("1M", 999_500);
    try expectTokens("1M", 999_999);
}

test "header leaves out the gauge for an unknown model" {
    // No window is known, so the gauge is left off whatever the count.
    var header = testHeader("who-knows", "/work");
    header.context_tokens = 5000;
    try expectHeader("billy · general · 01HF7YAT000000000000000000 · who-knows · /work", header);
}

test "a header is built from a session" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    session.mode = .chat;
    session.context_tokens = 100;
    try session.setModel("deepseek/deepseek-flash");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const model: Endpoint.Model = .{
        .choice = "deepseek/deepseek-flash",
        .info = .{ .provider = .deepseek, .context_window = 128_000 },
    };
    try out.writer.print("{f}", .{SessionHeader.of(&session, model, null)});

    // The mode, the id, the model and the directory all come from the session; only
    // the window it is measured against is passed in, since that is the model
    // table's and not the session's. The model is the choice the session recorded,
    // provider and all, which is what a page shows too.
    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    try expected.writer.print(
        "billy · chat · {s} · deepseek/deepseek-flash · /work · 100/128k (<1%)",
        .{session.id()},
    );
    try std.testing.expectEqualStrings(expected.written(), out.written());
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
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "agents" });
    try tmp.dir.writeFile(io, .{ .sub_path = "CLAUDE.md", .data = "claude" });

    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\nagents",
        projectInstructions,
        tmp.dir,
    );

    // With no AGENTS.md the other name is read, so a project written for another
    // tool still works.
    try tmp.dir.deleteFile(io, "AGENTS.md");
    try expectInstructions(
        "\n\nThe project's instructions follow, read from CLAUDE.md.\n\nclaude",
        projectInstructions,
        tmp.dir,
    );
}

test "the instructions are found in a parent up to the repository root" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A repository root holding the instructions, and a subdirectory to run from.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "root rules" });
    try tmp.dir.createDirPath(io, "a/b");

    var deep = try tmp.dir.openDir(io, "a/b", .{});
    defer deep.close(io);
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
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "" });

    try expectNoInstructions(projectInstructions, tmp.dir);
}

test "the nearest instructions win over an ancestor's" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "outer" });
    try tmp.dir.createDirPath(io, "inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "inner/AGENTS.md", .data = "inner" });

    var inner = try tmp.dir.openDir(io, "inner", .{});
    defer inner.close(io);

    try expectInstructions(
        "\n\nThe project's instructions follow, read from AGENTS.md.\n\ninner",
        projectInstructions,
        inner,
    );
}

test "the user's instructions are read from the configuration directory" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "Be terse.\n" });

    // The heading names the user rather than the project, so the two sections of
    // a prompt read apart, and the file is carried through as it was written.
    try expectInstructions(
        "\n\nThe user's instructions follow, read from AGENTS.md.\n\nBe terse.\n",
        globalInstructions,
        tmp.dir,
    );
}

test "the user's instructions are read from the directory alone, not above it" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file above the directory handed in is not found: the configuration
    // directory is read on its own, with no project above it to walk up to.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "outer" });
    try tmp.dir.createDirPath(io, "nested");
    var nested = try tmp.dir.openDir(io, "nested", .{});
    defer nested.close(io);

    try expectNoInstructions(globalInstructions, nested);
}

test "a user's instructions file that is missing or empty is not used" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try expectNoInstructions(globalInstructions, tmp.dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "" });
    try expectNoInstructions(globalInstructions, tmp.dir);
}

test "a large instructions file is streamed whole" {
    const io = std.testing.io;
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
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = file_text.written() });

    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    try expected.writer.writeAll("\n\nThe project's instructions follow, read from AGENTS.md.\n\n");
    try expected.writer.writeAll(&long_text);
    try expected.writer.writeAll("\n");

    try expectInstructions(expected.written(), projectInstructions, tmp.dir);
}

test "the prompt is billy's own, the user's instructions, then the project's" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    // A model without a known window has nothing to measure a conversation
    // against, so there is no threshold even with compaction on.
    var unknown_setup = try TestSetup.init(gpa, "m");
    defer unknown_setup.deinit();
    var unknown = try testAgent(io, gpa, unknown_setup, null);
    defer unknown.deinit();
    try session.setModel("test/m");
    try std.testing.expectEqual(0, unknown.compactThreshold(&session));

    // A model billy knows is measured against the window it is sent with.
    var setup = try TestSetup.init(gpa, "deepseek-flash");
    defer setup.deinit();
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();
    try session.setModel("test/deepseek-flash");

    // The default is a share of the window, not the whole of it.
    try std.testing.expectEqual(800_000, agent.compactThreshold(&session));

    // Zero turns it off.
    agent.behaviour.compact_at = 0;
    try std.testing.expectEqual(0, agent.compactThreshold(&session));

    // Any share the file names, whether or not it divides the window evenly.
    agent.behaviour.compact_at = 50;
    try std.testing.expectEqual(500_000, agent.compactThreshold(&session));
    agent.behaviour.compact_at = 33;
    try std.testing.expectEqual(330_000, agent.compactThreshold(&session));
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

    var setup = try TestSetup.init(gpa, "deepseek-flash");
    defer setup.deinit();
    setup.behaviour.compact_at = 80;
    // A conversation that has filled the window past the threshold.
    session.context_tokens = 900_000;

    // A server standing in for the model, answering the compaction request with a
    // fixed summary and recording the body it was sent.
    var mock = try Mock.start("/chat/completions", 1, Mock.completion("the summary"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    setup.pointAt("test", mock.url);

    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    var client = try agent.clientFor(&session);
    try std.testing.expect(try agent.maybeCompact(terminal.emitter(), &session, &client));

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

    // The gauge the compaction request would set is dropped, since the
    // conversation it measured has just been replaced.
    try std.testing.expectEqual(0, session.context_tokens);

    // The user is told, in one line, that the conversation was compacted.
    try std.testing.expectEqualStrings("⊟ compacted\n\n", out.written());
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

    var setup = try TestSetup.init(gpa, "deepseek-flash");
    defer setup.deinit();

    // Nothing is listening on this address, so a request made where the function
    // should have returned first would fail the test rather than pass it.

    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    const emitter = terminal.emitter();
    var client = try agent.clientFor(&session);

    // Below the threshold.
    session.context_tokens = 100;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session, &client));
    // Turned off.
    session.context_tokens = 999_900;
    agent.behaviour.compact_at = 0;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session, &client));

    // A model with no known window has no threshold to measure against, which is
    // a run of its own: the window follows the model it is sent to.
    var unknown_setup = try TestSetup.init(gpa, "m");
    defer unknown_setup.deinit();
    var unknown = try testAgent(io, gpa, unknown_setup, null);
    defer unknown.deinit();
    session.context_tokens = 999_900;
    var unknown_client = try unknown.clientFor(&session);
    try std.testing.expect(!try unknown.maybeCompact(emitter, &session, &unknown_client));

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

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    // Compaction is off, so only a manual one runs.
    setup.behaviour.compact_at = 0;

    var mock = try Mock.start("/chat/completions", 1, Mock.completion("the summary"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    setup.pointAt("test", mock.url);

    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    // Asked for now, so the threshold and the setting are ignored: the
    // conversation is folded whatever size it has grown to.
    var client = try agent.clientFor(&session);
    try std.testing.expect(try agent.fold(terminal.emitter(), &session, &client));
    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The summary is folded in, and the pair reads as one line.
    try std.testing.expectEqual(4, session.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "compacted") != null);

    // Asking again does nothing: the summary is the last message, so there is
    // nothing new to fold in, and a request would only re-summarize it.
    out.clearRetainingCapacity();
    try std.testing.expect(!try agent.fold(terminal.emitter(), &session, &client));
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

    var setup = try TestSetup.init(gpa, "deepseek-flash");
    defer setup.deinit();

    // Over the threshold, but the last message is the summary itself, so there is
    // nothing new to fold in and a request would only re-summarize it.
    session.context_tokens = 900_000;
    // Nothing is listening there, so a request made where this should have
    // returned first would fail the test.
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    var client = try agent.clientFor(&session);
    try std.testing.expect(!try agent.maybeCompact(terminal.emitter(), &session, &client));

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
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgentIn(io, gpa, setup, work_dir, null);
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

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.instructions = config_dir.dir;
    // `Agent.init` opens the directory it works in, so it has to be one that
    // exists; the session's recorded directory is separate.
    var agent = try testAgent(io, gpa, setup, null);
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

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.mode = .chat;
    setup.instructions = config_dir.dir;
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    try agent.prepare(&session);

    // The mode is recorded, no system prompt is set at all (a chat request is the
    // conversation alone, so the instructions never reach it), and the tools
    // stored are the ones chat allows.
    try std.testing.expectEqual(Mode.chat, session.mode);
    try std.testing.expect(session.systemPrompt() == null);

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
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    const plain = try agent.start(&session, "do the thing");
    try std.testing.expectEqualStrings("do the thing", plain.prompt);
    try std.testing.expectEqual(Mode.general, agent.mode);
    // The session was prepared, so it now carries the tools it will offer.
    try std.testing.expect(session.tools.len > 0);

    // A first prompt may name the mode itself, which wins over what the frontend
    // asked for, and the rest of the line is what is asked.
    var named = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer named.deinit();
    const chat = try agent.start(&named, "/chat what is a hash map?");
    try std.testing.expectEqualStrings("what is a hash map?", chat.prompt);
    try std.testing.expectEqual(Mode.chat, agent.mode);
    try std.testing.expectEqual(Mode.chat, named.mode);
}

test "a first prompt that names only a mode asks nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    // `/chat` on its own opens that mode: the session is set up and ready, and
    // there is nothing to send to the model yet.
    const started = try agent.start(&session, "/chat");
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
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    _ = try agent.start(&session, "the first thing");
    try session.append(.{ .role = .assistant, .content = "done" });

    // A session that has been asked something is not started again: its mode is
    // the one it was saved with, and a mode command in a later prompt is part of
    // what is asked rather than a command, since only the first prompt can name
    // one.
    const later = try agent.start(&session, "/chat is this a command?");
    try std.testing.expectEqual(Started.asked_before, later);
}

test "the terminal shows a tool call the way a replay does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // The parsed call's text is left in an allocator the caller drops in one go
    // (`Tools.parse`), so it gets an arena of its own; everything else is built
    // with the testing allocator, which reports anything not freed.
    var call_state = std.heap.ArenaAllocator.init(gpa);
    defer call_state.deinit();

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
    try Terminal.tool.describe(io, gpa, parsed, result.written(), .{}, .plain, &replayed.writer);

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
    /// The answer's fragments as they arrived, kept apart from the blocks: a
    /// frontend that streams shows them, and the `answer` block still follows
    /// with the whole text.
    deltas: std.ArrayList(Fragment) = .empty,

    const Seen = union(enum) {
        prompt: []const u8,
        answer: []const u8,
        tool_begin: []const u8,
        tool_end: struct { name: []const u8, result: []const u8 },
        compacted: Block.Compacted,
        notice: []const u8,
        elided: usize,
    };

    const Fragment = struct { text: []const u8 };

    fn emitter(self: *Recorder) Emitter {
        return .{ .context = self, .vtable = &.{ .block = show, .delta = showDelta } };
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

    fn showDelta(context: *anyopaque, delta: Delta) anyerror!void {
        const self = selfOf(context);
        if (delta.content) |text| try self.deltas.append(self.gpa, .{
            .text = try self.keeper(text),
        });
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
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"content\":\"all \"}}]}\n\n" ++
                        "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
                        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
                    "\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":" ++
                    "\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]," ++
                    "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
            };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 2, answering);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.pointAt("test", mock.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    var client = try agent.clientFor(&session);
    try turn(&agent, recorder.emitter(), &session, &client);

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

    // The answer reached the frontend while it was still being written, as the
    // pieces the model sent, before the block that carries the whole of it.
    try std.testing.expectEqual(2, recorder.deltas.items.len);
    try std.testing.expectEqualStrings("all ", recorder.deltas.items[0].text);
    try std.testing.expectEqualStrings("done", recorder.deltas.items[1].text);

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
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"content\":\"Fix the flaky test\"}}]," ++
                        "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"content\":\"all done\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
            };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 2, answering);
    defer mock.deinit();
    try mock.serve();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.behaviour.title = true;
    // The session is sent where its model's provider points, which is the mock.
    setup.pointAt("test", mock.url);
    // `Agent.init` opens the directory it works in, so it has to be one that
    // exists; the session's recorded directory is separate and stays "/work".
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var agent = try testAgent(io, gpa, setup, &http_client);
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

test "a turn is sent to the model the session records when it begins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // One server per model, each answering once: a turn sent to the wrong one
    // fails the test rather than passing.
    var deepseek = try Mock.start("/chat/completions", 1, Mock.completion("from the deepseek model"));
    defer deepseek.deinit();
    try deepseek.serve();
    var opencode = try Mock.start("/chat/completions", 1, Mock.completion("from the opencode model"));
    defer opencode.deinit();
    try opencode.serve();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    // Naming the session is a request of its own, which is not what this is about.
    setup.behaviour.title = false;
    // Each provider of the configuration is pointed at a server of its own, so a
    // turn sent to the wrong one fails the test rather than passing.
    setup.pointAt("test", deepseek.url);
    setup.pointAt("other", opencode.url);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});

    // The session runs on one model, and the turn goes to that model's server.
    try session.setModel("test/deepseek/deepseek-flash");
    try agent.ask(terminal.emitter(), &session, "the first question");

    // The model is changed to one of another provider between turns, and the
    // next turn goes there, with nothing else told to the agent.
    try session.setModel("other/kimi-k2.7-code");
    try agent.ask(terminal.emitter(), &session, "the second question");

    try deepseek.group.await(io);
    if (deepseek.err) |err| return err;
    try opencode.group.await(io);
    if (opencode.err) |err| return err;

    // Each server answered exactly the turn meant for it: the change was picked
    // up at the turn after it was made.
    try std.testing.expectEqual(@as(usize, 1), deepseek.served);
    try std.testing.expectEqual(@as(usize, 1), opencode.served);
}

test "a session is sent where the choice it recorded points, not the configuration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The configuration names an endpoint nothing listens on, so a request that
    // went there would fail rather than quietly answering.
    var chosen = try Mock.start("/chat/completions", 1, Mock.completion("chosen"));
    defer chosen.deinit();
    try chosen.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    // Only the provider the session records is pointed at a server; the one the
    // configuration names is left at a closed port, so a turn that went there
    // would fail rather than answer. Naming the session is a request of its own,
    // which is not what this is about.
    setup.behaviour.title = false;
    setup.pointAt("other", chosen.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    // The session records a model of another provider, and the turn goes there.
    try session.setModel("other/kimi-k2.7-code");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(&out.writer, .{});
    try agent.ask(terminal.emitter(), &session, "a question");

    try chosen.group.await(io);
    if (chosen.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), chosen.served);
    // The model it was sent is the one the session recorded, not the configured
    // one, which names a model of the provider nothing is listening on.
    try std.testing.expect(std.mem.indexOf(u8, chosen.bodies.items[0], "\"model\":\"kimi-k2.7-code\"") != null);
}
