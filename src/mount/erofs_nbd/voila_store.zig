const std = @import("std");
const posix_util = @import("./posix_util.zig");
const zstd = std.compress.zstd;

pub const ChunkSize = 1 << 20;

pub const zstd_magic: [4]u8 = .{ 0x28, 0xb5, 0x2f, 0xfd };

pub fn chunkBlobPath(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]const u8 {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    return std.fmt.allocPrint(allocator, "{s}/chunks/{s}/{s}/{s}", .{
        voila_root,
        chunk_hex[0..2],
        chunk_hex[2..4],
        chunk_hex,
    });
}

pub fn loadChunkRaw(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    const stored = try posix_util.readFileAlloc(allocator, path, 16 * ChunkSize);
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], &zstd_magic)) {
        const raw = try decompressZstd(allocator, stored);
        allocator.free(stored);
        return raw;
    }
    return stored;
}

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(compressed);
    var stream: zstd.Decompress = .init(&in, &.{}, .{});
    _ = try stream.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

pub const Error = error{
    BadChunkHex,
    FileTooLarge,
};
