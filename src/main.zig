const std = @import("std");
const Io = std.Io;

const billy = @import("billy");

const usage =
    \\usage: billy [--resume <session>]
    \\       billy login [<service>]
    \\       billy config <setting> <value>
    \\
    \\  -r, --resume <session>  continue the session with this id, in the
    \\                          directory it was started in
    \\  -h, --help              print this message
    \\
    \\With no service, `login` lists the services billy needs a key for and
    \\where each key comes from; `login <service>` reads a key for that service
    \\and stores it, so it need not be exported before every run.
    \\
    \\`config` sets one setting in the configuration file, named by its dotted
    \\path, and writes it back, so a setting can be changed without opening the
    \\file by hand; for example, `billy config tools.bash.format 'shfmt'`. A
    \\string is taken as it is, a number from its digits, and `null` clears a
    \\setting that has no value.
    \\
    \\The API key comes from `billy login <service>`, or from DEEPSEEK_API_KEY or
    \\OPENAI_API_KEY when none is stored. BILLY_BASE_URL and BILLY_MODEL override
    \\the endpoint and the model. The project's own instructions are read from
    \\AGENTS.md, or CLAUDE.md, in the working directory or the nearest parent up
    \\to the repository root, and sent with every request. Sessions are stored
    \\under $XDG_DATA_HOME/billy/sessions, or ~/.local/share/billy/sessions when
    \\that is unset. The configuration lives in
    \\$XDG_CONFIG_HOME/billy/config.json, or ~/.config/billy/config.json when
    \\that is unset, and is created with the defaults on the first run. It holds
    \\the turn limit, and resume_blocks, how many of the most recent blocks a
    \\resumed session replays (a block being a prompt, a reply, or a tool call
    \\with its result; 0 shows the whole session); under
    \\tools.bash.format, a shell script that lays a bash command out for the
    \\display, and under tools.bash.timeout_s, the seconds a command may run
    \\before it is killed; under tools.edit.format, one that lays out the diff an
    \\edit is shown as, such as "delta --paging=never"; under markdown.format, one
    \\that lays out a reply, such as "glow -"; and under tools.web_search, the
    \\backend to search the web with (only "tavily" for now) and how many results
    \\to ask for. A format reads the text on standard input and writes it back on
    \\standard output; an edit's script also gets the paths of two files billy
    \\wrote the sides of the change to, as its first two arguments, so a two-file
    \\differ can name them "$1" and "$2". The keys are kept in credentials.json in
    \\the data directory, readable by the owner alone. The context window and the
    \\token prices the header reports come from a table built into billy, keyed by
    \\provider and model, since the API reports token counts but neither of those.
    \\When a conversation fills the context window to compact_at percent of it,
    \\the model is asked to summarize it, and that summary is added to the
    \\session; every request from then on carries only the summary and what
    \\follows it, so a long session goes on rather than failing on an overlong
    \\request. The session keeps the whole history, so the transcript still shows
    \\everything. Set compact_at to 0 to turn this off; a model billy does not
    \\know has no window to measure against, so it is never compacted.
    \\
;

const Options = struct {
    /// Session to continue; a new one is started when this is null.
    resume_id: ?[]const u8 = null,
    /// Whether the user asked for usage instead of a run.
    help: bool = false,
    /// Set when the `login` subcommand was asked for. The service is the one to
    /// store a key for, or null to list the services and the keys they have.
    login: ?Login = null,
    /// Set when the `config` subcommand was asked for: the setting to change,
    /// named by its dotted path, and the text to set it to.
    config: ?Config = null,

    const Login = struct {
        service: ?[]const u8 = null,
    };

    const Config = struct {
        path: []const u8,
        value: []const u8,
    };
};

pub fn main(init: std.process.Init) !void {
    // Anything that lives as long as the process, including the conversation,
    // is allocated here.
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const args = try std.process.Args.toSlice(init.minimal.args, arena);
    const options = parseArgs(args) catch |err| {
        std.log.err("invalid arguments, try --help", .{});
        return err;
    };
    if (options.help) {
        try out.writeAll(usage);
        return;
    }

    // The config subcommand only touches the configuration file, so it runs
    // before billy's own files and credentials are reached for.
    if (options.config) |setting| {
        try billy.Config.run(
            io,
            out,
            arena,
            init.gpa,
            init.environ_map,
            setting.path,
            setting.value,
        );
        return;
    }

    // billy's own files live under the data directory: the credentials in the
    // directory itself, and the sessions in a subdirectory of it. The
    // credentials are not kept with the configuration, which is meant to be
    // shared between machines, and a key is not.
    const data_dir = billy.Session.dataDir(arena, init.environ_map) catch |err| {
        std.log.err("cannot find where to store billy's files: {s}", .{@errorName(err)});
        return err;
    };
    var data_dir_handle = Io.Dir.cwd().createDirPathOpen(io, data_dir, .{}) catch |err| {
        std.log.err("cannot use {s} for billy's files: {s}", .{ data_dir, @errorName(err) });
        return err;
    };
    defer data_dir_handle.close(io);

    var credentials = billy.credentials.load(io, data_dir_handle, arena) catch |err| {
        std.log.err("cannot read the credentials in {s}: {s}", .{ data_dir, @errorName(err) });
        return err;
    };

    if (options.login) |login| {
        try billy.credentials.run(
            io,
            out,
            arena,
            data_dir_handle,
            data_dir,
            &credentials,
            init.environ_map,
            login.service,
        );
        return;
    }

    const config_dir = billy.Config.defaultDir(arena, init.environ_map) catch |err| {
        std.log.err("cannot find where to store the configuration: {s}", .{@errorName(err)});
        return err;
    };
    var config_dir_handle = Io.Dir.cwd().createDirPathOpen(io, config_dir, .{}) catch |err| {
        std.log.err("cannot use {s} for the configuration: {s}", .{ config_dir, @errorName(err) });
        return err;
    };
    defer config_dir_handle.close(io);

    // The configuration owns an arena of its own for the strings it reads, so it
    // is freed when the run is over rather than with the process arena.
    var settings = billy.Config.open(io, config_dir_handle, init.gpa) catch |err| {
        std.log.err("cannot read the configuration in {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };
    defer settings.config.deinit();
    if (settings.created) {
        try out.print("wrote the default configuration to {s}\n", .{
            try std.fs.path.join(arena, &.{ config_dir, billy.Config.file_name }),
        });
    }

    const base_url = init.environ_map.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";
    const model = init.environ_map.get("BILLY_MODEL") orelse "deepseek-flash";
    const api_key = billy.credentials.modelKey(&credentials, init.environ_map, base_url) orelse {
        std.log.err("run `billy login deepseek`, or set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };
    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    // The sessions live in a subdirectory of billy's data directory, apart from
    // the credentials stored in the directory itself.
    const sessions_dir = billy.Session.defaultDir(arena, init.environ_map) catch |err| {
        std.log.err("cannot find where to store sessions: {s}", .{@errorName(err)});
        return err;
    };
    var sessions_dir_handle = Io.Dir.cwd().createDirPathOpen(io, sessions_dir, .{}) catch |err| {
        std.log.err("cannot use {s} for sessions: {s}", .{ sessions_dir, @errorName(err) });
        return err;
    };
    defer sessions_dir_handle.close(io);

    // `cwd` is where billy runs now. A new session records it, and a resumed one
    // keeps the directory it was saved with, so a session continues where it was
    // started rather than wherever it is picked up.
    var session = billy.Session.open(io, sessions_dir_handle, init.gpa, options.resume_id, cwd) catch |err| switch (err) {
        error.SessionNotFound => {
            std.log.err("no session '{s}' in {s}", .{ options.resume_id.?, sessions_dir });
            return err;
        },
        error.InvalidSessionId => {
            std.log.err("'{s}' cannot be used as a session name", .{options.resume_id.?});
            return err;
        },
        else => return err,
    };
    defer session.deinit();

    const search_config: ?billy.search.Config = if (settings.config.tools.web_search.provider) |provider| blk: {
        // A backend named without its key is an error rather than a silent "no
        // search": the configuration asked for the tool, and leaving it out
        // without a word would look like a bug.
        const service = billy.credentials.searchService(provider);
        const key = billy.credentials.credential(&credentials, init.environ_map, service) orelse {
            std.log.err(
                "run `billy login {s}`, or set {s} to use web search, or clear tools.web_search in the configuration",
                .{ service.name(), service.variable() },
            );
            return error.MissingApiKey;
        };
        break :blk .{
            .provider = provider,
            .api_key = key,
            .max_results = settings.config.tools.web_search.max_results,
        };
    } else null;
    const config: billy.agent.Config = .{
        .api_key = api_key,
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
            std.mem.trimEnd(u8, base_url, "/"),
        }),
        .model = model,
        .max_turns = settings.config.max_turns,
        .bash_timeout_s = settings.config.tools.bash.timeout_s,
        .cwd = session.cwd,
        .home = init.environ_map.get("HOME"),
        // The context window and the prices are not reported by the API, so
        // they are looked up by provider and model; an unknown model simply has
        // no gauge and no cost, and so no compaction, which needs a window to
        // measure a conversation against.
        .model_info = billy.models.lookup(billy.models.Provider.fromUrl(base_url), model),
        .compact_at = settings.config.compact_at,
        // How billy lays out and decorates what it shows. A bash command is laid
        // out by its format script, so the user reads the command the way it runs;
        // an edit is shown as a diff, laid out by its own script when one is set;
        // a reply and a prompt are laid out by the markdown script; and a terminal
        // gets the block headers with the name in bold, while a pipe or a
        // redirection, where the escape codes would only be noise, gets the same
        // text plain. Only the display changes: the command that runs, the file
        // that is written, the session and the model keep the text as it was
        // written.
        .display = .{
            .formats = .{
                .bash = if (settings.config.tools.bash.format) |script| .{
                    .script = script,
                    .io = io,
                    .gpa = init.gpa,
                } else null,
                .edit = if (settings.config.tools.edit.format) |script| .{
                    .script = script,
                    .io = io,
                    .gpa = init.gpa,
                } else null,
            },
            .markdown = if (settings.config.markdown.format) |script| .{
                .script = script,
                .io = io,
                .gpa = init.gpa,
            } else null,
            .style = billy.style.Style.detect(io),
        },
        // Web search is offered only when the configuration names a backend and
        // its key is set; the tool is left out of the request otherwise.
        .search = search_config,
    };

    if (options.resume_id != null) {
        // Replay the conversation as a transcript, so the context does not
        // have to be remembered from the previous run. Only the last few blocks
        // are shown, so resuming a long one is quick.
        try billy.agent.printTranscript(
            init.gpa,
            out,
            &session,
            config.display,
            settings.config.resume_blocks,
        );
    }
    try billy.agent.run(io, init.gpa, out, config, &session);
}

/// Reads the command line, whose first entry is the executable name. The `login`
/// subcommand takes the rest of the line, so it is read on its own rather than
/// mixed with the run options.
fn parseArgs(args: []const [:0]const u8) error{ InvalidArgument, MissingValue }!Options {
    if (args.len > 1 and std.mem.eql(u8, args[1], "login")) {
        if (args.len == 2) return .{ .login = .{} };
        if (args.len == 3 and args[2].len > 0 and args[2][0] != '-') {
            return .{ .login = .{ .service = args[2] } };
        }
        return error.InvalidArgument;
    }

    // `config` takes exactly a setting and the value to give it, and owns the
    // rest of the line, so neither is read as a run option.
    if (args.len > 1 and std.mem.eql(u8, args[1], "config")) {
        if (args.len == 4 and args[2].len > 0 and args[2][0] != '-') {
            return .{ .config = .{ .path = args[2], .value = args[3] } };
        }
        return error.InvalidArgument;
    }

    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.resume_id = args[i];
        } else if (std.mem.startsWith(u8, arg, "--resume=")) {
            options.resume_id = arg["--resume=".len..];
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

test "parseArgs" {
    try expectOptions(.{}, try parseArgs(&.{"billy"}));
    try expectOptions(.{ .help = true }, try parseArgs(&.{ "billy", "--help" }));
    try expectOptions(
        .{ .resume_id = "20250131-120000" },
        try parseArgs(&.{ "billy", "--resume", "20250131-120000" }),
    );
    try expectOptions(.{ .resume_id = "dev" }, try parseArgs(&.{ "billy", "-r", "dev" }));
    try expectOptions(.{ .resume_id = "dev" }, try parseArgs(&.{ "billy", "--resume=dev" }));
    try expectOptions(
        .{ .help = true, .resume_id = "both" },
        try parseArgs(&.{ "billy", "--help", "--resume=both" }),
    );
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "billy", "--resume" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "--nope" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "extra" }));
}

test "parseArgs reads the login subcommand on its own" {
    try expectOptions(.{ .login = .{} }, try parseArgs(&.{ "billy", "login" }));
    try expectOptions(
        .{ .login = .{ .service = "tavily" } },
        try parseArgs(&.{ "billy", "login", "tavily" }),
    );
    // The subcommand owns the rest of the line, so a run option after it is not
    // a run option, and a second service is not an argument it takes.
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "--help" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "tavily", "extra" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "login", "" }));
}

test "parseArgs reads the config subcommand on its own" {
    try expectOptions(
        .{ .config = .{ .path = "tools.bash.format", .value = "shfmt | bat -l bash" } },
        try parseArgs(&.{ "billy", "config", "tools.bash.format", "shfmt | bat -l bash" }),
    );
    // A value may look like an option or be empty; the path may not.
    try expectOptions(
        .{ .config = .{ .path = "tools.bash.format", .value = "--nope" } },
        try parseArgs(&.{ "billy", "config", "tools.bash.format", "--nope" }),
    );
    try expectOptions(
        .{ .config = .{ .path = "markdown.format", .value = "" } },
        try parseArgs(&.{ "billy", "config", "markdown.format", "" }),
    );
    // A setting without a value, a value without a setting, an option-shaped
    // setting, and trailing arguments are all refused.
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "max_turns" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "--nope", "1" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "billy", "config", "max_turns", "1", "extra" }));
}

/// The slices in `Options` are compared by content rather than by pointer.
fn expectOptions(expected: Options, actual: Options) !void {
    try std.testing.expectEqual(expected.help, actual.help);
    if (expected.resume_id) |id| {
        try std.testing.expectEqualStrings(id, actual.resume_id.?);
    } else {
        try std.testing.expect(actual.resume_id == null);
    }
    if (expected.login) |login| {
        const actual_login = actual.login.?;
        if (login.service) |service| {
            try std.testing.expectEqualStrings(service, actual_login.service.?);
        } else {
            try std.testing.expect(actual_login.service == null);
        }
    } else {
        try std.testing.expect(actual.login == null);
    }
    if (expected.config) |setting| {
        const actual_setting = actual.config.?;
        try std.testing.expectEqualStrings(setting.path, actual_setting.path);
        try std.testing.expectEqualStrings(setting.value, actual_setting.value);
    } else {
        try std.testing.expect(actual.config == null);
    }
}
