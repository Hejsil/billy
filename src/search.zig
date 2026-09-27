//! Web search and fetch: a query out to a backend for a list of results, and a
//! url in for its content.
//!
//! Tavily and Exa so far. Which backend is the configuration's choice, so another
//! is a variant in `Provider`, its endpoints beside it, a branch in
//! `Client.search` and `Client.extract`, and the credential it is asked with in
//! `credentials.Service`; nothing outside those files names a backend. Every
//! backend's results are mapped into one `Result`, so there is one place that
//! writes them. A `raw` fetch skips the backend and reads the url directly.

const std = @import("std");
const Io = std.Io;
const Mock = @import("mock.zig");

/// The backends billy can search with. The name is what the configuration holds,
/// stored as the variant itself so an unknown name is refused when the file is
/// read rather than carried around as a string.
pub const Provider = enum {
    tavily,
    exa,

    /// Where a query is sent. A backend that takes a GET carries the query in
    /// the url; one that takes a POST carries it in a JSON body.
    fn endpoint(provider: Provider) []const u8 {
        return switch (provider) {
            .tavily => "https://api.tavily.com/search",
            .exa => "https://api.exa.ai/search",
        };
    }

    /// Where a url is extracted, or null for a backend with no extraction:
    /// `Client.extract` then reads the url itself.
    fn extractEndpoint(provider: Provider) ?[]const u8 {
        return switch (provider) {
            .tavily => "https://api.tavily.com/extract",
            .exa => "https://api.exa.ai/contents",
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

/// One search result as the model reads it: the shape `render` writes and
/// `parseResults` reads back. Every backend's own results are mapped into it.
pub const Result = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    snippet: []const u8 = "",
};

/// Most results a backend is asked for, whatever the configuration says, so one
/// query cannot be turned into a wall of text.
const result_limit = 20;

/// Most characters a result's snippet is asked to hold, so a backend that would
/// return a whole page of text still comes back as a list of results.
const snippet_len = 500;

/// Most bytes a direct fetch keeps, so one large response cannot exhaust memory.
/// A page comes through the backend instead, which trims it; this is for the
/// `raw` path, where an API or a file is small.
const max_fetch_bytes = 1 << 20;

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
        const endpoint = client.provider.endpoint();
        return switch (client.provider) {
            .tavily => client.tavily(arena, query, endpoint, requested),
            .exa => client.exa(arena, query, endpoint, requested),
        };
    }

    /// Fetches one url and returns its content as the text the model reads,
    /// which `arena` owns.
    ///
    /// A page is extracted by the backend, which reads it and returns its text,
    /// so billy does not parse HTML itself. A `raw` fetch, and a backend with no
    /// extraction endpoint, read the url directly instead: the bytes come back as
    /// the server sent them, which is what an API returning JSON wants.
    pub fn extract(client: *Client, arena: std.mem.Allocator, url: []const u8, raw: bool) ![]const u8 {
        if (!raw) {
            if (client.provider.extractEndpoint()) |endpoint| {
                return switch (client.provider) {
                    .tavily => client.tavilyExtract(arena, url, endpoint),
                    .exa => client.exaContents(arena, url, endpoint),
                };
            }
        }
        return client.get(arena, url);
    }

    /// One Tavily search, posted to `endpoint`, which is the provider's own or a
    /// test server's. The request and the response are Tavily's shape; keeping
    /// the endpoint a parameter is what lets the wire format be tested without
    /// the network.
    fn tavily(
        client: *Client,
        arena: std.mem.Allocator,
        query: []const u8,
        endpoint: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, TavilyRequest{
            .query = query,
            .max_results = max_results,
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const auth = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(auth);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "authorization", .value = auth },
        }, "search")) orelse return error.SearchFailed;
        const parsed = try parse(TavilyResponse, arena, text, "search");
        return render(arena, try mapped(arena, parsed.results, "content"));
    }

    /// One Tavily extraction. The url's text is the backend's; a url the backend
    /// could not read comes back as `error.FetchFailed`.
    fn tavilyExtract(
        client: *Client,
        arena: std.mem.Allocator,
        url: []const u8,
        endpoint: []const u8,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, TavilyExtractRequest{
            .urls = &.{url},
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const auth = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{client.api_key});
        defer client.gpa.free(auth);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "authorization", .value = auth },
        }, "fetch")) orelse return error.FetchFailed;
        const parsed = try parse(TavilyExtractResponse, arena, text, "fetch");
        if (parsed.results.len == 0) {
            for (parsed.failed_results) |failed| {
                std.log.warn("fetch: {s}: {s}", .{ failed.url, failed.@"error" });
            }
            return error.FetchFailed;
        }
        return parsed.results[0].raw_content;
    }

    /// One Exa search, posted to `endpoint`. Exa would return the whole page of
    /// each result, so the text is asked for capped: a search is a list of
    /// snippets, and a page is what `web_fetch` is for.
    fn exa(
        client: *Client,
        arena: std.mem.Allocator,
        query: []const u8,
        endpoint: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, ExaRequest{
            .query = query,
            .numResults = max_results,
            .contents = .{ .text = .{ .maxCharacters = snippet_len } },
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "x-api-key", .value = client.api_key },
        }, "search")) orelse return error.SearchFailed;
        const parsed = try parse(ExaResponse, arena, text, "search");
        return render(arena, try mapped(arena, parsed.results, "text"));
    }

    /// One Exa extraction, posted to `endpoint`.
    fn exaContents(
        client: *Client,
        arena: std.mem.Allocator,
        url: []const u8,
        endpoint: []const u8,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, ExaContentsRequest{
            .urls = &.{url},
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "x-api-key", .value = client.api_key },
        }, "fetch")) orelse return error.FetchFailed;
        const parsed = try parse(ExaContentsResponse, arena, text, "fetch");
        if (parsed.results.len == 0 or parsed.results[0].text.len == 0) return error.FetchFailed;
        return parsed.results[0].text;
    }

    /// Reads `url` directly with a GET: the bytes as the server sent them, capped
    /// so one large response cannot exhaust memory.
    fn get(client: *Client, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
        const text = (try client.request(arena, .GET, url, null, &.{}, "fetch")) orelse
            return error.FetchFailed;
        return text[0..@min(text.len, max_fetch_bytes)];
    }

    /// Does one request and returns its body, copied into `arena`, or null when
    /// the status is not a success, which is logged under `what`.
    fn request(
        client: *Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        location: []const u8,
        payload: ?[]const u8,
        headers: []const std.http.Header,
        what: []const u8,
    ) !?[]const u8 {
        var body_writer: std.Io.Writer.Allocating = .init(client.gpa);
        defer body_writer.deinit();

        const result = try client.http.fetch(.{
            .location = .{ .url = location },
            .method = method,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .headers = .{
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = headers,
        });
        const text = body_writer.written();
        if (result.status.class() != .success) {
            std.log.err("{s}: HTTP {d}: {s}", .{ what, @intFromEnum(result.status), text });
            return null;
        }
        return try arena.dupe(u8, text);
    }
};

/// Parses a backend's reply, copying its strings out of the body so they outlive
/// it. A body that cannot be read is logged and returned.
fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8, what: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("{s}: cannot read the reply: {s}", .{ what, @errorName(err) });
        return err;
    };
}

/// A backend's results in the one shape `render` writes, where `snippet` names
/// the field that backend puts its text in.
fn mapped(arena: std.mem.Allocator, backend_results: anytype, comptime snippet: []const u8) ![]const Result {
    const results = try arena.alloc(Result, backend_results.len);
    for (backend_results, results) |result, *one| {
        one.* = .{ .title = result.title, .url = result.url, .snippet = @field(result, snippet) };
    }
    return results;
}

/// The body a Tavily search is posted with. `basic` depth is the fast, cheaper
/// one and is enough to rank sources; no synthesized answer is asked for, since
/// the model reads the sources itself.
const TavilyRequest = struct {
    query: []const u8,
    max_results: usize,
    search_depth: []const u8 = "basic",
    include_answer: bool = false,
};

/// The part of a Tavily search response billy uses. The rest, such as the answer
/// and the scores, is ignored.
const TavilyResponse = struct {
    results: []const TavilyResult = &.{},
};

/// One Tavily result: its snippet is the `content` field.
const TavilyResult = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

/// The body a Tavily extraction is posted with.
const TavilyExtractRequest = struct {
    urls: []const []const u8,
};

/// The part of a Tavily extraction response billy uses: the content of each url
/// it read, and why it could not read the others.
const TavilyExtractResponse = struct {
    results: []const TavilyExtractResult = &.{},
    failed_results: []const TavilyExtractFailure = &.{},
};

const TavilyExtractResult = struct {
    raw_content: []const u8 = "",
};

const TavilyExtractFailure = struct {
    url: []const u8 = "",
    @"error": []const u8 = "",
};

/// The body an Exa search is posted with. The text it returns is capped, so a
/// result is a snippet rather than the whole page.
const ExaRequest = struct {
    query: []const u8,
    numResults: usize,
    contents: Contents,

    const Contents = struct {
        text: Text,
    };

    const Text = struct {
        maxCharacters: usize,
    };
};

/// The part of an Exa search response billy uses.
const ExaResponse = struct {
    results: []const ExaResult = &.{},
};

/// One Exa result: its snippet is the `text` field.
const ExaResult = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    text: []const u8 = "",
};

/// The body an Exa extraction is posted with.
const ExaContentsRequest = struct {
    urls: []const []const u8,
};

/// The part of an Exa extraction response billy uses: the text of each url.
const ExaContentsResponse = struct {
    results: []const ExaContent = &.{},
};

const ExaContent = struct {
    url: []const u8 = "",
    text: []const u8 = "",
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
fn render(allocator: std.mem.Allocator, results: []const Result) ![]const u8 {
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
        if (std.mem.trim(u8, result.snippet, " \t\r\n").len == 0) continue;
        try out.writer.writeAll(indent);
        try writeField(&out.writer, result.snippet);
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

    pub fn next(self: *Results) ?Result {
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

    const results = [_]Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A language." },
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

    const results = [_]Result{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A language." },
        .{ .title = "Docs", .url = "https://ziglang.org/documentation" },
        .{ .title = "Blog", .url = "https://ziglang.org/blog", .snippet = "Notes." },
    };
    const text = try render(gpa, &results);
    defer gpa.free(text);

    var parsed = parseResults(text);
    for (results) |expected| {
        const found = parsed.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.title, found.title);
        try std.testing.expectEqualStrings(expected.url, found.url);
        try std.testing.expectEqualStrings(expected.snippet, found.snippet);
    }
    try std.testing.expect(parsed.next() == null);
}

test "a field with a newline in it does not read as another result" {
    const gpa = std.testing.allocator;

    // A title and a snippet that would each read as a heading or a field if the
    // newlines in them were kept, so the shape has to fold them away.
    const results = [_]Result{.{
        .title = "Node.js\n2. Not a result",
        .url = "https://nodejs.org",
        .snippet = "One line.\n\n3. Also not a result",
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
    try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "a tavily extraction posts the url and reads its content back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[{\"url\":\"https://ziglang.org\",\"raw_content\":\"# Zig\\n\\nA language.\"}],\"failed_results\":[]}";
    var mock = try Mock.start(gpa, io, "/extract", 1, Mock.fixed(reply));
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
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.tavilyExtract(reply_state.allocator(), "https://ziglang.org", mock.url);
    try group.await(io);
    if (mock.err) |err| return err;

    // The url went out as Tavily's body and the key as a bearer token.
    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}

test "a url tavily could not read is a failure, not empty content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[],\"failed_results\":[{\"url\":\"https://nope.invalid\",\"error\":\"not found\"}]}";
    var mock = try Mock.start(gpa, io, "/extract", 1, Mock.fixed(reply));
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
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    try std.testing.expectError(
        error.FetchFailed,
        client.tavilyExtract(reply_state.allocator(), "https://nope.invalid", mock.url),
    );
    try group.await(io);
    if (mock.err) |err| return err;
}

test "a raw fetch reads the url directly, without the backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The bytes come back exactly as sent, so a JSON body is not escaped as
    // markdown, which is what the backend would do to it.
    const reply = "{\"node_id\":\"abc\",\"full_name\":\"a/b\"}";
    var mock = try Mock.start(gpa, io, "/api", 1, Mock.fixed(reply));
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
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.extract(reply_state.allocator(), mock.url, true);
    try group.await(io);
    if (mock.err) |err| return err;

    // No authorization went out: the url was read directly, not through Tavily.
    try std.testing.expect(mock.header("authorization") == null);
    try std.testing.expectEqualStrings(reply, text);
}

test "an exa search posts the query and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply =
        \\{"results":[
        \\ {"title":"Zig Programming Language","url":"https://ziglang.org","text":"A language."},
        \\ {"title":"Docs","url":"https://ziglang.org/documentation","text":""}]}
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
        .provider = .exa,
        .api_key = "secret",
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.exa(reply_state.allocator(), "zig lang", mock.url, 3);
    try group.await(io);
    if (mock.err) |err| return err;

    // The query, the count and the capped text went out as Exa's body (its field
    // names are camelCase), the key as `x-api-key`, and the reply became the
    // numbered list the model reads.
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig lang\",\"numResults\":3,\"contents\":{\"text\":{\"maxCharacters\":500}}}",
        mock.bodies.items[0],
    );
    try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    try std.testing.expectEqualStrings(
        "1. Zig Programming Language\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "an exa extraction posts the url and reads its text back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[{\"url\":\"https://ziglang.org\",\"text\":\"# Zig\\n\\nA language.\"}]}";
    var mock = try Mock.start(gpa, io, "/contents", 1, Mock.fixed(reply));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .provider = .exa,
        .api_key = "secret",
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.exaContents(reply_state.allocator(), "https://ziglang.org", mock.url);
    try group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}
