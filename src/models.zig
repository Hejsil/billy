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

    /// The provider serving `url`, by host name, or null when it is not one of
    /// the known providers, as a proxy or a self-hosted endpoint would not be.
    pub fn fromUrl(url: []const u8) ?Provider {
        const host = hostOf(url) orelse return null;
        if (std.mem.eql(u8, host, "api.deepseek.com")) return .deepseek;
        return null;
    }

    /// Every provider in the table, for looking a model up without one.
    pub fn all() []const Provider {
        return std.enums.values(Provider);
    }
};

/// The model metadata the API does not report.
pub const Metadata = struct {
    provider: Provider,
    /// The model id as the API names it.
    model: []const u8,
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
};

/// The models of `provider`.
fn entries(provider: Provider) []const Entry {
    return switch (provider) {
        .deepseek => &table.deepseek,
    };
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
        .model = entry.id,
        .context_window = entry.context_window,
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

test "hostOf strips the scheme, port and path" {
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/chat/completions").?);
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com").?);
    try std.testing.expectEqualStrings("localhost", hostOf("http://localhost:8080/v1/chat/completions").?);
    try std.testing.expectEqualStrings("example.com", hostOf("example.com/v1").?);
    try std.testing.expect(hostOf("https://") == null);
}

test "Provider.fromUrl recognizes the known providers" {
    try std.testing.expectEqual(Provider.deepseek, Provider.fromUrl("https://api.deepseek.com/chat/completions").?);
    try std.testing.expect(Provider.fromUrl("https://api.openai.com/v1/chat/completions") == null);
    try std.testing.expect(Provider.fromUrl("http://127.0.0.1:8080/v1/chat/completions") == null);
}

test "lookup finds a model by name, alias and without a provider" {
    const flash = lookup(.deepseek, "deepseek-flash").?;
    try std.testing.expectEqual(1_000_000, flash.context_window);

    // An alias resolves to the model it names.
    const aliased = lookup(.deepseek, "deepseek-v4-flash").?;
    try std.testing.expectEqualStrings("deepseek-flash", aliased.model);

    // Without a provider, the model is still found.
    const discovered = lookup(null, "deepseek-v4-pro").?;
    try std.testing.expectEqual(Provider.deepseek, discovered.provider);

    // An unknown model has no metadata, so the header shows no gauge.
    try std.testing.expect(lookup(.deepseek, "gpt-4o") == null);
    try std.testing.expect(lookup(null, "who-knows") == null);
}
