//! Web search: one query out to a backend, a short list of results back.
//!
//! Only Tavily so far. Which backend is the configuration's choice, so a second
//! is a variant in `Provider`, its endpoint beside it, a branch in
//! `Client.search`, and the credential it is asked with in `credentials.Service`;
//! nothing outside those files names a backend.

const std = @import("std");
const Io = std.Io;
const Mock = @import("mock.zig");

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
    /// The one HTTP client of the run, borrowed by pointer so a query shares
    /// connections and scanned certificates with everything else that makes a
    /// request. The run owns it and outlives this.
    http: *std.http.Client,

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

        var body_writer: std.Io.Writer.Allocating = .init(client.gpa);
        defer body_writer.deinit();

        const result = try client.http.fetch(.{
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
        return render(arena, parsed.results);
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
///
/// The shape is meant to be read back as easily as it is read. Each result is
/// one heading line at the margin -- `N. title` -- and then, indented under it,
/// its url and its snippet, one field to a line. Nothing inside a field can
/// reach the margin, since every field carries the indent and every newline in
/// one is turned into a space, so a line at the margin is always a heading and a
/// blank line always falls between two results. See `parseResults`.
///
/// `allocator` owns the result and the buffer it is built in, so one allocator
/// does for the whole thing.
fn render(allocator: std.mem.Allocator, results: []const Response.Result) ![]const u8 {
    if (results.len == 0) return allocator.dupe(u8, "(no results)");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (results, 1..) |result, number| {
        if (number > 1) try out.writer.writeByte('\n');
        try out.writer.print("{d}. ", .{number});
        try writeField(&out.writer, result.title);
        try out.writer.writeByte('\n');
        try out.writer.writeAll(indent);
        try writeField(&out.writer, result.url);
        try out.writer.writeByte('\n');
        // A result with no snippet is still worth its title and url, so the
        // line is left out rather than written empty.
        if (std.mem.trim(u8, result.content, " \t\r\n").len == 0) continue;
        try out.writer.writeAll(indent);
        try writeField(&out.writer, result.content);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

/// The prefix a result's url and snippet are written under, so a line that
/// reaches the margin is the heading of a result and a line under it a field.
const indent = "   ";

/// Writes one field of a result on one line: the surrounding whitespace trimmed
/// and every newline turned into a space, so the field stays on the one line the
/// reading back expects, however the backend wrote it.
fn writeField(out: *Io.Writer, text: []const u8) !void {
    for (std.mem.trim(u8, text, " \t\r\n")) |c| {
        try out.writeByte(switch (c) {
            '\n', '\r' => ' ',
            else => c,
        });
    }
}

/// One result read out of the text `render` wrote.
pub const Found = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

/// Reads back the results `render` wrote, one at a time. Every value is a slice
/// of the text it reads, so nothing is copied and nothing has to be freed, and a
/// caller that wants them twice simply reads the text again.
///
/// A result begins at a line that reaches the margin -- `N. title` -- and its
/// url and snippet are the next fields under it. A line that does not reach the
/// margin is part of no heading, so it is skipped; that is what makes text that
/// is not a result list, such as `(no results)`, yield nothing rather than
/// something wrong.
pub const Results = struct {
    rest: []const u8,

    pub fn next(self: *Results) ?Found {
        while (self.rest.len > 0) {
            const line = takeLine(&self.rest);
            const marker = markerLen(line) orelse continue;
            const title = std.mem.trimEnd(u8, line[marker..], " \t\r");
            // The url line is always written; the snippet only when there is
            // one, which the next line being a field tells.
            const url = self.field() orelse "";
            const snippet = self.field() orelse "";
            return .{ .title = title, .url = url, .snippet = snippet };
        }
        return null;
    }

    /// The next field, trimmed, consumed; null when the next line is blank or a
    /// heading, which is where this result ends.
    fn field(self: *Results) ?[]const u8 {
        var ahead = self.rest;
        const line = takeLine(&ahead);
        if (markerLen(line) != null) return null;
        const value = std.mem.trim(u8, line, " \t\r");
        if (value.len == 0) return null;
        self.rest = ahead;
        return value;
    }
};

/// Reads the results out of `text`, which is the text `render` wrote.
pub fn parseResults(text: []const u8) Results {
    return .{ .rest = text };
}

/// The next line of `text`, advancing it past the newline that ends it. The last
/// line of a text without a newline is the whole of what is left.
fn takeLine(text: *[]const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text.*, '\n') orelse text.*.len;
    const line = text.*[0..end];
    text.* = if (end < text.*.len) text.*[end + 1 ..] else text.*[text.*.len..];
    return line;
}

/// The length of the `N. ` heading at the start of `line`, or null when the line
/// is not one. Only a heading reaches the margin, so this is what tells a result
/// from the text under it.
fn markerLen(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i >= line.len or line[i] != '.') return null;
    i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    return i;
}

test "results are formatted as a numbered list of title, url and snippet" {
    const gpa = std.testing.allocator;

    const results = [_]Response.Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .content = "A language." },
        // A result with no snippet is still worth its title and url.
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
    };
    const text = try render(gpa, &results);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "a query that matched nothing says so" {
    const gpa = std.testing.allocator;

    const text = try render(gpa, &.{});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("(no results)", text);
}

test "the list reads back as the results it was built from" {
    const gpa = std.testing.allocator;

    const results = [_]Response.Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .content = "A language." },
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
        .{ .title = "Blog", .url = "https://ziglang.org/blog", .content = "Notes." },
    };
    const text = try render(gpa, &results);
    defer gpa.free(text);

    var parsed = parseResults(text);
    for (results) |expected| {
        const found = parsed.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.title, found.title);
        try std.testing.expectEqualStrings(expected.url, found.url);
        try std.testing.expectEqualStrings(expected.content, found.snippet);
    }
    try std.testing.expect(parsed.next() == null);
}

test "a field with a newline in it does not read as another result" {
    const gpa = std.testing.allocator;

    // A title and a snippet that would each read as a heading or a field if the
    // newlines in them were kept, so the shape has to fold them away.
    const results = [_]Response.Result{.{
        .title = "Node.js\n2. Not a result",
        .url = "https://nodejs.org",
        .content = "One line.\n\n3. Also not a result",
    }};
    const text = try render(gpa, &results);
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "1. Node.js 2. Not a result\n" ++
            "   https://nodejs.org\n" ++
            "   One line.  3. Also not a result\n",
        text,
    );

    // Read back it is one result, with the newlines folded to spaces.
    var parsed = parseResults(text);
    const found = parsed.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Node.js 2. Not a result", found.title);
    try std.testing.expectEqualStrings("https://nodejs.org", found.url);
    try std.testing.expectEqualStrings("One line.  3. Also not a result", found.snippet);
    try std.testing.expect(parsed.next() == null);
}

test "text that is not a list of results reads back as none" {
    var parsed = parseResults("(no results)");
    try std.testing.expect(parsed.next() == null);
}

test "a tavily search posts the query and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A backend standing in for Tavily, answering with a fixed reply and
    // recording what it was sent.
    const reply =
        \\{"query":"zig lang","results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","content":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","content":""}]}
    ;
    var mock = try Mock.start(gpa, io, "/search", 1, Mock.fixed(reply));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .provider = .tavily,
        .api_key = "secret",
        .max_results = 3,
        .http = &http,
    };
    // `tavily` leaves the parsed reply and the list it built in the caller's
    // allocator, so it gets an arena; the rest is the testing allocator, which
    // reports anything not freed.
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.tavily(reply_state.allocator(), "zig lang", mock.url, 3);
    try group.await(io);
    if (mock.err) |err| return err;

    // The query and the count went out as Tavily's body, the key as a bearer
    // token, and the reply became the numbered list the model reads.
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig lang\",\"max_results\":3,\"search_depth\":\"basic\",\"include_answer\":false}",
        mock.bodies.items[0],
    );
    try std.testing.expectEqualStrings("Bearer secret", mock.authorization.?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}
