//! OpenAI-compatible `/chat/completions` client with function calling.

const std = @import("std");

const Health = @import("Health.zig");
const http = @import("http.zig");
const Mock = @import("Mock.zig");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn name(role: Role) []const u8 {
        return @tagName(role);
    }

    /// Writes the role as the string the API expects, so a request carries `"role":"user"` rather
    /// than a number.
    pub fn jsonStringify(role: Role, json: anytype) !void {
        try json.write(role.name());
    }
};

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: Function,

    pub const Function = struct {
        name: []const u8,
        arguments: []const u8,
    };
};

pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub const Delta = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: []const ToolCallDelta = &.{},
};

pub const ToolCallDelta = struct {
    index: usize = 0,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const StreamOptions = struct { include_usage: bool = true };

fn Request(Messages: type, Tools: type) type {
    return struct {
        model: []const u8,
        messages: Messages,
        tools: Tools,
        stream: bool = true,
        stream_options: StreamOptions = .{},
    };
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    url: []const u8,
    model: []const u8,
    max_attempts: usize = 4,
    retry_backoff: std.Io.Duration = .fromMilliseconds(500),
    http: *std.http.Client,

    pub fn complete(
        client: *Client,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        messages: anytype,
        tools: anytype,
    ) !*Stream {
        const authorization = try client.gpa.print("Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        const Request_ = Request(@TypeOf(messages), @TypeOf(tools));
        const request: Request_ = .{
            .model = client.model,
            .messages = messages,
            .tools = tools,
        };

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const answer = client.send(gpa, authorization, session_id, request) catch |err| {
                // A request that reached the network and failed is nearly always worth another try;
                // one that cannot ever work is not.
                if (!transportWorthRetrying(err) or attempt + 1 >= client.max_attempts) return err;
                try client.pause(attempt, null);
                continue;
            };

            switch (answer) {
                .stream => |stream| return stream,
                // A provider that did not answer with the stream it was asked for.
                .not_streamed => |body| {
                    defer client.gpa.free(body);
                    std.log.warn("the reply was not a stream: {s}", .{body});
                    return error.NotStreamed;
                },
                .failure => |failure| {
                    defer failure.deinit(client.gpa);
                    if (worthRetrying(failure.status) and attempt + 1 < client.max_attempts) {
                        try client.pause(attempt, failure.retry_after_ms);
                        continue;
                    }
                    std.log.warn("HTTP {d}: {s}", .{ @backingInt(failure.status), failure.body });
                    return error.HttpStatus;
                },
            }
        }
    }

    fn send(
        client: *Client,
        gpa: std.mem.Allocator,
        authorization: []const u8,
        session_id: []const u8,
        request: anytype,
    ) !Answer {
        // The body is serialized twice: once into a counter, because the head has to carry its
        // length before any of it is sent, and once onto the connection.
        var counted: std.Io.Writer.Discarding = .init("");
        try writeBody(&counted.writer, request);

        const extra_headers = [_]std.http.Header{
            .{ .name = "x-opencode-session", .value = session_id },
        };

        var req = try client.http.request(.POST, try std.Uri.parse(client.url), .{
            // A redirect after a request has been sent cannot be followed without sending it again,
            // so the redirect is handed back as the response.
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                // Named rather than left to the HTTP client's own, which is the library's name; a
                // provider that rate-limits or blocks generic SDK traffic has nothing to go on
                // otherwise.
                .user_agent = .{ .override = http.user_agent },
            },
            .extra_headers = &extra_headers,
        });
        var kept = false;
        defer if (!kept) req.deinit();
        req.transfer_encoding = .{ .content_length = counted.fullCount() };

        var body_buffer: [4096]u8 = undefined;
        var body = try req.sendBodyUnflushed(&body_buffer);
        try writeBody(&body.writer, request);
        try body.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        const retry_after_ms = Health.retryAfterMs(response.head.bytes);
        const streamed = isEventStream(response.head.content_type);
        const content_encoding = response.head.content_encoding;

        if (status.class() != .success) return .{ .failure = .{
            .status = status,
            .retry_after_ms = retry_after_ms,
            .body = try http.readBody(client.gpa, &response),
        } };
        if (!streamed) return .{ .not_streamed = try http.readBody(client.gpa, &response) };

        const buffers = try Stream.Buffers.init(gpa, content_encoding);
        errdefer gpa.free(buffers.decompress_buffer);

        const stream = try gpa.create(Stream);
        errdefer gpa.destroy(stream);
        stream.* = .{
            .gpa = gpa,
            .request = req,
            .buffers = buffers,
            .arena = .init(gpa),
            // Set below: the reader points into the stream, so it cannot be made before the fields
            // it points at exist.
            .reader = undefined,
        };
        stream.reader = stream.request.reader.bodyReaderDecompressing(
            &stream.buffers.transfer_buffer,
            stream.request.response_transfer_encoding,
            stream.request.response_content_length,
            content_encoding,
            &stream.buffers.decompress,
            stream.buffers.decompress_buffer,
        );
        kept = true;
        return .{ .stream = stream };
    }

    fn pause(client: *Client, attempt: usize, retry_after_ms: ?u64) !void {
        const wait = client.pauseFor(attempt, retry_after_ms);
        std.log.warn("retrying in {d}ms", .{wait.toMilliseconds()});
        return client.io.sleep(wait, .awake);
    }

    fn pauseFor(client: *Client, attempt: usize, retry_after_ms: ?u64) std.Io.Duration {
        if (retry_after_ms) |ms| return .fromMilliseconds(@intCast(@min(ms, max_retry_after_ms)));
        const base: u64 = @intCast(@max(client.retry_backoff.toMilliseconds(), 0));
        // The shift is capped so that a long attempt count cannot overflow it; the exponential is
        // capped anyway, so a large one is the same as this.
        const shift: u6 = @intCast(@min(attempt, 31));
        const full = @min(base << shift, max_backoff_ms);
        if (full == 0) return .zero;

        const half = full / 2;
        var seed: [8]u8 = undefined;
        client.io.random(&seed);
        return .fromMilliseconds(@intCast(half + std.mem.readInt(u64, &seed, .little) % (half + 1)));
    }
};

const max_backoff_ms: u64 = 30_000;
const max_retry_after_ms: u64 = 60_000;

const Answer = union(enum) {
    stream: *Stream,
    not_streamed: []u8,
    failure: Failure,

    const Failure = struct {
        status: std.http.Status,
        retry_after_ms: ?u64 = null,
        body: []u8,

        fn deinit(failure: Failure, gpa: std.mem.Allocator) void {
            gpa.free(failure.body);
        }
    };
};

fn isEventStream(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), "text/event-stream");
}

const zstd_window_len = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;

pub const Stream = struct {
    gpa: std.mem.Allocator,
    request: std.http.Client.Request,
    buffers: Buffers,
    reader: *std.Io.Reader,

    pending: std.ArrayList(u8) = .empty,
    parsed: usize = 0,
    data: std.ArrayList(u8) = .empty,
    arena: std.heap.ArenaAllocator,
    token_usage: Usage = .{},
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    done: bool = false,

    const Call = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,

        fn deinit(call: *Call, gpa: std.mem.Allocator) void {
            call.id.deinit(gpa);
            call.name.deinit(gpa);
            call.arguments.deinit(gpa);
        }
    };

    /// The memory a reply's body is read through: the transfer decoding's buffer, the window the
    /// decompressor reads through, and the decompressor itself.
    pub const Buffers = struct {
        transfer_buffer: [4096]u8 = undefined,
        decompress_buffer: []u8,
        decompress: std.http.Decompress = undefined,

        fn init(gpa: std.mem.Allocator, content_encoding: std.http.ContentEncoding) !Buffers {
            return .{ .decompress_buffer = switch (content_encoding) {
                .identity => &.{},
                .zstd => try gpa.alloc(u8, zstd_window_len),
                .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.UnsupportedCompressionMethod,
            } };
        }

        fn deinit(buffers: *Buffers, gpa: std.mem.Allocator) void {
            gpa.free(buffers.decompress_buffer);
        }
    };

    /// Reads until the next piece of the reply, or null when the stream has ended, adding the piece
    /// to the message as it is read.
    pub fn next(self: *Stream) !?Delta {
        var writer = std.Io.Writer.Allocating.fromArrayList(self.gpa, &self.pending);
        defer self.pending = writer.toArrayList();

        while (!self.done) {
            const unparsed = writer.written()[self.parsed..];
            if (frameEnd(unparsed)) |end| {
                const delta = try self.parseFrame(unparsed[0..end.body]);
                self.parsed += end.consumed;
                if (delta) |d| {
                    try self.add(d);
                    return d;
                }
                continue;
            }

            _ = self.reader.stream(&writer.writer, .unlimited) catch |err| switch (err) {
                error.EndOfStream => {
                    self.done = true;
                    continue;
                },
                else => return err,
            };
        }
        return null;
    }

    /// The token counts the provider sent with the reply, which it sends at the end of the stream
    /// when it was asked to.
    pub fn usage(self: *const Stream) Usage {
        return self.token_usage;
    }

    pub fn message(self: *Stream) !Message {
        std.debug.assert(self.done);
        self.tool_calls.clearRetainingCapacity();
        for (self.calls.items) |call|
            try self.tool_calls.append(self.gpa, .{
                .id = call.id.items,
                .function = .{ .name = call.name.items, .arguments = call.arguments.items },
            });
        return .{
            .role = .assistant,
            .content = if (self.content.items.len > 0) self.content.items else null,
            .tool_calls = if (self.tool_calls.items.len > 0) self.tool_calls.items else null,
            .reasoning_content = if (self.reasoning.items.len > 0) self.reasoning.items else null,
        };
    }

    pub fn deinit(self: *Stream) void {
        const gpa = self.gpa;
        self.request.deinit();
        self.buffers.deinit(gpa);
        self.pending.deinit(gpa);
        self.data.deinit(gpa);
        self.arena.deinit();
        self.content.deinit(gpa);
        self.reasoning.deinit(gpa);
        for (self.calls.items) |*call| call.deinit(gpa);
        self.calls.deinit(gpa);
        self.tool_calls.deinit(gpa);
        gpa.destroy(self);
    }

    fn add(self: *Stream, delta: Delta) !void {
        if (delta.content) |text| try self.content.appendSlice(self.gpa, text);
        if (delta.reasoning) |text| try self.reasoning.appendSlice(self.gpa, text);
        for (delta.tool_calls) |fragment| try self.addCall(fragment);
    }

    fn addCall(self: *Stream, fragment: ToolCallDelta) !void {
        while (self.calls.items.len <= fragment.index) try self.calls.append(self.gpa, .{});
        const call = &self.calls.items[fragment.index];
        if (fragment.id) |id| try set(&call.id, self.gpa, id);
        if (fragment.name) |name| try set(&call.name, self.gpa, name);
        if (fragment.arguments) |arguments| try call.arguments.appendSlice(self.gpa, arguments);
    }

    fn parseFrame(self: *Stream, bytes: []const u8) !?Delta {
        self.data.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const field = std.mem.trimEnd(u8, line, "\r");
            const data = std.mem.cutPrefix(u8, field, "data:") orelse continue;
            try self.data.appendSlice(self.gpa, std.mem.trim(u8, data, " \t"));
        }

        if (self.data.items.len == 0)
            return null;

        if (std.mem.eql(u8, self.data.items, "[DONE]")) {
            self.done = true;
            return null;
        }

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const chunk = std.json.parseFromSliceLeaky(Chunk, arena, self.data.items, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            // A delta that cannot be read is the provider's; the rest of the reply is still worth
            // reading, so it is reported and dropped.
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("a streamed delta could not be read: {s}: {s}", .{ @errorName(err), self.data.items });
                return null;
            },
        };
        if (chunk.@"error") |api_error| {
            std.log.warn("api error: {s}", .{api_error.message});
            return error.ApiError;
        }
        if (chunk.usage) |counts| self.token_usage = counts;
        if (chunk.choices.len == 0) return null;

        const piece = chunk.choices[0].delta orelse return null;
        const fragments = piece.tool_calls orelse &.{};
        const calls = try arena.alloc(ToolCallDelta, fragments.len);
        for (fragments, 0..) |fragment, index| {
            calls[index] = .{
                .index = fragment.index,
                .id = fragment.id,
                .name = fragment.function.name,
                .arguments = fragment.function.arguments,
            };
        }
        const delta: Delta = .{
            .content = piece.content,
            .reasoning = piece.reasoning_content,
            .tool_calls = calls,
        };
        if (delta.content == null and delta.reasoning == null and delta.tool_calls.len == 0)
            return null;
        return delta;
    }
};

fn set(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, text);
}

const Chunk = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,
    @"error": ?ApiError = null,

    const Choice = struct { delta: ?Piece = null };
    const Piece = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: ?[]const Call = null,
    };
    const Call = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        function: Function = .{},
        const Function = struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        };
    };
    const ApiError = struct { message: []const u8 };
};

const FrameEnd = struct { body: usize, consumed: usize };

fn frameEnd(bytes: []const u8) ?FrameEnd {
    var pos: usize = 0;
    while (std.mem.findAnyPos(u8, bytes, pos, "\n\r")) |next| {
        pos = next + 1;
        if (std.mem.startsWith(u8, bytes[next..], "\n\n"))
            return .{ .body = next, .consumed = next + 2 };
        if (std.mem.startsWith(u8, bytes[next..], "\r\n\r\n"))
            return .{ .body = next, .consumed = next + 4 };
    }

    return null;
}

fn worthRetrying(status: std.http.Status) bool {
    return status == .too_many_requests or status.class() == .server_error;
}

fn transportWorthRetrying(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.Canceled,
        error.InvalidFormat,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.CertificateBundleLoadFailure,
        error.UnsupportedCompressionMethod,
        => false,
        else => true,
    };
}

fn writeBody(writer: *std.Io.Writer, request: anytype) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.write(request);
}

const NoTools = struct {};

test "a request counts out to exactly the body it writes" {
    const gpa = std.testing.allocator;

    const messages = [_]Message{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content = "hello \"world\"\n" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
    };
    const request: Request(@TypeOf(&messages), []const NoTools) = .{
        .model = "some-model",
        .messages = &messages,
        .tools = &.{},
    };

    var counted: std.Io.Writer.Discarding = .init("");
    try writeBody(&counted.writer, request);

    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try writeBody(&written.writer, request);

    const one_pass = try std.json.Stringify.valueAlloc(gpa, request, .{ .emit_null_optional_fields = false });
    defer gpa.free(one_pass);

    try std.testing.expectEqual(written.written().len, counted.fullCount());
    try std.testing.expectEqualStrings(one_pass, written.written());
}

test "a request reaches the wire with the body the head promised" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{
        .{ .role = .system, .content = "be terse" },
        .{ .role = .user, .content = "say \"hi\"\n" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
    };
    const expected = try std.json.Stringify.valueAlloc(
        gpa,
        Request(@TypeOf(&messages), []const NoTools){
            .model = "some-model",
            .messages = &messages,
            .tools = &.{},
        },
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(expected);

    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hi there\"}}]," ++
            "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "secret",
        .url = mock.url,
        .model = "some-model",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqual(@as(u64, expected.len), mock.content_length.?);
    try std.testing.expectEqualStrings(expected, mock.bodies.items[0]);
    try std.testing.expectEqualStrings("hi there", (try stream.message()).content.?);
    try std.testing.expectEqual(9, stream.usage().total_tokens);
}

test "a request names billy and carries the session it belongs to" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.completion("hi"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    var found = std.StringHashMap([]const u8).init(gpa);
    defer found.deinit();
    for (mock.headers.items) |header| try found.put(header.name, header.value);
    try std.testing.expectEqualStrings(http.user_agent, found.get("user-agent").?);
    try std.testing.expectEqualStrings("01ABC", found.get("x-opencode-session").?);
}

test "a streamed reply is read a delta at a time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"a thought\"}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    var deltas: usize = 0;
    while (try stream.next()) |_| deltas += 1;

    try mock.await();

    try std.testing.expectEqual(3, deltas);

    const message = try stream.message();
    try std.testing.expectEqualStrings("hello", message.content.?);
    try std.testing.expectEqualStrings("a thought", message.reasoning_content.?);
    try std.testing.expect(message.tool_calls == null);
    try std.testing.expectEqual(5, stream.usage().total_tokens);
}

test "a delta that spells its fields as null is read, not dropped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider may write a field it has nothing for as an explicit null rather than leaving it
    // out, and it may do so in every field of the chunk at once.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1," ++
            "\"model\":\"m\",\"choices\":[{\"index\":0,\"finish_reason\":null,\"logprobs\":null," ++
            "\"delta\":{\"role\":null,\"content\":\"hel\",\"reasoning_content\":\" from REVIEW\"," ++
            "\"tool_calls\":null}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\",\"reasoning_content\":null," ++
            "\"tool_calls\":null}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":null,\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    var deltas: usize = 0;
    while (try stream.next()) |_| deltas += 1;

    try mock.await();

    try std.testing.expectEqual(2, deltas);
    const message = try stream.message();
    try std.testing.expectEqualStrings("hello", message.content.?);
    try std.testing.expectEqualStrings(" from REVIEW", message.reasoning_content.?);
}

test "a streamed reply that arrived compressed is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const events =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    // A provider may compress the events, and a compressed body is read through a decoder that
    // keeps what it has decoded in a buffer of its own.
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &compressed.writer,
        &window,
        .gzip,
        .default,
    );
    try compressor.writer.writeAll(events);
    try compressor.finish();

    const gzipped = struct {
        var body: []const u8 = &.{};
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{
                .body = body,
                .content_type = "text/event-stream",
                .content_encoding = "gzip",
            };
        }
    };
    gzipped.body = compressed.written();

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, gzipped.answer);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqualStrings("hello", (try stream.message()).content.?);
}

test "a frame that arrives in pieces is joined" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const long = try gpa.alloc(u8, 30_000);
    defer gpa.free(long);
    @memset(long, 'x');
    const reply = try gpa.print("data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\n" ++
        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"the end\"}}}}]}}\n\n" ++
        "data: [DONE]\n\n", .{long});
    defer gpa.free(reply);

    const streamed = struct {
        var body: []const u8 = &.{};
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{ .body = body, .content_type = "text/event-stream" };
        }
    };
    streamed.body = reply;

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, streamed.answer);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    const content = (try stream.message()).content.?;
    try std.testing.expectEqualStrings(long, content[0..long.len]);
    try std.testing.expectEqualStrings("the end", content[long.len..]);
}

test "a payload that runs over more than one data line is joined" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // OpenAI sends a chunk's JSON on one line, but that is its serializer's doing and not something
    // a client may lean on: the format is a stream of events, an event's payload is every one of
    // its `data:` lines, and a provider built on a generic emitter that splits on newlines -- one
    // that pretty-prints its JSON, say -- sends the object over several of them.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\n" ++
            "data:   \"choices\": [\n" ++
            "data:     {\"delta\": {\"content\": \"hel\"}}\n" ++
            "data:   ]\n" ++
            "data: }\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();

    // One frame is one delta, however many lines its payload took, so the test counts the deltas it
    // is handed rather than reading the message, which adds them up.
    var deltas: usize = 0;
    while (try stream.next()) |_| deltas += 1;

    try mock.await();

    try std.testing.expectEqual(2, deltas);
    try std.testing.expectEqualStrings("hello", (try stream.message()).content.?);
}

test "the fields beside data carry nothing billy reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        ": keepalive\n\n" ++
            "event: message\n" ++
            "id: 1\n" ++
            "retry: 5000\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" ++
            "event: ping\n\n" ++
            ": keepalive\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqualStrings("hi there", (try stream.message()).content.?);
}

test "a frame ends at the blank line that follows it" {
    const lf = frameEnd("data: 1\n\ndata: 2\n\n").?;
    try std.testing.expectEqual(7, lf.body);
    try std.testing.expectEqual(9, lf.consumed);

    const crlf = frameEnd("data: 1\r\n\r\ndata: 2\n\n").?;
    try std.testing.expectEqual(7, crlf.body);
    try std.testing.expectEqual(11, crlf.consumed);

    try std.testing.expect(frameEnd("data: 1\ndata: 2") == null);
}

test "a stream whose lines end with CRLF is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider is free to end its lines the way HTTP allows.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "event: message\r\n" ++
            "data: {\r\n" ++
            "data:   \"choices\": [{\"delta\": {\"content\": \"hi\"}}]\r\n" ++
            "data: }\r\n\r\n" ++
            "data: [DONE]\r\n\r\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqualStrings("hi", (try stream.message()).content.?);
}

test "a reply that is not a stream is reported, not read as a plain reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    try std.testing.expectError(error.NotStreamed, client.complete(
        gpa,
        "01SESSION",
        &messages,
        @as([]const NoTools, &.{}),
    ));

    try mock.await();
}

test "a stream that carries no choices is an empty reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider that says nothing at all streams no choices, which reads as an empty reply: the
    // caller decides what a reply with nothing in it means, rather than being handed an error for
    // it here.
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream("data: [DONE]\n\n"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    const message = try stream.message();
    try std.testing.expect(message.content == null);
    try std.testing.expect(message.reasoning_content == null);
    try std.testing.expect(message.tool_calls == null);
}

test "a tool call streamed in pieces is put back together" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{.{ .role = .user, .content = "run it" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\"," ++
            "\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," ++
            "\"function\":{\"arguments\":\"{\\\"command\\\":\"}}]}}]}\n\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," ++
            "\"function\":{\"arguments\":\"\\\"echo hi\\\"}\"}}]}}]}\n\n" ++
            "data: [DONE]\n\n",
    ));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    var stream = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    const calls = (try stream.message()).tool_calls.?;
    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("bash", calls[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", calls[0].function.arguments);
}

test "a body only counts as a stream when its content type says so" {
    try std.testing.expect(isEventStream("text/event-stream"));
    try std.testing.expect(isEventStream("text/event-stream; charset=utf-8"));
    try std.testing.expect(isEventStream("Text/Event-Stream"));
    try std.testing.expect(!isEventStream("application/json"));
    try std.testing.expect(!isEventStream(null));
}

test "worthRetrying is a rate limit or a server error" {
    try std.testing.expect(worthRetrying(.too_many_requests));
    try std.testing.expect(worthRetrying(.internal_server_error));
    try std.testing.expect(worthRetrying(.bad_gateway));
    try std.testing.expect(worthRetrying(.service_unavailable));
    try std.testing.expect(worthRetrying(.gateway_timeout));
    try std.testing.expect(!worthRetrying(.ok));
    try std.testing.expect(!worthRetrying(.bad_request));
    try std.testing.expect(!worthRetrying(.unauthorized));
    try std.testing.expect(!worthRetrying(.not_found));
}

test "transportWorthRetrying retries a connection and not a permanent failure" {
    try std.testing.expect(transportWorthRetrying(error.ConnectionRefused));
    try std.testing.expect(transportWorthRetrying(error.ConnectionResetByPeer));
    try std.testing.expect(!transportWorthRetrying(error.OutOfMemory));
    try std.testing.expect(!transportWorthRetrying(error.Canceled));
    try std.testing.expect(!transportWorthRetrying(error.UnsupportedCompressionMethod));
}

test "pauseFor honors Retry-After and otherwise backs off with jitter" {
    const gpa = std.testing.allocator;
    var http_client: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .api_key = "k",
        .url = "u",
        .model = "m",
        .http = &http_client,
    };

    // The server's own wait, clamped so it cannot park billy.
    try std.testing.expectEqual(
        @as(i64, 3000),
        client.pauseFor(0, 3000).toMilliseconds(),
    );
    try std.testing.expectEqual(
        @as(i64, max_retry_after_ms),
        client.pauseFor(0, max_retry_after_ms * 10).toMilliseconds(),
    );

    for (0..5) |_| {
        const wait = client.pauseFor(0, null).toMilliseconds();
        try std.testing.expect(wait >= 250 and wait <= 500);
    }
    const later = client.pauseFor(2, null).toMilliseconds();
    try std.testing.expect(later >= 1000 and later <= 2000);

    client.retry_backoff = .zero;
    try std.testing.expectEqual(@as(i64, 0), client.pauseFor(0, null).toMilliseconds());
}

fn clientAgainst(
    gpa: std.mem.Allocator,
    io: std.Io,
    http_client: *std.http.Client,
    url: []const u8,
    max_attempts: usize,
) Client {
    return .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = url,
        .model = "m",
        .max_attempts = max_attempts,
        .retry_backoff = .zero,
        .http = http_client,
    };
}

fn retrying(comptime fail_first: usize) *const fn (usize, []const u8) Mock.Answer {
    return struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number <= fail_first) return .{
                .status = .service_unavailable,
                .body = "{\"error\":{\"message\":\"busy\"}}",
            };
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"content\":\"made it\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4}}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
            };
        }
    }.answer;
}

test "a request that is rate limited is tried again and succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/chat/completions", 3, retrying(2));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 4);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};

    var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("made it", (try stream.message()).content.?);
    try std.testing.expectEqual(4, stream.usage().total_tokens);
}

test "a request that keeps failing is given up on after max_attempts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start("/chat/completions", 3, retrying(3));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 3);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};

    try std.testing.expectError(error.HttpStatus, client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{})));

    try mock.await();
    try std.testing.expectEqual(@as(usize, 3), mock.served);
}

test "the HTTP client is kept, so requests reuse one connection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const keep_alive = struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{
                .body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\n" ++
                    "data: [DONE]\n\n",
                .content_type = "text/event-stream",
                .keep_alive = true,
            };
        }
    }.answer;
    var mock = try Mock.start("/chat/completions", 2, keep_alive);
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http_client,
    };

    // Two completions through one client.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    for (0..2) |_| {
        var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
        defer stream.deinit();
        while (try stream.next()) |_| {}
        try std.testing.expectEqualStrings("hi", (try stream.message()).content.?);
    }

    try mock.await();
    try std.testing.expectEqual(@as(usize, 1), mock.connections);
    try std.testing.expectEqual(@as(usize, 2), mock.served);
}
