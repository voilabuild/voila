const std = @import("std");
const voila_store = @import("voila_store.zig");
const voila_registry_fetch = @import("voila_registry_fetch.zig");
/// Local chunk read with optional registry lazy-fetch (matches chunkstore.CachedStore.Get).
pub fn loadChunkRaw(
    io: ?std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
    algo: i32,
) ![]u8 {
    return voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch |e| {
        if (io) |i| {
            return voila_registry_fetch.fetchChunkRaw(i, allocator, voila_root, chunk_hex) catch e;
        }
        return e;
    };
}
