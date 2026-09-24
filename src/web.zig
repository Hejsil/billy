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
const Io = std.Io;
const agent = @import("agent.zig");
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
pub fn serve(setup: *Setup, out: *Io.Writer, host: []const u8, port: u16) !void {
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
    var group: Io.Group = .init;
    defer group.cancel(setup.io);

    // At most `max_connections` are served at once. A permit is taken before a
    // connection is accepted, so one that arrives while the server is full waits
    // in the socket's backlog rather than being given a task of its own; the
    // permit is given back when the connection is answered and its task ends.
    var slots: Io.Semaphore = .{ .permits = max_connections };
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
fn listenAddress(host: []const u8, port: u16) !Io.net.IpAddress {
    if (std.mem.eql(u8, host, "localhost")) return .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    // What was asked for that is not an address comes back as one error, since
    // what billy does not do is resolve a name; the caller says so.
    return Io.net.IpAddress.parse(host, port) catch error.InvalidHost;
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
    io: Io,
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// The ids of sessions handed out but not written yet, oldest first.
    reserved: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The ids of sessions a turn is running for right now, each with the id
    /// that names it owned as the key. A session can only be asked one thing at
    /// a time, so a second ask while one runs is refused.
    busy: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(registry: *Registry) void {
        for (registry.reserved.items) |id| registry.gpa.free(id);
        registry.reserved.deinit(registry.gpa);
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

    /// Records `id` as a session that has been handed out and has no file yet.
    fn reserve(registry: *Registry, id: []const u8) !void {
        const owned = try registry.gpa.dupe(u8, id);
        errdefer registry.gpa.free(owned);

        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);
        try registry.reserved.append(registry.gpa, owned);
    }

    /// Whether `id` is one handed out but not written yet.
    fn isReserved(registry: *Registry, id: []const u8) bool {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);
        for (registry.reserved.items) |held| {
            if (std.mem.eql(u8, held, id)) return true;
        }
        return false;
    }

    /// Adds the reserved ids that have no file yet to `sessions`, oldest first,
    /// and forgets the ones that do.
    ///
    /// A session that has been asked something is written out, so it is listed
    /// from disk like every other; keeping it reserved as well would list it
    /// twice. Forgetting it is also what keeps the reserved list from growing
    /// without bound as sessions are started.
    ///
    /// The ids are borrowed, which is safe because a reserved id is never freed
    /// while it is listed and the lock is held for the walk.
    fn takeReserved(
        registry: *Registry,
        dir: Io.Dir,
        io: Io,
        sessions: *std.ArrayList(Listed),
        gpa: std.mem.Allocator,
    ) !void {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);

        var index: usize = 0;
        while (index < registry.reserved.items.len) {
            const id = registry.reserved.items[index];
            if (Session.exists(dir, io, id)) {
                // Written out, so it is listed from disk and no longer reserved.
                registry.gpa.free(id);
                _ = registry.reserved.orderedRemove(index);
                continue;
            }
            // Handed out but not written, so it has no file and no title.
            try sessions.append(gpa, .{ .id = id, .title = "" });
            index += 1;
        }
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
    stream: Io.net.Stream,
    slots: *Io.Semaphore,
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
        if (std.mem.eql(u8, path, "/api/sessions")) return listSessions(setup, registry, request, answered);
        if (std.mem.startsWith(u8, path, "/api/sessions/")) {
            const rest = path["/api/sessions/".len..];
            // `{id}/message` is a prompt, which is a POST; everything under the
            // id otherwise is the session itself.
            if (std.mem.endsWith(u8, rest, "/message")) {
                return reply(request, .text, "method not allowed\n", .method_not_allowed, answered);
            }
            return openSession(setup, registry, request, rest, answered);
        }
    }
    if (request.head.method == .POST) {
        if (std.mem.eql(u8, path, "/api/sessions")) return startSession(setup, registry, request, answered);
        const prefix = "/api/sessions/";
        if (std.mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            if (std.mem.endsWith(u8, rest, "/message")) {
                const id = rest[0 .. rest.len - "/message".len];
                return askSession(setup, registry, http, request, id, answered);
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

/// `GET /api/sessions`: every session, the ones started but not written yet
/// first, then the ones on disk, newest written first.
fn listSessions(setup: *Setup, registry: *Registry, request: *std.http.Server.Request, answered: *bool) !void {
    const gpa = setup.gpa;

    // What is on disk. Each id and title is its own allocation, freed once the
    // reply is built from them. The listing opens the directory itself, so a
    // listing here and one on another connection do not read over each other.
    const stored = try Session.list(setup.io, setup.sessions_path, gpa);
    defer {
        for (stored) |named| {
            gpa.free(named.id);
            gpa.free(named.title);
        }
        gpa.free(stored);
    }

    var sessions: std.ArrayList(Listed) = .empty;
    defer sessions.deinit(gpa);
    try registry.takeReserved(setup.sessions, setup.io, &sessions, gpa);
    for (stored) |named| try sessions.append(gpa, .{ .id = named.id, .title = named.title });

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listing{ .sessions = sessions.items }, .{}, &body.writer);
    return reply(request, .json, body.written(), .ok, answered);
}

/// One session's page: the header line above a conversation, and the
/// conversation itself, both as HTML for the page to put in whole.
const Opened = struct { header: []const u8, blocks: []const u8 };

/// `GET /api/sessions/{id}`: a session as the page shows it.
///
/// A session with no file yet is one that has been started and not asked
/// anything, which is what a page should show: an empty conversation rather than
/// a failure. Any other missing id is a 404.
fn openSession(
    setup: *Setup,
    registry: *Registry,
    request: *std.http.Server.Request,
    id: []const u8,
    answered: *bool,
) !void {
    const gpa = setup.gpa;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const opened = writeSession(setup, registry, gpa, id, &body.writer) catch |err| switch (err) {
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
    registry: *Registry,
    gpa: std.mem.Allocator,
    id: []const u8,
    out: *Io.Writer,
) !bool {
    var session = Session.open(setup.io, setup.sessions, gpa, id, setup.cwd) catch |err| switch (err) {
        error.SessionNotFound => {
            // A session started but not yet written has no file to open; it is
            // an empty conversation with a header, not a missing page.
            if (!registry.isReserved(id)) return false;
            try writeEmpty(gpa, setup, id, out);
            return true;
        },
        else => return err,
    };
    defer session.deinit();

    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try html.header(.{
        .id = session.id(),
        .model = setup.model,
        .cwd = session.cwd,
        .home = setup.environ.get("HOME"),
        .context_tokens = session.context_tokens,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .cost = session.cost,
    }, &header.writer);

    var blocks: std.Io.Writer.Allocating = .init(gpa);
    defer blocks.deinit();
    try html.conversation(gpa, &session, &blocks.writer);

    try writeOpened(out, header.written(), blocks.written());
    return true;
}

/// Writes the page of a session that has no file yet: what it will be, with
/// nothing in it and nothing spent.
fn writeEmpty(gpa: std.mem.Allocator, setup: *Setup, id: []const u8, out: *Io.Writer) !void {
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try html.header(.{
        .id = id,
        .model = setup.model,
        .cwd = setup.cwd,
        .home = setup.environ.get("HOME"),
        .context_tokens = 0,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .cost = 0,
    }, &header.writer);

    try writeOpened(out, header.written(), "");
}

/// Writes the two halves of a session's page as the JSON object the page reads.
fn writeOpened(out: *Io.Writer, header: []const u8, blocks: []const u8) !void {
    try std.json.Stringify.value(Opened{ .header = header, .blocks = blocks }, .{}, out);
}

/// `POST /api/sessions`: hands out the id of a session that does not exist yet.
///
/// Nothing is written. The id is what the page opens, and the session comes into
/// being when it is first asked something.
fn startSession(setup: *Setup, registry: *Registry, request: *std.http.Server.Request, answered: *bool) !void {
    const gpa = setup.gpa;

    // Opening a session that is not resumed gives it a fresh id and writes
    // nothing, which is exactly the id wanted here.
    var fresh = try Session.open(setup.io, setup.sessions, gpa, null, setup.cwd);
    defer fresh.deinit();
    const id = try gpa.dupe(u8, fresh.id());
    defer gpa.free(id);
    try registry.reserve(id);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listed{ .id = id, .title = "" }, .{}, &body.writer);
    return reply(request, .json, body.written(), .created, answered);
}

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

test "a session that is handed out is listed before it is written" {
    const gpa = std.testing.allocator;
    var registry = Registry{ .io = std.testing.io, .gpa = gpa };
    defer registry.deinit();

    try std.testing.expect(!registry.isReserved("later"));
    try registry.reserve("later");
    try std.testing.expect(registry.isReserved("later"));
    try std.testing.expect(!registry.isReserved("later still"));

    // A reserved id reaches the listing, in the order it was handed out, and
    // before what is already on disk.
    var sessions: std.ArrayList(Listed) = .empty;
    defer sessions.deinit(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try registry.takeReserved(tmp.dir, std.testing.io, &sessions, gpa);
    try sessions.append(gpa, .{ .id = "on-disk", .title = "" });

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listing{ .sessions = sessions.items }, .{}, &body.writer);
    try std.testing.expectEqualStrings(
        "{\"sessions\":[{\"id\":\"later\",\"title\":\"\"},{\"id\":\"on-disk\",\"title\":\"\"}]}",
        body.written(),
    );
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
    try writeOpened(&out.writer, "<div class=\"header\">hi</div>\n", "<p>one</p>\n");
    try std.testing.expectEqualStrings(
        "{\"header\":\"<div class=\\\"header\\\">hi</div>\\n\",\"blocks\":\"<p>one</p>\\n\"}",
        out.written(),
    );
    // The page reads this back as the two strings it wrote.
    const parsed = try std.json.parseFromSlice(Opened, gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("<div class=\"header\">hi</div>\n", parsed.value.header);
    try std.testing.expectEqualStrings("<p>one</p>\n", parsed.value.blocks);
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
    try std.testing.expect(anywhere.eql(&(try Io.net.IpAddress.parse("0.0.0.0", 8787))));

    // `localhost` is the one name taken, and it names loopback.
    const here = try listenAddress("localhost", 8787);
    try std.testing.expect(here.eql(&(try Io.net.IpAddress.parse("127.0.0.1", 8787))));

    // A v6 address, and a port of zero, which asks the system for a free one.
    const v6 = try listenAddress("::1", 0);
    try std.testing.expect(v6.eql(&(try Io.net.IpAddress.parse("::1", 0))));

    // A name billy does not resolve is refused rather than left to fail later.
    try std.testing.expectError(error.InvalidHost, listenAddress("example.com", 8787));
    try std.testing.expectError(error.InvalidHost, listenAddress("", 8787));
}

/// The prompt a page sends: what the user typed.
const Prompt = struct { text: []const u8 };

/// `POST /api/sessions/{id}/message`: asks the session `text`, answering with the
/// run as it happens.
///
/// The answer is `text/event-stream`, one event per thing the run shows: a
/// `block` for each finished block (a prompt, a reply, a line billy writes), a
/// `tool_begin` and `tool_end` for the two halves of a tool call, a `header` with
/// the new gauge and cost, an `error` when the run fails, and `done` at the end.
/// Each is written and flushed as it happens, so the page fills in while the
/// model works rather than after it has finished.
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

    // The prompt is read first, so a request with nothing usable in it is
    // refused before the session is taken.
    var body_buffer: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buffer);
    const body = body_reader.allocRemaining(gpa, .limited(1 << 20)) catch
        return reply(request, .text, "cannot read the prompt\n", .bad_request, answered);
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(Prompt, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return reply(request, .text, "the prompt is not JSON\n", .bad_request, answered);
    defer parsed.deinit();
    if (parsed.value.text.len == 0)
        return reply(request, .text, "the prompt is empty\n", .bad_request, answered);

    // Taken for the whole turn, and given back however the turn ends.
    if (!try registry.claim(id))
        return reply(request, .text, "the session is busy\n", .conflict, answered);
    defer registry.release(id);

    // The session is opened fresh for this turn and dropped at the end, so it is
    // always what is on disk; a session changed by another billy in between is
    // read rather than overwritten. A session started but not written yet has no
    // file, which is not an error: opening it here is what writes it.
    var session = Session.open(setup.io, setup.sessions, gpa, id, setup.cwd) catch |err| switch (err) {
        error.SessionNotFound => if (!registry.isReserved(id))
            return reply(request, .text, "no such session\n", .not_found, answered)
        else
            try Session.create(setup.io, setup.sessions, gpa, id, setup.cwd),
        else => return err,
    };
    defer session.deinit();

    var runner = try Runner.init(setup.io, gpa, setup.agentConfig(session.cwd, .plain), session.cwd, http);
    defer runner.deinit();
    try runner.prepare(&session);

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

    // A session asked for the first time is named during the turn (see
    // `Runner.ask`), so the page is told the title afterwards to put in its list.
    const first_turn = session.messages.items.len == 0;

    runner.compactIfNeeded(emitter, &session);
    runner.ask(emitter, &session, parsed.value.text) catch |err| {
        std.log.err("a request failed: {s}", .{@errorName(err)});
        try stream.fail(@errorName(err));
    };

    // The title, when the session was just named, so the page's list picks it up.
    if (first_turn) if (session.title()) |title| {
        try stream.send("title", TitleEvent{ .title = title });
    };

    // What the run left the session at, so the page shows the new gauge and
    // cost, and knows the turn is over.
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try html.header(.{
        .id = session.id(),
        .model = setup.model,
        .cwd = session.cwd,
        .home = setup.environ.get("HOME"),
        .context_tokens = session.context_tokens,
        .model_info = models.lookup(models.Provider.fromUrl(setup.base_url), setup.model),
        .cost = session.cost,
    }, &header.writer);
    try stream.send("header", HtmlEvent{ .html = header.written() });
    try stream.done();
}

/// The event a block and a header are sent as: the HTML of one piece of the
/// page, which the page puts in whole.
const HtmlEvent = struct { html: []const u8 };

/// What a failure is sent as, so the page can show why a turn stopped.
const FailedEvent = struct { message: []const u8 };

/// What a new title is sent as, once a session's first turn has named it, so the
/// page can show it in the list without asking for the list again.
const TitleEvent = struct { title: []const u8 };

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
