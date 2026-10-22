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

/// One piece of a streamed reply: what changed since the piece before it. A
/// chunk usually carries one of these, but it may carry more than one, so a
/// caller adds every field that is set. Every string points into the stream, so
/// it is only valid until the next `next` call; a caller that keeps one copies
/// it.
pub const Delta = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: []const ToolCallDelta = &.{},
};

/// A piece of a tool call, as a streamed reply sends it. `index` says which call
/// of the message it belongs to; a call's id and name arrive once, with its
/// first piece, and its arguments a fragment at a time.
pub const ToolCallDelta = struct {
    index: usize = 0,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

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
        /// Ask for the reply as a stream of deltas. Every provider billy talks
        /// to streams, so this is not turned off.
        stream: bool = true,
        /// Ask for a usage count in the stream, which a provider sends only when
        /// asked for.
        stream_options: StreamOptions = .{},
    };
}

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

    /// Sends the conversation and returns the reply as it streams in. The caller
    /// keeps calling `Stream.next` until it returns null, adding the deltas up
    /// into the message it keeps; `Stream.usage` has the token counts once the
    /// stream has ended.
    ///
    /// Every provider billy talks to streams, so a success that is not a stream
    /// is reported as an error rather than read as a plain reply.
    ///
    /// `messages` is the conversation in whatever form the caller keeps it, so
    /// long as it writes itself into the format the API takes: a slice of
    /// `Message`, or the session's own stored messages. Nothing is allocated to
    /// put the conversation into the request: the body is written straight onto
    /// the connection.
    ///
    /// `gpa` owns what the stream reads with, and the caller frees it with
    /// `Stream.deinit`.
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
    ) !*Stream {
        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
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
                // A request that reached the network and failed is nearly always
                // worth another try; one that cannot ever work is not.
                if (!transportWorthRetrying(err) or attempt + 1 >= client.max_attempts) return err;
                try client.pause(attempt, null);
                continue;
            };

            switch (answer) {
                // The request went through, and its body is the stream the
                // caller now reads. A failure after this point is the caller's,
                // since part of the reply may already have been handed over.
                .stream => |stream| return stream,
                // A provider that did not answer with the stream it was asked
                // for. The body is carried whole, so the report says what it
                // sent instead of it being read as a stream it is not.
                .not_streamed => |body| {
                    defer client.gpa.free(body);
                    std.log.warn("the reply was not a stream: {s}", .{body});
                    return error.NotStreamed;
                },
                // A rate limit or a server error may pass on its own; a client
                // error will not, so it is not retried. The server's Retry-After,
                // when it sent one, is how long it asked to be waited.
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

    /// One request over a fresh connection. A success is handed back as the
    /// stream its body holds, for the caller to read; a failure is read whole
    /// and handed back with the status, which is what decides whether to try
    /// again. Nothing here retries: a failure to reach the server is a failure,
    /// not a decision about the reply.
    fn send(
        client: *Client,
        gpa: std.mem.Allocator,
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
        // The request is handed to the stream when the body is one, so only the
        // paths that do not stream free it here.
        var kept = false;
        defer if (!kept) req.deinit();
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
        // strings: the stream wires its body reader up from them below.
        const streamed = isEventStream(response.head.content_type);
        const content_encoding = response.head.content_encoding;

        if (status.class() != .success) return .{ .failure = .{
            .status = status,
            .retry_after_ms = retry_after_ms,
            .body = try http.readBody(client.gpa, &response),
        } };
        if (!streamed) return .{ .not_streamed = try http.readBody(client.gpa, &response) };

        // What the reply's body is read through, which the stream owns for as
        // long as it reads: the window is only allocated for a body that arrived
        // compressed.
        const buffers = try Stream.Buffers.init(gpa, content_encoding);
        errdefer gpa.free(buffers.decompress_buffer);

        const stream = try gpa.create(Stream);
        errdefer gpa.destroy(stream);
        stream.* = .{
            .gpa = gpa,
            .request = req,
            .buffers = buffers,
            .arena = .init(gpa),
            // Set below: the reader points into the stream, so it cannot be made
            // before the fields it points at exist.
            .reader = undefined,
        };
        // Wired up now that the stream is where it will stay. The room it reads
        // into is the stream's own, and the transfer encoding and the length are
        // read off the request, which holds them for its own use.
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

/// What one request answered with. A success is the stream its body holds, for
/// the caller to read; a failure carries the status and body that say why.
const Answer = union(enum) {
    stream: *Stream,
    /// A successful status whose body was not a stream of events: a provider
    /// that did not answer with what it was asked for. The body is carried whole,
    /// so the report says what it sent instead.
    not_streamed: []u8,
    /// A status that is not a success, with the body the provider sent to say
    /// why.
    failure: Failure,

    const Failure = struct {
        status: std.http.Status,
        /// Milliseconds the server asked to wait before another try, from a
        /// `Retry-After` header, or null when it sent none.
        retry_after_ms: ?u64 = null,
        body: []u8,

        fn deinit(failure: Failure, gpa: std.mem.Allocator) void {
            gpa.free(failure.body);
        }
    };
};

/// Whether a response's `Content-Type` names a stream of events, which is what a
/// provider answers with when it was asked to stream. The type may carry
/// parameters, such as `; charset=utf-8`, which are not part of it.
fn isEventStream(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), "text/event-stream");
}

/// zstd's window with the block it decodes into on top of it, which is what its
/// decompressor asserts it was given room for. Flate's window is smaller, and it
/// is the whole of what that one asks for.
const zstd_window_len = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;

/// A reply as it streams in. The caller keeps calling `next` until it returns
/// null, adding each delta up into the message it keeps; `usage` has the token
/// counts once the stream has ended.
///
/// The strings a delta holds point into the stream, so a delta is only valid
/// until the next call. A caller that keeps one copies it.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// The request whose body is the stream, which stays where it is put: the
    /// body reader points into it.
    request: std.http.Client.Request,
    /// What the reply's body is read through: the room both decoders read into,
    /// and the decompressor itself.
    buffers: Buffers,
    /// The reader over the reply's body, wired up when the stream is made. It
    /// points into `buffers` and into the request, so it is made once those are
    /// where they will stay.
    reader: *std.Io.Reader,

    /// The bytes of the frame being read, kept between reads so a frame that
    /// spans two of them is not lost.
    pending: std.ArrayList(u8) = .empty,
    /// The `data:` lines of the frame being read, joined with newlines.
    data: std.ArrayList(u8) = .empty,
    /// The parsed chunk a delta points into, reset before the next one is read.
    arena: std.heap.ArenaAllocator,
    /// The token counts the provider sent, which `usage` reads.
    token_usage: Usage = .{},
    /// Whether any chunk carried a choice, so a stream that carried none can be
    /// told from a reply that is simply empty.
    saw_choice: bool = false,
    /// Whether the stream has ended: its `[DONE]` frame was read, or the body
    /// ran out. Anything after that is not the reply's.
    done: bool = false,

    /// The memory a reply's body is read through: the transfer decoding's buffer,
    /// the window the decompressor reads through, and the decompressor itself.
    ///
    /// All of it is room to read into, so nothing here is initialised until
    /// something is read. The window is the one part that is allocated, and only
    /// for a body that arrived compressed.
    pub const Buffers = struct {
        /// The buffer the transfer decoding reads through.
        transfer_buffer: [4096]u8 = undefined,
        /// The window the decompressor reads through, sized for the encoding it
        /// decompresses and empty for a body that arrived as it was sent. It is
        /// this struct's to free, since `http.Decompress` only borrows it.
        decompress_buffer: []u8,
        /// The decompressor the reader reads through, once it has been wired up.
        decompress: std.http.Decompress = undefined,

        /// The room a body that arrived as `content_encoding` is read through.
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

    /// Reads until the next piece of the reply, or null when the stream has
    /// ended. The stream ends at its `[DONE]` frame or at the end of the body;
    /// anything left then is a frame cut off mid-way, which is not the reply's.
    /// A provider that sent no choices at all is reported as `error.NoChoices`
    /// rather than as an empty reply.
    pub fn next(self: *Stream) !?Delta {
        while (!self.done) {
            if (frameEnd(self.pending.items)) |end| {
                const delta = try self.parseFrame(self.pending.items[0..end.body]);
                self.consume(end.consumed);
                if (delta) |d| return d;
                continue;
            }

            var buffer: [4096]u8 = undefined;
            var slices = [_][]u8{&buffer};
            const n = self.reader.readVec(&slices) catch |err| switch (err) {
                // The body is over. Every complete frame was taken off the
                // front of `pending` above, so what is left is a frame cut off
                // mid-way, which is not the reply's and is dropped.
                error.EndOfStream => {
                    self.done = true;
                    continue;
                },
                else => return err,
            };
            // A read may hand over no bytes without the stream being over: a
            // reader is allowed to put them in its own buffer and return zero,
            // and the next read hands them on. Reading reaches the end only as
            // `error.EndOfStream`, so zero is waited past rather than taken for
            // the end, which would cut the reply off where it stood.
            if (n > 0) try self.pending.appendSlice(self.gpa, buffer[0..n]);
        }
        if (!self.saw_choice) return error.NoChoices;
        return null;
    }

    /// The token counts the provider sent with the reply, which it sends at the
    /// end of the stream when it was asked to. A provider that sent none leaves
    /// them zero.
    pub fn usage(self: *const Stream) Usage {
        return self.token_usage;
    }

    /// Stops reading and frees the stream. A body that was not read to the end
    /// is discarded, which is what lets the connection be used again.
    pub fn deinit(self: *Stream) void {
        self.request.deinit();
        self.buffers.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn consume(self: *Stream, n: usize) void {
        const rest = self.pending.items[n..];
        std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
        self.pending.items.len = rest.len;
    }

    /// Reads one frame into a delta. Only its `data:` lines carry the JSON; the
    /// other fields, such as `event:` or a comment, are ones billy has no use
    /// for. A payload that runs over more than one line is joined back with
    /// newlines.
    fn parseFrame(self: *Stream, bytes: []const u8) !?Delta {
        self.data.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const field = std.mem.trimEnd(u8, line, "\r");
            if (field.len == 0 or field[0] == ':') continue;
            if (!std.mem.startsWith(u8, field, "data:")) continue;
            if (self.data.items.len > 0) try self.data.append(self.gpa, '\n');
            try self.data.appendSlice(self.gpa, std.mem.trim(u8, field["data:".len..], " \t"));
        }
        if (self.data.items.len == 0) return null;
        if (std.mem.eql(u8, self.data.items, "[DONE]")) {
            self.done = true;
            return null;
        }

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const chunk = std.json.parseFromSliceLeaky(Chunk, arena, self.data.items, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            // A delta that cannot be read is the provider's; the rest of the
            // reply is still worth reading, so it is reported and dropped. The
            // reply's own memory is not something to skip over.
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("a streamed delta could not be read: {s}", .{@errorName(err)});
                return null;
            },
        };
        if (chunk.@"error") |api_error| {
            std.log.warn("api error: {s}", .{api_error.message});
            return error.ApiError;
        }
        if (chunk.usage) |counts| self.token_usage = counts;
        // The request asks for one choice, so only the first is read.
        if (chunk.choices.len == 0) return null;
        self.saw_choice = true;

        const piece = chunk.choices[0].delta;
        const calls = try arena.alloc(ToolCallDelta, piece.tool_calls.len);
        for (piece.tool_calls, 0..) |fragment, index| {
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
        if (delta.content == null and delta.reasoning == null and delta.tool_calls.len == 0) return null;
        return delta;
    }
};

/// Adds the deltas of a streamed reply up into the message they spell out. The
/// message points into this, so it outlives the message's use and is freed with
/// `deinit`.
pub const Reply = struct {
    gpa: std.mem.Allocator,
    /// The answer, the model's thinking, and one set of pieces per tool call.
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    tool_calls: std.ArrayList(ToolCall) = .empty,

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

    pub fn deinit(self: *Reply) void {
        self.content.deinit(self.gpa);
        self.reasoning.deinit(self.gpa);
        for (self.calls.items) |*call| call.deinit(self.gpa);
        self.calls.deinit(self.gpa);
        self.tool_calls.deinit(self.gpa);
    }

    /// Reads `stream` to its end, adding every delta to the reply.
    pub fn collect(self: *Reply, stream: *Stream) !void {
        while (try stream.next()) |delta| try self.add(delta);
    }

    /// Adds one delta of a streamed reply.
    pub fn add(self: *Reply, delta: Delta) !void {
        if (delta.content) |text| try self.content.appendSlice(self.gpa, text);
        if (delta.reasoning) |text| try self.reasoning.appendSlice(self.gpa, text);
        for (delta.tool_calls) |fragment| try self.addCall(fragment);
    }

    /// Adds a piece of a tool call to the call its `index` names, making that call
    /// on the first piece.
    fn addCall(self: *Reply, fragment: ToolCallDelta) !void {
        while (self.calls.items.len <= fragment.index) try self.calls.append(self.gpa, .{});
        const call = &self.calls.items[fragment.index];
        if (fragment.id) |id| try set(&call.id, self.gpa, id);
        if (fragment.name) |name| try set(&call.name, self.gpa, name);
        if (fragment.arguments) |arguments| try call.arguments.appendSlice(self.gpa, arguments);
    }

    /// The message the reply adds up to, its strings pointing into this.
    pub fn message(self: *Reply) !Message {
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
};

/// Sets `list` to `text`, keeping what it already allocated.
fn set(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, text);
}

/// One chunk of a streamed reply, as the API sends it. Unknown fields are
/// ignored, and a field a chunk leaves out keeps the default, since a chunk only
/// carries what changed.
const Chunk = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,
    @"error": ?ApiError = null,

    const Choice = struct { delta: Piece = .{} };
    const Piece = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: []const Call = &.{},
    };
    /// A piece of a tool call, in the shape the API nests it.
    const Call = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        function: Function = .{},
        const Function = struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        };
    };
    /// An error sent in place of a delta, which a provider may do mid-stream.
    const ApiError = struct { message: []const u8 };
};

/// Where the blank line that ends a frame is: `body` is the length of the frame
/// without it, and `consumed` is how much of the stream the frame and the blank
/// line take. A frame may end with `\n\n` or, from a provider that uses CRLF,
/// `\r\n\r\n`.
const FrameEnd = struct { body: usize, consumed: usize };

fn frameEnd(bytes: []const u8) ?FrameEnd {
    const lf = std.mem.indexOf(u8, bytes, "\n\n") orelse std.math.maxInt(usize);
    const crlf = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse std.math.maxInt(usize);
    if (lf == std.math.maxInt(usize) and crlf == std.math.maxInt(usize)) return null;
    if (lf < crlf) return .{ .body = lf, .consumed = lf + 2 };
    return .{ .body = crlf, .consumed = crlf + 4 };
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
    var collected: Reply = .{ .gpa = gpa };
    defer collected.deinit();
    try collected.collect(stream);

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The head carried the counted length, and the bytes behind it are exactly
    // the body the counter measured, not something assembled separately.
    try std.testing.expectEqual(@as(u64, expected.len), mock.content_length.?);
    try std.testing.expectEqualStrings(expected, mock.bodies.items[0]);
    try std.testing.expectEqualStrings("hi there", collected.content.items);
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
    // The body is read to its end, so the connection the mock answered on is
    // finished with before it is checked.
    while (try stream.next()) |_| {}

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
    var collected: Reply = .{ .gpa = gpa };
    defer collected.deinit();
    try collected.collect(stream);

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The caller adds the deltas up into the reply it keeps. The model's
    // thinking arrives beside the answer and is kept apart from it, so the
    // message can carry both back to a provider that asks for them.
    try std.testing.expectEqualStrings("hello", collected.content.items);
    try std.testing.expectEqualStrings("a thought", collected.reasoning.items);
    const message = try collected.message();
    try std.testing.expectEqualStrings("a thought", message.reasoning_content.?);
    try std.testing.expectEqualStrings("hello", message.content.?);
    try std.testing.expectEqual(0, collected.calls.items.len);
    try std.testing.expectEqual(5, stream.usage().total_tokens);
}

test "a frame ends at the blank line that follows it" {
    // A body arrives in whatever pieces the network hands over, so a frame is
    // only complete once its blank line is in. The line ending may be CRLF.
    const lf = frameEnd("data: 1\n\ndata: 2\n\n").?;
    try std.testing.expectEqual(7, lf.body);
    try std.testing.expectEqual(9, lf.consumed);

    const crlf = frameEnd("data: 1\r\n\r\ndata: 2\n\n").?;
    try std.testing.expectEqual(7, crlf.body);
    try std.testing.expectEqual(11, crlf.consumed);

    try std.testing.expect(frameEnd("data: 1\ndata: 2") == null);
}

test "a reply that is not a stream is reported, not read as a plain reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Every provider billy talks to streams, so a success that is one JSON
    // object is a provider that did not answer with what it was asked for.
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

    try mock.group.await(io);
    if (mock.err) |err| return err;
}

test "a stream that carries no choices is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // An empty stream is not an empty reply: the provider said nothing at all,
    // which the caller is told rather than being handed a message with nothing
    // in it.
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream("data: [DONE]\n\n"));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 1);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    try std.testing.expectError(error.NoChoices, stream.next());

    try mock.group.await(io);
    if (mock.err) |err| return err;
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
    var collected: Reply = .{ .gpa = gpa };
    defer collected.deinit();
    try collected.collect(stream);

    try mock.group.await(io);
    if (mock.err) |err| return err;

    // The id and name arrive once and the arguments a fragment at a time; the
    // caller puts them back into the one call the model meant.
    const calls = collected.calls.items;
    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id.items);
    try std.testing.expectEqualStrings("bash", calls[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", calls[0].arguments.items);
}

test "a body only counts as a stream when its content type says so" {
    // The type may carry parameters, and the case does not matter; anything but a
    // stream, or nothing at all, is a provider that did not answer with what it
    // was asked for.
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

/// A client pointed at `url`, with the retry backoff turned off so a test costs
/// no real time. The HTTP client is the caller's, so it outlives the streams the
/// client hands back.
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

/// The answer of a mock that fails the first `fail_first` requests with a 503 and
/// succeeds after, for the retry tests.
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

    // Two failures, then the answer: three requests, and the client should make
    // exactly that many.
    var mock = try Mock.start("/chat/completions", 3, retrying(2));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 4);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};

    var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
    defer stream.deinit();
    var collected: Reply = .{ .gpa = gpa };
    defer collected.deinit();
    try collected.collect(stream);

    try mock.group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("made it", collected.content.items);
    try std.testing.expectEqual(4, stream.usage().total_tokens);
}

test "a request that keeps failing is given up on after max_attempts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Every request fails, so the client tries as many times as it is allowed.
    var mock = try Mock.start("/chat/completions", 3, retrying(3));
    defer mock.deinit();
    try mock.serve();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = clientAgainst(gpa, io, &http_client, mock.url, 3);
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};

    try std.testing.expectError(error.HttpStatus, client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{})));

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

    // Two completions through one client. A fresh HTTP client per request would
    // have to open a second connection, which this server, on one, never
    // accepts; the second request only completes because the connection is
    // reused.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    for (0..2) |_| {
        var stream = try client.complete(gpa, "01SESSION", &messages, @as([]const NoTools, &.{}));
        defer stream.deinit();
        var collected: Reply = .{ .gpa = gpa };
        defer collected.deinit();
        try collected.collect(stream);
        try std.testing.expectEqualStrings("hi", collected.content.items);
    }

    try mock.group.await(io);
    if (mock.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), mock.connections);
    try std.testing.expectEqual(@as(usize, 2), mock.served);
}
