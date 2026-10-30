//! The web frontend: billy served over HTTP instead of in a terminal.

const std = @import("std");

const Agent = @import("Agent.zig");
const Config = @import("Config.zig");
const Credentials = @import("Credentials.zig");
const Health = @import("Health.zig");
const html = @import("html.zig");
const models = @import("models.zig");
const report = @import("report.zig");
const Session = @import("Session.zig");
const setup = @import("setup.zig");

const Server = @This();

pub const default_port = 8787;

pub const default_host = "127.0.0.1";

const page =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
    \\<title>billy</title>
    \\<style>
    \\
++ @embedFile("web/style.css") ++
    \\</style>
    \\</head>
    \\<body>
    \\
++ @embedFile("web/body.html") ++
    \\<script>
    \\
++ @embedFile("web/script.js") ++
    \\</script>
    \\</body>
    \\</html>
    \\
;

const max_connections = 64;

io: std.Io,
gpa: std.mem.Allocator,
session_dir: std.Io.Dir,
config_dir: std.Io.Dir,
config: *const Config,
catalog: *const models.Catalog,
credentials: Credentials,
health: *Health,
http_client: *std.http.Client,
cwd: []const u8,
environ: *const std.process.Environ.Map,
backends: setup.Backends,

fn options(server: *const Server) Agent.Options {
    return .{
        .config = server.config,
        .credentials = &server.credentials,
        .catalog = server.catalog,
        .behaviour = Agent.Behaviour.fromConfig(server.config),
        .tools = setup.toolSettings(server.config, server.backends, server.health),
        .home = server.environ.get("HOME"),
        .instructions = server.config_dir,
    };
}

pub fn serve(server: *const Server, host: []const u8, port: u16) !void {
    const address = listenAddress(host, port) catch |err| {
        std.log.err(
            "cannot listen on '{s}': {t}; give an address such as 127.0.0.1, 0.0.0.0 or 192.168.1.5",
            .{ host, err },
        );
        return report.Reported;
    };
    var listener = try address.listen(server.io, .{ .reuse_address = true });
    defer listener.deinit(server.io);

    var registry = Registry{ .io = server.io, .gpa = server.gpa };
    defer registry.deinit();

    std.log.info("billy serve is listening on http://{s}:{d}/", .{
        host,
        listener.socket.address.getPort(),
    });

    // One task per connection, gathered so that they are all cancelled when the loop ends, as they
    // all share the listener's lifetime.
    var group: std.Io.Group = .init;
    defer group.cancel(server.io);

    var slots: std.Io.Semaphore = .{ .permits = max_connections };
    while (true) {
        try slots.wait(server.io);
        const stream = listener.accept(server.io) catch |err| {
            slots.post(server.io);
            return err;
        };
        group.concurrent(server.io, handle, .{ server, &registry, stream, &slots }) catch |err| {
            // A connection that cannot be given a task is one to let go of, rather than one to
            // bring the server down over.
            slots.post(server.io);
            std.log.err("cannot serve a connection: {t}", .{err});
            var copy = stream;
            copy.close(server.io);
            continue;
        };
    }
}

fn listenAddress(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.eql(u8, host, "localhost"))
        return .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };

    return std.Io.net.IpAddress.parse(host, port) catch error.InvalidHost;
}

const Registry = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    busy: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(registry: *Registry) void {
        var running = registry.busy.keyIterator();
        while (running.next()) |id| registry.gpa.free(id.*);
        registry.busy.deinit(registry.gpa);
    }

    fn claim(registry: *Registry, id: []const u8) !bool {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);

        if (registry.busy.contains(id)) return false;
        const owned = try registry.gpa.dupe(u8, id);
        errdefer registry.gpa.free(owned);
        try registry.busy.put(registry.gpa, owned, {});
        return true;
    }

    fn release(registry: *Registry, id: []const u8) void {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);
        if (registry.busy.fetchRemove(id)) |removed| registry.gpa.free(removed.key);
    }
};

fn handle(
    server: *const Server,
    registry: *Registry,
    stream: std.Io.net.Stream,
    slots: *std.Io.Semaphore,
) void {
    defer slots.post(server.io);
    defer {
        // `Stream.close` overwrites its argument with undefined, which it cannot do to a parameter
        // that was not declared mutable.
        var copy = stream;
        copy.close(server.io);
    }

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(server.io, &recv_buffer);
    var writer = stream.writer(server.io, &send_buffer);

    // A `Server` is per-connection, not per-listener: it wraps this connection's reader and writer
    // and holds the protocol state for them, so it is built here, once for the connection, over
    // this connection's buffers.
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = http_server.receiveHead() catch return;

    var r = Request{ .server = server, .request = &request };
    route(&r, registry) catch |err| {
        // A failure that already said what went wrong, in the log this task writes to, is not said
        // again here: what is left is to answer the browser with a status rather than let the
        // connection drop.
        if (err != report.Reported) std.log.err("cannot answer a request: {t}", .{err});
        // Nothing has been sent, so the browser can be told what happened rather than only watching
        // the connection drop.
        if (!r.answered) request.respond("billy: internal error\n", .{
            .status = .internal_server_error,
            .extra_headers = &.{ContentType.text.header()},
            .keep_alive = false,
        }) catch {
            // Nothing is left to tell a connection that will not take the status: the browser sees
            // it drop, which is what this spares it rather than replaces.
        };
    };
}

const Request = struct {
    server: *const Server,
    request: *std.http.Server.Request,
    answered: bool = false,

    fn open(r: *Request, id: []const u8) !?Session {
        return Session.open(r.server.io, r.server.session_dir, r.server.gpa, id, r.server.cwd) catch |err| switch (err) {
            error.InvalidSessionId => {
                try r.reply(.text, "bad session id\n", .bad_request);
                return null;
            },
            error.SessionNotFound => {
                try r.noSession();
                return null;
            },
            else => return err,
        };
    }

    fn claim(r: *Request, registry: *Registry, id: []const u8) !bool {
        if (try registry.claim(id)) return true;
        try r.reply(.text, "the session is busy\n", .conflict);
        return false;
    }

    fn noSession(r: *Request) !void {
        return try r.reply(.text, "no such session\n", .not_found);
    }

    fn reply(r: *Request, content_type: ContentType, body: []const u8, status: std.http.Status) !void {
        r.answered = true;
        try r.request.respond(body, .{
            .status = status,
            .extra_headers = &.{content_type.header()},
            .keep_alive = false,
        });
    }

    fn replyNotAllowed(r: *Request) !void {
        return try r.reply(.text, "method not allowed\n", .method_not_allowed);
    }
};

fn route(r: *Request, registry: *Registry) !void {
    const target = r.request.head.target;
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/")) switch (r.request.head.method) {
        .GET => {
            r.answered = true;
            return try r.request.respond(page, .{
                .status = .ok,
                .extra_headers = &.{ContentType.html.header()},
                .keep_alive = false,
            });
        },
        else => return try r.replyNotAllowed(),
    };

    if (std.mem.eql(u8, path, "/api/sessions")) switch (r.request.head.method) {
        .GET => return try writeListing(r),
        .POST => return try createSession(r, registry),
        else => return try r.replyNotAllowed(),
    };

    const sessions_prefix = "/api/sessions/";
    if (std.mem.startsWith(u8, path, sessions_prefix)) {
        const id_end = std.mem.findScalarPos(u8, path, sessions_prefix.len, '/') orelse path.len;
        const id = path[sessions_prefix.len..id_end];

        if (std.mem.eql(u8, path[id_end..], "/message")) switch (r.request.head.method) {
            .POST => return try askSession(r, registry, id),
            else => return try r.replyNotAllowed(),
        };

        if (path.len == id_end) switch (r.request.head.method) {
            .GET => return try openSession(r, id),
            .PATCH => return try renameSession(r, registry, id),
            .DELETE => return try deleteSession(r, registry, id),
            else => return try r.replyNotAllowed(),
        };
    }

    return try r.reply(.text, "not found\n", .not_found);
}

fn deleteSession(r: *Request, registry: *Registry, id: []const u8) !void {
    // Taken for the moment it takes to remove, so a turn cannot start against a session that is
    // being removed.
    if (!try r.claim(registry, id)) return;
    defer registry.release(id);

    Session.delete(r.server.io, r.server.session_dir, id) catch |err| switch (err) {
        error.InvalidSessionId => return r.reply(.text, "bad session id\n", .bad_request),
        error.SessionNotFound => return r.noSession(),
        else => return err,
    };
    return r.reply(.text, "", .ok);
}

const Rename = struct { title: []const u8 };

fn renameSession(r: *Request, registry: *Registry, id: []const u8) !void {
    const gpa = r.server.gpa;

    var body_buffer: [4096]u8 = undefined;
    const body_reader = r.request.readerExpectNone(&body_buffer);
    const body = body_reader.allocRemaining(gpa, .limited(1 << 16)) catch
        return r.reply(.text, "cannot read the title\n", .bad_request);
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(Rename, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return r.reply(.text, "the title is not JSON\n", .bad_request);
    defer parsed.deinit();
    // A title of nothing is refused rather than stored: a session with an empty name reads as one
    // that was never named.
    const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
    if (title.len == 0) return r.reply(.text, "the title is empty\n", .bad_request);

    if (!try r.claim(registry, id)) return;
    defer registry.release(id);

    var session = (try r.open(id)) orelse return;
    defer session.deinit();
    try session.setTitle(title);
    try session.save();
    return r.reply(.text, "", .ok);
}

const Listed = struct {
    id: []const u8,
    title: []const u8,
};

const Listing = struct { sessions: []const Listed };

fn writeListing(r: *Request) !void {
    const gpa = r.server.gpa;

    const stored = try Session.list(r.server.io, r.server.session_dir, gpa);
    defer {
        for (stored) |named| {
            gpa.free(named.id);
            gpa.free(named.title);
        }
        gpa.free(stored);
    }

    var sessions: std.ArrayList(Listed) = .empty;
    defer sessions.deinit(gpa);
    for (stored) |named| try sessions.append(gpa, .{ .id = named.id, .title = named.title });

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listing{ .sessions = sessions.items }, .{}, &body.writer);
    return r.reply(.json, body.written(), .ok);
}

const Opened = struct {
    header: []const u8,
    blocks: []const u8,
};

fn openSession(r: *Request, id: []const u8) !void {
    const gpa = r.server.gpa;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const opened = r.server.writeSession(gpa, id, &body.writer) catch |err| switch (err) {
        error.InvalidSessionId => return r.reply(.text, "bad session id\n", .bad_request),
        else => return err,
    };
    if (!opened) return r.noSession();
    return r.reply(.json, body.written(), .ok);
}

fn writeSession(
    server: *const Server,
    gpa: std.mem.Allocator,
    id: []const u8,
    out: *std.Io.Writer,
) !bool {
    var session = Session.open(server.io, server.session_dir, gpa, id, server.cwd) catch |err| switch (err) {
        error.SessionNotFound => return false,
        else => return err,
    };
    defer session.deinit();

    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try server.writeHeader(&session, &header.writer);

    var blocks: std.Io.Writer.Allocating = .init(gpa);
    defer blocks.deinit();
    try html.conversation(gpa, &session, server.config.stored.web_blocks, &blocks.writer);

    try writeOpened(out, header.written(), blocks.written());
    return true;
}

fn writeOpened(out: *std.Io.Writer, header: []const u8, blocks: []const u8) !void {
    try std.json.Stringify.value(Opened{
        .header = header,
        .blocks = blocks,
    }, .{}, out);
}

const ContentType = enum {
    html,
    json,
    text,
    events,

    fn header(content_type: ContentType) std.http.Header {
        return .{
            .name = "content-type",
            .value = switch (content_type) {
                .html => "text/html; charset=utf-8",
                .json => "application/json; charset=utf-8",
                .text => "text/plain; charset=utf-8",
                .events => "text/event-stream; charset=utf-8",
            },
        };
    }
};

test "a session is taken for a turn, and refused while one runs" {
    const gpa = std.testing.allocator;
    var registry = Registry{ .io = std.testing.io, .gpa = gpa };
    defer registry.deinit();

    try std.testing.expect(try registry.claim("one"));
    try std.testing.expect(!try registry.claim("one"));
    try std.testing.expect(try registry.claim("two"));

    registry.release("one");
    try std.testing.expect(try registry.claim("one"));
    try std.testing.expect(!try registry.claim("two"));
    registry.release("one");
    registry.release("two");

    var short: [4]u8 = "take".*;
    try std.testing.expect(try registry.claim(&short));
    @memset(&short, 'x');
    try std.testing.expect(!try registry.claim("take"));
    registry.release("take");
    try std.testing.expect(try registry.claim("take"));
    registry.release("take");
}

test "a session's page is written as the JSON the page reads" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeOpened(&out.writer, "<div class=\"header\">hi</div>\n", "<p>one</p>\n");
    try std.testing.expectEqualStrings(
        "{\"header\":\"<div class=\\\"header\\\">hi</div>\\n\",\"blocks\":\"<p>one</p>\\n\"}",
        out.written(),
    );
    const parsed = try std.json.parseFromSlice(Opened, gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("<div class=\"header\">hi</div>\n", parsed.value.header);
    try std.testing.expectEqualStrings("<p>one</p>\n", parsed.value.blocks);
}

test "a parsed prompt is copied, so the body it came from can be freed" {
    const gpa = std.testing.allocator;

    var buffer: [64]u8 = @splat(' ');
    const json = "{\"text\":\"hello\"}";
    @memcpy(buffer[0..json.len], json);

    const parsed = try parsePrompt(gpa, buffer[0..json.len]);
    defer parsed.deinit();
    @memset(buffer[0..json.len], 'x');

    try std.testing.expectEqualStrings("hello", parsed.value.text);
}

test "the page the browser is given is the one that was written" {
    try std.testing.expect(std.mem.find(u8, page, "<!doctype html>") == 0);
    try std.testing.expect(std.mem.find(u8, page, "/api/sessions") != null);
}

test "an event leaves the stream as it is written, without filling a buffer" {
    const gpa = std.testing.allocator;

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var body_buffer: [4096]u8 = undefined;
    var body: std.http.BodyWriter = .{
        .http_protocol_output = &sink.writer,
        .state = .init_chunked,
        .writer = .{
            .buffer = &body_buffer,
            .vtable = &.{
                .drain = std.http.BodyWriter.chunkedDrain,
                .sendFile = std.http.BodyWriter.chunkedSendFile,
            },
        },
    };
    var stream = Stream{ .body = &body, .gpa = gpa };

    // A frame small enough to sit in the buffer whole, so it reaches the sink only because the
    // event is flushed.
    try stream.write("block", "{\"html\":\"<p>hi</p>\"}");
    try std.testing.expect(std.mem.find(u8, sink.written(), "event: block") != null);

    try stream.write("done", "{}");
    try std.testing.expect(std.mem.count(u8, sink.written(), "event: ") == 2);
}

test "the address to listen on is read from what was asked for" {
    const anywhere = try listenAddress("0.0.0.0", 8787);
    try std.testing.expect(anywhere.eql(&(try std.Io.net.IpAddress.parse("0.0.0.0", 8787))));

    const here = try listenAddress("localhost", 8787);
    try std.testing.expect(here.eql(&(try std.Io.net.IpAddress.parse("127.0.0.1", 8787))));

    const v6 = try listenAddress("::1", 0);
    try std.testing.expect(v6.eql(&(try std.Io.net.IpAddress.parse("::1", 0))));

    try std.testing.expectError(error.InvalidHost, listenAddress("example.com", 8787));
    try std.testing.expectError(error.InvalidHost, listenAddress("", 8787));
}

const Prompt = struct {
    text: []const u8,
};

fn readPrompt(r: *Request) !?std.json.Parsed(Prompt) {
    const gpa = r.server.gpa;
    var body_buffer: [4096]u8 = undefined;
    const body_reader = r.request.readerExpectNone(&body_buffer);
    const body = body_reader.allocRemaining(gpa, .limited(1 << 20)) catch {
        try r.reply(.text, "cannot read the prompt\n", .bad_request);
        return null;
    };
    defer gpa.free(body);

    return parsePrompt(gpa, body) catch {
        try r.reply(.text, "the prompt is not JSON\n", .bad_request);
        return null;
    };
}

fn parsePrompt(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Prompt) {
    return std.json.parseFromSlice(Prompt, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn createSession(r: *Request, registry: *Registry) !void {
    const gpa = r.server.gpa;
    const parsed = (try readPrompt(r)) orelse return;
    defer parsed.deinit();

    var session = try Session.open(r.server.io, r.server.session_dir, gpa, null, r.server.cwd);
    defer session.deinit();
    if (!try r.claim(registry, session.id())) return;
    defer registry.release(session.id());

    if (parsed.value.text.len == 0)
        return r.reply(.text, "the prompt is empty\n", .bad_request);

    try serveTurn(r, &session, r.server.options(), parsed.value.text, .announce);
}

fn askSession(r: *Request, registry: *Registry, id: []const u8) !void {
    const parsed = (try readPrompt(r)) orelse return;
    defer parsed.deinit();
    if (parsed.value.text.len == 0)
        return r.reply(.text, "the prompt is empty\n", .bad_request);

    if (!try r.claim(registry, id)) return;
    defer registry.release(id);

    var session = (try r.open(id)) orelse return;
    defer session.deinit();

    try serveTurn(r, &session, r.server.options(), parsed.value.text, .quiet);
}

const Announce = enum { announce, quiet };

fn serveTurn(
    r: *Request,
    session: *Session,
    run_options: Agent.Options,
    text: []const u8,
    announce: Announce,
) !void {
    const gpa = r.server.gpa;
    var agent = try Agent.init(r.server.io, gpa, run_options, session.cwd(), r.server.http_client);
    defer agent.deinit();
    try agent.prepare(session);

    // The head of the reply goes out before the run starts, so the page can read the stream while
    // the model is working.
    var stream_buffer: [4096]u8 = undefined;
    var body_writer = try r.request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .extra_headers = &.{ContentType.events.header()},
            .keep_alive = false,
        },
    });
    r.answered = true;

    var stream = Stream{ .body = &body_writer, .gpa = gpa };
    const emitter = stream.emitter();

    // The line is given to the agent before the session is announced, because a command is answered
    // without the session being started at all: a `/compact` on a page with a session that has
    // nothing to fold must leave the page with no new session to show.
    const waiting = try agent.take(emitter, session, text);
    if (waiting == .ran or waiting == .unresolved) {
        try r.server.sendHeader(gpa, session, &stream);
        try stream.done();
        return;
    }

    if (announce == .announce) try stream.send("session", SessionEvent{ .id = session.id() });

    if (waiting.prompt.title) |title| try stream.send("title", TitleEvent{ .title = title });

    agent.ask(emitter, session, text) catch |err| {
        std.log.err("could not show the turn: {t}", .{err});
        try stream.fail(@errorName(err));
    };

    try r.server.sendHeader(gpa, session, &stream);
    try stream.done();
}

fn writeHeader(server: *const Server, session: *const Session, out: *std.Io.Writer) !void {
    const shown = setup.sessionModel(server.config, server.catalog, session);
    try html.header(.{
        .id = session.id(),
        .model = shown.choice,
        .cwd = session.cwd(),
        .home = server.environ.get("HOME"),
        .context_tokens = session.context_tokens,
        .model_info = shown.info,
    }, out);
}

fn sendHeader(server: *const Server, gpa: std.mem.Allocator, session: *const Session, stream: *Stream) !void {
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();

    try server.writeHeader(session, &header.writer);
    try stream.send("header", HtmlEvent{ .html = header.written() });
}

const HtmlEvent = struct { html: []const u8 };

const FailedEvent = struct { message: []const u8 };

const TitleEvent = struct { title: []const u8 };

const SessionEvent = struct { id: []const u8 };

const Stream = struct {
    body: *std.http.BodyWriter,
    gpa: std.mem.Allocator,
    interface: Agent.Emitter = .{ .vtable = &vtable },

    const vtable: Agent.Emitter.VTable = .{ .block = show };

    fn emitter(self: *Stream) *Agent.Emitter {
        return &self.interface;
    }

    fn show(e: *Agent.Emitter, b: Agent.Block) anyerror!void {
        const self: *Stream = @alignCast(@fieldParentPtr("interface", e));
        var rendered: std.Io.Writer.Allocating = .init(self.gpa);
        defer rendered.deinit();

        const event: []const u8 = switch (b) {
            .tool_begin => "tool_begin",
            .tool_end => "tool_end",
            else => "block",
        };
        try html.block(self.gpa, b, &rendered.writer);
        try self.send(event, HtmlEvent{ .html = rendered.written() });
    }

    fn fail(self: *Stream, message: []const u8) !void {
        try self.send("error", FailedEvent{ .message = message });
    }

    fn done(self: *Stream) !void {
        try self.write("done", "{}");
        try self.body.end();
    }

    fn send(self: *Stream, event: []const u8, payload: anytype) !void {
        var data: std.Io.Writer.Allocating = .init(self.gpa);
        defer data.deinit();
        try std.json.Stringify.value(payload, .{}, &data.writer);
        try self.write(event, data.written());
    }

    fn write(self: *Stream, event: []const u8, data: []const u8) !void {
        try self.body.writer.print("event: {s}\ndata: {s}\n\n", .{ event, data });
        try self.body.writer.flush();
        try self.body.flush();
    }
};

const TestServer = struct {
    server: Server,
    tmp: std.testing.TmpDir,
    config: *Config,
    environ: *std.process.Environ.Map,
    health: *Health,
    registry: Registry,
    http: *std.http.Client,

    fn init() !TestServer {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const sessions = try tmp.dir.createDirPathOpen(std.testing.io, "sessions", .{});
        errdefer sessions.close(std.testing.io);
        const config = try gpa.create(Config);
        errdefer gpa.destroy(config);
        config.* = Config.init(gpa);
        errdefer config.deinit();
        const environ = try gpa.create(std.process.Environ.Map);
        errdefer gpa.destroy(environ);
        environ.* = .init(gpa);
        errdefer environ.deinit();
        try environ.put("HOME", "/home/tester");
        const health = try gpa.create(Health);
        errdefer gpa.destroy(health);
        health.* = try Health.load(std.testing.io, gpa, tmp.dir);
        errdefer health.deinit();
        const http = try gpa.create(std.http.Client);
        errdefer gpa.destroy(http);
        http.* = .{ .allocator = gpa, .io = std.testing.io };
        errdefer http.deinit();

        return .{
            .tmp = tmp,
            .config = config,
            .environ = environ,
            .health = health,
            .registry = .{ .io = std.testing.io, .gpa = gpa },
            .http = http,
            .server = .{
                .io = std.testing.io,
                .gpa = gpa,
                .session_dir = sessions,
                .config_dir = tmp.dir,
                .config = config,
                .catalog = &models.test_catalog,
                .credentials = .{},
                .health = health,
                .http_client = http,
                .cwd = ".",
                .environ = environ,
                .backends = .{ .search = null, .fetch = null },
            },
        };
    }

    fn deinit(server: *TestServer) void {
        server.http.deinit();
        std.testing.allocator.destroy(server.http);
        server.registry.deinit();
        server.server.session_dir.close(std.testing.io);
        server.health.deinit();
        std.testing.allocator.destroy(server.health);
        server.config.deinit();
        std.testing.allocator.destroy(server.config);
        server.environ.deinit();
        std.testing.allocator.destroy(server.environ);
        server.tmp.cleanup();
    }

    fn exchange(server: *TestServer, method: std.http.Method, path: []const u8, body: ?[]const u8) !Exchange {
        return try Exchange.run(&server.server, &server.registry, method, path, body);
    }

    fn session(server: *TestServer, title: ?[]const u8) ![]const u8 {
        var opened = try Session.open(std.testing.io, server.server.session_dir, std.testing.allocator, null, ".");
        defer opened.deinit();

        if (title) |name|
            try opened.setTitle(name);

        try opened.append(.{ .role = .user, .content = "hello" });
        try opened.save();
        return std.testing.allocator.dupe(u8, opened.id());
    }
};

fn sessionPath(id: []const u8, suffix: []const u8) ![]const u8 {
    return try std.testing.allocator.print("/api/sessions/{s}{s}", .{ id, suffix });
}

const Exchange = struct {
    written: std.Io.Writer.Allocating,
    answered: bool = false,

    fn run(
        server: *const Server,
        registry: *Registry,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !Exchange {
        const gpa = std.testing.allocator;
        var exchange: Exchange = .{ .written = .init(gpa) };
        errdefer exchange.written.deinit();

        const request_text = if (body) |payload|
            try gpa.print("{t} {s} HTTP/1.1\r\nhost: billy\r\ncontent-type: application/json\r\n" ++
                "content-length: {d}\r\n\r\n{s}", .{ method, path, payload.len, payload })
        else
            try gpa.print("{t} {s} HTTP/1.1\r\nhost: billy\r\n\r\n", .{ method, path });
        defer gpa.free(request_text);

        var in_buffer: [4096]u8 = undefined;
        if (request_text.len > in_buffer.len) return error.RequestTooLong;
        @memcpy(in_buffer[0..request_text.len], request_text);
        var reader = std.Io.Reader.fixed(in_buffer[0..request_text.len]);

        var out_buffer: [128 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buffer);

        var http_server: std.http.Server = .init(&reader, &writer);
        var request = try http_server.receiveHead();

        var r = Request{ .server = server, .request = &request };
        try route(&r, registry);

        exchange.answered = r.answered;
        try exchange.written.writer.writeAll(writer.buffered());
        return exchange;
    }

    fn deinit(exchange: *Exchange) void {
        exchange.written.deinit();
    }

    fn statusLine(exchange: *Exchange) []const u8 {
        const text = exchange.written.written();
        const end = std.mem.find(u8, text, "\r\n") orelse text.len;
        return text[0..end];
    }

    fn contains(exchange: *Exchange, needle: []const u8) bool {
        return std.mem.find(u8, exchange.written.written(), needle) != null;
    }
};

test "a route answers a request it does not know with a 404" {
    var server = try TestServer.init();
    defer server.deinit();

    var exchange = try server.exchange(.GET, "/nope", null);
    defer exchange.deinit();

    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found", exchange.statusLine());
    try std.testing.expect(exchange.contains("not found"));
}

test "the page is served at the root, byte for byte" {
    var server = try TestServer.init();
    defer server.deinit();

    var exchange = try server.exchange(.GET, "/", null);
    defer exchange.deinit();

    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", exchange.statusLine());
    try std.testing.expect(exchange.contains(page));
}

test "the session list is read from disk, newest first" {
    var server = try TestServer.init();
    defer server.deinit();

    var empty = try server.exchange(.GET, "/api/sessions", null);
    defer empty.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", empty.statusLine());
    try std.testing.expect(empty.contains("{\"sessions\":[]}"));

    const id = try server.session("a named session");
    defer std.testing.allocator.free(id);

    var listed = try server.exchange(.GET, "/api/sessions", null);
    defer listed.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", listed.statusLine());
    try std.testing.expect(listed.contains(id));
    try std.testing.expect(listed.contains("a named session"));
}

test "one session is opened as the page the frontend reads" {
    var server = try TestServer.init();
    defer server.deinit();

    const id = try server.session(null);
    defer std.testing.allocator.free(id);
    const path = try sessionPath(id, "");
    defer std.testing.allocator.free(path);

    var opened = try server.exchange(.GET, path, null);
    defer opened.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", opened.statusLine());
    try std.testing.expect(opened.contains("\"header\":"));
    try std.testing.expect(opened.contains("deepseek/deepseek-flash"));
    try std.testing.expect(opened.contains("\"blocks\":"));
    try std.testing.expect(opened.contains("hello"));
}

test "an id with no session is a 404, and one that is not an id is a 400" {
    var server = try TestServer.init();
    defer server.deinit();

    var missing = try server.exchange(.GET, "/api/sessions/01M3AAAAAAAAAAAAAAAAAAAAAA", null);
    defer missing.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found", missing.statusLine());

    var malformed = try server.exchange(.GET, "/api/sessions/..%2f..%2fetc", null);
    defer malformed.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", malformed.statusLine());
}

test "a session is renamed, and the name is on disk" {
    var server = try TestServer.init();
    defer server.deinit();

    const id = try server.session(null);
    defer std.testing.allocator.free(id);
    const path = try sessionPath(id, "");
    defer std.testing.allocator.free(path);

    var renamed = try server.exchange(.PATCH, path, "{\"title\":\"renamed by the test\"}");
    defer renamed.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", renamed.statusLine());

    var reread = try Session.open(std.testing.io, server.server.session_dir, std.testing.allocator, id, ".");
    defer reread.deinit();

    try std.testing.expectEqualStrings("renamed by the test", reread.title().?);
}

test "a rename that says nothing usable is refused" {
    var server = try TestServer.init();
    defer server.deinit();

    const id = try server.session(null);
    defer std.testing.allocator.free(id);
    const path = try sessionPath(id, "");
    defer std.testing.allocator.free(path);

    // Whitespace is not a title: a session named " " would read as one that was never named, which
    // is what the list falls back to the id for.
    var blank = try server.exchange(.PATCH, path, "{\"title\":\"   \"}");
    defer blank.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", blank.statusLine());

    var not_json = try server.exchange(.PATCH, path, "not json");
    defer not_json.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", not_json.statusLine());

    var reread = try Session.open(std.testing.io, server.server.session_dir, std.testing.allocator, id, ".");
    defer reread.deinit();

    try std.testing.expect(reread.title() == null);
}

test "a session is deleted, and deleting it again is a 404" {
    var server = try TestServer.init();
    defer server.deinit();

    const id = try server.session(null);
    defer std.testing.allocator.free(id);
    const path = try sessionPath(id, "");
    defer std.testing.allocator.free(path);

    var removed = try server.exchange(.DELETE, path, null);
    defer removed.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", removed.statusLine());

    try std.testing.expectError(error.SessionNotFound, Session.open(
        std.testing.io,
        server.server.session_dir,
        std.testing.allocator,
        id,
        ".",
    ));

    var again = try server.exchange(.DELETE, path, null);
    defer again.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found", again.statusLine());
}

test "a prompt is refused while the session is busy, and one that asks nothing" {
    var server = try TestServer.init();
    defer server.deinit();

    const id = try server.session(null);
    defer std.testing.allocator.free(id);
    const path = try sessionPath(id, "/message");
    defer std.testing.allocator.free(path);

    var empty = try server.exchange(.POST, path, "{\"text\":\"\"}");
    defer empty.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", empty.statusLine());

    try std.testing.expect(try server.registry.claim(id));
    defer server.registry.release(id);
    var busy = try server.exchange(.POST, path, "{\"text\":\"do something\"}");
    defer busy.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 409 Conflict", busy.statusLine());
}
