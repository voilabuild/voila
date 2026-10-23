const std = @import("std");
const voila_store = @import("../voila_store.zig");
const posix_util = @import("../../sys/posix_util.zig");
const blake3_c = @import("blake3_c");

pub const ChunkId = [32]u8;

pub fn hashRaw(raw: []const u8) ChunkId {
    var hasher: blake3_c.blake3_hasher = undefined;
    blake3_c.blake3_hasher_init(&hasher);
    blake3_c.blake3_hasher_update(&hasher, raw.ptr, raw.len);
    var digest: ChunkId = undefined;
    blake3_c.blake3_hasher_finalize(&hasher, &digest, blake3_c.BLAKE3_OUT_LEN);
    return digest;
}

pub fn idToHex(id: ChunkId) [64]u8 {
    return std.fmt.bytesToHex(&id, .lower);
}

pub fn chunkExists(allocator: std.mem.Allocator, voila_root: []const u8, id: ChunkId) bool {
    const hex = idToHex(id);
    const path = voila_store.chunkBlobPath(allocator, voila_root, &hex) catch return false;
    defer allocator.free(path);
    return posix_util.access(path);
}

pub fn putBytes(allocator: std.mem.Allocator, voila_root: []const u8, raw: []const u8) !ChunkId {
    const id = hashRaw(raw);
    const hex = idToHex(id);
    if (!chunkExists(allocator, voila_root, id)) {
        try voila_store.putChunkRaw(allocator, voila_root, &hex, raw);
    }
    return id;
}

pub fn getBytes(allocator: std.mem.Allocator, voila_root: []const u8, id: ChunkId) ![]u8 {
    const hex = idToHex(id);
    return voila_store.loadChunkRaw(allocator, voila_root, &hex, voila_store.AlgoRaw);
}
