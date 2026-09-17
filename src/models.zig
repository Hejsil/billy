//! What is known about the provider and model in use.
//!
//! The API reports how many tokens a request used, but not how large the
//! context window is or what a token costs. Those are kept here and looked up by
//! provider and model, so the header can show how full the window is and what
//! the session has cost. The numbers come from the providers' published pricing
//! pages and have to be updated by hand when they change.

const std = @import("std");

/// A provider whose models and prices are known.
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

/// What a million tokens cost, in USD.
pub const Price = struct {
    /// Input tokens served from the prompt cache, which cost less.
    cache_hit_input: f64 = 0,
    /// Input tokens that missed the cache.
    cache_miss_input: f64 = 0,
    /// Tokens the model wrote.
    output: f64 = 0,
};

/// The model metadata the API does not report.
pub const Metadata = struct {
    provider: Provider,
    /// The model id as the API names it.
    model: []const u8,
    /// Tokens the context window holds.
    context_window: usize,
    /// Rates outside peak hours, in USD per million tokens.
    price: Price,

    /// The rates in effect at `unix_seconds`. DeepSeek charges double during its
    /// peak hours, so the off-peak rates are the base and peak doubles them.
    pub fn priceAt(meta: Metadata, unix_seconds: u64) Price {
        if (!isDeepSeekPeak(unix_seconds)) return meta.price;
        return .{
            .cache_hit_input = meta.price.cache_hit_input * 2,
            .cache_miss_input = meta.price.cache_miss_input * 2,
            .output = meta.price.output * 2,
        };
    }
};

/// A model offered by a provider.
const Entry = struct {
    /// The model id to send.
    id: []const u8,
    /// Tokens the context window holds.
    context_window: usize,
    /// Off-peak rates in USD per million tokens.
    price: Price,
    /// Older names the API still accepts for the same model at the same price.
    aliases: []const []const u8 = &.{},
};

/// The models of every known provider. Prices are per million tokens, off-peak,
/// as published on the providers' pricing pages.
const table = struct {
    // https://api-docs.deepseek.com/quick_start/pricing
    const deepseek = [_]Entry{
        .{
            .id = "deepseek-flash",
            .context_window = 1_000_000,
            .price = .{ .cache_hit_input = 0.003, .cache_miss_input = 0.15, .output = 0.60 },
            .aliases = &.{ "deepseek-v4-flash", "deepseek-v4-flash-vision-exp" },
        },
        .{
            .id = "deepseek-v4-pro",
            .context_window = 1_000_000,
            .price = .{ .cache_hit_input = 0.022, .cache_miss_input = 0.66, .output = 1.98 },
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
/// header leaves the context gauge and the cost out.
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
        .price = entry.price,
    };
}

/// Whether `unix_seconds` falls in DeepSeek's peak hours, when rates double:
/// 01:00-04:00 and 06:00-10:00 UTC, Monday to Friday.
fn isDeepSeekPeak(unix_seconds: u64) bool {
    const seconds = std.time.epoch.EpochSeconds{ .secs = unix_seconds };
    const day = seconds.getEpochDay().day;
    // 1970-01-01 was a Thursday, so day 0 is 3 days into a week starting Monday.
    const weekday = (day + 3) % 7;
    if (weekday > 4) return false; // Saturday or Sunday

    const hour = seconds.getDaySeconds().getHoursIntoDay();
    return (hour >= 1 and hour < 4) or (hour >= 6 and hour < 10);
}

/// The host name of `url`, without the scheme, port or path.
fn hostOf(url: []const u8) ?[]const u8 {
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
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), flash.price.cache_miss_input, 1e-12);

    // An alias resolves to the model it names.
    const aliased = lookup(.deepseek, "deepseek-v4-flash").?;
    try std.testing.expectEqualStrings("deepseek-flash", aliased.model);

    // Without a provider, the model is still found.
    const discovered = lookup(null, "deepseek-v4-pro").?;
    try std.testing.expectEqual(Provider.deepseek, discovered.provider);
    try std.testing.expectApproxEqAbs(@as(f64, 1.98), discovered.price.output, 1e-12);

    // An unknown model has no metadata, so the header shows no gauge.
    try std.testing.expect(lookup(.deepseek, "gpt-4o") == null);
    try std.testing.expect(lookup(null, "who-knows") == null);
}

test "peak hours double the off-peak rates" {
    const flash = lookup(.deepseek, "deepseek-flash").?;
    const peak = flash.priceAt(1789696800); // Friday 2026-09-18 02:00 UTC
    const off_peak = flash.priceAt(1789732800); // Friday 2026-09-18 12:00 UTC
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), peak.cache_hit_input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), peak.cache_miss_input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), peak.output, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), off_peak.cache_hit_input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), off_peak.cache_miss_input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), off_peak.output, 1e-12);
}

test "the peak hours are 01:00-04:00 and 06:00-10:00 UTC on weekdays" {
    const hour = 3600;
    const monday = 1789344000; // Monday 2026-09-14 00:00 UTC
    try std.testing.expect(!isDeepSeekPeak(monday + 0 * hour)); // 00:00
    try std.testing.expect(isDeepSeekPeak(monday + 1 * hour)); // 01:00
    try std.testing.expect(isDeepSeekPeak(monday + 3 * hour)); // 03:00
    try std.testing.expect(!isDeepSeekPeak(monday + 4 * hour)); // 04:00
    try std.testing.expect(isDeepSeekPeak(monday + 6 * hour)); // 06:00
    try std.testing.expect(isDeepSeekPeak(monday + 9 * hour)); // 09:00
    try std.testing.expect(!isDeepSeekPeak(monday + 10 * hour)); // 10:00
    // Saturday 2026-09-19 and Sunday 2026-09-20 are off-peak all day.
    try std.testing.expect(!isDeepSeekPeak(1789783200));
    try std.testing.expect(!isDeepSeekPeak(1789869600));
}
