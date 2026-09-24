//! The web frontend: billy served over HTTP instead of in a terminal.
//!
//! The server binds the loopback address only, so it is reachable from this
//! machine and not from the network. Every connection is handled on its own task,
//! so a slow request does not hold up the rest, and a connection that cannot be
//! served is closed rather than taking the server down with it.
//!
//! Nothing is authenticated. Any process on this machine, and any page the
//! browser loads, can reach these routes, and the routes can run commands as the
//! user. That is accepted for now; it is why the address is loopback and not
//! something routable.

const std = @import("std");
const Io = std.Io;
const Setup = @import("Setup.zig");

/// The port billy serves on when nothing else is asked for.
pub const default_port = 8787;

/// The page the browser is given at `/`. It is a placeholder until the frontend
/// is written, and says so rather than failing.
const placeholder_page =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>billy</title>
    \\</head>
    \\<body>
    \\<h1>billy</h1>
    \\<p>The server is running. The frontend is not written yet.</p>
    \\</body>
    \\</html>
    \\
;

/// Serves the frontend on the loopback address at `port`, until the process is
/// stopped. Zero asks the system for a free port, which is what a test uses.
///
/// The URL is printed once the socket is bound, so what is printed is the port
/// that was actually taken, and not the one that was asked for.
pub fn serve(setup: *Setup, out: *Io.Writer, port: u16) !void {
    var address = try Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(setup.io, .{ .reuse_address = true });
    defer listener.deinit(setup.io);

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
        group.concurrent(setup.io, handle, .{ setup, stream }) catch |err| {
            // A connection that cannot be given a task is one to let go of,
            // rather than one to bring the server down over.
            std.log.err("cannot serve a connection: {s}", .{@errorName(err)});
            var copy = stream;
            copy.close(setup.io);
            continue;
        };
    }
}

/// Answers one connection, and closes it. Nothing a request or a reply does is
/// allowed to reach the caller: a connection that goes wrong is logged and
/// dropped, since the server outlives it.
fn handle(setup: *Setup, stream: Io.net.Stream) void {
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
    route(setup, &request) catch |err| {
        std.log.err("cannot answer a request: {s}", .{@errorName(err)});
    };
}

/// The routes there are. Everything else is a 404, so a request billy does not
/// understand is answered rather than left hanging.
fn route(setup: *Setup, request: *std.http.Server.Request) !void {
    _ = setup;
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/"))
        return send(request, .html, placeholder_page, .ok);

    return send(request, .html, "<!doctype html><p>not found</p>\n", .not_found);
}

/// What a reply is, so the browser is told how to read it.
const ContentType = enum {
    html,

    fn header(content_type: ContentType) std.http.Header {
        return .{
            .name = "content-type",
            .value = switch (content_type) {
                .html => "text/html; charset=utf-8",
            },
        };
    }
};

/// Answers a request with `body`, as `content_type`, and ends the connection.
fn send(
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
