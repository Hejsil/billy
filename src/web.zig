//! The web frontend: billy served over HTTP instead of in a terminal.
//!
//! The server listens where it is asked to, this machine only unless another
//! address is given. Every connection is handled on its own task, so a slow
//! request does not hold up the rest, and a connection that cannot be served is
//! closed rather than taking the server down with it.
//!
//! What a route answers with is rendered here but built by `html.zig` and read
//! out of a session, so the page shows the same blocks the terminal does. Every
//! string that comes from outside billy passes through `html.escape`, so nothing
//! a model, a file or a request writes can become markup.
//!
//! Nothing is authenticated. Any process that can reach the address, and any
//! page the browser loads, can reach these routes, and the routes can run
//! commands as the user. That is why the address is this machine only unless
//! something else is asked for, and why the help says so.

const std = @import("std");
const agent = @import("agent.zig");
const Config = @import("Config.zig");
const Health = @import("Health.zig");
const html = @import("html.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Runner = @import("agent.zig").Runner;
const Setup = @import("Setup.zig");

/// The port billy serves on when nothing else is asked for.
pub const default_port = 8787;

/// The address billy serves on when nothing else is asked for: this machine
/// only. Anywhere else may be asked for, but billy has no authentication and its
/// routes run commands as the user, so the help says what listening elsewhere
/// means.
pub const default_host = "127.0.0.1";

/// The page the browser is given at `/`: one file, with its styles and its
/// script in it, so the server serves it as it is and there is nothing to build.
const page = @embedFile("web/index.html");

/// The most connections billy serves at once.
///
/// Each connection is handled on its own task, so without a bound a server
/// listening beyond this machine could be asked for tasks until memory ran out.
/// A browser opens only a handful of connections, so this leaves room to spare
/// while keeping a stranger from taking the machine down.
const max_connections = 64;

/// Serves the frontend on the address `host` at `port`, until the process is
/// stopped. Zero asks the system for a free port, which is what a test uses.
///
/// The URL is printed once the socket is bound, so what is printed is the port
/// that was actually taken, and not the one that was asked for.
pub fn serve(setup: *Setup, out: *std.Io.Writer, host: []const u8, port: u16) !void {
    const address = listenAddress(host, port) catch |err| {
        std.log.err(
            "cannot listen on '{s}': {s}; give an address such as 127.0.0.1, 0.0.0.0 or 192.168.1.5",
            .{ host, @errorName(err) },
        );
        return err;
    };
    var listener = try address.listen(setup.io, .{ .reuse_address = true });
    defer listener.deinit(setup.io);

    // One HTTP client for the whole server, shared by every request of every
    // session, so they reuse its connections and share the certificates it scans
    // once.
    var http: std.http.Client = .{ .allocator = setup.gpa, .io = setup.io };
    defer http.deinit();

    // What the server knows about sessions beyond their files. It outlives every
    // connection, which is why it is here and not in the handler.
    var registry = Registry{ .io = setup.io, .gpa = setup.gpa };
    defer registry.deinit();

    try out.print("billy serve is listening on http://{s}:{d}/\n", .{
        host,
        listener.socket.address.getPort(),
    });
    try out.flush();

    // One task per connection, gathered so that they are all cancelled when the
    // loop ends, as they all share the listener's lifetime.
    var group: std.Io.Group = .init;
    defer group.cancel(setup.io);

    // At most `max_connections` are served at once. A permit is taken before a
    // connection is accepted, so one that arrives while the server is full waits
    // in the socket's backlog rather than being given a task of its own; the
    // permit is given back when the connection is answered and its task ends.
    var slots: std.Io.Semaphore = .{ .permits = max_connections };
    while (true) {
        try slots.wait(setup.io);
        const stream = listener.accept(setup.io) catch |err| {
            slots.post(setup.io);
            return err;
        };
        group.concurrent(setup.io, handle, .{ setup, &registry, &http, stream, &slots }) catch |err| {
            // A connection that cannot be given a task is one to let go of,
            // rather than one to bring the server down over.
            slots.post(setup.io);
            std.log.err("cannot serve a connection: {s}", .{@errorName(err)});
            var copy = stream;
            copy.close(setup.io);
            continue;
        };
    }
}

/// The address `host` and `port` name.
///
/// `localhost` is taken as the loopback address, which is what it means
/// everywhere. Anything else has to be an address, since billy does not resolve
/// names: `0.0.0.0` for every interface, or the address of one of them.
fn listenAddress(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.eql(u8, host, "localhost")) return .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    // What was asked for that is not an address comes back as one error, since
    // what billy does not do is resolve a name; the caller says so.
    return std.Io.net.IpAddress.parse(host, port) catch error.InvalidHost;
}

/// What the server knows about sessions that their files do not say.
///
/// A session is not written out until it is first asked something, so a new one
/// exists only as an id until then. This holds those ids: without it a session
/// just started would not be in the listing and its page would have nothing to
/// open.
///
/// Every connection runs on its own task, so this is reached from several at
/// once and a lock guards it.
const Registry = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// The ids of sessions a turn is running for right now, each with the id
    /// that names it owned as the key. A session can only be asked one thing at
    /// a time, so a second ask while one runs is refused.
    busy: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(registry: *Registry) void {
        var running = registry.busy.keyIterator();
        while (running.next()) |id| registry.gpa.free(id.*);
        registry.busy.deinit(registry.gpa);
    }

    /// Takes the session `id` for a turn, and says whether it was free. A
    /// session already taken is one a turn is running for, which is refused
    /// rather than queued: what a second ask would mean is not clear, and the
    /// page can say the session is busy.
    ///
    /// A taken session must be released with `release`, whatever happens in
    /// between, or it stays busy until the server stops.
    fn claim(registry: *Registry, id: []const u8) !bool {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);

        if (registry.busy.contains(id)) return false;
        // The key is the id itself, which the caller only has for this request,
        // so it is copied and the copy is the one freed on release.
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

/// Answers one connection, and closes it. Nothing a request or a reply does is
/// allowed to reach the caller: a connection that goes wrong is logged and
/// dropped, since the server outlives it.
///
/// `slots` is the permit the connection was accepted under, given back when the
/// connection is done so that the next one may be accepted.
fn handle(
    setup: *Setup,
    registry: *Registry,
    http: *std.http.Client,
    stream: std.Io.net.Stream,
    slots: *std.Io.Semaphore,
) void {
    defer slots.post(setup.io);
    defer {
        // `Stream.close` overwrites its argument with undefined, which it cannot
        // do to a parameter that was not declared mutable.
        var copy = stream;
        copy.close(setup.io);
    }

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(setup.io, &recv_buffer);
    var writer = stream.writer(setup.io, &send_buffer);
    // A `Server` is per-connection, not per-listener: it wraps this connection's
    // reader and writer and holds the protocol state for them, so it is built
    // here, once for the connection, over this connection's buffers. The shared
    // thing is `listener`, the socket that is accepted on. A single `Server`
    // handed to every connection would be shared mutable state over one reader,
    // and could only ever serve one of them.
    //
    // One request is served and the connection closed (`keep_alive = false`
    // everywhere), so `receiveHead` is called once; the same `Server` could
    // serve further requests on this connection if some reply asked to keep it.
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = server.receiveHead() catch return;
    // Whether a reply has gone out for this request yet. A failure after the
    // reply has started cannot be reported with a status -- the head is already
    // sent -- so the flag is what tells the failure path whether a 500 is still
    // possible.
    var answered = false;
    route(setup, registry, http, &request, &answered) catch |err| {
        std.log.err("cannot answer a request: {s}", .{@errorName(err)});
        // Nothing has been sent, so the browser can be told what happened
        // rather than only watching the connection drop.
        if (!answered) request.respond("billy: internal error\n", .{
            .status = .internal_server_error,
            .extra_headers = &.{ContentType.text.header()},
            .keep_alive = false,
        }) catch {};
    };
}

/// The routes there are. Everything else is a 404, so a request billy does not
/// understand is answered rather than left hanging.
///
/// `answered` is set once a reply for the request has begun, so the caller knows
/// whether a failure can still be turned into a status.
fn route(
    setup: *Setup,
    registry: *Registry,
    http: *std.http.Client,
    request: *std.http.Server.Request,
    answered: *bool,
) !void {
    // The path is the target up to a query, which none of these routes take.
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (request.head.method == .GET) {
        if (std.mem.eql(u8, path, "/")) {
            answered.* = true;
            return request.respond(page, .{
                .status = .ok,
                .extra_headers = &.{ContentType.html.header()},
                .keep_alive = false,
            });
        }
        if (std.mem.eql(u8, path, "/api/sessions")) return listSessions(setup, request, answered);
        if (std.mem.startsWith(u8, path, "/api/sessions/")) {
            const rest = path["/api/sessions/".len..];
            // `{id}/message` is a prompt, which is a POST; everything under the
            // id otherwise is the session itself.
            if (std.mem.endsWith(u8, rest, "/message")) {
                return reply(request, .text, "method not allowed\n", .method_not_allowed, answered);
            }
            return openSession(setup, request, rest, answered);
        }
    }
    if (request.head.method == .POST) {
        if (std.mem.eql(u8, path, "/api/sessions")) return createSession(setup, registry, http, request, answered);
        const prefix = "/api/sessions/";
        if (std.mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            if (std.mem.endsWith(u8, rest, "/message")) {
                const id = rest[0 .. rest.len - "/message".len];
                return askSession(setup, registry, http, request, id, answered);
            }
        }
    }

    if (request.head.method == .PATCH) {
        const prefix = "/api/sessions/";
        if (std.mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            if (rest.len > 0 and !std.mem.endsWith(u8, rest, "/message")) {
                return renameSession(setup, registry, request, rest, answered);
            }
        }
    }
    if (request.head.method == .DELETE) {
        const prefix = "/api/sessions/";
        if (std.mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            if (!std.mem.endsWith(u8, rest, "/message") and rest.len > 0) {
                return deleteSession(setup, registry, request, rest, answered);
            }
        }
    }

    answered.* = true;
    return request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{ContentType.text.header()},
        .keep_alive = false,
    });
}

/// `DELETE /api/sessions/{id}`: removes a session for good. There is no trash,
/// so this cannot be undone.
///
/// A session a turn is running for answers 409, since removing it under the turn
/// would leave the run writing to a file that is gone. An id with no file is a
/// 404, so deleting one twice says the second was nothing.
fn deleteSession(
    setup: *Setup,
    registry: *Registry,
    request: *std.http.Server.Request,
    id: []const u8,
    answered: *bool,
) !void {
    // Taken for the moment it takes to remove, so a turn cannot start against a
    // session that is being removed. Given back whether or not it is removed.
    if (!try registry.claim(id))
        return reply(request, .text, "the session is busy\n", .conflict, answered);
    defer registry.release(id);

    Session.delete(setup.io, setup.sessions, id) catch |err| switch (err) {
        error.InvalidSessionId => return reply(request, .text, "bad session id\n", .bad_request, answered),
        error.SessionNotFound => return reply(request, .text, "no such session\n", .not_found, answered),
        else => return err,
    };
    return reply(request, .text, "", .ok, answered);
}

/// The body a rename sends: the session's new name.
const Rename = struct { title: []const u8 };

/// `PATCH /api/sessions/{id}`: renames a session. The name is trimmed and cut the
/// way a model's title is (`Session.setTitle`), and written out at once, so the
/// list shows it. A session a turn is running for answers 409, since renaming it
/// would race the turn writing the same file.
fn renameSession(
    setup: *Setup,
    registry: *Registry,
    request: *std.http.Server.Request,
    id: []const u8,
    answered: *bool,
) !void {
    const gpa = setup.gpa;

    var body_buffer: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buffer);
    const body = body_reader.allocRemaining(gpa, .limited(1 << 16)) catch
        return reply(request, .text, "cannot read the title\n", .bad_request, answered);
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(Rename, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return reply(request, .text, "the title is not JSON\n", .bad_request, answered);
    defer parsed.deinit();
    // A title of nothing is refused rather than stored: a session with an empty
    // name reads as one that was never named.
    const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
    if (title.len == 0) return reply(request, .text, "the title is empty\n", .bad_request, answered);

    if (!try registry.claim(id))
        return reply(request, .text, "the session is busy\n", .conflict, answered);
    defer registry.release(id);

    var session = Session.open(setup.io, setup.sessions, gpa, id, setup.cwd) catch |err| switch (err) {
        error.InvalidSessionId => return reply(request, .text, "bad session id\n", .bad_request, answered),
        error.SessionNotFound => return reply(request, .text, "no such session\n", .not_found, answered),
        else => return err,
    };
    defer session.deinit();
    try session.setTitle(title);
    try session.save();
    return reply(request, .text, "", .ok, answered);
}

/// One session as the listing shows it: just its id, which is what names it.
const Listed = struct {
    id: []const u8,
    /// The session's title, shown in the list; "" for one that has not been named
    /// yet, which the page falls back to showing the id for.
    title: []const u8,
};

/// The body of `GET /api/sessions`: every session, in the order the page shows
/// them.
const Listing = struct { sessions: []const Listed };

/// `GET /api/sessions`: every session on disk, newest written first.
fn listSessions(setup: *Setup, request: *std.http.Server.Request, answered: *bool) !void {
    const gpa = setup.gpa;

    // What is on disk. Each id and title is its own allocation, freed once the
    // reply is built from them. The listing opens the directory itself, so a
    // listing here and one on another connection do not read over each other.
    const stored = try Session.list(setup.io, setup.sessions, gpa);
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
    return reply(request, .json, body.written(), .ok, answered);
}

/// One session's page: the header line above a conversation, and the
/// conversation itself, both as HTML for the page to put in whole.
const Opened = struct {
    header: []const u8,
    blocks: []const u8,
    /// The mode the session runs in, so the page can show it. It is fixed once
    /// the session has a conversation, which the page reads off `blocks`.
    mode: []const u8,
};

/// `GET /api/sessions/{id}`: a session as the page shows it.
///
/// A session with no file yet is one that has been started and not asked
/// anything, which is what a page should show: an empty conversation rather than
/// a failure. Any other missing id is a 404.
fn openSession(
    setup: *Setup,
    request: *std.http.Server.Request,
    id: []const u8,
    answered: *bool,
) !void {
    const gpa = setup.gpa;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const opened = writeSession(setup, gpa, id, &body.writer) catch |err| switch (err) {
        // An id that could not be a session name is a bad request, not a missing
        // session.
        error.InvalidSessionId => return reply(request, .text, "bad session id\n", .bad_request, answered),
        else => return err,
    };
    if (!opened) return reply(request, .text, "no such session\n", .not_found, answered);
    return reply(request, .json, body.written(), .ok, answered);
}

/// Writes the JSON a session's page is built from, and says whether the session
/// was there at all: false for an id that names no session and was never handed
/// out.
fn writeSession(
    setup: *Setup,
    gpa: std.mem.Allocator,
    id: []const u8,
    out: *std.Io.Writer,
) !bool {
    var session = Session.open(setup.io, setup.sessions, gpa, id, setup.cwd) catch |err| switch (err) {
        error.SessionNotFound => return false,
        else => return err,
    };
    defer session.deinit();

    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try html.header(.{
        .id = session.id(),
        .model = setup.model,
        .cwd = session.cwd(),
        .home = setup.environ.get("HOME"),
        .context_tokens = session.context_tokens,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .cost = session.cost,
    }, &header.writer);

    var blocks: std.Io.Writer.Allocating = .init(gpa);
    defer blocks.deinit();
    try html.conversation(gpa, &session, &blocks.writer);

    try writeOpened(out, header.written(), blocks.written(), @tagName(session.mode));
    return true;
}

/// Writes the two halves of a session's page as the JSON object the page reads.
fn writeOpened(out: *std.Io.Writer, header: []const u8, blocks: []const u8, session_mode: []const u8) !void {
    try std.json.Stringify.value(Opened{
        .header = header,
        .blocks = blocks,
        .mode = session_mode,
    }, .{}, out);
}

/// The mode a web session starts in, so a new one opens in ask unless the first
/// prompt says otherwise. The terminal keeps general as its own default.
const default_mode: agent.Mode = .chat;

/// What a reply is, so the browser is told how to read it.
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

/// Answers a request with `body`, and ends the connection. Marks the request
/// answered, so the caller knows a failure now cannot be reported with a status.
fn reply(
    request: *std.http.Server.Request,
    content_type: ContentType,
    body: []const u8,
    status: std.http.Status,
    answered: *bool,
) !void {
    answered.* = true;
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{content_type.header()},
        .keep_alive = false,
    });
}

test "a session is taken for a turn, and refused while one runs" {
    const gpa = std.testing.allocator;
    var registry = Registry{ .io = std.testing.io, .gpa = gpa };
    defer registry.deinit();

    // Free to begin with, so the first ask takes it.
    try std.testing.expect(try registry.claim("one"));
    // A second ask while the turn runs is refused rather than queued.
    try std.testing.expect(!try registry.claim("one"));
    // Another session is its own, so it is free.
    try std.testing.expect(try registry.claim("two"));

    // Giving one back frees only that one.
    registry.release("one");
    try std.testing.expect(try registry.claim("one"));
    try std.testing.expect(!try registry.claim("two"));
    registry.release("one");
    registry.release("two");

    // The keys were copied, so the id a claim was made with need not outlive it:
    // what is freed on release is the copy, not the caller's slice.
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

    // The two halves are HTML, so the quotes and newlines in them are escaped
    // into the JSON rather than ending the string early.
    try writeOpened(&out.writer, "<div class=\"header\">hi</div>\n", "<p>one</p>\n", "chat");
    try std.testing.expectEqualStrings(
        "{\"header\":\"<div class=\\\"header\\\">hi</div>\\n\",\"blocks\":\"<p>one</p>\\n\",\"mode\":\"chat\"}",
        out.written(),
    );
    // The page reads this back as the two strings it wrote, and the mode.
    const parsed = try std.json.parseFromSlice(Opened, gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("<div class=\"header\">hi</div>\n", parsed.value.header);
    try std.testing.expectEqualStrings("<p>one</p>\n", parsed.value.blocks);
    try std.testing.expectEqualStrings("chat", parsed.value.mode);
}

test "a parsed prompt is copied, so the body it came from can be freed" {
    const gpa = std.testing.allocator;

    // The body lives in a buffer that is overwritten after the parse, standing
    // in for the request body being freed. A borrowed string would follow the
    // overwrite and read as the overwrites; a copied one is unaffected.
    var buffer: [64]u8 = @splat(' ');
    const json = "{\"text\":\"hello\",\"mode\":\"chat\"}";
    @memcpy(buffer[0..json.len], json);

    const parsed = try parsePrompt(gpa, buffer[0..json.len]);
    defer parsed.deinit();
    @memset(buffer[0..json.len], 'x');

    try std.testing.expectEqualStrings("hello", parsed.value.text);
    try std.testing.expectEqual(agent.Mode.chat, parsed.value.mode.?);
}

test "the page the browser is given is the one that was written" {
    // The embedded page is served whole, so it is its own file and nothing is
    // built to serve it.
    try std.testing.expect(std.mem.indexOf(u8, page, "<!doctype html>") == 0);
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/sessions") != null);
}

test "an event leaves the stream as it is written, without filling a buffer" {
    const gpa = std.testing.allocator;

    // The body writer an event is written through, over a sink that keeps what
    // it is given. Only the protocol output is watched: an event that has been
    // flushed has reached it, and one still sitting in the body writer's buffer
    // has not.
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

    // A frame small enough to sit in the buffer whole, so it reaches the sink
    // only because the event is flushed. Without that flush it would wait there
    // until enough events filled the buffer, which is what made a page see them
    // in batches rather than as they happened.
    try stream.write("block", "{\"html\":\"<p>hi</p>\"}");
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "event: block") != null);

    // A second event reaches the sink too, each as a chunk of its own.
    try stream.write("done", "{}");
    try std.testing.expect(std.mem.count(u8, sink.written(), "event: ") == 2);
}

test "the address to listen on is read from what was asked for" {
    // An address is taken as itself, and the port carried through.
    const anywhere = try listenAddress("0.0.0.0", 8787);
    try std.testing.expect(anywhere.eql(&(try std.Io.net.IpAddress.parse("0.0.0.0", 8787))));

    // `localhost` is the one name taken, and it names loopback.
    const here = try listenAddress("localhost", 8787);
    try std.testing.expect(here.eql(&(try std.Io.net.IpAddress.parse("127.0.0.1", 8787))));

    // A v6 address, and a port of zero, which asks the system for a free one.
    const v6 = try listenAddress("::1", 0);
    try std.testing.expect(v6.eql(&(try std.Io.net.IpAddress.parse("::1", 0))));

    // A name billy does not resolve is refused rather than left to fail later.
    try std.testing.expectError(error.InvalidHost, listenAddress("example.com", 8787));
    try std.testing.expectError(error.InvalidHost, listenAddress("", 8787));
}

/// The prompt a page sends: what the user typed, and the mode the page chose for
/// a new session. `mode` is null for a session that already has a conversation,
/// whose mode is fixed on the session.
const Prompt = struct {
    text: []const u8,
    mode: ?agent.Mode = null,
};

/// Reads the prompt a POST carries, or replies with why it could not and returns
/// null, so the caller has nothing more to do.
fn readPrompt(gpa: std.mem.Allocator, request: *std.http.Server.Request, answered: *bool) !?std.json.Parsed(Prompt) {
    // The prompt is read first, so a request with nothing usable in it is
    // refused before a session is taken or made.
    var body_buffer: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buffer);
    const body = body_reader.allocRemaining(gpa, .limited(1 << 20)) catch {
        try reply(request, .text, "cannot read the prompt\n", .bad_request, answered);
        return null;
    };
    defer gpa.free(body);

    // The strings are copied out of `body`, which is freed on the way out, so
    // the value stands on its own.
    return parsePrompt(gpa, body) catch {
        try reply(request, .text, "the prompt is not JSON\n", .bad_request, answered);
        return null;
    };
}

/// Parses the prompt out of a request body. Every string is copied out of
/// `body`, so the value does not point into it and outlives it: a borrowed slice
/// would dangle once the body is freed.
fn parsePrompt(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(Prompt) {
    return std.json.parseFromSlice(Prompt, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// `POST /api/sessions`: starts a session with the page's first prompt and
/// answers with the run as it happens.
///
/// A new session has no id on the page until it is asked something, so the id it
/// is given here is the first event of the stream: that is how the page learns it
/// and adds the session to its list.
fn createSession(
    setup: *Setup,
    registry: *Registry,
    http: *std.http.Client,
    request: *std.http.Server.Request,
    answered: *bool,
) !void {
    const gpa = setup.gpa;
    const parsed = (try readPrompt(setup.gpa, request, answered)) orelse return;
    defer parsed.deinit();

    // A fresh session with a new id and no file: the first message writes it.
    var session = try Session.open(setup.io, setup.sessions, gpa, null, setup.cwd);
    defer session.deinit();
    if (!try registry.claim(session.id()))
        return reply(request, .text, "the session is busy\n", .conflict, answered);
    defer registry.release(session.id());

    // The mode the page chose, or a `/chat`/`/general` command in the prompt,
    // which wins over the choice.
    const choice = agent.Mode.start(parsed.value.text, parsed.value.mode orelse default_mode);
    if (choice.text.len == 0)
        return reply(request, .text, "the prompt is empty\n", .bad_request, answered);
    var config = setup.agentConfig(session.cwd(), .plain);
    config.mode = choice.mode;

    try serveTurn(setup, http, request, answered, &session, config, choice.text, session.id());
}

/// `POST /api/sessions/{id}/message`: asks the session `text`, answering with the
/// run as it happens.
///
/// A session a turn is already running for answers 409: one thing at a time.
fn askSession(
    setup: *Setup,
    registry: *Registry,
    http: *std.http.Client,
    request: *std.http.Server.Request,
    id: []const u8,
    answered: *bool,
) !void {
    const gpa = setup.gpa;
    const parsed = (try readPrompt(setup.gpa, request, answered)) orelse return;
    defer parsed.deinit();
    if (parsed.value.text.len == 0)
        return reply(request, .text, "the prompt is empty\n", .bad_request, answered);

    // Taken for the whole turn, and given back however the turn ends.
    if (!try registry.claim(id))
        return reply(request, .text, "the session is busy\n", .conflict, answered);
    defer registry.release(id);

    // The session is opened fresh for this turn and dropped at the end, so it is
    // always what is on disk; a session changed by another billy in between is
    // read rather than overwritten. It runs in the mode stored with it.
    var session = Session.open(setup.io, setup.sessions, gpa, id, setup.cwd) catch |err| switch (err) {
        error.SessionNotFound => return reply(request, .text, "no such session\n", .not_found, answered),
        else => return err,
    };
    defer session.deinit();

    try serveTurn(setup, http, request, answered, &session, setup.agentConfig(session.cwd(), .plain), parsed.value.text, null);
}

/// Answers one prompt as the run happens: the run's blocks as the events of a
/// stream, written and flushed one at a time rather than gathered, so a page sees
/// each block the moment it is done and a slow tool call start long before it
/// finishes.
///
/// A session created by this request has no id on the page yet, so its id is sent
/// as the first event, before anything else; `announce_id` is null for a session
/// the page already has.
fn serveTurn(
    setup: *Setup,
    http: *std.http.Client,
    request: *std.http.Server.Request,
    answered: *bool,
    session: *Session,
    config: agent.Config,
    text: []const u8,
    announce_id: ?[]const u8,
) !void {
    const gpa = setup.gpa;
    var runner = try Runner.init(setup.io, gpa, config, session.cwd(), http);
    defer runner.deinit();
    try runner.prepare(session);

    // The head of the reply goes out before the run starts, so the page can read
    // the stream while the model is working. From here on a failure is part of
    // the stream rather than something the connection can be told with a status.
    var stream_buffer: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .extra_headers = &.{ContentType.events.header()},
            .keep_alive = false,
        },
    });
    answered.* = true;
    defer body_writer.end() catch {};

    var stream = Stream{ .body = &body_writer, .gpa = gpa };
    const emitter = stream.emitter();

    // A `/compact` command folds the conversation into a summary and stops,
    // rather than being sent to the model. It comes before the session is
    // announced, so a `/compact` on a session that has nothing to fold leaves the
    // page with no new session to show.
    if (agent.Command.of(text)) |cmd| {
        switch (cmd) {
            .compact => if (!runner.compact(emitter, session)) try stream.fail("nothing to compact"),
        }
        try sendHeader(setup, gpa, session, &stream);
        try stream.done();
        return;
    }

    if (announce_id) |id| try stream.send("session", SessionEvent{ .id = id });

    // A session asked for the first time is named at once, from what was asked,
    // so the page's list shows a name before the model has answered; the model's
    // own title, if it gives one, arrives with the list the page refreshes when
    // the turn ends.
    if (session.messages.items.len == 0) {
        _ = try agent.nameFromPrompt(session, text);
        if (session.title()) |title| try stream.send("title", TitleEvent{ .title = title });
    }

    runner.compactIfNeeded(emitter, session);
    runner.ask(emitter, session, text) catch |err| {
        std.log.err("a request failed: {s}", .{@errorName(err)});
        try stream.fail(@errorName(err));
    };

    // What the run left the session at, so the page shows the new gauge and
    // cost, and knows the turn is over.
    try sendHeader(setup, gpa, session, &stream);
    try stream.done();
}

/// Sends the header line the page shows above a conversation: the session's state
/// now, so the gauge and cost are current.
fn sendHeader(setup: *Setup, gpa: std.mem.Allocator, session: *const Session, stream: *Stream) !void {
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try html.header(.{
        .id = session.id(),
        .model = setup.model,
        .cwd = session.cwd(),
        .home = setup.environ.get("HOME"),
        .context_tokens = session.context_tokens,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .cost = session.cost,
    }, &header.writer);
    try stream.send("header", HtmlEvent{ .html = header.written() });
}

/// The event a block and a header are sent as: the HTML of one piece of the
/// page, which the page puts in whole.
const HtmlEvent = struct { html: []const u8 };

/// What a failure is sent as, so the page can show why a turn stopped.
const FailedEvent = struct { message: []const u8 };

/// What a new title is sent as, once a session's first turn has named it, so the
/// page can show it in the list without asking for the list again.
const TitleEvent = struct { title: []const u8 };

/// What a new session's id is sent as, first, so the page can add it to the list.
const SessionEvent = struct { id: []const u8 };

/// Turns the blocks of a run into the events of a stream as they happen.
///
/// The events are written and flushed one at a time rather than gathered, which
/// is the whole point: a page sees each block the moment it is done, and sees a
/// slow tool call start long before it finishes.
const Stream = struct {
    body: *std.http.BodyWriter,
    gpa: std.mem.Allocator,

    fn emitter(self: *Stream) agent.Emitter {
        return .{ .context = self, .vtable = &.{ .block = show } };
    }

    fn show(context: *anyopaque, b: agent.Block) anyerror!void {
        const self: *Stream = @ptrCast(@alignCast(context));
        var rendered: std.Io.Writer.Allocating = .init(self.gpa);
        defer rendered.deinit();

        // Both halves of a tool call are whole elements on their own, so the page
        // can replace the call it is showing with the finished one. Everything
        // else is a single `block`.
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
    }

    /// Writes one event, and flushes it, so the page has it now.
    fn send(self: *Stream, event: []const u8, payload: anytype) !void {
        var data: std.Io.Writer.Allocating = .init(self.gpa);
        defer data.deinit();
        try std.json.Stringify.value(payload, .{}, &data.writer);
        try self.write(event, data.written());
    }

    /// Writes one event frame: its name, its data on one line, and the blank
    /// line that ends it. The data is JSON, which never holds a newline, so a
    /// frame is always what it should be.
    ///
    /// The two flushes are both needed and are in this order. The body writer
    /// gathers what is written to it in a buffer of its own, and only pushes that
    /// into `http_protocol_output` when it is flushed or full; `BodyWriter.flush`
    /// flushes `http_protocol_output` and *not* that buffer. Flushing the buffer
    /// first sends this event into the protocol output, and flushing the body
    /// then sends it down the socket. Without the first, an event sits in the
    /// buffer until enough of them fill it, so a page sees them in batches rather
    /// than as they happen.
    fn write(self: *Stream, event: []const u8, data: []const u8) !void {
        try self.body.writer.print("event: {s}\ndata: {s}\n\n", .{ event, data });
        try self.body.writer.flush();
        try self.body.flush();
    }
};

/// A `Setup` over a temporary directory, for a test that drives a route.
///
/// The real one reads the environment, the configuration file and the
/// credentials; a route needs none of that, only somewhere to keep sessions and
/// a model to name. What it does not read is left empty, and nothing in the
/// routes reaches for it.
const TestServer = struct {
    setup: Setup,
    tmp: std.testing.TmpDir,
    /// The configuration the setup points at, freed with it.
    settings: Config,
    /// The environment the setup reads, which a route asks for `HOME`. It is
    /// held by pointer and allocated, so the address the setup was given stays
    /// the map's when this value is moved out of `init`.
    environ: *std.process.Environ.Map,
    /// Which search backends are set aside, so the search settings the setup
    /// carries point at a table that is really there.
    health: Health,
    /// What the server knows beyond the session files, and the client its routes
    /// borrow, which outlive every request made through this.
    registry: Registry,
    http: std.http.Client,

    fn init() !TestServer {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const sessions = try tmp.dir.createDirPathOpen(std.testing.io, "sessions", .{});
        const settings = Config.init(gpa);
        const environ = try gpa.create(std.process.Environ.Map);
        errdefer gpa.destroy(environ);
        environ.* = .init(gpa);
        errdefer environ.deinit();
        try environ.put("HOME", "/home/tester");
        const health = try Health.load(std.testing.io, gpa, tmp.dir);
        errdefer health.deinit();
        return .{
            .tmp = tmp,
            .settings = settings,
            .environ = environ,
            .health = health,
            .registry = .{ .io = std.testing.io, .gpa = gpa },
            .http = .{ .allocator = gpa, .io = std.testing.io },
            .setup = .{
                .io = std.testing.io,
                .gpa = gpa,
                .environ = environ,
                .settings = settings,
                .sessions = sessions,
                .data_dir = tmp.dir,
                .config_dir = tmp.dir,
                .cwd = ".",
                .api_key = "k",
                .base_url = "https://api.deepseek.com",
                .url = "https://api.deepseek.com/chat/completions",
                .model = "m",
                .search = null,
                .health = health,
            },
        };
    }

    fn deinit(server: *TestServer) void {
        server.http.deinit();
        server.registry.deinit();
        server.health.deinit();
        server.setup.sessions.close(std.testing.io);
        server.settings.deinit();
        server.environ.deinit();
        std.testing.allocator.destroy(server.environ);
        server.tmp.cleanup();
    }

    /// Answers `method path` with `body`, through the real `route`.
    fn exchange(server: *TestServer, method: std.http.Method, path: []const u8, body: ?[]const u8) !Exchange {
        return Exchange.run(&server.setup, &server.registry, &server.http, method, path, body);
    }

    /// A session holding one prompt and its reply, written to disk and named as
    /// `title` when there is one, so a route has something to serve. Its id is
    /// returned, owned by the caller.
    fn session(server: *TestServer, title: ?[]const u8) ![]const u8 {
        var opened = try Session.open(std.testing.io, server.setup.sessions, std.testing.allocator, null, ".");
        defer opened.deinit();
        if (title) |name| try opened.setTitle(name);
        try opened.append(.{ .role = "user", .content = "hello" });
        try opened.save();
        return std.testing.allocator.dupe(u8, opened.id());
    }
};

/// The path a session's route is asked for, owned by the caller.
fn sessionPath(id: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(std.testing.allocator, "/api/sessions/{s}{s}", .{ id, suffix });
}

/// One request through the real `route`, answered into `out`.
///
/// The request is written as HTTP and read back by a real `std.http.Server`, so
/// what is tested is the dispatcher and the handlers as they run, not a stand-in
/// for them: the target, the method and the body all take the path they take in
/// a served connection. Nothing is allocated for the answer's own buffers, so a
/// test sees the bytes the socket would have carried.
const Exchange = struct {
    /// What the connection would have written: the status line, the headers and
    /// the body.
    written: std.Io.Writer.Allocating,
    /// Whether a reply had begun, as `handle` tracks it.
    answered: bool = false,

    /// Answers `method path` with `body`, exactly as the server would.
    fn run(
        setup: *Setup,
        registry: *Registry,
        http: *std.http.Client,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !Exchange {
        const gpa = std.testing.allocator;
        var exchange: Exchange = .{ .written = .init(gpa) };
        errdefer exchange.written.deinit();

        const request_text = if (body) |payload|
            try std.fmt.allocPrint(gpa, "{s} {s} HTTP/1.1\r\nhost: billy\r\ncontent-type: application/json\r\n" ++
                "content-length: {d}\r\n\r\n{s}", .{ @tagName(method), path, payload.len, payload })
        else
            try std.fmt.allocPrint(gpa, "{s} {s} HTTP/1.1\r\nhost: billy\r\n\r\n", .{ @tagName(method), path });
        defer gpa.free(request_text);

        var in_buffer: [4096]u8 = undefined;
        if (request_text.len > in_buffer.len) return error.RequestTooLong;
        @memcpy(in_buffer[0..request_text.len], request_text);
        var reader = std.Io.Reader.fixed(in_buffer[0..request_text.len]);

        // Room for the largest answer a route writes, which is the page itself.
        var out_buffer: [128 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buffer);

        var server: std.http.Server = .init(&reader, &writer);
        var request = try server.receiveHead();
        try route(setup, registry, http, &request, &exchange.answered);
        try exchange.written.writer.writeAll(writer.buffered());
        return exchange;
    }

    fn deinit(exchange: *Exchange) void {
        exchange.written.deinit();
    }

    /// What the answer began with, such as `200 OK`, or the method and target
    /// when the answer is the one `route` writes for a request it does not know.
    fn statusLine(exchange: *Exchange) []const u8 {
        const text = exchange.written.written();
        const end = std.mem.indexOf(u8, text, "\r\n") orelse text.len;
        return text[0..end];
    }

    fn contains(exchange: *Exchange, needle: []const u8) bool {
        return std.mem.indexOf(u8, exchange.written.written(), needle) != null;
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
    // The answer is the embedded page and nothing else, so what is served is
    // the file `index.html` holds rather than something built to look like it.
    try std.testing.expect(exchange.contains(page));
}

test "the session list is read from disk, newest first" {
    var server = try TestServer.init();
    defer server.deinit();

    // Nothing on disk is an empty list rather than a failure, since a fresh
    // billy has no sessions at all.
    var empty = try server.exchange(.GET, "/api/sessions", null);
    defer empty.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", empty.statusLine());
    try std.testing.expect(empty.contains("{\"sessions\":[]}"));

    // A session written to disk is listed by its id and title.
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
    // The three things the page reads: the header, the blocks, and the mode.
    try std.testing.expect(opened.contains("\"header\":"));
    try std.testing.expect(opened.contains("\"blocks\":"));
    try std.testing.expect(opened.contains("\"mode\":"));
    // The conversation is in the blocks, as the page shows it.
    try std.testing.expect(opened.contains("hello"));
}

test "an id with no session is a 404, and one that is not an id is a 400" {
    var server = try TestServer.init();
    defer server.deinit();

    // An id of the right shape with no file behind it.
    var missing = try server.exchange(.GET, "/api/sessions/01M3AAAAAAAAAAAAAAAAAAAAAA", null);
    defer missing.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found", missing.statusLine());

    // Something that could never be an id is refused as a bad request rather
    // than looked for, so it cannot be turned into a path.
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

    // The new name is on disk, not only in the answer.
    var reread = try Session.open(std.testing.io, server.setup.sessions, std.testing.allocator, id, ".");
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

    // Whitespace is not a title: a session named " " would read as one that was
    // never named, which is what the list falls back to the id for.
    var blank = try server.exchange(.PATCH, path, "{\"title\":\"   \"}");
    defer blank.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", blank.statusLine());

    // Body that is not JSON at all.
    var not_json = try server.exchange(.PATCH, path, "not json");
    defer not_json.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", not_json.statusLine());

    // And the session is left unnamed rather than holding either of them.
    var reread = try Session.open(std.testing.io, server.setup.sessions, std.testing.allocator, id, ".");
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

    // Gone from disk, so nothing can be opened by that id again.
    try std.testing.expectError(error.SessionNotFound, Session.open(
        std.testing.io,
        server.setup.sessions,
        std.testing.allocator,
        id,
        ".",
    ));

    // A second delete finds nothing to remove, which is a 404 rather than a
    // failure: the session is gone either way.
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

    // An empty prompt is refused before anything is opened or taken, so a
    // request that asks nothing cannot start a turn.
    var empty = try server.exchange(.POST, path, "{\"text\":\"\"}");
    defer empty.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", empty.statusLine());

    // A session a turn is running for answers 409 rather than running a second
    // one over the top of it. The claim stands in for the turn here.
    try std.testing.expect(try server.registry.claim(id));
    defer server.registry.release(id);
    var busy = try server.exchange(.POST, path, "{\"text\":\"do something\"}");
    defer busy.deinit();
    try std.testing.expectEqualStrings("HTTP/1.1 409 Conflict", busy.statusLine());
}
