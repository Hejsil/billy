//! The words and phrases billy asks the model not to write: the tics its own answers reached for.

const std = @import("std");

/// What the answers in billy's own sessions reached for most, each of which says nothing the plain
/// sentence would not. A run reads its own list from the configuration; this one is what it starts
/// with.
pub const default = [_][]const u8{
    "—",
    "here's what",
    "here's where",
    "honest",
    "load-bearing",
    "the shape of",
    "worth a look",
    "worth noting",
};

/// The entries of `banned` that `answer` used, joined for the model to read, or null when it used
/// none of them.
pub fn used(gpa: std.mem.Allocator, answer: []const u8, banned: []const []const u8) !?[]const u8 {
    var wrote: std.ArrayList([]const u8) = .empty;
    defer wrote.deinit(gpa);

    for (banned) |phrase| {
        if (written(answer, phrase)) try wrote.append(gpa, phrase);
    }
    if (wrote.items.len == 0) return null;
    return try std.mem.join(gpa, ", ", wrote.items);
}

/// Whether `answer` writes `phrase`, whatever case it is written in.
fn written(answer: []const u8, phrase: []const u8) bool {
    if (phrase.len == 0 or answer.len < phrase.len) return false;
    for (0..answer.len - phrase.len + 1) |at| {
        if (std.ascii.eqlIgnoreCase(answer[at..][0..phrase.len], phrase)) return true;
    }
    return false;
}

test "a phrase is found whatever case it was written in" {
    const gpa = std.testing.allocator;
    const found = (try used(gpa, "The frame end is LOAD-BEARING.", &.{"load-bearing"})).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings("load-bearing", found);
}

test "only what the answer used is reported, in the list's order" {
    const gpa = std.testing.allocator;
    const found = (try used(gpa, "It is worth noting that — done", &.{
        "—",
        "here's what",
        "worth noting",
    })).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings("—, worth noting", found);
}

test "an answer that used none of them reports nothing" {
    try std.testing.expect((try used(
        std.testing.allocator,
        "the frame end is fine",
        &.{ "—", "worth noting" },
    )) == null);
}
