const std = @import("std");
const posix_util = @import("posix_util.zig");
const zstd = @import("zstd");
const blake3_c = @import("blake3_c");

pub const ChunkSize = 1 << 20;

pub const AlgoRaw = 0;
pub const AlgoZstd = 1;

pub fn chunkBlobPath(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]const u8 {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    return std.fmt.allocPrint(allocator, "{s}/chunks/{s}/{s}/{s}", .{
        voila_root,
        chunk_hex[0..2],
        chunk_hex[2..4],
        chunk_hex,
    });
}

pub fn loadChunkRaw(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
    algo: i32,
) ![]u8 {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    const stored = try posix_util.readFileAlloc(allocator, path, 16 * ChunkSize);
    const raw: []u8 = switch (algo) {
        AlgoRaw => stored,
        AlgoZstd => try decompressZstd(allocator, stored),
        else => {
            allocator.free(stored);
            return error.UnknownChunkAlgo;
        },
    };
    if (algo == AlgoZstd) allocator.free(stored);
    verifyChunkId(chunk_hex, raw) catch |e| {
        allocator.free(raw);
        return e;
    };
    return raw;
}

/// Matches chunkstore.LocalStore.Get: BLAKE3-256 of raw (uncompressed) bytes
/// must equal the content-addressed chunk id (64-char lowercase hex).
fn verifyChunkId(chunk_hex: []const u8, raw: []const u8) !void {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    var expect: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(expect[0..], chunk_hex);

    var hasher: blake3_c.blake3_hasher = undefined;
    blake3_c.blake3_hasher_init(&hasher);
    blake3_c.blake3_hasher_update(&hasher, raw.ptr, raw.len);
    var digest: [32]u8 = undefined;
    blake3_c.blake3_hasher_finalize(&hasher, &digest, blake3_c.BLAKE3_OUT_LEN);
    if (!std.mem.eql(u8, &digest, &expect)) return error.ChunkIntegrity;
}

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    if (compressed.len == 0) return error.ZstdDecode;

    const bound = zstd.ZSTD_decompressBound(compressed.ptr, compressed.len);
    if (zstd.ZSTD_isError(bound) != 0) return error.ZstdDecode;
    if (bound > ChunkSize) return error.ChunkOversize;

    const out = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(out);

    const n = zstd.ZSTD_decompress(out.ptr, out.len, compressed.ptr, compressed.len);
    if (zstd.ZSTD_isError(n) != 0) return error.ZstdDecode;

    return out[0..@intCast(n)];
}

test "verify chunk id matches blake3 of raw bytes" {
    const payload = "voila-chunk-verify";
    // BLAKE3-256(payload), same as Go chunkstore.hash.
    const id_hex = "96e67efc75e9297e57b40b1ea934a8c4e115070bc2576ca6aea609de93df9ce8";
    try verifyChunkId(id_hex, payload);
}

test "verify rejects hash mismatch" {
    const payload = "voila-chunk-verify";
    const wrong_id = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.ChunkIntegrity, verifyChunkId(wrong_id, payload));
}

test "decompress zstd empty frame" {
    const input_raw =
        "\x28\xb5\x2f\xfd" ++ // zstandard frame magic number
        "\x20\x00" ++ // frame header: single_segment_flag, frame_content_size zero
        "\x01\x00\x00"; // last block, raw, size zero
    const gpa = std.testing.allocator;
    const raw = try decompressZstd(gpa, input_raw);
    defer gpa.free(raw);
    try std.testing.expectEqualSlices(u8, "", raw);
}

test "decompress zstd rejects truncated frame" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ZstdDecode, decompressZstd(gpa, "\x28\xb5\x2f"));
}
