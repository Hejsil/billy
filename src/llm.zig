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
    /// keeps calling `Stream.next` until it returns null, showing each delta as
    /// it arrives; `Stream.message` is the reply those deltas add up to, and
    /// `Stream.usage` its token counts, the two of them read once the stream has
    /// ended.
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
                .user_agent = .{ .override = http.user_agent },
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
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), "text/event-stream");
}

/// zstd's window with the block it decodes into on top of it, which is what its
/// decompressor asserts it was given room for. Flate's window is smaller, and it
/// is the whole of what that one asks for.
const zstd_window_len = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;

/// A reply as it streams in. The caller keeps calling `next` until it returns
/// null, showing each delta as it arrives; the deltas are added up as they are
/// read, so `message` has the message they spell out once the stream has
/// ended, and `usage` the token counts.
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
    /// spans two of them is not lost. It is also the room the body is read into:
    /// `next` hands its buffer to the writer it reads through, so the list is
    /// empty while a read is under way.
    pending: std.ArrayList(u8) = .empty,
    /// Where the next frame starts in `pending`. A frame is moved past by
    /// moving this index, and its bytes stay where they arrived, so the buffer
    /// holds the whole of the body as it streams in.
    parsed: usize = 0,
    /// The `data:` lines of the frame being read, one after another.
    data: std.ArrayList(u8) = .empty,
    /// The parsed chunk a delta points into, reset before the next one is read.
    arena: std.heap.ArenaAllocator,
    /// The token counts the provider sent, which `usage` reads.
    token_usage: Usage = .{},
    /// The answer, the model's thinking, and one set of pieces per tool call,
    /// added up from every delta as it is read, which `message` spells out.
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    /// The calls `message` hands back, which point into `calls`.
    tool_calls: std.ArrayList(ToolCall) = .empty,
    /// Whether the stream has ended: its `[DONE]` frame was read, or the body
    /// ran out. Anything after that is not the reply's.
    done: bool = false,

    /// The pieces of one tool call, which arrive a fragment at a time and make
    /// the `ToolCall` `message` hands back.
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
    /// ended, adding the piece to the message as it is read. The stream ends at
    /// its `[DONE]` frame or at the end of the body; anything left then is a
    /// frame cut off mid-way, which is not the reply's. A provider that sent no
    /// choices at all streams nothing, which is an empty reply rather than an
    /// error: what that means is the caller's to say.
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

    /// The token counts the provider sent with the reply, which it sends at the
    /// end of the stream when it was asked to. A provider that sent none leaves
    /// them zero.
    pub fn usage(self: *const Stream) Usage {
        return self.token_usage;
    }

    /// The message the deltas added up to, its strings pointing into the
    /// stream. Read once the stream has ended: a reply that has not finished
    /// arriving is not all there.
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

    /// Stops reading and frees the stream. A body that was not read to the end
    /// is discarded, which is what lets the connection be used again.
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

    /// Adds one delta to the message, copying the strings it points into the
    /// stream, since the stream's own copy is what outlives it.
    fn add(self: *Stream, delta: Delta) !void {
        if (delta.content) |text| try self.content.appendSlice(self.gpa, text);
        if (delta.reasoning) |text| try self.reasoning.appendSlice(self.gpa, text);
        for (delta.tool_calls) |fragment| try self.addCall(fragment);
    }

    /// Adds a piece of a tool call to the call its `index` names, making that
    /// call on the first piece.
    fn addCall(self: *Stream, fragment: ToolCallDelta) !void {
        while (self.calls.items.len <= fragment.index) try self.calls.append(self.gpa, .{});
        const call = &self.calls.items[fragment.index];
        if (fragment.id) |id| try set(&call.id, self.gpa, id);
        if (fragment.name) |name| try set(&call.name, self.gpa, name);
        if (fragment.arguments) |arguments| try call.arguments.appendSlice(self.gpa, arguments);
    }

    /// Reads one frame into a delta. Only its `data:` lines carry the JSON; the
    /// other fields, such as `event:` or a comment, are ones billy has no use
    /// for. A payload that runs over more than one line is put back together,
    /// its lines one after another: JSON counts the newline between them as
    /// whitespace, so it is not put back.
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
            // A delta that cannot be read is the provider's; the rest of the
            // reply is still worth reading, so it is reported and dropped. The
            // reply's own memory is not something to skip over.
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
        // The request asks for one choice, so only the first is read.
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

/// Sets `list` to `text`, keeping what it already allocated.
fn set(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, text);
}

/// One chunk of a streamed reply, as the API sends it. Unknown fields are
/// ignored, and a field a chunk leaves out keeps the default, since a chunk only
/// carries what changed. A field a provider writes as an explicit `null` has to
/// be optional for the same reason a missing field does: a null read as a slice
/// is `UnexpectedToken`, which throws away a delta that was perfectly readable.
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
    while (try stream.next()) |_| {}

    try mock.await();

    // The head carried the counted length, and the bytes behind it are exactly
    // the body the counter measured, not something assembled separately.
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
    // The body is read to its end, so the connection the mock answered on is
    // finished with before it is checked.
    while (try stream.next()) |_| {}

    try mock.await();

    // The HTTP client's own name is the library's, which a provider that
    // watches its traffic for abuse asks clients not to send, and the session
    // is what a provider routes and caches a conversation by, so both have to
    // reach the wire.
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
    // The frames that carry nothing but a finish reason or a usage count are
    // not deltas, so the reply arrives in the three pieces that say something.
    var deltas: usize = 0;
    while (try stream.next()) |_| deltas += 1;

    try mock.await();

    try std.testing.expectEqual(3, deltas);

    // The stream adds the deltas up as it reads them. The model's thinking
    // arrives beside the answer and is kept apart from it, so the message can
    // carry both back to a provider that asks for them.
    const message = try stream.message();
    try std.testing.expectEqualStrings("hello", message.content.?);
    try std.testing.expectEqualStrings("a thought", message.reasoning_content.?);
    try std.testing.expect(message.tool_calls == null);
    try std.testing.expectEqual(5, stream.usage().total_tokens);
}

test "a delta that spells its fields as null is read, not dropped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider may write a field it has nothing for as an explicit null
    // rather than leaving it out, and it may do so in every field of the chunk
    // at once. The text and the thinking beside those nulls are the reply, so a
    // chunk that reads as unparseable loses a piece of it.
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

    // The finish reason is not a delta, so the two that carry text are the
    // whole reply: both were read, and the second one's nulls cost nothing.
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

    // A provider may compress the events, and a compressed body is read through
    // a decoder that keeps what it has decoded in a buffer of its own. That
    // buffer is only handed over by a read through the reader, so a stream read
    // any other way would lose the whole body.
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

    // A body arrives in whatever pieces the network hands over, and this one is
    // larger than any buffer it passes through, so the frame carrying it is cut
    // in two by the reads that bring it. The rest of a frame is found where the
    // frame before it ended, not at the front of what was last read.
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

    // OpenAI sends a chunk's JSON on one line, but that is its serializer's
    // doing and not something a client may lean on: the format is a stream of
    // events, an event's payload is every one of its `data:` lines, and a
    // provider built on a generic emitter that splits on newlines -- one that
    // pretty-prints its JSON, say -- sends the object over several of them. What
    // this holds to is that every line is taken, which is the part a rewrite can
    // lose. Whether the newline is put back between them cannot be seen from the
    // chunk that comes out: JSON counts it as whitespace, so a payload that
    // parses parses with or without it.
    const messages = [_]Message{.{ .role = .user, .content = "hi" }};
    var mock = try Mock.start("/chat/completions", 1, Mock.eventStream(
        "data: {\n" ++
            "data:   \"choices\": [\n" ++
            "data:     {\"delta\": {\"content\": \"hel\"}}\n" ++
            "data:   ]\n" ++
            "data: }\n\n" ++
            // The frame after a joined one starts where the last one ended.
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

    // One frame is one delta, however many lines its payload took, so the test
    // counts the deltas it is handed rather than reading the message, which
    // adds them up.
    var deltas: usize = 0;
    while (try stream.next()) |_| deltas += 1;

    try mock.await();

    try std.testing.expectEqual(2, deltas);
    try std.testing.expectEqualStrings("hello", (try stream.message()).content.?);
}

test "the fields beside data carry nothing billy reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A frame may carry an event name and an id, which billy has no use for,
    // and a server may send a comment as a keepalive, which is a frame that is
    // only a comment. None of them is the reply, and none of them ends it.
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

    // The keepalives are not deltas, so they leave no trace in the reply.
    try std.testing.expectEqualStrings("hi there", (try stream.message()).content.?);
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

test "a stream whose lines end with CRLF is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider is free to end its lines the way HTTP allows. What this holds
    // to is that a frame that ends this way is found at all, which is what makes
    // the stream read rather than run to its end unparsed; the carriage return
    // taken off the field is one JSON would have read as whitespace anyway. The
    // payload below runs over two lines, so both trims are on the way.
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

    try mock.await();
}

test "a stream that carries no choices is an empty reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A provider that says nothing at all streams no choices, which reads as an
    // empty reply: the caller decides what a reply with nothing in it means,
    // rather than being handed an error for it here.
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

    // Nothing was said, so the message has nothing in it: no text, no thinking
    // and no call, which is what an empty reply is.
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

    // The id and name arrive once and the arguments a fragment at a time; the
    // stream puts them back into the one call the model meant.
    const calls = (try stream.message()).tool_calls.?;
    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("bash", calls[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", calls[0].function.arguments);
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
    while (try stream.next()) |_| {}

    try mock.await();

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("made it", (try stream.message()).content.?);
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

    try mock.await();
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
        while (try stream.next()) |_| {}
        try std.testing.expectEqualStrings("hi", (try stream.message()).content.?);
    }

    try mock.await();
    try std.testing.expectEqual(@as(usize, 1), mock.connections);
    try std.testing.expectEqual(@as(usize, 2), mock.served);
}
