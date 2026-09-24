//! Everything billy needs read in before it can do anything: where it keeps its
//! files, the configuration, the credentials, and the endpoint and model it talks
//! to.
//!
//! It is read in one place so the terminal run and the web server are set up the
//! same way, and cannot drift from each other. The values that depend on where a
//! command is asked for -- such as the working directory a session records -- are
//! left to the caller, which builds the agent configuration from this.

const std = @import("std");
const Io = std.Io;
const agent = @import("agent.zig");
const Config = @import("Config.zig");
const credentials = @import("credentials.zig");
const models = @import("models.zig");
const Search = @import("search.zig");
const Session = @import("Session.zig");
const styling = @import("style.zig");

const Setup = @This();

io: Io,
/// Temporary allocations, and what a tool format script is given to lay its
/// output out with.
gpa: std.mem.Allocator,
environ: *const std.process.Environ.Map,

/// The configuration. It owns an arena of its own for the strings read out of
/// the file, which `deinit` frees.
settings: Config,
/// Directory handle holding the session files.
sessions: Io.Dir,
/// The path of the sessions directory, for a message that has to name it.
sessions_path: []const u8,
/// The directories billy's own files were found in, held so they stay open for
/// as long as the credentials file might be written.
data_dir: Io.Dir,
config_dir: Io.Dir,

/// Where billy was started. A new session records it, so a session continues
/// where it was started rather than wherever it is picked up.
cwd: []const u8,
/// The key for the model endpoint, already resolved from the credentials or the
/// environment.
api_key: []const u8,
/// The endpoint billy talks to, and the model it asks for.
base_url: []const u8,
/// The full URL of the chat completions endpoint, built once from `base_url`.
/// It is kept here rather than made per run because both frontends ask for it
/// often -- the web server once per turn -- and it never changes.
url: []const u8,
model: []const u8,
/// Web search, when the configuration names a backend and its key is set. Null
/// leaves `web_search` out of the tools the model is offered.
search: ?Search.Config,

/// Reads the configuration, the credentials and the directories billy keeps its
/// files in, and reports what could not be read.
///
/// `out` is for the note that the configuration file was created, which is the
/// one thing here the user is told about.
pub fn open(init: std.process.Init, out: *Io.Writer) !Setup {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    // billy's own files live under the data directory: the credentials in the
    // directory itself, and the sessions in a subdirectory of it. The credentials
    // are not kept with the configuration, which is meant to be shared between
    // machines, and a key is not.
    const data_dir_path = Session.dataDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store billy's files: {s}", .{@errorName(err)});
        return err;
    };
    var data_dir = Io.Dir.cwd().createDirPathOpen(io, data_dir_path, .{}) catch |err| {
        std.log.err("cannot use {s} for billy's files: {s}", .{ data_dir_path, @errorName(err) });
        return err;
    };
    errdefer data_dir.close(io);

    const store = credentials.load(io, data_dir, arena) catch |err| {
        std.log.err("cannot read the credentials in {s}: {s}", .{ data_dir_path, @errorName(err) });
        return err;
    };

    const config_dir_path = Config.defaultDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store the configuration: {s}", .{@errorName(err)});
        return err;
    };
    var config_dir = Io.Dir.cwd().createDirPathOpen(io, config_dir_path, .{}) catch |err| {
        std.log.err("cannot use {s} for the configuration: {s}", .{ config_dir_path, @errorName(err) });
        return err;
    };
    errdefer config_dir.close(io);

    // The configuration owns an arena of its own for the strings it reads, so it
    // is freed when the run is over rather than with the process arena.
    var settings = Config.open(io, config_dir, init.gpa) catch |err| {
        std.log.err("cannot read the configuration in {s}: {s}", .{ config_dir_path, @errorName(err) });
        return err;
    };
    errdefer settings.config.deinit();
    if (settings.created) {
        try out.print("wrote the default configuration to {s}\n", .{
            try std.fs.path.join(arena, &.{ config_dir_path, Config.file_name }),
        });
    }

    const base_url = environ.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";
    const model = environ.get("BILLY_MODEL") orelse "deepseek-flash";
    // The endpoint URL is built once, here, and lives with the process. The web
    // server asks for the agent configuration once per turn, so building it
    // there would leak one allocation per turn into the process arena.
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
        std.mem.trimEnd(u8, base_url, "/"),
    });
    const api_key = credentials.modelKey(&store, environ, base_url) orelse {
        std.log.err("run `billy login deepseek`, or set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };

    const cwd = std.process.currentPathAlloc(io, arena) catch |err| {
        std.log.err("cannot find the working directory: {s}", .{@errorName(err)});
        return err;
    };

    // The sessions live in a subdirectory of billy's data directory, apart from
    // the credentials stored in the directory itself.
    const sessions_path = Session.defaultDir(arena, environ) catch |err| {
        std.log.err("cannot find where to store sessions: {s}", .{@errorName(err)});
        return err;
    };
    var sessions = Io.Dir.cwd().createDirPathOpen(io, sessions_path, .{}) catch |err| {
        std.log.err("cannot use {s} for sessions: {s}", .{ sessions_path, @errorName(err) });
        return err;
    };
    errdefer sessions.close(io);

    const search_config: ?Search.Config = if (settings.config.tools.web_search.provider) |provider| blk: {
        // A backend named without its key is an error rather than a silent "no
        // search": the configuration asked for the tool, and leaving it out
        // without a word would look like a bug.
        const service = credentials.searchService(provider);
        const key = credentials.credential(&store, environ, service) orelse {
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

    return .{
        .io = io,
        .gpa = init.gpa,
        .environ = environ,
        .settings = settings.config,
        .sessions = sessions,
        .sessions_path = sessions_path,
        .data_dir = data_dir,
        .config_dir = config_dir,
        .cwd = cwd,
        .api_key = api_key,
        .base_url = base_url,
        .url = url,
        .model = model,
        .search = search_config,
    };
}

pub fn deinit(setup: *Setup) void {
    setup.settings.deinit();
    setup.sessions.close(setup.io);
    setup.config_dir.close(setup.io);
    setup.data_dir.close(setup.io);
}

/// The agent configuration for a session working in `cwd`, with its blocks
/// decorated for `style`.
///
/// The window and the prices are not reported by the API, so they are looked up
/// by provider and model; an unknown model simply has no gauge and no cost, and
/// so no compaction, which needs a window to measure a conversation against.
///
/// Nothing is allocated here: every string is one the setup already holds, so
/// asking for this once a turn costs nothing that would have to be freed.
pub fn agentConfig(setup: *const Setup, cwd: []const u8, style: styling.Style) agent.Config {
    const settings = &setup.settings;
    return .{
        .api_key = setup.api_key,
        .url = setup.url,
        .model = setup.model,
        .max_turns = settings.max_turns,
        .bash_timeout_s = settings.tools.bash.timeout_s,
        .cwd = cwd,
        .home = setup.environ.get("HOME"),
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .compact_at = settings.compact_at,
        // How billy lays out and decorates what it shows. A bash command is laid
        // out by its format script, so the user reads the command the way it
        // runs; an edit is shown as a diff, laid out by its own script when one
        // is set; a reply and a prompt are laid out by the markdown script; and
        // the block headers are decorated for `style`. Only the display changes:
        // the command that runs, the file that is written, the session and the
        // model keep the text as it was written.
        .display = .{
            .formats = .{
                .bash = if (settings.tools.bash.format) |script| .{
                    .script = script,
                    .io = setup.io,
                    .gpa = setup.gpa,
                } else null,
                .edit = if (settings.tools.edit.format) |script| .{
                    .script = script,
                    .io = setup.io,
                    .gpa = setup.gpa,
                } else null,
            },
            .markdown = if (settings.markdown.format) |script| .{
                .script = script,
                .io = setup.io,
                .gpa = setup.gpa,
            } else null,
            .style = style,
        },
        // Web search is offered only when the configuration names a backend and
        // its key is set; the tool is left out of the request otherwise.
        .search = setup.search,
    };
}
