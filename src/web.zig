//! The web frontend: billy served over HTTP instead of in a terminal.
//!
//! The server binds the loopback address only, so it is reachable from this
//! machine and not from the network. Every connection is handled on its own task,
//! so a slow request does not hold up the rest, and a connection that cannot be
//! served is closed rather than taking the server down with it.
//!
//! What a route answers with is rendered here but built by `html.zig` and read
//! out of a session, so the page shows the same blocks the terminal does. Every
//! string that comes from outside billy passes through `html.escape`, so nothing
//! a model, a file or a request writes can become markup.
//!
//! Nothing is authenticated. Any process on this machine, and any page the
//! browser loads, can reach these routes, and the routes can run commands as the
//! user. That is accepted for now; it is why the address is loopback and not
//! something routable.

const std = @import("std");
const Io = std.Io;
const agent = @import("agent.zig");
const html = @import("html.zig");
const models = @import("models.zig");
const Session = @import("Session.zig");
const Setup = @import("Setup.zig");

/// The port billy serves on when nothing else is asked for.
pub const default_port = 8787;

/// The page the browser is given at `/`: one file, with its styles and its
/// script in it, so the server serves it as it is and there is nothing to build.
const page = @embedFile("web/index.html");

/// Serves the frontend on the loopback address at `port`, until the process is
/// stopped. Zero asks the system for a free port, which is what a test uses.
///
/// The URL is printed once the socket is bound, so what is printed is the port
/// that was actually taken, and not the one that was asked for.
pub fn serve(setup: *Setup, out: *Io.Writer, port: u16) !void {
    var address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(setup.io, .{ .reuse_address = true });
    defer listener.deinit(setup.io);

    // What the server knows about sessions beyond their files. It outlives every
    // connection, which is why it is here and not in the handler.
    var registry = Registry{ .io = setup.io, .gpa = setup.gpa };
    defer registry.deinit();

    try out.print("billy serve is listening on http://127.0.0.1:{d}/\n", .{
        listener.socket.address.getPort(),
    });
    try out.flush();

    // One task per connection, gathered so that they are all cancelled when the
    // loop ends, as they all share the listener's lifetime.
    var group: Io.Group = .init;
    defer group.cancel(setup.io);
    while (true) {
        const stream = listener.accept(setup.io) catch |err| switch (err) {
            error.Canceled => return err,
            else => |other| return other,
        };
        group.concurrent(setup.io, handle, .{ setup, &registry, stream }) catch |err| {
            // A connection that cannot be given a task is one to let go of,
            // rather than one to bring the server down over.
            std.log.err("cannot serve a connection: {s}", .{@errorName(err)});
            var copy = stream;
            copy.close(setup.io);
            continue;
        };
    }
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

    fn deinit(registry: *Registry) void {
        for (registry.reserved.items) |id| registry.gpa.free(id);
        registry.reserved.deinit(registry.gpa);
    }

    /// Records `id` as a session that has been handed out and has no file yet.
    fn reserve(registry: *Registry, id: []const u8) !void {
        const owned = try registry.gpa.dupe(u8, id);
        errdefer registry.gpa.free(owned);

        try registry.mutex.lock(registry.io);
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

    /// Adds the reserved ids to `sessions`, oldest first. The ids are borrowed,
    /// which is safe because a reserved id is never freed while the server runs;
    /// the lock is held for the walk, so the list cannot move under it.
    fn appendReserved(registry: *Registry, sessions: *std.ArrayList(Listed), gpa: std.mem.Allocator) !void {
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);
        for (registry.reserved.items) |id| try sessions.append(gpa, .{ .id = id });
    }
};

/// Answers one connection, and closes it. Nothing a request or a reply does is
/// allowed to reach the caller: a connection that goes wrong is logged and
/// dropped, since the server outlives it.
fn handle(setup: *Setup, registry: *Registry, stream: Io.net.Stream) void {
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
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = server.receiveHead() catch return;
    route(setup, registry, &request) catch |err| {
        std.log.err("cannot answer a request: {s}", .{@errorName(err)});
    };
}

/// The routes there are. Everything else is a 404, so a request billy does not
/// understand is answered rather than left hanging.
fn route(setup: *Setup, registry: *Registry, request: *std.http.Server.Request) !void {
    // The path is the target up to a query, which none of these routes take.
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (request.head.method == .GET) {
        if (std.mem.eql(u8, path, "/")) return request.respond(page, .{
            .status = .ok,
            .extra_headers = &.{ContentType.html.header()},
            .keep_alive = false,
        });
        if (std.mem.eql(u8, path, "/api/sessions")) return listSessions(setup, registry, request);
        if (std.mem.startsWith(u8, path, "/api/sessions/"))
            return openSession(setup, registry, request, path["/api/sessions/".len..]);
    }
    if (request.head.method == .POST and std.mem.eql(u8, path, "/api/sessions"))
        return startSession(setup, registry, request);

    return request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{ContentType.text.header()},
        .keep_alive = false,
    });
}

/// One session as the listing shows it: just its id, which is what names it.
const Listed = struct { id: []const u8 };

/// The body of `GET /api/sessions`: every session, in the order the page shows
/// them.
const Listing = struct { sessions: []const Listed };

/// `GET /api/sessions`: every session, the ones started but not written yet
/// first, then the ones on disk, newest written first.
fn listSessions(setup: *Setup, registry: *Registry, request: *std.http.Server.Request) !void {
    const gpa = setup.gpa;

    // What is on disk. Each id is its own allocation, freed once the reply is
    // built from them.
    const stored = try Session.list(setup.sessions, setup.io, gpa);
    defer {
        for (stored) |id| gpa.free(id);
        gpa.free(stored);
    }

    var sessions: std.ArrayList(Listed) = .empty;
    defer sessions.deinit(gpa);
    try registry.appendReserved(&sessions, gpa);
    for (stored) |id| try sessions.append(gpa, .{ .id = id });

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listing{ .sessions = sessions.items }, .{}, &body.writer);
    return reply(request, .json, body.written(), .ok);
}

/// One session's page: the header line above a conversation, and the
/// conversation itself, both as HTML for the page to put in whole.
const Opened = struct { header: []const u8, blocks: []const u8 };

/// `GET /api/sessions/{id}`: a session as the page shows it.
///
/// A session with no file yet is one that has been started and not asked
/// anything, which is what a page should show: an empty conversation rather than
/// a failure. Any other missing id is a 404.
fn openSession(setup: *Setup, registry: *Registry, request: *std.http.Server.Request, id: []const u8) !void {
    const gpa = setup.gpa;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const opened = writeSession(setup, registry, gpa, id, &body.writer) catch |err| switch (err) {
        // An id that could not be a session name is a bad request, not a missing
        // session.
        error.InvalidSessionId => return reply(request, .text, "bad session id\n", .bad_request),
        else => return err,
    };
    if (!opened) return reply(request, .text, "no such session\n", .not_found);
    return reply(request, .json, body.written(), .ok);
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
fn startSession(setup: *Setup, registry: *Registry, request: *std.http.Server.Request) !void {
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
    try std.json.Stringify.value(Listed{ .id = id }, .{}, &body.writer);
    return reply(request, .json, body.written(), .created);
}

/// What a reply is, so the browser is told how to read it.
const ContentType = enum {
    html,
    json,
    text,

    fn header(content_type: ContentType) std.http.Header {
        return .{
            .name = "content-type",
            .value = switch (content_type) {
                .html => "text/html; charset=utf-8",
                .json => "application/json; charset=utf-8",
                .text => "text/plain; charset=utf-8",
            },
        };
    }
};

/// Answers a request with `body`, and ends the connection.
fn reply(
    request: *std.http.Server.Request,
    content_type: ContentType,
    body: []const u8,
    status: std.http.Status,
) !void {
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
    try registry.appendReserved(&sessions, gpa);
    try sessions.append(gpa, .{ .id = "on-disk" });

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.json.Stringify.value(Listing{ .sessions = sessions.items }, .{}, &body.writer);
    try std.testing.expectEqualStrings(
        "{\"sessions\":[{\"id\":\"later\"},{\"id\":\"on-disk\"}]}",
        body.written(),
    );
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
