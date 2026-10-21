//! What is known about the provider and model in use.
//!
//! The API reports how many tokens a request used, but not how large the
//! context window is. That is kept here and looked up by provider and model, so
//! the header can show how full the window is. The numbers come from the
//! providers' documentation and have to be updated by hand when they change.

const std = @import("std");

/// A provider whose models are known.
pub const Provider = enum {
    deepseek,
    opencode_go,

    /// Every provider in the table, for looking a model up without one.
    pub fn all() []const Provider {
        return std.enums.values(Provider);
    }

    /// The name the provider is written and configured under, which is the
    /// variant's own.
    pub fn name(provider: Provider) []const u8 {
        return @tagName(provider);
    }

    /// The provider called `text`, or null when it is not one billy knows.
    pub fn fromName(text: []const u8) ?Provider {
        return std.meta.stringToEnum(Provider, text);
    }

    /// Where the provider's API lives, as the base URL its completions path is
    /// appended to.
    pub fn baseUrl(provider: Provider) []const u8 {
        return switch (provider) {
            .deepseek => "https://api.deepseek.com",
            .opencode_go => "https://opencode.ai/zen/go/v1",
        };
    }
};

/// A provider and the model of its that a run asks for, as the one string the
/// configuration and a session store: `provider/model`, such as
/// `deepseek/deepseek-v4-flash`.
///
/// Kept as the string it is read from rather than resolved to a `Provider` and a
/// model id here, so a session file can name a provider a later billy adds to
/// its table without this having to be edited, and so a session that names one
/// billy does not know is refused where it can be reported rather than silently
/// read as some other endpoint.
pub const Choice = struct {
    /// The whole string, as configured. It is what a session stores and what an
    /// error names, so the two halves are not kept apart from it.
    text: []const u8,

    /// The provider half, before the first `/`.
    pub fn provider(choice: Choice) []const u8 {
        const slash = std.mem.indexOfScalar(u8, choice.text, '/') orelse return "";
        return choice.text[0..slash];
    }

    /// The model half, after the first `/`. A model id may itself contain one,
    /// so only the first is the split.
    pub fn model(choice: Choice) []const u8 {
        const slash = std.mem.indexOfScalar(u8, choice.text, '/') orelse return choice.text;
        return choice.text[slash + 1 ..];
    }

    /// Whether the string names both halves. A model with no provider in front
    /// of it names no endpoint to send it to.
    pub fn isComplete(choice: Choice) bool {
        return choice.provider().len > 0 and choice.model().len > 0;
    }
};

/// The model metadata the API does not report.
pub const Metadata = struct {
    provider: Provider,
    /// Tokens the context window holds.
    context_window: usize,
};

/// A model offered by a provider.
const Entry = struct {
    /// The model id to send.
    id: []const u8,
    /// Tokens the context window holds.
    context_window: usize,
    /// Older names the API still accepts for the same model.
    aliases: []const []const u8 = &.{},
};

/// The models of every known provider.
const table = struct {
    // https://api-docs.deepseek.com/quick_start/pricing
    const deepseek = [_]Entry{
        .{
            .id = "deepseek-flash",
            .context_window = 1_000_000,
            .aliases = &.{ "deepseek-v4-flash", "deepseek-v4-flash-vision-exp" },
        },
        .{
            .id = "deepseek-v4-pro",
            .context_window = 1_000_000,
        },
    };

    // https://opencode.ai/docs/go -- the OpenAI-compatible models only. The Go
    // endpoint also serves models on Anthropic's `/v1/messages` (MiniMax, Qwen)
    // and on OpenAI's `/v1/responses` (Grok, the Luna pair, Muse Spark); billy
    // speaks neither, so listing them would offer a model it cannot call.
    //
    // The windows come from models.dev, which publishes what the Go page does
    // not; the ids are the ones `GET /zen/go/v1/models` returns now, which runs
    // slightly ahead of that catalog.
    const opencode_go = [_]Entry{
        .{ .id = "glm-5.3-flash", .context_window = 1_000_000 },
        .{ .id = "glm-5.3", .context_window = 1_000_000 },
        .{ .id = "glm-5.2", .context_window = 1_000_000 },
        .{ .id = "glm-5.1", .context_window = 1_000_000 },
        .{ .id = "kimi-k3", .context_window = 1_048_576 },
        .{ .id = "kimi-k2.7-code", .context_window = 262_144 },
        .{ .id = "kimi-k2.6", .context_window = 262_144 },
        .{ .id = "deepseek-v4.1-flash", .context_window = 1_000_000 },
        .{ .id = "deepseek-v4-pro", .context_window = 1_000_000 },
        .{ .id = "deepseek-v4-flash", .context_window = 1_000_000 },
        .{ .id = "deepseek-v4-flash-vision-exp", .context_window = 1_000_000 },
        // The Go endpoint accepts this id too, at the same window, so a session
        // started on DeepSeek keeps its gauge when it is sent there.
        .{ .id = "deepseek-flash", .context_window = 1_000_000 },
        .{ .id = "mimo-v2.6-flash", .context_window = 1_048_576 },
        .{ .id = "mimo-v2.6-pro", .context_window = 1_048_576 },
        .{ .id = "mimo-v2.5", .context_window = 1_000_000 },
        .{ .id = "mimo-v2.5-pro", .context_window = 1_048_576 },
        .{ .id = "longcat-2.0", .context_window = 1_000_000 },
        .{ .id = "longcat-2.5-preview-free", .context_window = 1_000_000 },
        .{ .id = "step-5-preview-free", .context_window = 1_000_000 },
        .{ .id = "hy4-preview", .context_window = 1_024_000 },
        .{ .id = "hy3", .context_window = 256_000 },
        .{ .id = "space-bunny", .context_window = 1_048_576 },
    };
};

/// The models of `provider`.
fn entries(provider: Provider) []const Entry {
    return switch (provider) {
        .deepseek => &table.deepseek,
        .opencode_go => &table.opencode_go,
    };
}

/// The host name of `url`, without the scheme, port or path.
pub fn hostOf(url: []const u8) ?[]const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const end = std.mem.indexOfAny(u8, after_scheme, "/:") orelse after_scheme.len;
    const host = after_scheme[0..end];
    if (host.len == 0) return null;
    return host;
}

/// What is known about `model`, looked up at `provider` when it is known and
/// among all providers otherwise, so a model behind an unrecognized endpoint is
/// still recognized. Null when the model is not in the table, in which case the
/// header leaves the context gauge out.
pub fn lookup(provider: ?Provider, model: []const u8) ?Metadata {
    if (provider) |known| {
        for (entries(known)) |entry| {
            if (matches(entry, model)) return metadataOf(known, entry);
        }
        return null;
    }
    for (Provider.all()) |candidate| {
        for (entries(candidate)) |entry| {
            if (matches(entry, model)) return metadataOf(candidate, entry);
        }
    }
    return null;
}

fn matches(entry: Entry, model: []const u8) bool {
    if (std.mem.eql(u8, entry.id, model)) return true;
    for (entry.aliases) |alias| {
        if (std.mem.eql(u8, alias, model)) return true;
    }
    return false;
}

fn metadataOf(provider: Provider, entry: Entry) Metadata {
    return .{
        .provider = provider,
        .context_window = entry.context_window,
    };
}

test "a choice names its provider before the slash and its model after it" {
    const flash = Choice{ .text = "deepseek/deepseek-flash" };
    try std.testing.expectEqualStrings("deepseek", flash.provider());
    try std.testing.expectEqualStrings("deepseek-flash", flash.model());
    try std.testing.expect(flash.isComplete());

    // Only the first slash is the split, so a model id with one of its own keeps
    // the rest of it.
    const variant = Choice{ .text = "vendor/model/variant" };
    try std.testing.expectEqualStrings("vendor", variant.provider());
    try std.testing.expectEqualStrings("model/variant", variant.model());

    // A bare model id names no provider, so it is sent as it is: it is what a run
    // against a proxy or a local server names, and it is not a complete choice.
    const bare = Choice{ .text = "qwen3-coder:30b" };
    try std.testing.expectEqualStrings("", bare.provider());
    try std.testing.expectEqualStrings("qwen3-coder:30b", bare.model());
    try std.testing.expect(!bare.isComplete());
}

test "hostOf strips the scheme, port and path" {
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/chat/completions").?);
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com").?);
    try std.testing.expectEqualStrings("localhost", hostOf("http://localhost:8080/v1/chat/completions").?);
    try std.testing.expectEqualStrings("example.com", hostOf("example.com/v1").?);
    try std.testing.expect(hostOf("https://") == null);
}

test "lookup finds a model by name, alias and without a provider" {
    const flash = lookup(.deepseek, "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, flash.context_window);

    // An alias resolves to the model it names.
    const aliased = lookup(.deepseek, "deepseek-v4-flash").?;
    try std.testing.expectEqual(flash.context_window, aliased.context_window);

    // Without a provider, the model is still found.
    const discovered = lookup(null, "deepseek-v4-pro").?;
    try std.testing.expectEqual(Provider.deepseek, discovered.provider);

    // An unknown model has no metadata, so the header shows no gauge.
    try std.testing.expect(lookup(.deepseek, "gpt-4o") == null);
    try std.testing.expect(lookup(null, "who-knows") == null);
}
