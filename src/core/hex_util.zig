const std = @import("std");

const charset_lower = "0123456789abcdef";

pub fn encodeHexLower(out: []u8, input: []const u8) void {
    std.debug.assert(out.len >= input.len * 2);
    for (input, 0..) |b, i| {
        out[i * 2 + 0] = charset_lower[b >> 4];
        out[i * 2 + 1] = charset_lower[b & 15];
    }
}

/// Lowercase hex of a 32-byte chunk id.
pub fn chunkIdToHex(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    if (id.len != 32) return error.BadChunkId;
    return allocHexLower(allocator, id);
}

pub fn allocHexLower(allocator: std.mem.Allocator, slice: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, slice.len * 2);
    encodeHexLower(out, slice);
    return out;
}

pub const Error = error{BadChunkId};
