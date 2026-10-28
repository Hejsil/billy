//! The agent loop: ask the model, run the tools it asks for, and repeat until it answers with text.
const std = @import("std");

const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const endpoint = @import("endpoint.zig");
const llm = @import("llm.zig");
const Mock = @import("Mock.zig");
const models = @import("models.zig");
const report = @import("report.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const Tools = @import("Tools.zig");

const Agent = @This();

const Command = union(enum) {
    compact,
    model: ?[]const u8,
    cwd: ?[]const u8,

    pub fn of(text: []const u8) ?Command {
        const spaces = " \t\r\n";

        const line = std.mem.trim(u8, text, spaces);
        const typed = std.mem.cutPrefix(u8, line, "/") orelse return null;
        const split = std.mem.findAny(u8, typed, spaces) orelse typed.len;
        const name = typed[0..split];
        const argument = std.mem.trim(u8, typed[split..], spaces);

        const fields = @typeInfo(Command).@"union";
        inline for (fields.field_names, fields.field_types) |field_name, argument_type| {
            if (std.mem.eql(u8, name, field_name)) {
                return switch (argument_type) {
                    void => if (argument.len == 0) @unionInit(Command, field_name, {}) else null,
                    ?[]const u8 => @unionInit(Command, field_name, if (argument.len == 0) null else argument),
                    else => @compileError("a command takes no argument or one optional one"),
                };
            }
        }
        return null;
    }
};

const Target = endpoint.Target;

/// What a run is given, in one value: what each turn's target is resolved from, how its agent
/// behaves on it, what its tools run with, and the home directory and instructions the run reads
/// outside the session.
pub const Options = struct {
    config: *const Config,
    credentials: *const Credentials,
    catalog: *const models.Catalog,
    behaviour: Behaviour,
    tools: Tools.Settings,
    home: ?[]const u8 = null,
    instructions: ?std.Io.Dir = null,
};

/// How the agent behaves on a session: how many turns it gives the model before giving up, how full
/// the window may get before the conversation is compacted into a summary, and whether it asks the
/// model for a name for the session.
pub const Behaviour = struct {
    max_turns: usize,
    compact_at: usize = 80,
    title: bool = true,

    /// How a run's agent behaves: the turns it gives the model, the share of the window it fills
    /// before the conversation is compacted into a summary, and whether it names the session.
    pub fn fromConfig(config: *const Config) Behaviour {
        const stored = &config.stored;
        return .{
            .max_turns = stored.max_turns,
            .compact_at = stored.compact_at,
            .title = stored.title,
        };
    }
};

/// One unit of what a run shows: the pieces a conversation is made of, in the order they happened.
pub const Block = union(enum) {
    prompt: []const u8,
    answer: []const u8,
    tool_begin: Tools.Call,
    tool_end: Tool,
    compacted: Compacted,
    notice: []const u8,
    hidden: usize,

    pub const Tool = struct {
        call: Tools.Call,
        result: []const u8,
    };

    pub const Compacted = struct {
        prompt: []const u8,
        summary: []const u8,
    };
};

/// A fragment of an answer as the model writes it, on its way to the `answer` block that carries
/// the whole of it.
pub const Delta = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
};

pub const Emitter = struct {
    vtable: *const VTable,
    shown: usize = 0,

    pub const VTable = struct {
        block: *const fn (emitter: *Emitter, block: Block) anyerror!void,
        delta: ?*const fn (emitter: *Emitter, delta: Delta) anyerror!void = null,
    };

    pub fn show(emitter: *Emitter, block: Block) !void {
        try emitter.vtable.block(emitter, block);
        emitter.shown += 1;
    }

    pub fn showDelta(emitter: *Emitter, delta: Delta) !void {
        const show_delta = emitter.vtable.delta orelse return;
        try show_delta(emitter, delta);
        emitter.shown += 1;
    }
};

const instruction_files = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
const max_instructions_len = 1 << 20;

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

        // A file with no bytes is nothing to say, so the search carries on rather than putting a
        // blank heading in the prompt.
        const size = try file.length(io);
        if (size == 0) continue;

        try out.print("\n\n{s} instructions follow, read from {s}.\n\n", .{ what, name });
        var buffer: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buffer);
        try file_reader.interface.streamExact(out, @intCast(@min(size, max_instructions_len)));
        return true;
    }
    return false;
}

fn projectInstructions(io: std.Io, out: *std.Io.Writer, dir: std.Io.Dir) !bool {
    var current = dir;
    var owned = false;
    defer if (owned) current.close(io);

    while (true) {
        if (try instructionsIn(io, out, current, &instruction_files, "The project's"))
            return true;
        if (holds(io, current, ".git")) return false;

        // The parent is opened rather than derived from a path, so the walk keeps no path string
        // and follows the filesystem's own notion of a parent.
        const parent = current.openDir(io, "..", .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };
        if (sameDir(io, current, parent)) {
            parent.close(io);
            return false;
        }
        if (owned) current.close(io);
        current = parent;
        owned = true;
    }
}

fn globalInstructions(io: std.Io, out: *std.Io.Writer, dir: std.Io.Dir) !bool {
    return instructionsIn(io, out, dir, &instruction_files, "The user's");
}

fn holds(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

fn sameDir(io: std.Io, a: std.Io.Dir, b: std.Io.Dir) bool {
    const one = a.statFile(io, ".", .{}) catch return false;
    const two = b.statFile(io, ".", .{}) catch return false;
    return one.inode == two.inode;
}

/// The line shown above the input prompt: the session id, the model, the working directory, and how
/// much of the context window the conversation fills.
pub const SessionHeader = struct {
    id: []const u8,
    model: []const u8,
    cwd: []const u8,
    home: ?[]const u8 = null,
    context_tokens: usize = 0,
    context_window: ?usize = null,

    /// The header for `session`: what it holds -- its id, directory and size -- with the model it
    /// goes to and the window of that model, and the `home` a path is shortened against, which the
    /// session keeps none of.
    pub fn of(session: *const Session, model: endpoint.Model, home: ?[]const u8) SessionHeader {
        return .{
            .id = session.id(),
            .model = model.choice,
            .cwd = session.cwd(),
            .home = home,
            .context_tokens = session.context_tokens,
            .context_window = if (model.info) |info| info.context_window else null,
        };
    }

    pub fn format(self: SessionHeader, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("billy · {s} · {s} · ", .{ self.id, self.model });
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try out.writeAll(displayPath(&path_buffer, self.cwd, self.home));
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

pub fn formatTokens(out: *std.Io.Writer, count: usize) !void {
    if (count < 1000) return out.print("{d}", .{count});
    if (count < 999_500) return formatScaled(out, count, 1000, 'k');
    return formatScaled(out, count, 1_000_000, 'M');
}

fn formatScaled(out: *std.Io.Writer, count: usize, unit: usize, suffix: u8) !void {
    try out.print("{d:.0}{c}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(unit)),
        suffix,
    });
}

pub fn formatPercent(out: *std.Io.Writer, used: usize, total: usize) !void {
    if (total == 0) return out.writeAll("0%");
    const percent = used * 100 / total;
    if (percent == 0 and used > 0) return out.writeAll("<1%");
    try out.print("{d}%", .{percent});
}

/// The working directory as shown in the header: shortened to `~` when it is inside the home
/// directory, so a long path stays readable, and otherwise returned as it is.
pub fn displayPath(buffer: []u8, cwd: []const u8, home: ?[]const u8) []const u8 {
    if (home) |dir| {
        if (dir.len > 0 and std.mem.startsWith(u8, cwd, dir)) {
            const rest = cwd[dir.len..];
            if (rest.len == 0) return "~";
            if (rest[0] == '/') return std.mem.print(buffer, "~{s}", .{rest}) catch cwd;
        }
    }
    return cwd;
}

io: std.Io,
gpa: std.mem.Allocator,
behaviour: Behaviour,
config: *const Config,
catalog: *const models.Catalog,
credentials: *const Credentials,
http: *std.http.Client,
target_state: std.heap.ArenaAllocator,
instructions: ?std.Io.Dir = null,
work_dir: std.Io.Dir,
tool_set: Tools,

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    cwd: []const u8,
    http_client: *std.http.Client,
) !Agent {
    var work_dir = std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| {
        std.log.err("cannot work in {s}: {s}", .{ cwd, @errorName(err) });
        return report.Reported;
    };
    errdefer work_dir.close(io);

    const tool_set = Tools.init(io, work_dir, gpa, http_client, options.tools);

    return .{
        .io = io,
        .gpa = gpa,
        .behaviour = options.behaviour,
        .config = options.config,
        .credentials = options.credentials,
        .catalog = options.catalog,
        .http = http_client,
        .target_state = std.heap.ArenaAllocator.init(gpa),
        .instructions = options.instructions,
        .work_dir = work_dir,
        .tool_set = tool_set,
    };
}

pub fn deinit(agent: *Agent) void {
    agent.target_state.deinit();
    agent.work_dir.close(agent.io);
}

pub fn prepare(agent: *Agent, session: *Session) !void {
    if (session.messages.items.len == 0 and session.systemPrompt() == null) {
        const prompt_text = try leadPrompt(agent.io, agent.gpa, agent.work_dir, agent.instructions);
        defer agent.gpa.free(prompt_text);
        try session.setSystemPrompt(prompt_text);
    }
    try session.ensureTools(agent.tool_set.definitions());
}

fn targetFor(agent: *Agent, session: *Session) !Target {
    _ = agent.target_state.reset(.retain_capacity);
    const choice = session.modelChoice(agent.config.stored.model);
    if (session.model() == null) try session.setModel(choice);
    return endpoint.targetFor(agent.config, agent.credentials, agent.catalog, agent.target_state.allocator(), choice);
}

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

fn sessionModel(agent: *const Agent, session: *const Session) endpoint.Model {
    return endpoint.modelOf(session.modelChoice(agent.config.stored.model), agent.catalog);
}

pub const Waiting = union(enum) {
    prompt: Prompt,
    ran,
    unresolved,

    pub const Prompt = struct {
        text: []const u8,
        title: ?[]const u8,
    };
};

/// Takes a line typed into `session` and does what it asks for, except asking the model, which is
/// left to `ask`.
pub fn take(agent: *Agent, emitter: *Emitter, session: *Session, line: []const u8) !Waiting {
    // A command is run rather than asked, and before any client is made: a session on a model that
    // cannot be reached is exactly the one `/model` has to be able to move.
    if (Command.of(line)) |cmd| {
        switch (cmd) {
            .compact => {
                var client = (try agent.resolvedClient(emitter, session)) orelse return .unresolved;
                if (agent.compact(emitter, session, &client, .now) != .done)
                    try emitter.show(.{ .notice = "nothing to compact" });
            },
            .model => |choice| try agent.selectModel(emitter, session, choice),
            .cwd => |path| try agent.changeCwd(emitter, session, path),
        }
        return .ran;
    }

    var client = (try agent.resolvedClient(emitter, session)) orelse return .unresolved;

    _ = agent.compact(emitter, session, &client, .when_needed);

    const named = try nameFromPrompt(session, line);

    if (session.messages.items.len == 0) try agent.prepare(session);

    return .{
        .prompt = .{
            .text = line,
            .title = if (named) session.title() else null,
        },
    };
}

fn resolvedClient(agent: *Agent, emitter: *Emitter, session: *Session) !?llm.Client {
    return agent.clientFor(session) catch |err| switch (err) {
        error.MissingApiKey, error.UnknownProvider => {
            var notice: [256]u8 = undefined;
            const choice = session.modelChoice(agent.config.stored.model);
            try emitter.show(.{ .notice = endpoint.unreachableModel(&notice, err, choice) });
            return null;
        },
        else => |other| return other,
    };
}

fn selectModel(agent: *Agent, emitter: *Emitter, session: *Session, choice: ?[]const u8) !void {
    var notice: [256]u8 = undefined;
    const asked = choice orelse {
        const current = session.modelChoice(agent.config.stored.model);
        return emitter.show(.{ .notice = std.mem.print(
            &notice,
            "the model is {s}; use /model <provider>/<model> to change it",
            .{current},
        ) catch "use /model <provider>/<model> to change the model" });
    };

    if (!(models.Choice{ .text = asked }).isComplete()) {
        return emitter.show(.{ .notice = "a model is named as <provider>/<model>, such as /model deepseek/deepseek-flash" });
    }

    try session.setModel(asked);
    // A session that has messages is a file already, and the model it goes to is part of it, so the
    // move is written down now rather than at the next turn.
    if (session.messages.items.len > 0) session.save() catch |err|
        std.log.warn("could not write the session: {s}", .{@errorName(err)});

    return emitter.show(.{ .notice = std.mem.print(&notice, "the model is now {s}", .{asked}) catch
        "the model is set" });
}

fn changeCwd(agent: *Agent, emitter: *Emitter, session: *Session, asked: ?[]const u8) !void {
    var notice: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const wanted = asked orelse {
        const current = session.cwd();
        return emitter.show(.{ .notice = std.mem.print(
            &notice,
            "the session works in {s}; use /cwd <directory> to move it",
            .{current},
        ) catch "use /cwd <directory> to move the session" });
    };

    // Read from the directory the session works in now, so `/cwd ..` is the parent of where it was
    // moved to rather than of where billy was started, and recorded as the filesystem names it, so
    // the header, a resume and `pwd` agree.
    const path = agent.work_dir.realPathFileAlloc(agent.io, wanted, agent.gpa) catch |err|
        return cwdNotice(emitter, &notice, wanted, err);
    defer agent.gpa.free(path);

    // Opened before the old one is let go, so a directory that cannot be opened leaves the session
    // working where it was.
    const moved = std.Io.Dir.openDirAbsolute(agent.io, path, .{}) catch |err|
        return cwdNotice(emitter, &notice, wanted, err);

    agent.work_dir.close(agent.io);
    agent.work_dir = moved;
    agent.tool_set.dir = moved;
    try session.setCwd(path);

    // A session that has been asked something carries a prompt read from the directory it worked in
    // then, so that is read again -- which writes the session out, the move with it.
    if (session.messages.items.len > 0) agent.refresh(session);

    return emitter.show(.{ .notice = std.mem.print(
        &notice,
        "the session works in {s}",
        .{path},
    ) catch "the session works in the new directory" });
}

fn cwdNotice(emitter: *Emitter, buffer: []u8, path: []const u8, err: anyerror) !void {
    return emitter.show(.{ .notice = std.mem.print(
        buffer,
        "cannot work in {s}: {s}",
        .{ path, @errorName(err) },
    ) catch "cannot work in that directory" });
}

const Compaction = enum { done, nothing, failed };

fn compact(
    agent: *Agent,
    emitter: *Emitter,
    session: *Session,
    client: *llm.Client,
    when: enum { when_needed, now },
) Compaction {
    const compacted = (switch (when) {
        .when_needed => agent.maybeCompact(emitter, session, client),
        .now => agent.summarize(emitter, session, client),
    }) catch |err| {
        std.log.warn("compaction failed: {s}", .{@errorName(err)});
        return .failed;
    };
    if (!compacted) return .nothing;
    agent.refresh(session);
    return .done;
}

fn refresh(agent: *Agent, session: *Session) void {
    agent.refreshLead(agent.tool_set.definitions(), session) catch |err|
        std.log.warn("could not refresh the prompt and tools: {s}", .{@errorName(err)});
}

/// Asks `session` one thing and shows how the answer is reached: the prompt, the tool calls it
/// makes, and the reply.
pub fn ask(agent: *Agent, emitter: *Emitter, session: *Session, text: []const u8) !void {
    var client = (try agent.resolvedClient(emitter, session)) orelse return;

    const first_turn = session.messages.items.len == 0;
    _ = try nameFromPrompt(session, text);

    try session.append(.{ .role = .user, .content = text });
    try emitter.show(.{ .prompt = text });

    // A turn that failed is shown where the answer would have been, so the loss is visible in the
    // conversation rather than only in a log.
    const shown_before = emitter.shown;
    agent.turn(emitter, session, &client) catch |err| {
        std.log.err("a request failed: {s}", .{@errorName(err)});
        var notice: [256]u8 = undefined;
        return emitter.show(.{ .notice = failureNotice(&notice, err, emitter.shown > shown_before) });
    };

    if (first_turn and agent.behaviour.title) {
        agent.titleSession(session, &client) catch |err|
            std.log.warn("could not title the session: {s}", .{@errorName(err)});
    }
}

fn failureNotice(buffer: []u8, err: anyerror, shown: bool) []const u8 {
    const outcome = if (shown) "the turn stopped partway" else "nothing was sent";
    return std.mem.print(buffer, "the request failed: {s} — {s}, try again", .{ @errorName(err), outcome }) catch
        (if (shown)
            "the request failed, and the turn stopped partway — try again"
        else
            "the request failed — nothing was sent, try again");
}

/// Replays a stored conversation on the terminal as the blocks it was made of, so remembering the
/// context of an earlier run is not left to the user.
pub fn printTranscript(
    io: std.Io,
    gpa: std.mem.Allocator,
    writer: Terminal.Writer,
    session: *const Session,
    blocks: usize,
) !void {
    var terminal = Terminal{ .writer = writer, .io = io, .scratch = gpa };
    defer terminal.deinit();
    try walk(gpa, session, blocks, terminal.emitter());
    try writer.flush();
}

pub fn walk(gpa: std.mem.Allocator, session: *const Session, blocks: usize, emitter: *Emitter) !void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const trim = transcriptTrim(session, blocks);
    if (trim.hidden > 0) try emitter.show(.{ .hidden = trim.hidden });

    for (session.messages.items[trim.index..], trim.index..) |message, index| {
        const skip = if (index == trim.index) trim.skip else 0;
        try emitMessage(scratch, session, index, message, skip, emitter);
        _ = scratch_state.reset(.retain_capacity);
    }
}

fn emitMessage(
    arena: std.mem.Allocator,
    session: *const Session,
    index: usize,
    message: Session.Message,
    skip: usize,
    emitter: *Emitter,
) !void {
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
        const result = session.toolResult(index + 1, call.id);
        try emitter.show(.{ .tool_begin = parsed });
        try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result } });
    }
}

const Trim = struct {
    index: usize,
    skip: usize,
    hidden: usize,
};

fn transcriptTrim(session: *const Session, blocks: usize) Trim {
    if (blocks == 0) return .{ .index = 0, .skip = 0, .hidden = 0 };

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
            skip = count - remaining;
            remaining = 0;
        }
    }

    var hidden = skip;
    for (0..index) |earlier| hidden += blocksIn(session, messages, earlier);
    return .{ .index = index, .skip = skip, .hidden = hidden };
}

fn blocksIn(session: *const Session, messages: []const Session.Message, index: usize) usize {
    if (session.isCompaction(index)) return 1;
    if (session.isCompaction(index + 1)) return 0;
    const message = messages[index];
    if (message.role == .user) return 1;
    if (message.role != .assistant) return 0;
    const calls = message.tool_calls.len;
    return if (calls == 0) 1 else calls;
}

fn showDeltaText(emitter: *Emitter, delta: llm.Delta) !void {
    if (delta.reasoning) |text| try emitter.showDelta(.{ .reasoning = text });
    if (delta.content) |text| try emitter.showDelta(.{ .content = text });
}

const max_retries: usize = 3;

fn turn(agent: *Agent, emitter: *Emitter, session: *Session, client: *llm.Client) !void {
    var scratch_state = std.heap.ArenaAllocator.init(agent.tool_set.gpa);
    defer scratch_state.deinit();

    var remaining: usize = agent.behaviour.max_turns;
    // The second bound on the loop: how many replies in a row may say nothing before the turn stops
    // asking.
    var retries: usize = max_retries;
    // A compaction that failed is not tried again within the same turn, so a provider that will not
    // summarize cannot turn every request of a long turn into a second failed one.
    var compact_failed = false;
    while (remaining > 0 and retries > 0) : (remaining -= 1) {
        if (!compact_failed) compact_failed = agent.compact(emitter, session, client, .when_needed) == .failed;

        var stream = try client.complete(
            agent.gpa,
            session.id(),
            session.conversation(&.{}),
            session.toolSet(),
        );
        defer stream.deinit();

        while (try stream.next()) |delta| try showDeltaText(emitter, delta);

        const message = try stream.message();
        const calls = message.tool_calls orelse &.{};

        if (calls.len == 0 and message.content == null) {
            retries -= 1;
            continue;
        }

        // This reply said something, so the silence before it is behind the turn rather than in
        // front of it: the next one may be asked again as often as the first was.
        retries = max_retries;

        session.recordUsage(stream.usage());
        try session.append(message);

        if (calls.len == 0) return emitter.show(.{ .answer = message.content orelse "" });

        try runCalls(&agent.tool_set, emitter, &scratch_state, session, calls);
    }
    var buffer: [96]u8 = undefined;
    // Which bound stopped the loop says what went wrong.
    if (retries == 0) {
        const silent = std.mem.print(
            &buffer,
            "stopped after {d} replies in a row that said nothing",
            .{max_retries},
        ) catch "stopped with nothing to show";
        return emitter.show(.{ .notice = silent });
    }
    const stopped = std.mem.print(
        &buffer,
        "stopped after {d} turns without a final answer",
        .{agent.behaviour.max_turns},
    ) catch "stopped without a final answer";
    try emitter.show(.{ .notice = stopped });
}

fn runCalls(
    tool_set: *Tools,
    emitter: *Emitter,
    scratch_state: *std.heap.ArenaAllocator,
    session: *Session,
    calls: []const llm.ToolCall,
) !void {
    for (calls) |call| {
        _ = scratch_state.reset(.retain_capacity);
        const parsed = Tools.parse(scratch_state.allocator(), call);
        try emitter.show(.{ .tool_begin = parsed });

        var result: std.Io.Writer.Allocating = .init(tool_set.gpa);
        defer result.deinit();
        try tool_set.run(parsed, &result.writer);

        try session.append(.{
            .role = .tool,
            .tool_call_id = call.id,
            .content = result.written(),
        });
        try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });
    }
}

const base_prompt =
    \\You are billy, a helpful assistant. Answer the user's questions directly.
    \\Use the tools when they help with the task: read or change files, run a
    \\command, or search the web. Inspect the code before you change it, and
    \\reply in plain text when the work is done.
;

fn leadPrompt(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, user_dir: ?std.Io.Dir) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();

    try text.writer.writeAll(base_prompt);
    if (user_dir) |config_dir| _ = try globalInstructions(io, &text.writer, config_dir);
    _ = try projectInstructions(io, &text.writer, dir);
    return text.toOwnedSlice();
}

fn refreshLead(
    agent: *const Agent,
    definitions: []const Session.Definition,
    session: *Session,
) !void {
    const prompt_text = try leadPrompt(
        agent.io,
        agent.gpa,
        agent.tool_set.dir,
        agent.instructions,
    );
    defer agent.gpa.free(prompt_text);
    if (prompt_text.len > 0) try session.setSystemPrompt(prompt_text);
    try session.setTools(definitions);
    try session.save();
}

const title_prompt =
    \\The conversation above is the start of a session. Write a short title for
    \\it, so the user can find it again in a list: a few words, no more than
    \\about eight, naming what the session is about. Reply with the title alone,
    \\as plain text, with no quotes, no trailing punctuation and no explanation.
;

fn titleSession(agent: *Agent, session: *Session, client: *llm.Client) !void {
    const raw = try agent.askWith(session, client, title_prompt) orelse return;
    defer agent.gpa.free(raw);
    const title = try cleanTitle(agent.gpa, raw) orelse return;
    defer agent.gpa.free(title);
    try session.setTitle(title);
    try session.save();
}

fn cleanTitle(gpa: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const line = std.mem.sliceTo(raw, '\n');
    const unquoted = std.mem.trim(u8, std.mem.trim(u8, line, " \t\r"), "\"'`");
    const text = std.mem.trim(u8, unquoted, " \t\r");
    if (text.len == 0) return null;
    return try gpa.dupe(u8, text);
}

fn provisionalTitle(text: []const u8) []const u8 {
    const line = std.mem.sliceTo(text, '\n');
    return std.mem.trim(u8, line, " \t\r");
}

fn nameFromPrompt(session: *Session, text: []const u8) !bool {
    if (session.title() != null) return false;
    try session.setTitle(provisionalTitle(text));
    return true;
}

const compact_prompt =
    \\The conversation above is being compacted to free room in the context
    \\window. Write a summary of it that lets the work continue as if the
    \\earlier messages were still here. Cover the user's goals, what was decided
    \\and why, the files and functions that were changed and their current
    \\state, anything that was tried and did not work, and what is still to be
    \\done. Be specific: name the files, the functions and the commands. Reply
    \\with the summary alone, as plain text.
;

fn compactThreshold(agent: *const Agent, session: *const Session) usize {
    if (agent.behaviour.compact_at == 0) return 0;
    const info = agent.sessionModel(session).info orelse return 0;
    return info.context_window * agent.behaviour.compact_at / 100;
}

fn maybeCompact(agent: *Agent, emitter: *Emitter, session: *Session, client: *llm.Client) !bool {
    const threshold = agent.compactThreshold(session);
    if (threshold == 0 or session.context_tokens < threshold) return false;
    return agent.summarize(emitter, session, client);
}

fn summarize(agent: *Agent, emitter: *Emitter, session: *Session, client: *llm.Client) !bool {
    // Nothing has been added since the last compaction, so there is nothing new to compact in:
    // compacting again would only summarize the summary, and would do so on every request.
    const sent_from = session.sentFrom();
    if (session.messages.items.len - sent_from <= 1) return false;

    const summary = try agent.askWith(session, client, compact_prompt) orelse return false;
    defer agent.gpa.free(summary);

    session.context_tokens = 0;
    try session.appendCompaction(compact_prompt, summary);
    try emitter.show(.{ .compacted = .{ .prompt = compact_prompt, .summary = summary } });
    return true;
}

fn askWith(agent: *Agent, session: *Session, client: *llm.Client, question: []const u8) !?[]u8 {
    const extra = [_]llm.Message{.{ .role = .user, .content = question }};
    var stream = try client.complete(
        agent.gpa,
        session.id(),
        session.conversation(&extra),
        session.toolSet(),
    );
    defer stream.deinit();

    while (try stream.next()) |_| {}
    const content = (try stream.message()).content orelse return null;
    return try agent.gpa.dupe(u8, content);
}

fn expectTranscript(
    expected: []const u8,
    messages: []const llm.Message,
    style: Terminal.Writer.Style,
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

    // Plain, since what these cover is how a message is headed and laid out rather than how a
    // terminal decorates it.
    const writer: Terminal.Writer = .{ .style = style, .out = &out.writer };
    try printTranscript(io, gpa, writer, &session, 0);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "printTranscript shows only the last blocks and counts the rest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
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
    const writer: Terminal.Writer = .{ .out = &out.writer };

    try printTranscript(io, gpa, writer, &session, 2);
    try std.testing.expectEqualStrings(
        "… 2 earlier blocks\n\n" ++
            "▸ read b.zig\n▾ output\ncontents b\n\n" ++
            "◆ answer\ndone\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try printTranscript(io, gpa, writer, &session, 10);
    try std.testing.expect(std.mem.find(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
    out.clearRetainingCapacity();

    try printTranscript(io, gpa, writer, &session, 0);
    try std.testing.expect(std.mem.find(u8, out.written(), "earlier blocks") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "» prompt\none\n\n"));
}

test "printTranscript replays a conversation as the blocks it was made of" {
    // The system prompt is never shown while running, the tool result only as the output of the
    // call it belongs to.
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
    // A result whose call is not in the session has nothing to belong to, and a system prompt is
    // never shown at all.
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
    try expectTranscript(
        "◆ answer\nhi\n\n",
        &.{.{ .role = .assistant, .content = "**hi**" }},
        .plain,
    );

    try expectTranscript(
        "◆ answer\n(empty reply)\n\n",
        &.{.{ .role = .assistant, .content = "" }},
        .plain,
    );
}

test "a prompt from the session is headed and laid out like a reply" {
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
    const writer: Terminal.Writer = .{ .out = &out.writer };

    try printTranscript(io, gpa, writer, &session, 0);
    try std.testing.expectEqualStrings(
        "» prompt\none\n\n" ++
            "◆ answer\na1\n\n" ++
            "⊟ compacted\n\n" ++
            "» prompt\ntwo\n\n" ++
            "◆ answer\na2\n\n",
        out.written(),
    );
    out.clearRetainingCapacity();

    try printTranscript(io, gpa, writer, &session, 3);
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
    const writer: Terminal.Writer = .{ .style = .ansi, .out = &out.writer };
    try printTranscript(io, gpa, writer, &session, 0);

    try std.testing.expect(std.mem.find(u8, out.written(), "\x1b[33m⊟\x1b[0m \x1b[1mcompacted\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "ASKEDFORTHEcompaction") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "THESUMMARYTEXT") == null);
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

fn testAgent(io: std.Io, gpa: std.mem.Allocator, setup: TestSetup, http_client: ?*std.http.Client) !Agent {
    const work_dir = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(work_dir);
    return testAgentIn(io, gpa, setup, work_dir, http_client);
}

fn testAgentIn(
    io: std.Io,
    gpa: std.mem.Allocator,
    setup: TestSetup,
    work_dir: []const u8,
    http_client: ?*std.http.Client,
) !Agent {
    var unused: std.http.Client = undefined;
    return Agent.init(io, gpa, setup.options(), work_dir, http_client orelse &unused);
}

const TestSetup = struct {
    arena: std.heap.ArenaAllocator,
    config: *Config,
    credentials: *Credentials,
    entries: []Config.Providers.Entry,
    behaviour: Behaviour = .{ .max_turns = 10 },
    tools: Tools.Settings = .{ .bash_timeout_s = 120 },
    catalog: *const models.Catalog = &models.test_catalog,
    home: ?[]const u8 = null,
    instructions: ?std.Io.Dir = null,

    fn init(gpa: std.mem.Allocator, model: []const u8) !TestSetup {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const credentials = try arena.create(Credentials);
        credentials.* = .{};
        try credentials.put(arena, "test", "k");
        try credentials.put(arena, "other", "k");

        const config = try arena.create(Config);
        config.* = Config.init(gpa);
        errdefer config.deinit();
        config.stored.model = try arena.print("test/{s}", .{model});
        // A closed port, so a request that went somewhere a test did not mean it to fails rather
        // than waiting for an answer that never comes.
        const entries = try arena.dupe(Config.Providers.Entry, &.{
            .{ .name = "test", .base_url = "http://127.0.0.1:1" },
            .{ .name = "other", .base_url = "http://127.0.0.1:1" },
        });
        config.stored.providers = .{ .entries = entries };

        return .{
            .arena = arena_state,
            .config = config,
            .credentials = credentials,
            .entries = entries,
        };
    }

    fn deinit(setup: *TestSetup) void {
        setup.config.deinit();
        setup.arena.deinit();
    }

    fn pointAt(setup: *TestSetup, name: []const u8, url: []const u8) void {
        for (setup.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) entry.base_url = url;
        }
    }

    fn options(setup: TestSetup) Options {
        return .{
            .config = setup.config,
            .credentials = setup.credentials,
            .catalog = setup.catalog,
            .behaviour = setup.behaviour,
            .tools = setup.tools,
            .home = setup.home,
            .instructions = setup.instructions,
        };
    }
};

fn testTerminal(writer: Terminal.Writer) Terminal {
    return .{ .writer = writer, .io = std.testing.io, .scratch = std.testing.allocator };
}

test "a model that cannot be resolved is a notice, and asks nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.config.stored.providers = .{ .entries = try setup.arena.allocator().dupe(
        Config.Providers.Entry,
        &.{.{ .name = "nokey", .base_url = "http://127.0.0.1:1" }},
    ) };

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
    defer terminal.deinit();
    const emitter = terminal.emitter();

    try session.setModel("nokey/m");
    try std.testing.expect((try agent.take(emitter, &session, "hi")) == .unresolved);
    try std.testing.expect(std.mem.find(u8, out.written(), "the model nokey/m cannot be reached") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "billy login nokey") != null);
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expect(session.systemPrompt() == null);

    // A provider neither the configuration nor the catalog names says where an address comes from
    // instead.
    out.clearRetainingCapacity();
    try session.setModel("who-knows/m");
    try std.testing.expect((try agent.take(emitter, &session, "hi")) == .unresolved);
    try std.testing.expect(std.mem.find(u8, out.written(), "the model who-knows/m cannot be reached") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "billy models --refresh") != null);

    // And the way out of that state still answers: `/model` is read before any client is made, so
    // it works on the session that cannot be asked.
    out.clearRetainingCapacity();
    try std.testing.expect((try agent.take(emitter, &session, "/model other/m")) == .ran);
    try std.testing.expectEqualStrings("other/m", session.model().?);
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
}

const test_session_id = "01HF7YAT000000000000000000";

fn testHeader(model: []const u8, cwd: []const u8) SessionHeader {
    return .{ .id = test_session_id, .model = model, .cwd = cwd };
}

fn expectHeader(expected: []const u8, header: SessionHeader) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{header});
    try std.testing.expectEqualStrings(expected, out.written());
}

fn expectTokens(expected: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try formatTokens(&out.writer, count);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "header names the session, the model and the working directory" {
    try expectHeader(
        "billy · 01HF7YAT000000000000000000 · deepseek-flash · /work",
        testHeader("deepseek-flash", "/work"),
    );
}

test "header shortens a path inside the home directory" {
    var header = testHeader("m", "/home/user/repo/billy");
    header.home = "/home/user";
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · ~/repo/billy", header);

    header.cwd = "/home/user";
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · ~", header);

    header.cwd = "/home/user2";
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /home/user2", header);
}

test "header shows how full the context window is" {
    var header = testHeader("m", "/work");
    header.context_window = 128_000;

    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 0/128k (0%)", header);
    header.context_tokens = 500;
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 500/128k (<1%)", header);
    header.context_tokens = 16_000;
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 16k/128k (12%)", header);
    header.context_tokens = 128_000;
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 128k/128k (100%)", header);
    header.context_tokens = 12_500;
    try expectHeader("billy · 01HF7YAT000000000000000000 · m · /work · 13k/128k (9%)", header);
}

test "token counts are whole" {
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
    var header = testHeader("who-knows", "/work");
    header.context_tokens = 5000;
    try expectHeader("billy · 01HF7YAT000000000000000000 · who-knows · /work", header);
}

test "a header is built from a session" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Session.open(std.testing.io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    session.context_tokens = 100;
    try session.setModel("deepseek/deepseek-flash");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const model: endpoint.Model = .{
        .choice = "deepseek/deepseek-flash",
        .info = .{ .context_window = 128_000 },
    };
    try out.writer.print("{f}", .{SessionHeader.of(&session, model, null)});

    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    try expected.writer.print(
        "billy · {s} · deepseek/deepseek-flash · /work · 100/128k (<1%)",
        .{session.id()},
    );
    try std.testing.expectEqualStrings(expected.written(), out.written());
}

fn expectInstructions(expected: []const u8, read: anytype, dir: std.Io.Dir) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try read(std.testing.io, &out.writer, dir));
    try std.testing.expectEqualStrings(expected, out.written());
}

fn expectNoInstructions(read: anytype, dir: std.Io.Dir) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try read(std.testing.io, &out.writer, dir));
}

test "the project's instructions are read from the working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "Write tests.\n" });

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

    // The heading names the user rather than the project, so the two sections of a prompt read
    // apart, and the file is carried through as it was written.
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

    var config = std.testing.tmpDir(.{});
    defer config.cleanup();
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    try project.dir.createDirPath(io, ".git");

    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(base_prompt, text);
    }

    try config.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "USER RULES" });
    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir);
        defer gpa.free(text);
        const expected = try gpa.print("{s}\n\nThe user's instructions follow, read from AGENTS.md.\n\nUSER RULES", .{base_prompt});
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, text);
    }

    try project.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "PROJECT RULES" });
    {
        const text = try leadPrompt(io, gpa, project.dir, config.dir);
        defer gpa.free(text);
        const user = std.mem.find(u8, text, "USER RULES") orelse return error.TestUnexpectedResult;
        const local = std.mem.find(u8, text, "PROJECT RULES") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.find(u8, text, base_prompt) != null);
        try std.testing.expect(user < local);
    }

    try config.dir.deleteFile(io, "AGENTS.md");
    {
        const text = try leadPrompt(io, gpa, project.dir, null);
        defer gpa.free(text);
        try std.testing.expect(std.mem.find(u8, text, "PROJECT RULES") != null);
        try std.testing.expect(std.mem.find(u8, text, "USER RULES") == null);
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

    var unknown_setup = try TestSetup.init(gpa, "m");
    defer unknown_setup.deinit();
    var unknown = try testAgent(io, gpa, unknown_setup, null);
    defer unknown.deinit();
    try session.setModel("test/m");
    try std.testing.expectEqual(0, unknown.compactThreshold(&session));

    var setup = try TestSetup.init(gpa, "deepseek-flash");
    defer setup.deinit();
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();
    try session.setModel("test/deepseek-flash");

    try std.testing.expectEqual(800_000, agent.compactThreshold(&session));

    agent.behaviour.compact_at = 0;
    try std.testing.expectEqual(0, agent.compactThreshold(&session));

    agent.behaviour.compact_at = 50;
    try std.testing.expectEqual(500_000, agent.compactThreshold(&session));
    agent.behaviour.compact_at = 33;
    try std.testing.expectEqual(330_000, agent.compactThreshold(&session));
}

test "maybeCompact compacts the conversation once it has filled the window" {
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
    session.context_tokens = 900_000;

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
    var terminal = testTerminal(.{ .out = &out.writer });
    var client = try agent.clientFor(&session);
    try std.testing.expect(try agent.maybeCompact(terminal.emitter(), &session, &client));

    try mock.await();

    const body = mock.bodies.items[0];
    try std.testing.expect(std.mem.find(u8, body, "OLDPROMPT") != null);
    try std.testing.expect(std.mem.find(u8, body, "call_x") != null);
    try std.testing.expect(std.mem.find(u8, body, "OLDTOOLOUTPUT") != null);
    try std.testing.expect(std.mem.find(u8, body, "OLDANSWER") != null);
    try std.testing.expect(std.mem.find(u8, body, "free room in the context") != null);

    try std.testing.expectEqual(6, session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.messages.items[4].role.name());
    try std.testing.expectEqualStrings("user", session.messages.items[5].role.name());
    try std.testing.expectEqualStrings("the summary", session.contentOf(session.messages.items[5]).?);
    try std.testing.expectEqual(5, session.sentFrom());
    try std.testing.expect(session.isCompaction(5));

    try std.testing.expectEqual(0, session.context_tokens);

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

    // Nothing is listening on this address, so a request made where the function should have
    // returned first would fail the test rather than pass it.

    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
    const emitter = terminal.emitter();
    var client = try agent.clientFor(&session);

    session.context_tokens = 100;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session, &client));
    session.context_tokens = 999_900;
    agent.behaviour.compact_at = 0;
    try std.testing.expect(!try agent.maybeCompact(emitter, &session, &client));

    var unknown_setup = try TestSetup.init(gpa, "m");
    defer unknown_setup.deinit();
    var unknown = try testAgent(io, gpa, unknown_setup, null);
    defer unknown.deinit();
    session.context_tokens = 999_900;
    var unknown_client = try unknown.clientFor(&session);
    try std.testing.expect(!try unknown.maybeCompact(emitter, &session, &unknown_client));

    try std.testing.expectEqual(1, session.messages.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

test "a compaction asked for now compacts the conversation in whatever its size" {
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
    var terminal = testTerminal(.{ .out = &out.writer });
    var client = try agent.clientFor(&session);
    try std.testing.expect(try agent.summarize(terminal.emitter(), &session, &client));
    try mock.await();

    try std.testing.expectEqual(4, session.messages.items.len);
    try std.testing.expect(std.mem.find(u8, out.written(), "compacted") != null);

    // Asking again does nothing: the summary is the last message, so there is nothing new to
    // compact in, and a request would only re-summarize it.
    out.clearRetainingCapacity();
    try std.testing.expect(!try agent.summarize(terminal.emitter(), &session, &client));
    try std.testing.expectEqualStrings("", out.written());
}

test "a command is read from the whole line, and takes its argument with it" {
    try std.testing.expectEqual(Command.compact, Command.of("/compact").?);
    try std.testing.expectEqual(Command.compact, Command.of("  /compact\n").?);

    try std.testing.expectEqualStrings(
        "deepseek/deepseek-flash",
        Command.of("/model deepseek/deepseek-flash").?.model.?,
    );
    try std.testing.expectEqualStrings(
        "deepseek/deepseek-flash",
        Command.of("  /model  deepseek/deepseek-flash \n").?.model.?,
    );
    try std.testing.expect(Command.of("/model").?.model == null);
    try std.testing.expect(Command.of("/model   ").?.model == null);

    try std.testing.expectEqualStrings("/tmp", Command.of("/cwd /tmp").?.cwd.?);
    try std.testing.expect(Command.of("/cwd").?.cwd == null);

    try std.testing.expect(Command.of("/compact this") == null);
    try std.testing.expect(Command.of("/modelling it") == null);
    try std.testing.expect(Command.of("/modeler") == null);
    try std.testing.expect(Command.of("//model x") == null);
    try std.testing.expect(Command.of("/") == null);
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

    // Over the threshold, but the last message is the summary itself, so there is nothing new to
    // compact in and a request would only re-summarize it.
    session.context_tokens = 900_000;
    // Nothing is listening there, so a request made where this should have returned first would
    // fail the test.
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
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
    try session.setSystemPrompt("OLD PROMPT");
    try session.setTools(&old_tools);

    const work_dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(work_dir);
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgentIn(io, gpa, setup, work_dir, null);
    defer agent.deinit();

    try agent.refreshLead(&new_tools, &session);

    const prompt_text = session.systemPrompt().?;
    try std.testing.expect(std.mem.find(u8, prompt_text, base_prompt) != null);
    try std.testing.expect(std.mem.find(u8, prompt_text, "PROJECT RULES") != null);
    try std.testing.expect(std.mem.find(u8, prompt_text, "OLD PROMPT") == null);

    var tools: std.Io.Writer.Allocating = .init(gpa);
    defer tools.deinit();
    try std.json.Stringify.value(session.toolSet(), .{}, &tools.writer);
    try std.testing.expect(std.mem.find(u8, tools.written(), "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.find(u8, tools.written(), "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.find(u8, tools.written(), "\"name\":\"old\"") == null);

    var resumed = try Session.open(io, tmp.dir, gpa, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings(prompt_text, resumed.systemPrompt().?);
    try std.testing.expectEqual(2, resumed.tools.len);
}

test "prepare gives a fresh session the user's instructions from the configuration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

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
    var agent = try testAgent(io, gpa, setup, null);
    defer agent.deinit();

    try agent.prepare(&session);

    try std.testing.expect(std.mem.find(u8, session.systemPrompt().?, base_prompt) != null);
    try std.testing.expect(std.mem.find(u8, session.systemPrompt().?, "USER RULES") != null);
}

test "a first prompt gives the session its prompt and tools, and is asked as typed" {
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

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
    const waiting = try agent.take(terminal.emitter(), &session, "do the thing");

    try std.testing.expectEqualStrings("do the thing", waiting.prompt.text);
    try std.testing.expectEqualStrings("do the thing", waiting.prompt.title.?);
    try std.testing.expectEqualStrings("do the thing", session.title().?);
    try std.testing.expect(session.systemPrompt() != null);
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

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    _ = try agent.take(terminal.emitter(), &session, "the first thing");
    const prompt_text = try gpa.dupe(u8, session.systemPrompt().?);
    defer gpa.free(prompt_text);
    try session.append(.{ .role = .assistant, .content = "done" });

    const later = try agent.take(terminal.emitter(), &session, "/chat is this a command?");
    try std.testing.expectEqualStrings("/chat is this a command?", later.prompt.text);
    try std.testing.expect(later.prompt.title == null);
    try std.testing.expectEqualStrings(prompt_text, session.systemPrompt().?);
}

test "the model command says where the session is sent, and moves it there" {
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

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    const asked = try agent.take(terminal.emitter(), &session, "/model");
    try std.testing.expect(asked == .ran);
    try std.testing.expect(std.mem.find(u8, out.written(), "the model is test/m") != null);
    try std.testing.expect(session.model() == null);

    const moved = try agent.take(terminal.emitter(), &session, "/model other/other-model");
    try std.testing.expect(moved == .ran);
    try std.testing.expectEqualStrings("other/other-model", session.model().?);
    try std.testing.expect(std.mem.find(u8, out.written(), "the model is now other/other-model") != null);

    const refused = try agent.take(terminal.emitter(), &session, "/model other-model");
    try std.testing.expect(refused == .ran);
    try std.testing.expect(std.mem.find(u8, out.written(), "a model is named as <provider>/<model>") != null);
    try std.testing.expectEqualStrings("other/other-model", session.model().?);
}

test "a model chosen mid-session is the one the session is resumed with" {
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

    try session.append(.{ .role = .user, .content = "hello" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    const moved = try agent.take(terminal.emitter(), &session, "/model other/other-model");
    try std.testing.expect(moved == .ran);

    const id = try gpa.dupe(u8, session.id());
    defer gpa.free(id);
    var resumed = try Session.open(io, tmp.dir, gpa, id, "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("other/other-model", resumed.model().?);
}

test "the cwd command moves the session, its tools and its prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "ROOT RULES" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/AGENTS.md", .data = "SUB RULES" });

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const sub = try tmp.dir.realPathFileAlloc(io, "sub", gpa);
    defer gpa.free(sub);

    var session = try Session.open(io, tmp.dir, gpa, null, root);
    defer session.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgentIn(io, gpa, setup, root, null);
    defer agent.deinit();

    try agent.prepare(&session);
    try std.testing.expect(std.mem.find(u8, session.systemPrompt().?, "ROOT RULES") != null);
    try session.append(.{ .role = .user, .content = "hello" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    const asked = try agent.take(terminal.emitter(), &session, "/cwd");
    try std.testing.expect(asked == .ran);
    try std.testing.expect(std.mem.find(u8, out.written(), root) != null);

    const moved = try agent.take(terminal.emitter(), &session, "/cwd sub");
    try std.testing.expect(moved == .ran);
    try std.testing.expectEqualStrings(sub, session.cwd());
    try std.testing.expect(std.mem.find(u8, out.written(), sub) != null);

    try std.testing.expect(std.mem.find(u8, session.systemPrompt().?, "SUB RULES") != null);
    try std.testing.expect(std.mem.find(u8, session.systemPrompt().?, "ROOT RULES") == null);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try agent.tool_set.run(
        Tools.parseCallNamed(arena_state.allocator(), "write", "{\"path\":\"note.txt\",\"content\":\"hi\"}"),
        &written.writer,
    );
    const note = try tmp.dir.readFileAlloc(io, "sub/note.txt", gpa, .unlimited);
    defer gpa.free(note);
    try std.testing.expectEqualStrings("hi", note);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "note.txt", gpa, .unlimited));

    const id = try gpa.dupe(u8, session.id());
    defer gpa.free(id);
    var resumed = try Session.open(io, tmp.dir, gpa, id, "/elsewhere");
    defer resumed.deinit();
    try std.testing.expectEqualStrings(sub, resumed.cwd());

    const missing = try agent.take(terminal.emitter(), &session, "/cwd nowhere");
    try std.testing.expect(missing == .ran);
    try std.testing.expectEqualStrings(sub, session.cwd());
    try std.testing.expect(std.mem.find(u8, out.written(), "cannot work in nowhere") != null);
}

test "the cwd command writes no session that has not been asked anything" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const sub = try tmp.dir.realPathFileAlloc(io, "sub", gpa);
    defer gpa.free(sub);

    var session = try Session.open(io, tmp.dir, gpa, null, root);
    defer session.deinit();
    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    var agent = try testAgentIn(io, gpa, setup, root, null);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    const moved = try agent.take(terminal.emitter(), &session, "/cwd sub");
    try std.testing.expect(moved == .ran);
    try std.testing.expectEqualStrings(sub, session.cwd());

    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "{s}.json", .{session.id()});
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, name, .{}));
}

test "the model command can move a session off a model that cannot be reached" {
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

    // A model neither the configuration nor the catalog names, so a turn for it has no endpoint to
    // be resolved to: the command that moves the session off it cannot be one that needs a target
    // itself.
    try session.setModel("who-knows/m");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });

    const asked = try agent.take(terminal.emitter(), &session, "/model");
    try std.testing.expect(asked == .ran);
    try std.testing.expect(std.mem.find(u8, out.written(), "the model is who-knows/m") != null);

    const moved = try agent.take(terminal.emitter(), &session, "/model test/m");
    try std.testing.expect(moved == .ran);
    try std.testing.expectEqualStrings("test/m", session.model().?);
}

test "the terminal shows a tool call the way a replay does" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var call_state = std.heap.ArenaAllocator.init(gpa);
    defer call_state.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var tool_set = Tools.init(io, std.Io.Dir.cwd(), gpa, &http_client, .{ .bash_timeout_s = 120 });

    const call: llm.ToolCall = .{ .id = "1", .function = .{
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    } };

    var live: std.Io.Writer.Allocating = .init(gpa);
    defer live.deinit();
    var terminal = testTerminal(.{ .out = &live.writer });
    const emitter = terminal.emitter();

    const parsed = Tools.parse(call_state.allocator(), call);
    try emitter.show(.{ .tool_begin = parsed });
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    try tool_set.run(parsed, &result.writer);
    try emitter.show(.{ .tool_end = .{ .call = parsed, .result = result.written() } });

    var replayed: std.Io.Writer.Allocating = .init(gpa);
    defer replayed.deinit();
    try Terminal.tool.describe(gpa, parsed, result.written(), .{ .out = &replayed.writer });

    try std.testing.expectEqualStrings("❯ bash echo hi\necho hi\n✓ exit 0\n▾ stdout\nhi\n\n", live.written());
    try std.testing.expectEqualStrings(replayed.written(), live.written());
}

const Recorder = struct {
    gpa: std.mem.Allocator,
    seen: std.ArrayList(Seen) = .empty,
    deltas: std.ArrayList(Fragment) = .empty,
    reasonings: std.ArrayList(Fragment) = .empty,
    interface: Emitter = .{ .vtable = &vtable },

    const Seen = union(enum) {
        prompt: []const u8,
        answer: []const u8,
        tool_begin: []const u8,
        tool_end: struct { name: []const u8, result: []const u8 },
        compacted: Block.Compacted,
        notice: []const u8,
        hidden: usize,
    };

    const Fragment = struct { text: []const u8 };

    const vtable: Emitter.VTable = .{ .block = show, .delta = showDelta };

    fn emitter(self: *Recorder) *Emitter {
        return &self.interface;
    }

    fn show(e: *Emitter, block: Block) anyerror!void {
        const self = selfOf(e);
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
            .hidden => |count| .{ .hidden = count },
        };
        try self.seen.append(self.gpa, seen);
    }

    fn showDelta(e: *Emitter, delta: Delta) anyerror!void {
        const self = selfOf(e);
        if (delta.reasoning) |text| try self.reasonings.append(self.gpa, .{
            .text = try self.keeper(text),
        });
        if (delta.content) |text| try self.deltas.append(self.gpa, .{
            .text = try self.keeper(text),
        });
    }

    fn keeper(self: *Recorder, text: []const u8) ![]const u8 {
        return self.gpa.dupe(u8, text);
    }

    fn selfOf(e: *Emitter) *Recorder {
        return @alignCast(@fieldParentPtr("interface", e));
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

    const answering = struct {
        fn answer(_: usize, body: []const u8) Mock.Answer {
            if (std.mem.find(u8, body, "\"tool\"") != null) {
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"content\":\"all \"}}]}\n\n" ++
                        "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
                        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"I should run the command.\"}}]}\n\n" ++
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
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
    try agent.turn(recorder.emitter(), &session, &client);

    try mock.await();

    try std.testing.expectEqual(@as(usize, 2), mock.bodies.items.len);
    try std.testing.expect(std.mem.find(
        u8,
        mock.bodies.items[1],
        "\"reasoning_content\":\"I should run the command.\"",
    ) != null);

    try std.testing.expectEqual(3, recorder.seen.items.len);
    try std.testing.expectEqualStrings("bash", recorder.seen.items[0].tool_begin);
    const tool = recorder.seen.items[1].tool_end;
    try std.testing.expectEqualStrings("bash", tool.name);
    try std.testing.expectEqualStrings("exit code: 0\nhi\n", tool.result);
    try std.testing.expectEqualStrings("all done", recorder.seen.items[2].answer);

    try std.testing.expectEqual(1, recorder.reasonings.items.len);
    try std.testing.expectEqualStrings("I should run the command.", recorder.reasonings.items[0].text);
    try std.testing.expectEqual(2, recorder.deltas.items.len);
    try std.testing.expectEqualStrings("all ", recorder.deltas.items[0].text);
    try std.testing.expectEqualStrings("done", recorder.deltas.items[1].text);

    try std.testing.expectEqualStrings(
        "exit code: 0\nhi\n",
        session.contentOf(session.messages.items[session.messages.items.len - 2]).?,
    );
    try std.testing.expectEqualStrings(
        "all done",
        session.contentOf(session.messages.items[session.messages.items.len - 1]).?,
    );
}

fn expectNotice(expected: []const u8, err: anyerror, shown: bool) !void {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, failureNotice(&buffer, err, shown));
}

test "a failure notice says whether the answer had started" {
    try expectNotice(
        "the request failed: ApiError — the turn stopped partway, try again",
        error.ApiError,
        true,
    );
    try expectNotice(
        "the request failed: HttpStatus — nothing was sent, try again",
        error.HttpStatus,
        false,
    );
}

test "an emitter counts what it shows, and not a delta it drops" {
    const silent = struct {
        fn show(_: *Emitter, _: Block) anyerror!void {
            // Writes nothing, which is what a frontend that only counts does.
        }
    };
    var emitter: Emitter = .{ .vtable = &.{ .block = silent.show } };

    try emitter.showDelta(.{ .content = "half an answer" });
    try std.testing.expectEqual(@as(usize, 0), emitter.shown);

    try emitter.show(.{ .notice = "something" });
    try std.testing.expectEqual(@as(usize, 1), emitter.shown);
}

test "a turn that fails mid-answer has shown something" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"content\":\"half an answer\"}}]}\n\n" ++
            "data: {\"error\":{\"message\":\"the rest failed\"}}\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.pointAt("test", mock.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    var client = try agent.clientFor(&session);
    try std.testing.expectError(error.ApiError, agent.turn(recorder.emitter(), &session, &client));
    try mock.await();

    try std.testing.expectEqual(@as(usize, 1), recorder.interface.shown);
    try std.testing.expectEqual(1, recorder.deltas.items.len);
    try std.testing.expectEqualStrings("half an answer", recorder.deltas.items[0].text);
}

test "a turn that fails before showing anything has shown nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const refusing = struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{ .body = "no", .status = .bad_request };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 1, refusing);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.pointAt("test", mock.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    var client = try agent.clientFor(&session);
    try std.testing.expectError(error.HttpStatus, agent.turn(recorder.emitter(), &session, &client));
    try mock.await();

    try std.testing.expectEqual(@as(usize, 0), recorder.interface.shown);
    try std.testing.expectEqual(0, recorder.deltas.items.len);
}

test "a reply with nothing is not kept, and the turn is asked again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "first" });

    const answering = struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) {
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking it over\"}}]}\n\n" ++
                        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"content\":\"all done\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":1,\"total_tokens\":13}}\n\n" ++
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
    try agent.turn(recorder.emitter(), &session, &client);

    try mock.await();

    try std.testing.expectEqual(1, recorder.seen.items.len);
    try std.testing.expectEqualStrings("all done", recorder.seen.items[0].answer);
    try std.testing.expectEqual(1, recorder.reasonings.items.len);
    try std.testing.expectEqualStrings("thinking it over", recorder.reasonings.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), recorder.deltas.items.len);

    try std.testing.expectEqualStrings(mock.bodies.items[0], mock.bodies.items[1]);
    try std.testing.expect(std.mem.find(u8, mock.bodies.items[1], "\"assistant\"") == null);

    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expectEqualStrings("assistant", session.messages.items[1].role.name());
    try std.testing.expectEqualStrings("all done", session.contentOf(session.messages.items[1]).?);
}

test "a provider that keeps saying nothing ends the turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "first" });

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();

    // Every reply says nothing, which is a provider that is not answering rather than a model that
    // thought and stopped: the next ask gets the same nothing.
    var mock = try Mock.start("/chat/completions", setup.behaviour.max_turns, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking it over\"}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();
    setup.pointAt("test", mock.url);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    var client = try agent.clientFor(&session);
    try agent.turn(recorder.emitter(), &session, &client);

    // Stopped rather than waited on, since a turn that stops asking leaves the mock waiting for the
    // requests it was started for.
    try mock.stop();

    // What the turn ends with is a notice saying the model kept saying nothing, which is not the
    // notice a turn that ran out of turns shows: the model was asked and did not answer, rather
    // than getting as far as it was allowed.
    try std.testing.expectEqual(1, recorder.seen.items.len);
    try std.testing.expect(recorder.seen.items[0] == .notice);
    try std.testing.expectEqual(max_retries, recorder.reasonings.items.len);
    for (recorder.reasonings.items) |fragment|
        try std.testing.expectEqualStrings("thinking it over", fragment.text);
    var expected: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.mem.print(&expected, "stopped after {d} replies in a row that said nothing", .{max_retries}),
        recorder.seen.items[0].notice,
    );

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqual(@as(usize, max_retries), mock.bodies.items.len);
    for (mock.bodies.items[1..]) |body| try std.testing.expectEqualStrings(mock.bodies.items[0], body);
}

test "a reply that says something starts the run of silence over" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "first" });

    // Silence, then a call, then silence again, then the answer: more replies that say nothing than
    // the turn may take in a row, and a call in the middle of them.
    const answering = struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 2) {
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
                        "\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":" ++
                        "\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            if (number == 5) {
                return .{
                    .body = "data: {\"choices\":[{\"delta\":{\"content\":\"all done\"}}]}\n\n" ++
                        "data: [DONE]\n\n",
                    .content_type = "text/event-stream",
                };
            }
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking it over\"}}]}\n\n" ++
                    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
            };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 5, answering);
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
    try agent.turn(recorder.emitter(), &session, &client);

    // Stopped rather than waited on: the mock is answering the request that carries the answer, and
    // a turn that stopped before reaching it would leave the mock waiting for one that is not
    // coming.
    try mock.stop();

    try std.testing.expectEqual(3, recorder.seen.items.len);
    try std.testing.expectEqualStrings("bash", recorder.seen.items[0].tool_begin);
    try std.testing.expect(recorder.seen.items[2] == .answer);
    try std.testing.expectEqualStrings("all done", recorder.seen.items[2].answer);
    try std.testing.expectEqual(3, recorder.reasonings.items.len);
    try std.testing.expectEqual(@as(usize, 5), mock.bodies.items.len);
}

test "a turn that runs out of turns says so" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();
    try session.setSystemPrompt("be terse");
    try session.append(.{ .role = .user, .content = "first" });

    // A model that keeps calling a tool never reaches an answer, so the turn is the turn limit's to
    // end.
    var mock = try Mock.start("/chat/completions", 2, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
            "\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":" ++
            "\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.pointAt("test", mock.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();
    agent.behaviour.max_turns = 2;

    var recorder = Recorder{ .gpa = arena_state.allocator() };
    var client = try agent.clientFor(&session);
    try agent.turn(recorder.emitter(), &session, &client);

    try mock.stop();

    try std.testing.expectEqual(@as(usize, 2), mock.bodies.items.len);
    try std.testing.expectEqual(5, recorder.seen.items.len);
    try std.testing.expectEqualStrings("bash", recorder.seen.items[0].tool_begin);
    try std.testing.expectEqualStrings("bash", recorder.seen.items[2].tool_begin);
    try std.testing.expect(recorder.seen.items[4] == .notice);
    try std.testing.expectEqualStrings(
        "stopped after 2 turns without a final answer",
        recorder.seen.items[4].notice,
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

    const answering = struct {
        fn answer(_: usize, body: []const u8) Mock.Answer {
            if (std.mem.find(u8, body, "short title") != null) {
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
    setup.pointAt("test", mock.url);
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
    try agent.ask(terminal.emitter(), &session, "the flaky test keeps failing, please fix it");

    try mock.await();

    try std.testing.expectEqualStrings("Fix the flaky test", session.title().?);
    var resumed = try Session.open(io, tmp.dir, gpa, session.id(), "/work");
    defer resumed.deinit();
    try std.testing.expectEqualStrings("Fix the flaky test", resumed.title().?);

    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expectEqualStrings("user", session.messages.items[0].role.name());
    try std.testing.expectEqualStrings("assistant", session.messages.items[1].role.name());
    for (session.messages.items) |message| {
        const text = session.contentOf(message) orelse "";
        try std.testing.expect(std.mem.find(u8, text, "short title") == null);
    }
}

test "a title is cut to one clean line, or dropped when there is none" {
    const gpa = std.testing.allocator;

    try expectCleanTitle(gpa, "Fix the parser", "Fix the parser\nand more");
    try expectCleanTitle(gpa, "Fix it", "  \"Fix it\"  ");
    try expectCleanTitle(gpa, "Fix it", "`Fix it`");
    try expectCleanTitle(gpa, "just one line", "just one line\nextra");

    try std.testing.expect((try cleanTitle(gpa, "")) == null);
    try std.testing.expect((try cleanTitle(gpa, "   \n  ")) == null);

    const too_long: [200]u8 = @splat('x');
    const long = (try cleanTitle(gpa, &too_long)).?;
    defer gpa.free(long);
    try std.testing.expectEqual(@as(usize, 200), long.len);

    try std.testing.expectEqualStrings(
        "add a title to sessions",
        provisionalTitle("add a title to sessions\nand lots of detail follows"),
    );
    try std.testing.expectEqualStrings("short", provisionalTitle("   short   "));
}

fn expectCleanTitle(gpa: std.mem.Allocator, expected: []const u8, raw: []const u8) !void {
    const title = (try cleanTitle(gpa, raw)).?;
    defer gpa.free(title);
    try std.testing.expectEqualStrings(expected, title);
}

test "a turn is sent to the model the session records when it begins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var deepseek = try Mock.start("/chat/completions", 1, Mock.completion("from the deepseek model"));
    defer deepseek.deinit();
    try deepseek.serve();
    var opencode = try Mock.start("/chat/completions", 1, Mock.completion("from the opencode model"));
    defer opencode.deinit();
    try opencode.serve();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    setup.behaviour.title = false;
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
    var terminal = testTerminal(.{ .out = &out.writer });

    try session.setModel("test/deepseek/deepseek-flash");
    try agent.ask(terminal.emitter(), &session, "the first question");

    try session.setModel("other/kimi-k2.7-code");
    try agent.ask(terminal.emitter(), &session, "the second question");

    try deepseek.await();
    try opencode.await();

    try std.testing.expectEqual(@as(usize, 1), deepseek.served);
    try std.testing.expectEqual(@as(usize, 1), opencode.served);
}

test "a session is sent where the choice it recorded points, not the configuration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The configuration names an endpoint nothing listens on, so a request that went there would
    // fail rather than quietly answering.
    var chosen = try Mock.start("/chat/completions", 1, Mock.completion("chosen"));
    defer chosen.deinit();
    try chosen.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var setup = try TestSetup.init(gpa, "m");
    defer setup.deinit();
    // Only the provider the session records is pointed at a server; the one the configuration names
    // is left at a closed port, so a turn that went there would fail rather than answer.
    setup.behaviour.title = false;
    setup.pointAt("other", chosen.url);
    var agent = try testAgent(io, gpa, setup, &http_client);
    defer agent.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session = try Session.open(io, tmp.dir, gpa, null, "/work");
    defer session.deinit();

    try session.setModel("other/kimi-k2.7-code");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var terminal = testTerminal(.{ .out = &out.writer });
    try agent.ask(terminal.emitter(), &session, "a question");

    try chosen.await();
    try std.testing.expectEqual(@as(usize, 1), chosen.served);
    try std.testing.expect(std.mem.find(u8, chosen.bodies.items[0], "\"model\":\"kimi-k2.7-code\"") != null);
}
