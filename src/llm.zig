//! OpenAI-compatible `/chat/completions` client with function calling.

const std = @import("std");
const Io = std.Io;

/// A message in the conversation, as sent to and received from the API.
pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: Function,

    pub const Function = struct {
        name: []const u8,
        /// JSON object with the tool arguments.
        arguments: []const u8,
    };
};

pub const Tool = struct {
    type: []const u8 = "function",
    function: Function,

    pub const Function = struct {
        name: []const u8,
        description: []const u8,
        /// JSON Schema for the arguments.
        parameters: std.json.Value,
    };
};

/// Token counts for one request, with the provider-specific spellings of the
/// cached-input split normalized away.
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Input tokens served from the prompt cache, which cost less.
    cache_hit_tokens: usize = 0,
    /// Input tokens that missed the cache and cost the full input price.
    cache_miss_tokens: usize = 0,

    /// The totals of two requests, for keeping a running session total.
    pub fn plus(a: Usage, b: Usage) Usage {
        return .{
            .prompt_tokens = a.prompt_tokens + b.prompt_tokens,
            .completion_tokens = a.completion_tokens + b.completion_tokens,
            .total_tokens = a.total_tokens + b.total_tokens,
            .cache_hit_tokens = a.cache_hit_tokens + b.cache_hit_tokens,
            .cache_miss_tokens = a.cache_miss_tokens + b.cache_miss_tokens,
        };
    }
};

/// What one request produced: the assistant message and the tokens it used.
pub const Completion = struct {
    message: Message,
    usage: Usage,
};

/// The body of one completion request.
///
/// `Messages` is whatever the conversation is held as, which only has to be
/// able to write itself into the format the API takes. That is what lets a
/// conversation be sent from where it is stored instead of being resolved into
/// a second copy of itself first.
fn Request(comptime Messages: type) type {
    return struct {
        model: []const u8,
        messages: Messages,
        tools: []const Tool,
        stream: bool = false,
    };
}

/// Token counts as the API reports them. Kept apart from `Usage` because the
/// fields differ between providers, and each normalizes to the same shape.
const Reported = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// DeepSeek reports the cached and uncached parts of the prompt separately.
    prompt_cache_hit_tokens: ?usize = null,
    prompt_cache_miss_tokens: ?usize = null,
    /// Other OpenAI-compatible providers report only the cached part.
    prompt_tokens_details: ?struct { cached_tokens: usize = 0 } = null,

    /// The cache hit count, wherever the provider put it, with the rest of the
    /// prompt counted as misses.
    fn normalized(reported: Reported) Usage {
        const hit = reported.prompt_cache_hit_tokens orelse
            if (reported.prompt_tokens_details) |details| details.cached_tokens else 0;
        return .{
            .prompt_tokens = reported.prompt_tokens,
            .completion_tokens = reported.completion_tokens,
            .total_tokens = reported.total_tokens,
            .cache_hit_tokens = hit,
            .cache_miss_tokens = reported.prompt_cache_miss_tokens orelse
                (reported.prompt_tokens -| hit),
        };
    }
};

/// The part of the response the harness uses. Unknown fields are ignored.
const Response = struct {
    choices: []const Choice = &.{},
    usage: ?Reported = null,
    @"error": ?ApiError = null,

    pub const Choice = struct { message: Message };
    pub const ApiError = struct { message: []const u8 };
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    api_key: []const u8,
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    model: []const u8,

    /// Sends the conversation and returns the next assistant message together
    /// with the tokens the request used.
    ///
    /// `messages` is the conversation in whatever form the caller keeps it, so
    /// long as it writes itself into the format the API takes: a slice of
    /// `Message`, or the session's own stored messages. Nothing is allocated to
    /// put the conversation into the request: the body is written straight onto
    /// the connection.
    ///
    /// `arena` holds the parsed response, which has to outlive the response
    /// buffer but need not outlive the caller's use of it: the session interns
    /// what it keeps, so an arena dropped with the request is enough.
    pub fn complete(
        client: *Client,
        arena: std.mem.Allocator,
        messages: anytype,
        tools: []const Tool,
    ) !Completion {
        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        var http: std.http.Client = .{ .allocator = client.gpa, .io = client.io };
        defer http.deinit();

        var response_text: std.Io.Writer.Allocating = .init(client.gpa);
        defer response_text.deinit();

        const request: Request(@TypeOf(messages)) = .{
            .model = client.model,
            .messages = messages,
            .tools = tools,
        };

        // The body is serialized twice: once into a counter, because the head has
        // to carry its length before any of it is sent, and once onto the
        // connection. Neither holds a copy of it, so a request no longer allocates
        // its own body.
        var counted_buffer: [1024]u8 = undefined;
        var counted: std.Io.Writer.Discarding = .init(&counted_buffer);
        try writeBody(&counted.writer, request);

        var req = try http.request(.POST, try std.Uri.parse(client.url), .{
            // A redirect after a request has been sent cannot be followed without
            // sending it again, so the redirect is handed back as the response.
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = counted.fullCount() };

        var body_buffer: [4096]u8 = undefined;
        var body = try req.sendBodyUnflushed(&body_buffer);
        try writeBody(&body.writer, request);
        // `end` asserts that what was written adds up to the length the head
        // promised, which is what keeps the two passes honest about each other.
        try body.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        const status = response.head.status;

        // The body of the response is read the way `fetch` reads it, so that a
        // provider answering with a compressed body still parses.
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try client.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try client.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer client.gpa.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = try reader.streamRemaining(&response_text.writer);

        const text = response_text.written();
        // The response buffer is freed when this function returns, so the
        // strings in the parsed message must be copies.
        const parsed = std.json.parseFromSliceLeaky(Response, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err("HTTP {d}: {s}", .{ @intFromEnum(status), text });
            return err;
        };
        if (parsed.@"error") |api_error| {
            std.log.err("api error: {s}", .{api_error.message});
            return error.ApiError;
        }
        if (parsed.choices.len == 0) {
            std.log.err("HTTP {d} without choices: {s}", .{ @intFromEnum(status), text });
            return error.NoChoices;
        }
        // A provider that omits usage leaves the totals at zero, so the session
        // totals under-report rather than the request failing.
        return .{
            .message = parsed.choices[0].message,
            .usage = if (parsed.usage) |reported| reported.normalized() else .{},
        };
    }
};

/// Writes one request body. Called twice for a request: once into a counter, to
/// learn the length the head has to carry, and once onto the connection.
fn writeBody(writer: *Io.Writer, request: anytype) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.write(request);
}

test "a request counts out to exactly the body it writes" {
    const gpa = std.testing.allocator;

    const messages = [_]Message{
        .{ .role = "system", .content = "be terse" },
        .{ .role = "user", .content = "hello \"world\"\n" },
        .{ .role = "assistant", .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
    };
    const request: Request(@TypeOf(&messages)) = .{
        .model = "some-model",
        .messages = &messages,
        .tools = &.{},
    };

    // The length the head carries is the count, and the bytes sent are what a
    // second pass writes. They have to be the same length *and* the same bytes,
    // or the request goes out malformed.
    var counted_buffer: [16]u8 = undefined;
    var counted: std.Io.Writer.Discarding = .init(&counted_buffer);
    try writeBody(&counted.writer, request);

    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try writeBody(&written.writer, request);

    const one_pass = try std.json.Stringify.valueAlloc(gpa, request, .{ .emit_null_optional_fields = false });
    defer gpa.free(one_pass);

    try std.testing.expectEqual(written.written().len, counted.fullCount());
    try std.testing.expectEqualStrings(one_pass, written.written());
}

/// Answers one request over a real socket with a fixed reply, recording what
/// the client actually put on the connection so the test can check it. The
/// count-and-write pair is only correct if the bytes that arrive are the ones
/// the head announced, which is what a live connection is needed to see.
const TestProvider = struct {
    /// The body the client is expected to send, compared against what arrives.
    expected_body: []const u8,
    /// The length the request head announced, read off the wire.
    content_length: ?u64 = null,
    /// The request body as it arrived, owned by `std.testing.allocator`.
    body: ?[]u8 = null,
    /// The first failure the server ran into, if any, so the test can report it
    /// instead of the connection simply hanging.
    err: ?anyerror = null,

    fn serve(io: Io, listener: *std.Io.net.Server, self: *TestProvider) Io.Cancelable!void {
        self.run(io, listener) catch |err| {
            self.err = err;
        };
    }

    fn run(self: *TestProvider, io: Io, listener: *std.Io.net.Server) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);

        var in_buffer: [4096]u8 = undefined;
        var out_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);

        var request = try server.receiveHead();
        self.content_length = request.head.content_length;

        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        self.body = try body_reader.allocRemaining(std.testing.allocator, .unlimited);

        try request.respond(
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi there\"}}]," ++
                "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}",
            .{ .keep_alive = false },
        );
    }
};

test "a request reaches the wire with the body the head promised" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{
        .{ .role = "system", .content = "be terse" },
        .{ .role = "user", .content = "say \"hi\"\n" },
        .{ .role = "assistant", .tool_calls = &.{.{
            .id = "call_1",
            .function = .{ .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        }} },
        .{ .role = "tool", .tool_call_id = "call_1", .content = "1\tconst x = 1;\n" },
    };
    const expected = try std.json.Stringify.valueAlloc(
        gpa,
        Request(@TypeOf(&messages)){ .model = "some-model", .messages = &messages, .tools = &.{} },
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(expected);

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var provider: TestProvider = .{ .expected_body = expected };
    defer if (provider.body) |body| gpa.free(body);

    var group: Io.Group = .init;
    try group.concurrent(io, TestProvider.serve, .{ io, &listener, &provider });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/chat/completions", .{
        listener.socket.address.getPort(),
    });
    defer gpa.free(url);

    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "secret",
        .url = url,
        .model = "some-model",
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const completion = try client.complete(arena_state.allocator(), &messages, &.{});

    try group.await(io);
    if (provider.err) |err| return err;

    // The head carried the counted length, and the bytes behind it are exactly
    // the body the counter measured, not something assembled separately.
    try std.testing.expectEqual(@as(u64, expected.len), provider.content_length.?);
    try std.testing.expectEqualStrings(expected, provider.body.?);
    try std.testing.expectEqualStrings("hi there", completion.message.content.?);
    try std.testing.expectEqual(9, completion.usage.total_tokens);
}

test "usage is normalized from the DeepSeek cache fields" {
    const usage = Reported.normalized(try parseReported(
        \\{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110,
        \\ "prompt_cache_hit_tokens":90,"prompt_cache_miss_tokens":10}
    ));
    try std.testing.expectEqual(100, usage.prompt_tokens);
    try std.testing.expectEqual(10, usage.completion_tokens);
    try std.testing.expectEqual(110, usage.total_tokens);
    try std.testing.expectEqual(90, usage.cache_hit_tokens);
    try std.testing.expectEqual(10, usage.cache_miss_tokens);
}

test "usage falls back to the cached_tokens field and counts the rest as misses" {
    const usage = Reported.normalized(try parseReported(
        \\{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110,
        \\ "prompt_tokens_details":{"cached_tokens":64}}
    ));
    try std.testing.expectEqual(64, usage.cache_hit_tokens);
    try std.testing.expectEqual(36, usage.cache_miss_tokens);
}

test "plus accumulates session totals" {
    const a: Usage = .{ .prompt_tokens = 10, .completion_tokens = 2, .total_tokens = 12, .cache_hit_tokens = 8, .cache_miss_tokens = 2 };
    const b: Usage = .{ .prompt_tokens = 20, .completion_tokens = 3, .total_tokens = 23, .cache_hit_tokens = 19, .cache_miss_tokens = 1 };
    const sum = Usage.plus(a, b);
    try std.testing.expectEqual(30, sum.prompt_tokens);
    try std.testing.expectEqual(5, sum.completion_tokens);
    try std.testing.expectEqual(35, sum.total_tokens);
    try std.testing.expectEqual(27, sum.cache_hit_tokens);
    try std.testing.expectEqual(3, sum.cache_miss_tokens);
}

/// Parses a usage object the way `complete` does, ignoring unknown fields.
fn parseReported(json: []const u8) !Reported {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    return std.json.parseFromSliceLeaky(Reported, arena_state.allocator(), json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
