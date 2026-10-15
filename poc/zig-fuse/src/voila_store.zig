const std = @import("std");
const posix_util = @import("posix_util.zig");
const zstd = @import("zstd");

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
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    const stored = try posix_util.readFileAlloc(allocator, path, 16 * ChunkSize);
    return switch (algo) {
        AlgoRaw => stored,
        AlgoZstd => decompressZstd(allocator, stored),
        else => error.UnknownChunkAlgo,
    };
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
