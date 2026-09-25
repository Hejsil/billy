//! A stand-in provider for the tests: a real HTTP server a client can be pointed
//! at instead of a live service.
//!
//! Every test that needs one used to carry its own accept loop -- six copies of
//! the same forty-odd lines. This is the one copy. It listens, reads each
//! request, records what it was sent, and answers with whatever the test's
//! `answer` function returns.
//!
//! It is not a part of billy; it is only reached from tests, so it is not
//! exported from `root.zig`.

const std = @import("std");
const Io = std.Io;

const Mock = @This();

gpa: std.mem.Allocator,
/// How many requests to answer before it stops, so a test's mock does not wait
/// on a connection that never comes.
requests: usize,
/// What to answer a request with, given the request's number (1-based) and its
/// body as it arrived.
answer: *const fn (number: usize, body: []const u8) Answer,

/// The address it listens on, as the full URL a client is pointed at.
url: []const u8,
/// The socket it accepts on.
listener: std.Io.net.Server,

/// How many requests it has answered, and how many connections it accepted: a
/// client that reuses a connection is seen as fewer connections than requests.
served: usize = 0,
connections: usize = 0,
/// The body of each request, in the order they arrived, owned by `gpa`.
bodies: std.ArrayList([]const u8) = .empty,
/// The length the last request announced, when it carried one.
content_length: ?u64 = null,
/// The authorization header the last request carried, owned by `gpa`.
authorization: ?[]u8 = null,
/// The first failure the server ran into, so a test reports it rather than
/// hanging on a connection.
err: ?anyerror = null,

/// What one request is answered with.
pub const Answer = struct {
    /// The body to send. It has to outlive the reply, so it is a string the
    /// program holds rather than one built for the reply alone.
    body: []const u8,
    status: std.http.Status = .ok,
    /// Whether to leave the connection open for another request.
    keep_alive: bool = false,
};

/// Starts a mock listening on a free port, at `path` -- `/chat/completions` for
/// a model, `/search` for the search backend. The caller starts `serve` in a
/// group and then points a client at `mock.url`.
pub fn start(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    requests: usize,
    answer: *const fn (usize, []const u8) Answer,
) !Mock {
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);
    return .{
        .gpa = gpa,
        .requests = requests,
        .answer = answer,
        .listener = listener,
        .url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{
            listener.socket.address.getPort(),
            path,
        }),
    };
}

/// Stops listening and frees everything the mock recorded.
pub fn deinit(mock: *Mock, io: Io) void {
    mock.listener.deinit(io);
    mock.gpa.free(mock.url);
    for (mock.bodies.items) |body| mock.gpa.free(body);
    mock.bodies.deinit(mock.gpa);
    if (mock.authorization) |value| mock.gpa.free(value);
}

/// The accept loop, for a test to hand to `Io.Group.concurrent`. A failure is
/// kept on the mock, which a test reports once the group has finished.
pub fn serve(io: Io, mock: *Mock) Io.Cancelable!void {
    mock.run(io) catch |err| {
        mock.err = err;
    };
}

fn run(mock: *Mock, io: Io) !void {
    while (mock.served < mock.requests) {
        var stream = try mock.listener.accept(io);
        mock.connections += 1;
        mock.serveConnection(io, stream) catch |err| {
            mock.err = err;
        };
        stream.close(io);
    }
}

/// Answers requests on one connection until the client closes it or a reply asks
/// not to keep it alive, which is what the client does after a reply it does not
/// intend to reuse.
fn serveConnection(mock: *Mock, io: Io, stream: Io.net.Stream) !void {
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    while (mock.served < mock.requests) {
        var request = server.receiveHead() catch return; // the client closed it

        mock.content_length = request.head.content_length;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            if (mock.authorization) |old| mock.gpa.free(old);
            mock.authorization = try mock.gpa.dupe(u8, header.value);
        }

        var body_buffer: [8192]u8 = undefined;
        const body = try request.readerExpectNone(&body_buffer).allocRemaining(mock.gpa, .unlimited);
        try mock.bodies.append(mock.gpa, body);

        const answer = mock.answer(mock.served + 1, body);
        mock.served += 1;
        try request.respond(answer.body, .{
            .status = answer.status,
            .keep_alive = answer.keep_alive,
        });
        if (!answer.keep_alive) return;
    }
}

/// The answer of a mock that sends the same `reply` every time. Tests that vary
/// their reply write their own function.
pub fn fixed(comptime reply: []const u8) *const fn (usize, []const u8) Answer {
    return struct {
        fn answer(_: usize, _: []const u8) Answer {
            return .{ .body = reply };
        }
    }.answer;
}

/// The answer of a mock whose reply is a completion carrying `content`: the
/// shape a model provider sends back.
pub fn completion(comptime content: []const u8) *const fn (usize, []const u8) Answer {
    return struct {
        fn answer(_: usize, _: []const u8) Answer {
            return .{ .body = comptime "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"" ++
                content ++ "\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}" };
        }
    }.answer;
}
