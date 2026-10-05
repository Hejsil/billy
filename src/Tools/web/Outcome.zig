//! What one provider call came back with.

const std = @import("std");

const Outcome = @This();

/// The result of one call to one provider: either the text the model reads, or
/// the wait the provider asked for before it is asked again.
///
/// The text is owned by the allocator the provider was given, which the caller
/// frees once it has written the text on. A provider that failed for any other
/// reason returns an error instead, so a caller only has to tell an answer from
/// a wait.
pub const Value = union(enum) {
    /// The answer, as the model reads it.
    text: []const u8,
    /// The backend asked to be set aside before it is asked again, which is what
    /// its `Retry-After` was. The backend itself is fine: the caller records the
    /// wait and tries the next one.
    retry_after_ms: i64,
};
