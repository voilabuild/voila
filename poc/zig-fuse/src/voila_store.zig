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
    const tmp_in = try std.fmt.allocPrint(allocator, "/tmp/zig-fuse-chunk-{d}.zst", .{std.c.getpid()});
    defer allocator.free(tmp_in);
    const tmp_out = try std.fmt.allocPrint(allocator, "/tmp/zig-fuse-chunk-{d}.raw", .{std.c.getpid()});
    defer allocator.free(tmp_out);
    try writeFileBytes(tmp_in, compressed);
    const cmd = try std.fmt.allocPrint(allocator, "zstd -dq -f -o {s} {s}", .{ tmp_out, tmp_in });
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.ZstdDecode;
    defer posix_util.unlink(tmp_in);
    defer posix_util.unlink(tmp_out);
    return posix_util.readFileAlloc(allocator, tmp_out, ChunkSize);
}

fn writeFileBytes(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}
