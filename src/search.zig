//! Web search and fetch: a query out to a backend for a list of results, and a
//! url in for its content.
//!
//! Tavily, Exa, Brave and SearXNG so far. Which backend is the configuration's
//! choice, so another
//! is a variant in `Provider`, its endpoints beside it, a branch in
//! `Client.search` and `Client.extract`, and the credential it is asked with in
//! `credentials.Service`; nothing outside those files names a backend. Every
//! backend's results are mapped into one `Result`, so there is one place that
//! writes them. A `raw` fetch skips the backend and reads the url directly.

const std = @import("std");
const Io = std.Io;
const Health = @import("Health.zig");
const Mock = @import("mock.zig");

/// The backends billy can search with. The name is what the configuration holds,
/// stored as the variant itself so an unknown name is refused when the file is
/// read rather than carried around as a string.
pub const Provider = enum {
    tavily,
    exa,
    brave,
    searxng,

    /// Where a query is sent. A backend that takes a GET carries the query in
    /// the url; one that takes a POST carries it in a JSON body.
    fn endpoint(provider: Provider) []const u8 {
        return switch (provider) {
            .tavily => "https://api.tavily.com/search",
            .exa => "https://api.exa.ai/search",
            .brave => "https://api.search.brave.com/res/v1/web/search",
            // SearXNG is self-hosted, so it has no endpoint billy knows: the
            // instance the configuration names is used instead.
            .searxng => "",
        };
    }

    /// Where a url is extracted, or null for a backend with no extraction:
    /// `Client.extract` then reads the url itself.
    fn extractEndpoint(provider: Provider) ?[]const u8 {
        return switch (provider) {
            .tavily => "https://api.tavily.com/extract",
            .exa => "https://api.exa.ai/contents",
            // These have no extraction: `Client.extract` reads the url itself.
            .brave, .searxng => null,
        };
    }
};

/// One backend to search with, and what it is asked with: the key, from the
/// credential `billy login` stored or its environment variable, and the instance
/// for a backend that is the user's own.
pub const Backend = struct {
    provider: Provider,
    /// The key the backend is asked with. Empty for one that needs none, which
    /// is SearXNG, whose instance the user runs.
    api_key: []const u8 = "",
    /// Where the backend is reached, when it is not the address billy knows:
    /// SearXNG's instance, or, in a test, the server standing in for a backend.
    /// Null uses the backend's own address.
    endpoint: ?[]const u8 = null,

    /// The address to send to: the one named for this backend, or the backend's
    /// own.
    fn reach(backend: Backend) []const u8 {
        return backend.endpoint orelse backend.provider.endpoint();
    }
};

/// What the configuration says about searching, with the keys already resolved:
/// the backends to try, in order, and how many results to ask for. A null of
/// this in a tool set is what leaves web search out of a request.
pub const Config = struct {
    backends: []const Backend,
    /// Results asked for per query. A backend may return fewer.
    max_results: usize,
    /// The waits of every backend, so one that just failed is set aside. Null
    /// runs without them, which is what a test wants.
    health: ?*Health = null,
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
    /// The backends to try, in order: the first that answers is used, so a
    /// backend that is down or rate-limited falls through to the next.
    backends: []const Backend = &.{},
    max_results: usize,
    /// The waits of every backend, so one that just failed is set aside. Null
    /// runs without them.
    health: ?*Health = null,
    /// What the last failed request was told to wait, from its `Retry-After`.
    /// Set by `request` and read by the caller that records the failure.
    retry_after_ms: ?i64 = null,
    /// The one HTTP client of the run, borrowed by pointer so a query shares
    /// connections and scanned certificates with everything else that makes a
    /// request. The run owns it and outlives this.
    http: *std.http.Client,

    /// Runs one query and returns the results as the text the model reads: each
    /// result's title, its url and its snippet, in the order the backend ranked
    /// them. `arena` owns the result, which is what the caller keeps.
    pub fn search(client: *Client, arena: std.mem.Allocator, query: []const u8) ![]const u8 {
        const requested = std.math.clamp(client.max_results, 1, result_limit);
        const now_ms = client.nowMs();
        var failed: ?anyerror = null;
        for (client.backends) |backend| {
            // A backend that failed not long ago is skipped, so a backend that
            // is down, rate-limited or out of credit is not asked again yet.
            if (client.setAside(backend.provider, now_ms)) continue;
            const text = client.backendSearch(arena, backend, query, requested) catch |err| {
                try client.giveUp(backend.provider, now_ms);
                std.log.warn("search: {s} failed: {s}, trying the next", .{
                    @tagName(backend.provider), @errorName(err),
                });
                failed = err;
                continue;
            };
            try client.answered(backend.provider);
            return text;
        }
        // Every backend was tried and failed, or every one is set aside. The
        // second is not a failure of any backend, but of the setup.
        return failed orelse error.AllBackendsSetAside;
    }

    /// Runs one query against one backend, whichever it is.
    fn backendSearch(
        client: *Client,
        arena: std.mem.Allocator,
        backend: Backend,
        query: []const u8,
        max_results: usize,
    ) ![]const u8 {
        return switch (backend.provider) {
            .tavily => client.tavily(arena, backend.api_key, backend.reach(), query, max_results),
            .exa => client.exa(arena, backend.api_key, backend.reach(), query, max_results),
            .brave => client.brave(arena, backend.api_key, backend.reach(), query, max_results),
            .searxng => client.searxng(arena, backend.reach(), query, max_results),
        };
    }

    /// Fetches one url and returns its content as the text the model reads,
    /// which `arena` owns.
    ///
    /// A page is extracted by the backend, which reads it and returns its text,
    /// so billy does not parse HTML itself. A `raw` fetch, and a backend with no
    /// extraction endpoint, read the url directly instead: the bytes come back as
    /// the server sent them, which is what an API returning JSON wants.
    ///
    /// A backend that answered but could not read the url is not set aside: the
    /// next backend is tried, and the url read directly if none reads it. Only a
    /// backend that did not answer, or answered without a success, is set aside.
    /// This is what keeps one unreadable url from taking search down with it,
    /// since the waits are keyed by backend and shared with `search`.
    pub fn extract(client: *Client, arena: std.mem.Allocator, url: []const u8, raw: bool) ![]const u8 {
        const now_ms = client.nowMs();
        if (!raw) {
            for (client.backends) |backend| {
                if (backend.provider.extractEndpoint() == null) continue;
                if (client.setAside(backend.provider, now_ms)) continue;
                const text = client.backendExtract(arena, backend, url) catch |err| {
                    // A url the backend could not read is not a backend that is
                    // down: it answered, so the next backend is tried without
                    // setting this one aside. Anything else -- no answer, or an
                    // answer that is not a success -- is a failure of the
                    // backend itself, and it waits.
                    if (err == error.UrlUnreadable) {
                        std.log.warn("fetch: {s} could not read the url, trying the next", .{
                            @tagName(backend.provider),
                        });
                        continue;
                    }
                    try client.giveUp(backend.provider, now_ms);
                    std.log.warn("fetch: {s} failed: {s}, trying the next", .{
                        @tagName(backend.provider), @errorName(err),
                    });
                    continue;
                };
                try client.answered(backend.provider);
                return text;
            }
        }
        // No backend that extracts is worth trying, so the url is read straight.
        return client.get(arena, url);
    }

    /// The time now, in ms since the epoch, which decides whether a backend's
    /// wait is over.
    fn nowMs(client: *Client) i64 {
        return Io.Clock.now(.real, client.io).toMilliseconds();
    }

    /// Whether `provider` is set aside at `now`, and so should be skipped.
    fn setAside(client: *Client, provider: Provider, now: i64) bool {
        const health = client.health orelse return false;
        return health.skips(@tagName(provider), now);
    }

    /// Records that `provider` failed, so it is skipped for a while.
    fn giveUp(client: *Client, provider: Provider, now: i64) !void {
        const health = client.health orelse return;
        defer client.retry_after_ms = null;
        try health.record(@tagName(provider), client.retry_after_ms, now);
    }

    /// Records that `provider` answered, clearing any wait it had.
    fn answered(client: *Client, provider: Provider) !void {
        client.retry_after_ms = null;
        const health = client.health orelse return;
        try health.clear(@tagName(provider));
    }

    /// Extracts one url with one backend, whichever it is. Only a backend with an
    /// extraction endpoint is passed here.
    fn backendExtract(client: *Client, arena: std.mem.Allocator, backend: Backend, url: []const u8) ![]const u8 {
        return switch (backend.provider) {
            .tavily => client.tavilyExtract(arena, backend.api_key, backend.reach(), url),
            .exa => client.exaContents(arena, backend.api_key, backend.reach(), url),
            // Only a backend with an extraction endpoint is passed here.
            .brave, .searxng => unreachable,
        };
    }

    /// One Tavily search, posted to `endpoint`, which is the provider's own or a
    /// test server's. The request and the response are Tavily's shape; keeping
    /// the endpoint a parameter is what lets the wire format be tested without
    /// the network.
    fn tavily(
        client: *Client,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        query: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, TavilyRequest{
            .query = query,
            .max_results = max_results,
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const auth = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{api_key});
        defer client.gpa.free(auth);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "authorization", .value = auth },
        }, "search")) orelse return error.SearchFailed;
        const parsed = try parse(TavilyResponse, arena, text, "search");
        return render(arena, try mapped(arena, parsed.results, "content"));
    }

    /// One Tavily extraction. The url's text is the backend's; a url the backend
    /// could not read comes back as `error.UrlUnreadable`, which is not a failure
    /// of the backend.
    fn tavilyExtract(
        client: *Client,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        url: []const u8,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, TavilyExtractRequest{
            .urls = &.{url},
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const auth = try std.fmt.allocPrint(client.gpa, "Bearer {s}", .{api_key});
        defer client.gpa.free(auth);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "authorization", .value = auth },
        }, "fetch")) orelse return error.FetchFailed;
        const parsed = try parse(TavilyExtractResponse, arena, text, "fetch");
        if (parsed.results.len == 0) {
            for (parsed.failed_results) |failed| {
                std.log.warn("fetch: {s}: {s}", .{ failed.url, failed.@"error" });
            }
            return error.UrlUnreadable;
        }
        return parsed.results[0].raw_content;
    }

    /// One Brave search, sent as a GET with the query in the url. Brave wants
    /// its key in `x-subscription-token`, not an auth header, and the reply's
    /// results sit under `web`.
    fn brave(
        client: *Client,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        query: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const url = try queryUrl(arena, endpoint, query, "&count={d}", .{max_results});
        const text = (try client.request(arena, .GET, url, null, &.{
            .{ .name = "x-subscription-token", .value = api_key },
            .{ .name = "accept", .value = "application/json" },
        }, "search")) orelse return error.SearchFailed;
        const parsed = try parse(BraveResponse, arena, text, "search");
        return render(arena, try mapped(arena, parsed.web.results, "description"));
    }

    /// One SearXNG search, sent as a GET to the instance the configuration
    /// names. SearXNG needs no key, and answers with the same shape of results
    /// whatever engines it searched. It takes no result count, so the cap is
    /// applied here.
    fn searxng(
        client: *Client,
        arena: std.mem.Allocator,
        base: []const u8,
        query: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const endpoint = try std.fmt.allocPrint(arena, "{s}/search", .{
            std.mem.trimEnd(u8, base, "/"),
        });
        const url = try queryUrl(arena, endpoint, query, "&format=json", .{});
        const text = (try client.request(arena, .GET, url, null, &.{}, "search")) orelse
            return error.SearchFailed;
        const parsed = try parse(SearxngResponse, arena, text, "search");
        const results = parsed.results[0..@min(parsed.results.len, max_results)];
        return render(arena, try mapped(arena, results, "content"));
    }

    /// One Exa search, posted to `endpoint`. Exa would return the whole page of
    /// each result, so the text is asked for capped: a search is a list of
    /// snippets, and a page is what `web_fetch` is for.
    fn exa(
        client: *Client,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        query: []const u8,
        max_results: usize,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, ExaRequest{
            .query = query,
            .numResults = max_results,
            .contents = .{ .text = .{ .maxCharacters = snippet_len } },
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "x-api-key", .value = api_key },
        }, "search")) orelse return error.SearchFailed;
        const parsed = try parse(ExaResponse, arena, text, "search");
        return render(arena, try mapped(arena, parsed.results, "text"));
    }

    /// One Exa extraction, posted to `endpoint`. A url the backend could not
    /// read comes back as `error.UrlUnreadable`, which is not a failure of the
    /// backend.
    fn exaContents(
        client: *Client,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        url: []const u8,
    ) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(client.gpa, ExaContentsRequest{
            .urls = &.{url},
        }, .{ .emit_null_optional_fields = false });
        defer client.gpa.free(body);

        const text = (try client.request(arena, .POST, endpoint, body, &.{
            .{ .name = "x-api-key", .value = api_key },
        }, "fetch")) orelse return error.FetchFailed;
        const parsed = try parse(ExaContentsResponse, arena, text, "fetch");
        if (parsed.results.len == 0 or parsed.results[0].text.len == 0) return error.UrlUnreadable;
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
    /// the status is not a success.
    ///
    /// This is `std.http.Client.fetch` done by hand, because `fetch` throws the
    /// response headers away and a `Retry-After` is one of them: what the
    /// backend asked to be waited is put on `retry_after_ms` for the caller to
    /// record. The body is read the way `fetch` reads it, so a compressed reply
    /// still parses.
    fn request(
        client: *Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        location: []const u8,
        payload: ?[]const u8,
        headers: []const std.http.Header,
        what: []const u8,
    ) !?[]const u8 {
        client.retry_after_ms = null;

        var req = try client.http.request(method, try std.Uri.parse(location), .{
            // A redirect is followed, so an endpoint that moved still answers.
            .redirect_behavior = @enumFromInt(3),
            .headers = .{
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = headers,
        });
        defer req.deinit();

        if (payload) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
            var sending = try req.sendBodyUnflushed(&.{});
            try sending.writer.writeAll(body);
            try sending.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // What the backend asked to be waited, if it said, is kept where the
        // caller that records the failure can find it.
        if (Health.retryAfterMs(response.head.bytes)) |ms| {
            client.retry_after_ms = @intCast(@min(ms, max_retry_after_ms));
        }

        if (response.head.status.class() != .success) {
            // A backend failing is a warning rather than an error: with more
            // than one backend the caller tries the next, and the failure is
            // reported to the model as the result of the call.
            std.log.warn("{s}: HTTP {d}", .{ what, @intFromEnum(response.head.status) });
            const discarded = response.reader(&.{});
            _ = discarded.discardRemaining() catch {};
            return null;
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try client.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try client.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer client.gpa.free(decompress_buffer);

        var body_writer: std.Io.Writer.Allocating = .init(client.gpa);
        defer body_writer.deinit();

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = try reader.streamRemaining(&body_writer.writer);

        return try arena.dupe(u8, body_writer.written());
    }
};

/// The longest a `Retry-After` is honored, so a backend cannot set billy aside
/// for longer than the waits ever reach anyway.
const max_retry_after_ms: u64 = @intCast(Health.max_wait_ms);

/// Parses a backend's reply, copying its strings out of the body so they outlive
/// it. A body that cannot be read is logged and returned.
fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8, what: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("{s}: cannot read the reply: {s}", .{ what, @errorName(err) });
        return err;
    };
}

/// A url carrying `query` as the `q` parameter, followed by `tail`, which is
/// whatever else the backend wants such as a result count. The query is
/// percent-encoded, so a space or an `&` in it is part of the value rather than
/// breaking the url.
fn queryUrl(
    arena: std.mem.Allocator,
    base: []const u8,
    query: []const u8,
    comptime tail: []const u8,
    tail_args: anytype,
) ![]const u8 {
    var url: std.Io.Writer.Allocating = .init(arena);
    try url.writer.print("{s}?q=", .{base});
    for (query) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try url.writer.writeByte(c),
        else => try url.writer.print("%{x:0>2}", .{c}),
    };
    try url.writer.print(tail, tail_args);
    return url.toOwnedSlice();
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

/// The part of a SearXNG response billy uses, which is the same from every
/// engine it searched.
const SearxngResponse = struct {
    results: []const SearxngResult = &.{},
};

/// One SearXNG result: its snippet is the `content` field.
const SearxngResult = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
};

/// The part of a Brave search response billy uses. The results sit under `web`,
/// which a query that matched nothing leaves out, so it defaults to none.
const BraveResponse = struct {
    web: Web = .{},

    const Web = struct {
        results: []const BraveResult = &.{},
    };
};

/// One Brave result: its snippet is the `description` field.
const BraveResult = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
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
        .max_results = 3,
        .http = &http,
    };
    // `tavily` leaves the parsed reply and the list it built in the caller's
    // allocator, so it gets an arena; the rest is the testing allocator, which
    // reports anything not freed.
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.tavily(reply_state.allocator(), "secret", mock.url, "zig lang", 3);
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
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.tavilyExtract(reply_state.allocator(), "secret", mock.url, "https://ziglang.org");
    try group.await(io);
    if (mock.err) |err| return err;

    // The url went out as Tavily's body and the key as a bearer token.
    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("Bearer secret", mock.header("authorization").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}

test "a url tavily could not read is not a failure of the backend" {
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
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    try std.testing.expectError(
        error.UrlUnreadable,
        client.tavilyExtract(reply_state.allocator(), "secret", mock.url, "https://nope.invalid"),
    );
    try group.await(io);
    if (mock.err) |err| return err;
}

test "a url no backend could read does not set the backend aside" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two requests: Tavily answers the extraction without the url's text, and
    // the direct read that follows gets the page.
    var mock = try Mock.start(gpa, io, "/extract", 2, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{
                .body = "{\"results\":[],\"failed_results\":[{\"url\":\"https://nope.invalid\",\"error\":\"not found\"}]}",
            };
            return .{ .body = "<html>a page</html>" };
        }
    }.answer);
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .health = &health,
        .backends = &.{.{ .provider = .tavily, .api_key = "secret", .endpoint = mock.url }},
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();

    // Tavily could not read the url, so the url is read directly instead.
    try std.testing.expectEqualStrings(
        "<html>a page</html>",
        try client.extract(reply_state.allocator(), mock.url, false),
    );
    try group.await(io);
    if (mock.err) |err| return err;

    // Tavily answered, so it is not set aside: a search after this fetch still
    // reaches it. The direct read carried no key, so it was not Tavily's.
    try std.testing.expect(!health.skips("tavily", Io.Clock.now(.real, io).toMilliseconds()));
    try std.testing.expectEqual(@as(usize, 0), health.entries.count());
    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expect(mock.header("authorization") == null);
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
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.exa(reply_state.allocator(), "secret", mock.url, "zig lang", 3);
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
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.exaContents(reply_state.allocator(), "secret", mock.url, "https://ziglang.org");
    try group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqualStrings("{\"urls\":[\"https://ziglang.org\"]}", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("secret", mock.header("x-api-key").?);
    try std.testing.expectEqualStrings("# Zig\n\nA language.", text);
}

test "a query is percent-encoded into a url" {
    const gpa = std.testing.allocator;
    // A space, `&`, `/` and a non-ASCII character are all part of the query
    // value, not the url around it.
    const url = try queryUrl(gpa, "https://x/search", "a b&c/dé", "&count={d}", .{3});
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://x/search?q=a%20b%26c%2fd%c3%a9&count=3", url);
}

test "a brave search sends the query in the url and reads the results back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"web\":{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"description\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\"}]}}";
    var mock = try Mock.start(gpa, io, "/res/v1/web/search", 1, Mock.fixed(reply));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.brave(reply_state.allocator(), "secret", mock.url, "zig lang", 3);
    try group.await(io);
    if (mock.err) |err| return err;

    // The query is a GET, so nothing was posted; the key went out in Brave's own
    // header, and the reply rendered as the list the model reads.
    try std.testing.expectEqualStrings("", mock.bodies.items[0]);
    try std.testing.expectEqualStrings("secret", mock.header("x-subscription-token").?);
    try std.testing.expectEqualStrings("application/json", mock.header("accept").?);
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n\n" ++
            "2. Docs\n   https://ziglang.org/documentation\n",
        text,
    );
}

test "a backend with no extraction reads the url itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Brave has no extraction endpoint, so a fetch reads the url directly and
    // returns its bytes, even without `raw`.
    const reply = "<html>a page</html>";
    var mock = try Mock.start(gpa, io, "/page", 1, Mock.fixed(reply));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        // Brave has no extraction endpoint, so the backend list is skipped and
        // the url is read directly.
        .backends = &.{.{ .provider = .brave, .api_key = "secret" }},
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    try std.testing.expectEqualStrings(reply, try client.extract(reply_state.allocator(), mock.url, false));
    try group.await(io);
    if (mock.err) |err| return err;
}

test "a searxng search sends the query to the instance, and caps the results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const reply = "{\"results\":[" ++
        "{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}," ++
        "{\"title\":\"Docs\",\"url\":\"https://ziglang.org/documentation\",\"content\":\"\"}]}";
    // The instance is the mock's base, which SearXNG's `/search` is added to.
    var mock = try Mock.start(gpa, io, "", 1, Mock.fixed(reply));
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .max_results = 5,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    // The cap is applied here, since SearXNG takes no result count: only the
    // first of the two results is rendered.
    const text = try client.searxng(reply_state.allocator(), mock.url, "zig lang", 1);
    try group.await(io);
    if (mock.err) |err| return err;

    // The query is a GET with no key: SearXNG is the user's own instance.
    try std.testing.expectEqualStrings("", mock.bodies.items[0]);
    try std.testing.expect(mock.header("authorization") == null);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", text);
}

test "the backends are tried in order until one answers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The first reply is a server error and the second is results, so the first
    // backend fails and the second answers.
    var mock = try Mock.start(gpa, io, "/search", 2, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{ .status = .internal_server_error, .body = "{}" };
            return .{ .body = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language.\"}]}" };
        }
    }.answer);
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    // Two backends, both standing in for the same server, so what is tested is
    // the order rather than which backend it is.
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .tavily, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    const text = try client.search(reply_state.allocator(), "zig lang");
    try group.await(io);
    if (mock.err) |err| return err;

    // Both were tried: the first failed and the second answered.
    try std.testing.expectEqual(@as(usize, 2), mock.served);
    try std.testing.expectEqualStrings("1. Zig\n   https://ziglang.org\n   A language.\n", text);
}

test "a search fails only when every backend has failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var mock = try Mock.start(gpa, io, "/search", 2, struct {
        fn answer(_: usize, _: []const u8) Mock.Answer {
            return .{ .status = .internal_server_error, .body = "{}" };
        }
    }.answer);
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    try std.testing.expectError(error.SearchFailed, client.search(reply_state.allocator(), "zig lang"));
    try group.await(io);
    if (mock.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), mock.served);
}

test "a backend that failed is set aside, so the next search skips it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three requests: Tavily fails the first search, Brave answers it, and Brave
    // answers the second search, which never asks Tavily again.
    var mock = try Mock.start(gpa, io, "/search", 3, struct {
        fn answer(number: usize, _: []const u8) Mock.Answer {
            if (number == 1) return .{ .status = .internal_server_error, .body = "{}" };
            return .{ .body = "{\"web\":{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"description\":\"A language.\"}]}}" };
        }
    }.answer);
    defer mock.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, Mock.serve, .{ io, &mock });

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .health = &health,
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();

    // The first search falls through Tavily, which fails, to Brave, which
    // answers, and Tavily is left set aside.
    try std.testing.expectEqualStrings(
        "1. Zig\n   https://ziglang.org\n   A language.\n",
        try client.search(reply_state.allocator(), "zig lang"),
    );
    try std.testing.expect(health.skips("tavily", Io.Clock.now(.real, io).toMilliseconds()));

    // The second search is Brave alone: Tavily posts its query as a body and
    // Brave asks in the url, so the third request arriving with no body is
    // Brave answering, not Tavily being asked again.
    _ = try client.search(reply_state.allocator(), "zig lang");
    try group.await(io);
    if (mock.err) |err| return err;

    try std.testing.expectEqual(@as(usize, 3), mock.served);
    try std.testing.expectEqualStrings("", mock.bodies.items[2]);
    try std.testing.expectEqualStrings("b", mock.header("x-subscription-token").?);
}

test "a search with every backend set aside says so, without asking any" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A listener that never serves: no backend should be reached.
    var mock = try Mock.start(gpa, io, "/search", 1, Mock.fixed("{}"));
    defer mock.deinit(io);

    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var health = try Health.load(io, gpa, tmp.dir);
    defer health.deinit();
    const now = Io.Clock.now(.real, io).toMilliseconds();
    try health.record("tavily", null, now);
    try health.record("brave", null, now);

    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .health = &health,
        .backends = &.{
            .{ .provider = .tavily, .api_key = "a", .endpoint = mock.url },
            .{ .provider = .brave, .api_key = "b", .endpoint = mock.url },
        },
        .max_results = 3,
        .http = &http,
    };
    var reply_state = std.heap.ArenaAllocator.init(gpa);
    defer reply_state.deinit();
    try std.testing.expectError(
        error.AllBackendsSetAside,
        client.search(reply_state.allocator(), "zig lang"),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.served);
}
