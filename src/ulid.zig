//! Session ids: ULIDs.
//!
//! An id is 128 bits -- 48 bits of milliseconds since the epoch and 80 bits of
//! randomness -- written as 26 characters of Crockford base32. The timestamp
//! comes first and most significant, so the ids sort lexicographically in the
//! order they were made, which is what lets a listing be ordered without asking
//! the filesystem anything. The random part is what keeps two ids from meeting,
//! even for two sessions made in the same millisecond.
//!
//! Crockford base32 leaves out `I`, `L`, `O` and `U`, so an id cannot be misread
//! as another one when it is typed or copied. There are no dashes, so an id is a
//! name a file and a URL can both hold as it stands.

const std = @import("std");
const Io = std.Io;

/// Characters in an id.
pub const length = 26;

/// The alphabet an id is written in. The letters are in ASCII order, so a byte
/// comparison of two ids of the same length orders them as the numbers do; the
/// digits below the letters keep that true across the alphabet's whole range.
pub const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Writes the id of `time_ms` and `random` into `buf`. `random` is the 80 bits
/// that tell two ids of the same millisecond apart.
///
/// The 128 bits are written from the most significant end, five bits at a time
/// into 26 characters, which is room for 130: the two spare bits are the empty
/// top of the first character, so an id never begins above `7`.
pub fn encode(buf: *[length]u8, time_ms: u48, random: [10]u8) void {
    var value: u128 = 0;
    for (random) |byte| value = (value << 8) | byte;
    value |= @as(u128, time_ms) << 80;

    var index: usize = length;
    while (index > 0) {
        index -= 1;
        buf[index] = alphabet[@intCast(value & 0x1f)];
        value >>= 5;
    }
}

/// Writes a fresh id into `buf`: the current time and 80 random bits.
///
/// `io` is both the clock and the source of the random bits, which are drawn
/// from the platform's CSPRNG. That is what makes an id unique without asking
/// whether it has been used: two billys on one machine cannot see each other's
/// unstarted sessions, so there is nothing to ask.
pub fn generate(io: Io, buf: *[length]u8) void {
    var random: [10]u8 = undefined;
    io.random(&random);
    // The epoch is the floor, and the low 48 bits are all an id has room for;
    // a clock before 1970 or after the year 10889 is not worth failing over.
    const now_ms = Io.Clock.now(.real, io).toMilliseconds();
    const time_ms: u48 = @truncate(@as(u64, @intCast(@max(now_ms, 0))));
    encode(buf, time_ms, random);
}

/// Whether `text` looks like an id this module makes: 26 characters of the
/// alphabet, so a typed id can be told from a name that is not one.
pub fn isId(text: []const u8) bool {
    if (text.len != length) return false;
    for (text) |byte| {
        if (std.mem.indexOfScalar(u8, alphabet, byte) == null) return false;
    }
    return true;
}

test "an id carries the time it was made and sorts by it" {
    var earlier: [length]u8 = undefined;
    var later: [length]u8 = undefined;
    const none = [_]u8{0} ** 10;

    encode(&earlier, 1_700_000_000_000, none);
    encode(&later, 1_700_000_001_000, none);

    // A millisecond later is an id that sorts after, which is the whole point of
    // the timestamp being first.
    try std.testing.expectEqualStrings("01HF7YAT00", earlier[0..10]);
    try std.testing.expect(std.mem.order(u8, &earlier, &later) == .lt);
}

test "an id is 26 characters of Crockford base32" {
    var buf: [length]u8 = undefined;
    var random: [10]u8 = undefined;
    for (&random, 0..) |*byte, i| byte.* = @intCast(i * 25 % 256);
    encode(&buf, 0xffffffffffff, random);

    try std.testing.expectEqual(26, buf.len);
    try std.testing.expect(isId(&buf));
    // The 128 bits fit in 130, so the first character is the top three, which is
    // never more than `7`.
    try std.testing.expectEqual('7', buf[0]);
    // None of the letters Crockford leaves out can appear.
    for (buf) |byte| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "ILOU", byte) == null);
    }
}

test "two ids made in the same millisecond differ, and sort by their random part" {
    var first: [length]u8 = undefined;
    var second: [length]u8 = undefined;
    const time_ms: u48 = 1_700_000_000_000;

    encode(&first, time_ms, [_]u8{0} ** 10);
    encode(&second, time_ms, [_]u8{0} ** 9 ++ [_]u8{1});

    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expect(std.mem.order(u8, &first, &second) == .lt);
    // The timestamp is the same, so the ids agree on their first characters.
    try std.testing.expectEqualSlices(u8, first[0..9], second[0..9]);
}

test "isId tells an id from a name and from a shorter or longer string" {
    var buf: [length]u8 = undefined;
    encode(&buf, 1, [_]u8{0} ** 10);
    try std.testing.expect(isId(&buf));

    try std.testing.expect(!isId("20260924-104612"));
    try std.testing.expect(!isId(""));
    try std.testing.expect(!isId("01HF7YAT00"));
    // A character the alphabet leaves out, at the length that would otherwise
    // pass.
    try std.testing.expect(!isId("01HF7YAT00000000000000000I"));
}

test "the value encoded is the value decoded" {
    // The encoder is checked against the bits rather than against a string, so a
    // wrong alphabet or a misplaced bit cannot pass by reading back what it
    // wrote.
    var buf: [length]u8 = undefined;
    // A fixed random part, so the encoded value is known.
    const random = [10]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a };
    encode(&buf, 0x0000_0000_0001, random);

    // The id reads back as the same bits: the alphabet is in order, so the
    // position of each character is its five bits.
    try std.testing.expectEqualStrings("0000000001041061050R3GG28A", &buf);

    var value: u128 = 0;
    for (buf) |byte| value = value << 5 | std.mem.indexOfScalar(u8, alphabet, byte).?;

    var expected: u128 = 0;
    for (random) |byte| expected = (expected << 8) | byte;
    expected |= @as(u128, 1) << 80;
    try std.testing.expectEqual(expected, value);
}
