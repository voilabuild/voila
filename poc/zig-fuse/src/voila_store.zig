const std = @import("std");
const posix_util = @import("posix_util.zig");

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

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var in: std.Io.Reader = .fixed(compressed);
    var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{
        .window_len = @intCast(ChunkSize),
    });

    _ = zstd_stream.reader.streamRemaining(&out.writer) catch |e| {
        if (zstd_stream.err) |ze| return ze;
        return e;
    };
    if (zstd_stream.err) |ze| return ze;

    const result = try out.toOwnedSlice();
    if (result.len > ChunkSize) {
        allocator.free(result);
        return error.ChunkOversize;
    }
    return result;
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
    try std.testing.expectError(std.compress.zstd.Decompress.Error.BadMagic, decompressZstd(gpa, "\x28\xb5\x2f"));
}
