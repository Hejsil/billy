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

const Request = struct {
    model: []const u8,
    messages: []const Message,
    tools: []const Tool,
    stream: bool = false,
};

/// The part of the response the harness uses. Unknown fields are ignored.
const Response = struct {
    choices: []const Choice = &.{},
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

    /// Sends the conversation and returns the next assistant message.
    pub fn complete(client: *Client, messages: []const Message, tools: []const Tool) !Message {
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
        return response.choices[0].message;
    }
};
