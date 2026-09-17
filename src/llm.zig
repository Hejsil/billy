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

const Request = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const Tool,
    stream: bool = false,
};

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
    /// Holds the conversation, including parsed responses.
    arena: std.mem.Allocator,
    io: Io,
    api_key: []const u8,
    /// Full URL of the chat completions endpoint.
    url: []const u8,
    model: []const u8,

    /// Sends the conversation and returns the next assistant message together
    /// with the tokens the request used.
    pub fn complete(client: *Client, messages: []const Message, tools: []const Tool) !Completion {
        const body = try std.json.Stringify.valueAlloc(client.gpa, Request{
            .model = client.model,
            .messages = messages,
            .tools = tools,
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        var http: std.http.Client = .{ .allocator = client.gpa, .io = client.io };
        defer http.deinit();

        var body_writer: std.Io.Writer.Allocating = .init(client.gpa);
        defer body_writer.deinit();

        const result = try http.fetch(.{
            .location = .{ .url = client.url },
            .method = .POST,
            .payload = body,
            .response_writer = &body_writer.writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
            },
        });

        const text = body_writer.written();
        // The response buffer is freed when this function returns, so the
        // strings in the parsed message must be copies.
        const response = std.json.parseFromSliceLeaky(Response, client.arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err("HTTP {d}: {s}", .{ @intFromEnum(result.status), text });
            return err;
        };
        if (response.@"error") |api_error| {
            std.log.err("api error: {s}", .{api_error.message});
            return error.ApiError;
        }
        if (response.choices.len == 0) {
            std.log.err("HTTP {d} without choices: {s}", .{ @intFromEnum(result.status), text });
            return error.NoChoices;
        }
        // A provider that omits usage leaves the totals at zero, so the session
        // totals under-report rather than the request failing.
        return .{
            .message = response.choices[0].message,
            .usage = if (response.usage) |reported| reported.normalized() else .{},
        };
    }
};

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
