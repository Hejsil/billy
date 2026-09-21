//! Web search: one query out to a backend, a short list of results back.
//!
//! Only Tavily so far. Which backend is the configuration's choice, so a second
//! is a variant in `Provider`, its endpoint beside it, a branch in
//! `Client.search`, and the credential it is asked with in `credentials.Service`;
//! nothing outside those files names a backend.

const std = @import("std");
const Io = std.Io;

/// The backends billy can search with. The name is what the configuration holds,
/// stored as the variant itself so an unknown name is refused when the file is
/// read rather than carried around as a string.
pub const Provider = enum {
    tavily,

    /// Where a query is posted.
    fn endpoint(provider: Provider) []const u8 {
        return switch (provider) {
            .tavily => "https://api.tavily.com/search",
        };
    }
};

/// What the configuration says about searching, with the key already resolved.
/// A null of this in a tool set is what leaves web search out of a request.
pub const Config = struct {
    provider: Provider,
    api_key: []const u8,
    /// Results asked for per query. The backend may return fewer.
    max_results: usize,
};

/// Most results a backend is asked for, whatever the configuration says, so one
/// query cannot be turned into a wall of text.
const result_limit = 20;

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    provider: Provider,
    api_key: []const u8,
    max_results: usize,

    /// Runs one query and returns the results as the text the model reads: each
    /// result's title, its url and its snippet, in the order the backend ranked
    /// them. `arena` owns the result, which is what the caller keeps.
    pub fn search(client: *Client, arena: std.mem.Allocator, query: []const u8) ![]const u8 {
        const requested = std.math.clamp(client.max_results, 1, result_limit);
        return switch (client.provider) {
            .tavily => client.tavily(arena, query, client.provider.endpoint(), requested),
        };
    }

    /// One Tavily search, posted to `endpoint`, which is the provider's own or a
    /// test server's. The request and the response are Tavily's shape; keeping
    /// the endpoint a parameter is what lets the wire format be tested without
    /// the network.
    ///
    /// The body is small, since it is one query, so it is built as a string;
    /// a whole conversation is the only thing too large to stringify, and this
    /// is not one.
    fn tavily(
        client: *Client,
        arena: std.mem.Allocator,
        query: []const u8,
        endpoint: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, Request{
            .query = query,
            .max_results = max_results,
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const authorization = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(authorization);

        var http: std.http.Client = .{ .allocator = client.gpa, .io = client.io };
        defer http.deinit();

        var body_writer: std.Io.Writer.Allocating = .init(client.gpa);
        defer body_writer.deinit();

        const result = try http.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = body,
            .response_writer = &body_writer.writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
            },
        });

        const text = body_writer.written();
        if (result.status.class() != .success) {
            std.log.err("search: HTTP {d}: {s}", .{ @intFromEnum(result.status), text });
            return error.SearchFailed;
        }
        // The response buffer is freed when this function returns, so the
        // strings in the parsed results are copies in `arena`.
        const parsed = std.json.parseFromSliceLeaky(Response, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err("search: HTTP {d}: {s}", .{ @intFromEnum(result.status), text });
            return err;
        };
        return render(client.gpa, arena, parsed.results);
    }
};

/// The body a Tavily search is posted with. `basic` depth is the fast, cheaper
/// one and is enough to rank sources; no synthesized answer is asked for, since
/// the model reads the sources itself.
const Request = struct {
    query: []const u8,
    max_results: usize,
    search_depth: []const u8 = "basic",
    include_answer: bool = false,
};

/// The part of a Tavily response billy uses. The rest, such as the answer and
/// the scores, is ignored.
const Response = struct {
    results: []const Result = &.{},

    pub const Result = struct {
        title: []const u8 = "",
        url: []const u8 = "",
        content: []const u8 = "",
    };
};

/// Formats results as the numbered list the model reads and the user sees the
/// top of: each result's title, its url, and whatever snippet the backend
/// returned. A query that matched nothing says so, which is not an error.
fn render(gpa: std.mem.Allocator, arena: std.mem.Allocator, results: []const Response.Result) ![]const u8 {
    if (results.len == 0) return arena.dupe(u8, "(no results)");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (results, 1..) |result, number| {
        if (number > 1) try out.writer.writeAll("\n");
        try out.writer.print("{d}. {s}\n{s}\n", .{ number, result.title, result.url });
        if (result.content.len > 0) try out.writer.print("{s}\n", .{result.content});
    }
    return arena.dupe(u8, out.written());
}

test "results are formatted as a numbered list of title, url and snippet" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const results = [_]Response.Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .content = "A language." },
        // A result with no snippet is still worth its title and url.
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
    };
    try std.testing.expectEqualStrings(
        "1. Zig\nhttps://ziglang.org\nA language.\n\n2. Docs\nhttps://ziglang.org/documentation\n",
        try render(gpa, arena_state.allocator(), &results),
    );
}

test "a query that matched nothing says so" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("(no results)", try render(gpa, arena_state.allocator(), &.{}));
}

/// Stands in for the backend over a real socket: it records what the client put
/// on the connection and answers with a fixed Tavily-shaped body. A live
/// connection is the only way to see the request the client actually sends.
const TestBackend = struct {
    /// The request body as it arrived, owned by `std.testing.allocator`.
    body: ?[]u8 = null,
    /// The authorization header as it arrived, owned by `std.testing.allocator`.
    authorization: ?[]u8 = null,
    /// The first failure the server ran into, so the test reports it rather than
    /// the connection simply hanging.
    err: ?anyerror = null,

    const reply =
        \\{"query":"zig lang","results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","content":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","content":""}]}
    ;

    fn serve(io: Io, listener: *std.Io.net.Server, self: *TestBackend) Io.Cancelable!void {
        self.run(io, listener) catch |err| {
            self.err = err;
        };
    }

    fn run(self: *TestBackend, io: Io, listener: *std.Io.net.Server) !void {
        var stream = try listener.accept(io);
        defer stream.close(io);

        var in_buffer: [4096]u8 = undefined;
        var out_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);

        var request = try server.receiveHead();
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                self.authorization = try std.testing.allocator.dupe(u8, header.value);
            }
        }

        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        self.body = try body_reader.allocRemaining(std.testing.allocator, .unlimited);

        try request.respond(reply, .{ .keep_alive = false });
    }
};

test "a tavily search posts the query and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var backend: TestBackend = .{};
    defer {
        if (backend.body) |body| gpa.free(body);
        if (backend.authorization) |authorization| gpa.free(authorization);
    }

    var group: Io.Group = .init;
    try group.concurrent(io, TestBackend.serve, .{ io, &listener, &backend });

    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/search", .{
        listener.socket.address.getPort(),
    });
    defer gpa.free(endpoint);

    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .provider = .tavily,
        .api_key = "secret",
        .max_results = 3,
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const text = try client.tavily(arena_state.allocator(), "zig lang", endpoint, 3);
    try group.await(io);
    if (backend.err) |err| return err;

    // The query and the count went out as Tavily's body, the key as a bearer
    // token, and the reply became the numbered list the model reads.
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig lang\",\"max_results\":3,\"search_depth\":\"basic\",\"include_answer\":false}",
        backend.body.?,
    );
    try std.testing.expectEqualStrings("Bearer secret", backend.authorization.?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\nhttps://ziglang.org\nA language.\n\n" ++
            "2. Docs\nhttps://ziglang.org/documentation\n",
        text,
    );
}
