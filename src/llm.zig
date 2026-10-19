//! OpenAI-compatible `/chat/completions` client with function calling.

const std = @import("std");
const Health = @import("Health.zig");
const http = @import("http.zig");
const Mock = @import("Mock.zig");

/// Who a message is from. The API names these as strings; they are an enum here
/// because they are a fixed set that is compared and stored far more often than
/// it is written, and a string would be interned, hashed and compared by bytes
/// on every one of them.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    /// The name the API knows the role by, which is the variant's own.
    pub fn name(role: Role) []const u8 {
        return @tagName(role);
    }

    /// Writes the role as the string the API expects, so a request carries
    /// `"role":"user"` rather than a number.
    pub fn jsonStringify(role: Role, json: anytype) !void {
        try json.write(role.name());
    }
};

/// A message in the conversation, as sent to and received from the API.
pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    /// What a reasoning model thought before it answered, which the API reports
    /// beside `content`. A provider that wants it back on the next request is
    /// sent it from here; a provider that does not, or does not have one, is
    /// sent nothing, since the field is written only when it is set.
    reasoning_content: ?[]const u8 = null,
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

/// Token counts for one request.
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
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

/// What a request asks of a provider's thinking, for a model that has it.
/// Thinking is a provider's own default and most providers have none, so a
/// provider nothing is asked of is left to do whatever it does.
pub const Reasoning = union(enum) {
    /// Say nothing, which leaves the model on its provider's own default.
    provider_default,
    /// Ask for no thinking.
    off,
    /// Ask for a level of thinking, by the name the provider gives it.
    effort: []const u8,
};

/// The thinking toggle, in the shape the API takes it: `{"type": "..."}`.
pub const Thinking = struct { type: []const u8 };

/// `stream_options`: what a streamed reply should carry beside the deltas. The
/// usage count is only sent when it is asked for, and without it the context
/// gauge has nothing to show.
const StreamOptions = struct { include_usage: bool = true };

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
        /// Ask for the reply as a stream of deltas, which is added back up into the
        /// message a plain reply would be, so a caller need not know which it got.
        stream: bool = true,
        /// Ask for a usage count in the stream, which a provider sends only when
        /// asked for.
        stream_options: ?StreamOptions = .{},
        /// The thinking toggle. Null sends none, which is what leaves the model
        /// on its own default.
        thinking: ?Thinking = null,
        /// How hard the model should think, by the provider's own name for the
        /// level. Null sends none.
        reasoning_effort: ?[]const u8 = null,

        /// The two thinking controls `reasoning` asks for.
        fn controls(reasoning: Reasoning) struct { thinking: ?Thinking, reasoning_effort: ?[]const u8 } {
            return switch (reasoning) {
                .provider_default => .{ .thinking = null, .reasoning_effort = null },
                .off => .{ .thinking = .{ .type = "disabled" }, .reasoning_effort = null },
                .effort => |level| .{ .thinking = null, .reasoning_effort = level },
            };
        }
    };
}

/// The part of the response the harness uses. Unknown fields are ignored.
const Response = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,
    @"error": ?ApiError = null,

    pub const Choice = struct { message: Message };
    pub const ApiError = struct { message: []const u8 };
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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
    retry_backoff: std.Io.Duration = .fromMilliseconds(500),
    /// The one HTTP client of the run, borrowed by pointer so that every
    /// request, chat and search alike, shares its connections and its scanned
    /// certificates. The run owns it and outlives this.
    http: *std.http.Client,
    /// What the request asks of the model's thinking.
    reasoning: Reasoning = .provider_default,

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
    ///
    /// `session_id` names the conversation the request belongs to. Some
    /// providers ask for it so they can route and cache a conversation
    /// together, and one of them refuses a request without it; a provider that
    /// wants none ignores the header.
    pub fn complete(
        client: *Client,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        messages: anytype,
        tools: anytype,
    ) !Completion {
        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        const Request_ = Request(@TypeOf(messages), @TypeOf(tools));
        const controls = Request_.controls(client.reasoning);
        const request: Request_ = .{
            .model = client.model,
            .messages = messages,
            .tools = tools,
            .thinking = controls.thinking,
            .reasoning_effort = controls.reasoning_effort,
        };

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const answer = client.send(authorization, session_id, request) catch |err| {
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
    fn send(
        client: *Client,
        authorization: []const u8,
        session_id: []const u8,
        request: anytype,
    ) !Answer {
        // The body is serialized twice: once into a counter, because the head has
        // to carry its length before any of it is sent, and once onto the
        // connection. Neither holds a copy of it, so a request does not allocate
        // its own body.
        var counted: std.Io.Writer.Discarding = .init("");
        try writeBody(&counted.writer, request);

        const extra_headers = [_]std.http.Header{
            .{ .name = "x-opencode-session", .value = session_id },
        };

        var req = try client.http.request(.POST, try std.Uri.parse(client.url), .{
            // A redirect after a request has been sent cannot be followed without
            // sending it again, so the redirect is handed back as the response.
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                // Named rather than left to the HTTP client's own, which is the
                // library's name; a provider that rate-limits or blocks generic
                // SDK traffic has nothing to go on otherwise.
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = &extra_headers,
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
        const retry_after_ms = Health.retryAfterMs(response.head.bytes);
        // Read before the body, whose reader is what invalidates the head's
        // strings.
        const streamed = isEventStream(response.head.content_type);

        const answer_body = try http.readBody(client.gpa, &response);

        return .{
            .status = status,
            .retry_after_ms = retry_after_ms,
            .streamed = streamed,
            .body = answer_body,
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
    fn pauseFor(client: *Client, attempt: usize, retry_after_ms: ?u64) std.Io.Duration {
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

/// What billy calls itself to a provider, rather than leaving the HTTP client's
/// own name, which is the standard library's. A provider that watches its
/// traffic for abuse asks to know what is talking to it.
const user_agent = "billy/1.0";

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
    /// Whether the body is a stream of events, from the `Content-Type` the server
    /// sent it with.
    streamed: bool = false,
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
        std.log.warn("HTTP {d}: {s}", .{ @backingInt(answer.status), answer.body });
        return error.HttpStatus;
    }
    // A reply asked for as a stream comes as event-stream frames; a plain one is
    // a single JSON object. The server says which it sent, so neither the body nor
    // its leading bytes are guessed at. Either is read into the same `Response`,
    // so the rest of billy sees one shape.
    if (answer.streamed) return interpretStream(gpa, answer.body);
    return interpretJson(gpa, answer.status, answer.body);
}

/// Whether a response's `Content-Type` names a stream of events, which is what a
/// provider answers with when it was asked to stream. The type may carry
/// parameters, such as `; charset=utf-8`, which are not part of it.
fn isEventStream(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), "text/event-stream");
}

/// Reads a reply sent as one JSON object.
fn interpretJson(gpa: std.mem.Allocator, status: std.http.Status, body: []const u8) !Completion {
    const parsed = std.json.parseFromSlice(Response, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("HTTP {d}: {s}", .{ @backingInt(status), body });
        return err;
    };
    errdefer parsed.deinit();

    if (parsed.value.@"error") |api_error| {
        std.log.warn("api error: {s}", .{api_error.message});
        return error.ApiError;
    }
    if (parsed.value.choices.len == 0) {
        std.log.warn("HTTP {d} without choices: {s}", .{ @backingInt(status), body });
        return error.NoChoices;
    }
    // A provider that omits usage leaves the counts at zero, so the context gauge
    // under-reports rather than the request failing.
    return .{
        .message = parsed.value.choices[0].message,
        .usage = parsed.value.usage orelse .{},
        .response = parsed,
    };
}

/// Reads a reply sent as a stream: the `data:` frames are added up into the
/// message they spell out, then written back out in the shape a plain reply has,
/// so the one reader above takes both. Nothing here shows a delta to the caller
/// yet: the reply is assembled whole, and bubbling the deltas up is what comes
/// next.
fn interpretStream(gpa: std.mem.Allocator, body: []const u8) !Completion {
    var assembled: Assembled = .{ .gpa = gpa };
    defer assembled.deinit();
    try assembled.feed(body);

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try json.writer.writeAll("{\"choices\":[{\"message\":");
    try std.json.Stringify.value(try assembled.message(), .{}, &json.writer);
    try json.writer.writeAll("}],\"usage\":");
    try std.json.Stringify.value(assembled.usage, .{}, &json.writer);
    try json.writer.writeAll("}");
    return interpretJson(gpa, .ok, json.written());
}

/// One delta of a streamed reply, as the API sends it. Unknown fields are
/// ignored, and a field a delta leaves out keeps the default, since a delta only
/// carries what changed.
const Chunk = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,

    const Choice = struct {
        delta: Delta = .{},
        finish_reason: ?[]const u8 = null,
    };
    const Delta = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: []const ToolCallDelta = &.{},
    };
    /// A piece of a tool call. The first piece carries the `id` and the name, and
    /// the arguments follow a fragment at a time; `index` says which call of the
    /// message they belong to.
    const ToolCallDelta = struct {
        index: u32 = 0,
        id: ?[]const u8 = null,
        function: Function = .{},
        const Function = struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        };
    };
};

/// The deltas of one streamed reply, added up into the message and usage they
/// spell out.
const Assembled = struct {
    gpa: std.mem.Allocator,
    /// The answer, the model's thinking, and one set of pieces per tool call.
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Pieces) = .empty,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    usage: Usage = .{},

    const Pieces = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,

        fn deinit(pieces: *Pieces, gpa: std.mem.Allocator) void {
            pieces.id.deinit(gpa);
            pieces.name.deinit(gpa);
            pieces.arguments.deinit(gpa);
        }
    };

    fn deinit(self: *Assembled) void {
        self.content.deinit(self.gpa);
        self.reasoning.deinit(self.gpa);
        for (self.calls.items) |*pieces| pieces.deinit(self.gpa);
        self.calls.deinit(self.gpa);
        self.tool_calls.deinit(self.gpa);
    }

    /// Reads the `data:` frames of `body` into the reply, until the frame that
    /// ends the stream.
    fn feed(self: *Assembled, body: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.gpa);

        var frames = std.mem.splitSequence(u8, body, "\n\n");
        while (frames.next()) |frame| {
            data.clearRetainingCapacity();
            // A frame is lines; only `data:` carries the JSON, and a payload that
            // runs over more than one line is joined back with newlines.
            var lines = std.mem.splitScalar(u8, frame, '\n');
            while (lines.next()) |line| {
                const payload = std.mem.trimStart(u8, line, " ");
                if (!std.mem.startsWith(u8, payload, "data:")) continue;
                if (data.items.len > 0) try data.append(self.gpa, '\n');
                try data.appendSlice(self.gpa, std.mem.trim(u8, payload["data:".len..], " \t\r"));
            }
            if (data.items.len == 0) continue;
            if (std.mem.eql(u8, data.items, "[DONE]")) return;
            _ = arena_state.reset(.retain_capacity);
            self.apply(arena_state.allocator(), data.items) catch |err|
                std.log.warn("a streamed delta could not be read: {s}", .{@errorName(err)});
        }
    }

    /// Adds one delta to the reply.
    fn apply(self: *Assembled, arena: std.mem.Allocator, json_text: []const u8) !void {
        const chunk = try std.json.parseFromSliceLeaky(Chunk, arena, json_text, .{
            .ignore_unknown_fields = true,
        });
        if (chunk.usage) |usage| self.usage = usage;
        for (chunk.choices) |choice| {
            if (choice.delta.content) |text| try self.content.appendSlice(self.gpa, text);
            if (choice.delta.reasoning_content) |text| try self.reasoning.appendSlice(self.gpa, text);
            for (choice.delta.tool_calls) |fragment| try self.addCall(fragment);
        }
    }

    /// Adds a piece of a tool call to the call its `index` names, making that call
    /// on the first piece.
    fn addCall(self: *Assembled, fragment: Chunk.ToolCallDelta) !void {
        while (self.calls.items.len <= fragment.index) try self.calls.append(self.gpa, .{});
        const pieces = &self.calls.items[fragment.index];
        if (fragment.id) |id| try replace(&pieces.id, self.gpa, id);
        if (fragment.function.name) |name| try replace(&pieces.name, self.gpa, name);
        if (fragment.function.arguments) |arguments| try pieces.arguments.appendSlice(self.gpa, arguments);
    }

    /// The message the reply adds up to, its strings pointing into this.
    fn message(self: *Assembled) !Message {
        self.tool_calls.clearRetainingCapacity();
        for (self.calls.items) |pieces|
            try self.tool_calls.append(self.gpa, .{
                .id = pieces.id.items,
                .function = .{ .name = pieces.name.items, .arguments = pieces.arguments.items },
            });
        return .{
            .role = .assistant,
            .content = if (self.content.items.len > 0) self.content.items else null,
            .reasoning_content = if (self.reasoning.items.len > 0) self.reasoning.items else null,
            .tool_calls = if (self.tool_calls.items.len > 0) self.tool_calls.items else null,
        };
    }
};

/// Sets `list` to `text`, keeping what it already allocated.
fn replace(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, text);
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

/// Writes one request body. Called twice for a request: once into a counter, to
/// learn the length the head has to carry, and once onto the connection.
fn writeBody(writer: *std.Io.Writer, request: anytype) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.write(request);
}

/// Stands for the tools of a request that has none. The request is generic over
/// the tools, so a test that sends none still names a type for them.
const NoTools = struct {};

test "what a request asks of the model's thinking, by setting" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};

    // The three shapes, and the field each puts on the wire: none at all for the
    // model's own default, the toggle for no thinking, and the level for an
    // effort the provider named. Never two of them, which would ask twice.
    const cases = [_]struct { reasoning: Reasoning, has: []const u8, has_not: []const u8 }{
        .{ .reasoning = .provider_default, .has = "", .has_not = "thinking" },
        .{ .reasoning = .off, .has = "\"thinking\":{\"type\":\"disabled\"}", .has_not = "reasoning_effort" },
        .{ .reasoning = .{ .effort = "high" }, .has = "\"reasoning_effort\":\"high\"", .has_not = "thinking" },
    };
    for (cases) |case| {
        const Request_ = Request(@TypeOf(&messages), []const NoTools);
        const controls = Request_.controls(case.reasoning);
        const request: Request_ = .{
            .model = "m",
            .messages = &messages,
            .tools = &.{},
            .thinking = controls.thinking,
            .reasoning_effort = controls.reasoning_effort,
        };
        const body = try std.json.Stringify.valueAlloc(gpa, request, .{ .emit_null_optional_fields = false });
        defer gpa.free(body);
        if (case.has.len > 0) try std.testing.expect(std.mem.indexOf(u8, body, case.has) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, case.has_not) == null);
    }
}

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

    var mock = try Mock.start("/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi there\"}}]," ++
            "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}",
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

    const completion = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer completion.deinit();

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The head carried the counted length, and the bytes behind it are exactly
    // the body the counter measured, not something assembled separately.
    try std.testing.expectEqual(@as(u64, expected.len), mock.content_length.?);
    try std.testing.expectEqualStrings(expected, mock.bodies.items[0]);
    try std.testing.expectEqualStrings("hi there", completion.message.content.?);
    try std.testing.expectEqual(9, completion.usage.total_tokens);
}

test "a request names billy and carries the session it belongs to" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.fixed(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}",
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

    const completion = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer completion.deinit();

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The HTTP client's own name is the library's, which a provider that
    // watches its traffic for abuse asks clients not to send, and the session
    // is what a provider routes and caches a conversation by, so both have to
    // reach the wire.
    var found = std.StringHashMap([]const u8).init(gpa);
    defer found.deinit();
    for (mock.headers.items) |header| try found.put(header.name, header.value);
    try std.testing.expectEqualStrings(user_agent, found.get("user-agent").?);
    try std.testing.expectEqualStrings("01ABC", found.get("x-opencode-session").?);
}

test "a streamed reply is added up into the message and usage" {
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

    const completion = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer completion.deinit();

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The deltas are folded into one message, the same shape a whole reply has.
    try std.testing.expectEqualStrings("hello", completion.message.content.?);
    try std.testing.expectEqualStrings("a thought", completion.message.reasoning_content.?);
    try std.testing.expect(completion.message.tool_calls == null);
    try std.testing.expectEqual(5, completion.usage.total_tokens);
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

    const completion = try client.complete(gpa, "01ABC", &messages, @as([]const NoTools, &.{}));
    defer completion.deinit();

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The id and name arrive once and the arguments a fragment at a time; they
    // are put back into the one call the model meant.
    const calls = completion.message.tool_calls.?;
    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("bash", calls[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", calls[0].function.arguments);
}

test "a body is read by the content type it was sent with" {
    // The type may carry parameters, and the case does not matter; anything but a
    // stream, or nothing at all, is a plain reply.
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
fn completeAgainst(gpa: std.mem.Allocator, io: std.Io, url: []const u8, max_attempts: usize) !Completion {
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .api_key = "k",
        .url = url,
        .model = "m",
        .max_attempts = max_attempts,
        .retry_backoff = .zero,
        .http = &http_client,
    };
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    return client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
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
    var mock = try Mock.start("/chat/completions", 3, retrying(2));
    defer mock.deinit();
    try mock.serve();

    const completion = try completeAgainst(gpa, io, mock.url, 4);
    defer completion.deinit();

    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("made it", completion.message.content.?);
    try std.testing.expectEqual(4, completion.usage.total_tokens);
}

test "a request that keeps failing is given up on after max_attempts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Every request fails, so the client tries as many times as it is allowed.
    var mock = try Mock.start("/chat/completions", 3, retrying(3));
    defer mock.deinit();
    try mock.serve();

    try std.testing.expectError(error.HttpStatus, completeAgainst(gpa, io, mock.url, 3));

    try mock.group.await(io);
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

    // Two completions through one client. A fresh HTTP client per request would
    // have to open a second connection, which this server, on one, never
    // accepts; the second request only completes because the connection is
    // reused.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    for (0..2) |_| {
        const completion = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
        defer completion.deinit();
        try std.testing.expectEqualStrings("hi", completion.message.content.?);
    }

    try mock.group.await(io);
    if (mock.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), mock.connections);
    try std.testing.expectEqual(@as(usize, 2), mock.served);
}
