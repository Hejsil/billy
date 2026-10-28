//! Session ids: ULIDs.

const std = @import("std");

pub const length = 26;

pub const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

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

pub fn generate(io: std.Io, buf: *[length]u8) void {
    var random: [10]u8 = undefined;
    io.random(&random);
    // The epoch is the floor, and the low 48 bits are all an id has room for; a clock before 1970
    // or after the year 10889 is not worth failing over.
    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const time_ms: u48 = @truncate(@as(u64, @intCast(@max(now_ms, 0))));
    encode(buf, time_ms, random);
}

pub fn isId(text: []const u8) bool {
    if (text.len != length) return false;
    for (text) |byte| {
        if (std.mem.findScalar(u8, alphabet, byte) == null) return false;
    }
    return true;
}

test "an id carries the time it was made and sorts by it" {
    var earlier: [length]u8 = undefined;
    var later: [length]u8 = undefined;
    const none: [10]u8 = @splat(0);

    encode(&earlier, 1_700_000_000_000, none);
    encode(&later, 1_700_000_001_000, none);

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
    // The 128 bits fit in 130, so the first character is the top three, which is never more than
    // `7`.
    try std.testing.expectEqual('7', buf[0]);
    for (buf) |byte| {
        try std.testing.expect(std.mem.findScalar(u8, "ILOU", byte) == null);
    }
}

test "two ids made in the same millisecond differ, and sort by their random part" {
    var first: [length]u8 = undefined;
    var second: [length]u8 = undefined;
    const time_ms: u48 = 1_700_000_000_000;

    encode(&first, time_ms, @splat(0));
    const nine_zeros: [9]u8 = @splat(0);
    encode(&second, time_ms, nine_zeros ++ [_]u8{1});

    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expect(std.mem.order(u8, &first, &second) == .lt);
    try std.testing.expectEqualSlices(u8, first[0..9], second[0..9]);
}

test "isId tells an id from a name and from a shorter or longer string" {
    var buf: [length]u8 = undefined;
    encode(&buf, 1, @splat(0));
    try std.testing.expect(isId(&buf));

    try std.testing.expect(!isId("20260924-104612"));
    try std.testing.expect(!isId(""));
    try std.testing.expect(!isId("01HF7YAT00"));
    try std.testing.expect(!isId("01HF7YAT00000000000000000I"));
}

test "the value encoded is the value decoded" {
    // The encoder is checked against the bits rather than against a string, so a wrong alphabet or
    // a misplaced bit cannot pass by reading back what it wrote.
    var buf: [length]u8 = undefined;
    const random = [10]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a };
    encode(&buf, 0x0000_0000_0001, random);

    try std.testing.expectEqualStrings("0000000001041061050R3GG28A", &buf);

    var value: u128 = 0;
    for (buf) |byte| value = value << 5 | std.mem.findScalar(u8, alphabet, byte).?;

    var expected: u128 = 0;
    for (random) |byte| expected = (expected << 8) | byte;
    expected |= @as(u128, 1) << 80;
    try std.testing.expectEqual(expected, value);
}
