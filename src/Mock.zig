//! A stand-in provider for the tests: a real HTTP server a client can be pointed at instead of a
//! live service.

const std = @import("std");

const Mock = @This();

gpa: std.mem.Allocator,

requests: usize,

answer: *const fn (number: usize, body: []const u8) Answer,

url: []const u8,

listener: std.Io.net.Server,

served: usize = 0,
connections: usize = 0,

bodies: std.ArrayList([]const u8) = .empty,

targets: std.ArrayList([]const u8) = .empty,

content_length: ?u64 = null,

headers: std.ArrayList(Header) = .empty,

err: ?anyerror = null,

group: std.Io.Group = .init,

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Answer = struct {
    body: []const u8,
    status: std.http.Status = .ok,
    keep_alive: bool = false,
    content_type: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

pub fn start(
    path: []const u8,
    requests: usize,
    answer: *const fn (usize, []const u8) Answer,
) !Mock {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);
    return .{
        .gpa = gpa,
        .requests = requests,
        .answer = answer,
        .listener = listener,
        .url = try gpa.print("http://127.0.0.1:{d}{s}", .{
            listener.socket.address.getPort(),
            path,
        }),
    };
}

pub fn deinit(mock: *Mock) void {
    const io = std.testing.io;
    mock.listener.deinit(io);
    mock.gpa.free(mock.url);
    for (mock.bodies.items) |body| mock.gpa.free(body);
    mock.bodies.deinit(mock.gpa);
    for (mock.targets.items) |target| mock.gpa.free(target);
    mock.targets.deinit(mock.gpa);
    mock.clearHeaders();
    mock.headers.deinit(mock.gpa);
}

pub fn header(mock: *const Mock, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (mock.headers.items) |one| {
        if (std.ascii.eqlIgnoreCase(one.name, name)) found = one.value;
    }
    return found;
}

fn clearHeaders(mock: *Mock) void {
    for (mock.headers.items) |one| {
        mock.gpa.free(one.name);
        mock.gpa.free(one.value);
    }
    mock.headers.clearRetainingCapacity();
}

pub fn serve(mock: *Mock) !void {
    try mock.group.concurrent(std.testing.io, Mock.serveInGroup, .{mock});
}

pub fn await(mock: *Mock) !void {
    try mock.group.await(std.testing.io);
    if (mock.err) |err| return err;
}

pub fn stop(mock: *Mock) !void {
    mock.group.cancel(std.testing.io);
    const err = mock.err orelse return;
    mock.err = null;
    // The task was still waiting for a request when it was stopped, which is the whole reason to
    // stop it rather than wait.
    if (err == error.Canceled) return;
    return err;
}

fn serveInGroup(mock: *Mock) std.Io.Cancelable!void {
    mock.run() catch |err| {
        mock.err = err;
    };
}

fn run(mock: *Mock) !void {
    const io = std.testing.io;
    while (mock.served < mock.requests) {
        var stream = try mock.listener.accept(io);
        mock.connections += 1;
        mock.serveConnection(io, stream) catch |err| {
            mock.err = err;
        };
        stream.close(io);
    }
}

fn serveConnection(mock: *Mock, io: std.Io, stream: std.Io.net.Stream) !void {
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    while (mock.served < mock.requests) {
        var request = server.receiveHead() catch return; // the client closed it

        mock.content_length = request.head.content_length;
        try mock.targets.append(mock.gpa, try mock.gpa.dupe(u8, request.head.target));
        mock.clearHeaders();
        var headers = request.iterateHeaders();
        while (headers.next()) |one| {
            try mock.headers.append(mock.gpa, .{
                .name = try mock.gpa.dupe(u8, one.name),
                .value = try mock.gpa.dupe(u8, one.value),
            });
        }

        var body_buffer: [8192]u8 = undefined;
        const body = try request.readerExpectNone(&body_buffer).allocRemaining(mock.gpa, .unlimited);
        try mock.bodies.append(mock.gpa, body);

        const answer = mock.answer(mock.served + 1, body);
        mock.served += 1;
        var extra: [8]std.http.Header = undefined;
        var extra_count: usize = 0;
        if (answer.content_type) |value| {
            extra[extra_count] = .{ .name = "content-type", .value = value };
            extra_count += 1;
        }
        if (answer.content_encoding) |value| {
            extra[extra_count] = .{ .name = "content-encoding", .value = value };
            extra_count += 1;
        }
        // What the answer asked to be sent beside its body, as many as there is room for: a test
        // that wanted more would be answered with fewer rather than overrunning the array.
        for (answer.headers) |one| {
            if (extra_count == extra.len) break;
            extra[extra_count] = one;
            extra_count += 1;
        }
        try request.respond(answer.body, .{
            .status = answer.status,
            .keep_alive = answer.keep_alive,
            .extra_headers = extra[0..extra_count],
        });
        if (!answer.keep_alive) return;
    }
}

pub fn fixed(comptime reply: []const u8) *const fn (usize, []const u8) Answer {
    return struct {
        fn answer(_: usize, _: []const u8) Answer {
            return .{ .body = reply };
        }
    }.answer;
}

/// The answer of a mock whose reply is a completion carrying `content`: the shape a model provider
/// sends back when it was asked to stream.
pub fn completion(comptime content: []const u8) *const fn (usize, []const u8) Answer {
    return struct {
        fn answer(_: usize, _: []const u8) Answer {
            return .{
                .body = comptime "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"" ++
                    content ++ "\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1,\"total_tokens\":11}}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
            };
        }
    }.answer;
}

/// The answer of a mock that sends `reply` as a stream of events, the shape a provider answers with
/// when it was asked to stream.
pub fn eventStream(comptime reply: []const u8) *const fn (usize, []const u8) Answer {
    return struct {
        fn answer(_: usize, _: []const u8) Answer {
            return .{ .body = reply, .content_type = "text/event-stream" };
        }
    }.answer;
}
