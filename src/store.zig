//! The bytes a store of billy's own is kept as: records, a pool of strings they name, and a header.

/// What a file is read through: room for a field, and a page of it at a time.
pub const read_buffer = 8 * 1024;

// What fails here is what says to bump a version: a file is the memory of the structs it holds.
pub fn fixedSize(T: type, comptime len: usize) void {
    if (@sizeOf(T) != len) @compileError("format_version: " ++ @typeName(T) ++ " is no longer the size it was written at");
}

pub fn fixedPacking(T: type) void {
    var held: usize = 0;
    inline for (@typeInfo(T).@"struct".field_types) |Field| held += @sizeOf(Field);
    if (held != @sizeOf(T)) @compileError("format_version: " ++ @typeName(T) ++ " has a gap the file cannot hold");
}

pub fn fixedOffset(T: type, comptime field: []const u8, comptime at: usize) void {
    if (@offsetOf(T, field) != at) @compileError("format_version: " ++ @typeName(T) ++ "." ++ field ++ " no longer sits where it was written");
}
