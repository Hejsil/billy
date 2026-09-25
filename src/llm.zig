//! OpenAI-compatible `/chat/completions` client with function calling.

const std = @import("std");
const Io = std.Io;
const Mock = @import("mock.zig");

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
///
/// `message` points into `response`, the parsed reply the completion owns, so
/// the strings stay valid until `deinit` is called. That is what frees the
/// caller from holding an arena for the response to live in.
pub const Completion = struct {
    message: Message,
    usage: Usage,
    /// The parsed response `message` points into, freed by `deinit`.
    response: std.json.Parsed(Response),

    /// Frees the parsed response the reply points into.
    pub fn deinit(completion: Completion) void {
        completion.response.deinit();
    }
};

/// The body of one completion request.
///
/// `Messages` and `Tools` are whatever the conversation and the tool
/// definitions are held as, which only have to be able to write themselves into
/// the format the API takes. That is what lets a conversation and its tools be
/// sent from where they are stored instead of being resolved into a second copy
/// of themselves first; the session writes both out of its own pools.
fn Request(comptime Messages: type, comptime Tools: type) type {
    return struct {
        model: []const u8,
        messages: Messages,
        tools: Tools,
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
    /// How many times one request is tried, the first try included. Only a
    /// failure that may pass is ever retried, so this bounds those and not a
    /// request that is simply wrong.
    max_attempts: usize = 4,
    /// The pause before the first retry, doubled for each one after it and
    /// jittered, so a burst of retries does not stay in step. A test sets it to
    /// zero, so a retry costs no real time.
    retry_backoff: Io.Duration = .fromMilliseconds(500),
    /// The one HTTP client of the run, borrowed by pointer so that every
    /// request, chat and search alike, shares its connections and its scanned
    /// certificates. The run owns it and outlives this.
    http: *std.http.Client,

    /// Sends the conversation and returns the next assistant message together
    /// with the tokens the request used.
    ///
    /// `messages` is the conversation in whatever form the caller keeps it, so
    /// long as it writes itself into the format the API takes: a slice of
    /// `Message`, or the session's own stored messages. Nothing is allocated to
    /// put the conversation into the request: the body is written straight onto
    /// the connection.
    ///
    /// `gpa` owns the parsed response the returned completion carries; the
    /// caller frees it with `Completion.deinit`.
    pub fn complete(
        client: *Client,
        gpa: std.mem.Allocator,
        messages: anytype,
        tools: anytype,
    ) !Completion {
        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        const request: Request(@TypeOf(messages), @TypeOf(tools)) = .{
            .model = client.model,
            .messages = messages,
            .tools = tools,
        };

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const answer = client.send(authorization, request) catch |err| {
                // A request that reached the network and failed is nearly always
                // worth another try; one that cannot ever work is not.
                if (!transportWorthRetrying(err) or attempt + 1 >= client.max_attempts) return err;
                try client.pause(attempt, null);
                continue;
            };
            defer answer.deinit(client.gpa);

            // A rate limit or a server error may pass on its own; a client error
            // will not, so it is not retried. The server's Retry-After, when it
            // sent one, is how long it asked to be waited.
            if (worthRetrying(answer.status) and attempt + 1 < client.max_attempts) {
                try client.pause(attempt, answer.retry_after_ms);
                continue;
            }
            return interpret(gpa, answer);
        }
    }

    /// One request over a fresh connection, returning what the server answered
    /// with and the body, which the caller owns. Nothing is interpreted here: a
    /// failure is a failure to reach the server, not a decision about the reply.
    fn send(client: *Client, authorization: []const u8, request: anytype) !Answer {
        // The body is serialized twice: once into a counter, because the head has
        // to carry its length before any of it is sent, and once onto the
        // connection. Neither holds a copy of it, so a request does not allocate
        // its own body.
        var counted: std.Io.Writer.Discarding = .init("");
        try writeBody(&counted.writer, request);

        var req = try client.http.request(.POST, try std.Uri.parse(client.url), .{
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
        const retry_after_ms = retryAfterMs(response.head.bytes);

        // The body of the response is read the way `fetch` reads it, so that a
        // provider answering with a compressed body still parses.
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try client.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try client.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer client.gpa.free(decompress_buffer);

        var response_text: std.Io.Writer.Allocating = .init(client.gpa);
        errdefer response_text.deinit();

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = try reader.streamRemaining(&response_text.writer);

        return .{
            .status = status,
            .retry_after_ms = retry_after_ms,
            .body = try response_text.toOwnedSlice(),
        };
    }

    /// Waits before the next try. The server's Retry-After is honored when it
    /// sent one, and otherwise a backoff that doubles each attempt is used,
    /// jittered so that clients retrying together do not stay in step.
    fn pause(client: *Client, attempt: usize, retry_after_ms: ?u64) !void {
        const wait = client.pauseFor(attempt, retry_after_ms);
        std.log.warn("retrying in {d}ms", .{wait.toMilliseconds()});
        return client.io.sleep(wait, .awake);
    }

    /// How long to wait before try `attempt + 1`. The exponential is jittered
    /// over its lower half, so the wait is long but the clients spread out.
    fn pauseFor(client: *Client, attempt: usize, retry_after_ms: ?u64) Io.Duration {
        if (retry_after_ms) |ms| return .fromMilliseconds(@intCast(@min(ms, max_retry_after_ms)));
        const base: u64 = @intCast(@max(client.retry_backoff.toMilliseconds(), 0));
        // The shift is capped so that a long attempt count cannot overflow it;
        // the exponential is capped anyway, so a large one is the same as this.
        const shift: u6 = @intCast(@min(attempt, 31));
        const full = @min(base << shift, max_backoff_ms);
        if (full == 0) return .zero;

        const half = full / 2;
        var seed: [8]u8 = undefined;
        client.io.random(&seed);
        return .fromMilliseconds(@intCast(half + std.mem.readInt(u64, &seed, .little) % (half + 1)));
    }
};

/// The longest a backoff waits, so a long outage does not turn a retry into a
/// wait measured in minutes.
const max_backoff_ms: u64 = 30_000;
/// The longest a `Retry-After` is honored, so a server cannot park billy for
/// longer than a run would last anyway.
const max_retry_after_ms: u64 = 60_000;

/// What one request answered with, before it is interpreted: the status, what
/// the server asked to be waited before another try, and the body. The body is
/// owned by the caller.
const Answer = struct {
    status: std.http.Status,
    /// Milliseconds the server asked to wait before another try, from a
    /// `Retry-After` header, or null when it sent none.
    retry_after_ms: ?u64 = null,
    body: []u8,

    fn deinit(answer: Answer, gpa: std.mem.Allocator) void {
        gpa.free(answer.body);
    }
};

/// Turns an answer into a completion: the reply the model wrote and the tokens
/// it used. A status that is not a success is reported with its body, which is
/// where the provider usually says why.
///
/// The body is parsed into a response the completion carries, so the reply
/// outlives the answer buffer without the caller holding an arena for it; the
/// caller frees it with `Completion.deinit`.
fn interpret(gpa: std.mem.Allocator, answer: Answer) !Completion {
    // The client logs what the server said as context; the error it returns is
    // what the caller reports, so the failure is not announced twice.
    if (answer.status.class() != .success) {
        std.log.warn("HTTP {d}: {s}", .{ @intFromEnum(answer.status), answer.body });
        return error.HttpStatus;
    }
    const parsed = std.json.parseFromSlice(Response, gpa, answer.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("HTTP {d}: {s}", .{ @intFromEnum(answer.status), answer.body });
        return err;
    };
    errdefer parsed.deinit();

    if (parsed.value.@"error") |api_error| {
        std.log.warn("api error: {s}", .{api_error.message});
        return error.ApiError;
    }
    if (parsed.value.choices.len == 0) {
        std.log.warn("HTTP {d} without choices: {s}", .{ @intFromEnum(answer.status), answer.body });
        return error.NoChoices;
    }
    // A provider that omits usage leaves the totals at zero, so the session
    // totals under-report rather than the request failing.
    return .{
        .message = parsed.value.choices[0].message,
        .usage = if (parsed.value.usage) |reported| reported.normalized() else .{},
        .response = parsed,
    };
}

/// Whether a status says to try the request again: a rate limit, or a server
/// error the provider may recover from. A request that is wrong (4xx) would be
/// just as wrong the second time, so it is not retried.
fn worthRetrying(status: std.http.Status) bool {
    return status == .too_many_requests or status.class() == .server_error;
}

/// Whether a failure to reach the server is worth another try. A connection
/// that did not open, was reset or timed out is the transient kind, and there
/// are many ways for one to fail, so the failure is retried unless it is one
/// that will fail the same way every time: not enough memory, a cancel, or a
/// request or reply that cannot be built or read at all.
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

/// The wait a `Retry-After` header asked for, in milliseconds, or null when
/// there is none. Only the seconds form is read; an HTTP-date is left to the
/// backoff, which is close enough for a retry.
fn retryAfterMs(head: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "retry-after")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        return std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    }
    return null;
}

/// Writes one request body. Called twice for a request: once into a counter, to
/// learn the length the head has to carry, and once onto the connection.
fn writeBody(writer: *Io.Writer, request: anytype) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.write(request);
}

/// Stands for the tools of a request that has none. The request is generic over
/// the tools, so a test that sends none still names a type for them.
const NoTools = struct {};

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
    const request: Request(@TypeOf(&messages), []const NoTools) = .{
        .model = "some-model",
        .messages = &messages,
        .tools = &.{},
    };

    // The length the head carries is the count, and the bytes sent are what a
    // second pass writes. They have to be the same length *and* the same bytes,
    // or the request goes out malformed.
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
        Request(@TypeOf(&messages), []const NoTools){
            .model = "some-model",
            .messages = &messages,
            .tools = &.{},
        },
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(expected);

    var mock = try Mock.start(gpa, io, "/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi there\"}}]," ++
            "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}",
    ));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "secret",
        .url = mock.url,
        .model = "some-model",
        .http = &http,
    };

    const completion = try client.complete(gpa, &messages, @as([]const NoTools, &.{}));
    defer completion.deinit();

    try group.await(io);
    if (mock.err) |err| return err;

    // The head carried the counted length, and the bytes behind it are exactly
    // the body the counter measured, not something assembled separately.
    try std.testing.expectEqual(@as(u64, expected.len), mock.content_length.?);
    try std.testing.expectEqualStrings(expected, mock.bodies.items[0]);
    try std.testing.expectEqualStrings("hi there", completion.message.content.?);
    try std.testing.expectEqual(9, completion.usage.total_tokens);
}

test "retryAfterMs reads the seconds form and ignores the rest" {
    try std.testing.expectEqual(
        @as(?u64, 2000),
        retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 2\r\nContent-Length: 0\r\n\r\n"),
    );
    // The header name is matched however it is spelled.
    try std.testing.expectEqual(
        @as(?u64, 5000),
        retryAfterMs("HTTP/1.1 503\r\nretry-after: 5\r\n\r\n"),
    );
    // No header, and the HTTP-date form, are left to the backoff.
    try std.testing.expect(retryAfterMs("HTTP/1.1 200 OK\r\n\r\n") == null);
    try std.testing.expect(retryAfterMs("HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n") == null);
}

test "worthRetrying is a rate limit or a server error" {
    try std.testing.expect(worthRetrying(.too_many_requests));
    try std.testing.expect(worthRetrying(.internal_server_error));
    try std.testing.expect(worthRetrying(.bad_gateway));
    try std.testing.expect(worthRetrying(.service_unavailable));
    try std.testing.expect(worthRetrying(.gateway_timeout));
    // A request that is wrong will be just as wrong a second time.
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
    var http: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer http.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .api_key = "k",
        .url = "u",
        .model = "m",
        .http = &http,
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

    // The backoff doubles, jittered over the lower half, so it is between half
    // and all of the exponential.
    for (0..5) |_| {
        const wait = client.pauseFor(0, null).toMilliseconds();
        try std.testing.expect(wait >= 250 and wait <= 500);
    }
    const later = client.pauseFor(2, null).toMilliseconds();
    try std.testing.expect(later >= 1000 and later <= 2000);

    // A test sets the backoff to zero, so a retry costs no real time.
    client.retry_backoff = .zero;
    try std.testing.expectEqual(@as(i64, 0), client.pauseFor(0, null).toMilliseconds());
}

/// Runs one completion against `url`, with the retry backoff turned off so the
/// test costs no real time. The caller owns the returned completion and frees it
/// with `deinit`.
fn completeAgainst(gpa: std.mem.Allocator, io: Io, url: []const u8, max_attempts: usize) !Completion {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = url,
        .model = "m",
        .max_attempts = max_attempts,
        .retry_backoff = .zero,
        .http = &http,
    };
    const messages = [_]Message{.{ .role = "user", .content = "hi" }};
    return client.complete(gpa, &messages, @as([]const NoTools, &.{}));
}

/// The answer of a mock that fails the first `fail_first` requests with a 503 and
/// succeeds after, for the retry tests.
fn retrying(comptime fail_first: usize) *const fn (usize, []const u8) Mock.Answer {
    return struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number <= fail_first) return .{
                .status = .service_unavailable,
                .body = "{\"error\":{\"message\":\"busy\"}}",
            };
            return .{ .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"made it\"}}]," ++
                "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4}}" };
        }
    }.answer;
}

test "a request that is rate limited is tried again and succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Two failures, then the answer: three requests, and the client should make
    // exactly that many.
    var mock = try Mock.start(gpa, io, "/chat/completions", 3, retrying(2));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    const completion = try completeAgainst(gpa, io, mock.url, 4);
    defer completion.deinit();

    try group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("made it", completion.message.content.?);
    try std.testing.expectEqual(4, completion.usage.total_tokens);
}

test "a request that keeps failing is given up on after max_attempts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Every request fails, so the client tries as many times as it is allowed.
    var mock = try Mock.start(gpa, io, "/chat/completions", 3, retrying(3));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    try std.testing.expectError(error.HttpStatus, completeAgainst(gpa, io, mock.url, 3));

    try group.await(io);
    if (mock.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 3), mock.served);
}

test "the HTTP client is kept, so requests reuse one connection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A mock that keeps each connection open, so a client that reuses one needs
    // a single connection for its requests and one that opens a fresh connection
    // a request needs more.
    const keep_alive = struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{
                .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]," ++
                    "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}",
                .keep_alive = true,
            };
        }
    }.answer;
    var mock = try Mock.start(gpa, io, "/chat/completions", 2, keep_alive);
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = mock.url,
        .model = "m",
        .http = &http,
    };

    // Two completions through one client. A fresh HTTP client per request would
    // have to open a second connection, which this server, on one, never
    // accepts; the second request only completes because the connection is
    // reused.
    const messages = [_]Message{.{ .role = "user", .content = "hi" }};
    for (0..2) |_| {
        const completion = try client.complete(gpa, &messages, @as([]const NoTools, &.{}));
        defer completion.deinit();
        try std.testing.expectEqualStrings("hi", completion.message.content.?);
    }

    try group.await(io);
    if (mock.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), mock.connections);
    try std.testing.expectEqual(@as(usize, 2), mock.served);
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
