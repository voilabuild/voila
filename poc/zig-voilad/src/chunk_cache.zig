//! Registry-backed local chunk cache for EROFS/NBD (Go CachedStore parity).
const std = @import("std");
const nbd = @import("voilad_nbd");
const posix_util = @import("posix_util");
const voila_http = @import("voila_http");
const voila_registry = @import("voila_registry");
const blake3 = @import("blake3_c");

const zstd_magic: [4]u8 = .{ 0x28, 0xb5, 0x2f, 0xfd };
const ChunkSize = nbd.backend.ChunkSize;

var g_chunk_origin: ?[]const u8 = null;
var g_origin_loaded = false;

pub fn install() void {
    nbd.backend.load_chunk_cached = loadChunk;
}

fn loadChunk(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
) ![]u8 {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    return loadLocal(allocator, voila_root, chunk_hex) catch {
        return fetchAndCache(io, allocator, voila_root, chunk_hex);
    };
}

fn loadLocal(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    const stored = try posix_util.readFileAlloc(allocator, path, 16 * ChunkSize);
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], &zstd_magic)) {
        return decompressZstd(allocator, stored);
    }
    return stored;
}

fn fetchAndCache(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    const cfg = voila_registry.getConfigCopy(allocator) orelse return error.RegistryUnset;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
    }
    try ensureOrigin(io, allocator, cfg);

    const url = if (g_chunk_origin) |o|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ o, chunk_hex })
    else
        try std.fmt.allocPrint(allocator, "{s}/v1/chunks/{s}", .{ cfg.base_url, chunk_hex });
    defer allocator.free(url);

    const stored = try voila_http.httpGet(io, allocator, url, "");
    defer allocator.free(stored);

    var raw: []u8 = stored;
    var owned = false;
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], &zstd_magic)) {
        raw = try decompressZstd(allocator, stored);
        owned = true;
    }
    try verifyChunkId(chunk_hex, raw);
    try putChunkRaw(allocator, voila_root, chunk_hex, raw);
    if (owned) allocator.free(raw);
    return loadLocal(allocator, voila_root, chunk_hex);
}

fn ensureOrigin(io: std.Io, allocator: std.mem.Allocator, cfg: voila_registry.Config) !void {
    if (g_origin_loaded) return;
    g_origin_loaded = true;
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/registry/config", .{cfg.base_url});
    defer allocator.free(url);
    const body = voila_http.httpGet(io, allocator, url, cfg.token) catch return;
    defer allocator.free(body);
    const needle = "\"chunk_endpoint\"";
    if (std.mem.indexOf(u8, body, needle)) |i| {
        var rest = body[i + needle.len ..];
        if (std.mem.indexOf(u8, rest, "\"")) |q| rest = rest[q + 1 ..];
        if (std.mem.indexOf(u8, rest, "\"")) |end| {
            const ep = trimRightSlash(rest[0..end]);
            if (ep.len != 0) g_chunk_origin = try allocator.dupe(u8, ep);
        }
    }
}

fn trimRightSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn chunkBlobPath(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/chunks/{s}/{s}/{s}", .{
        voila_root,
        chunk_hex[0..2],
        chunk_hex[2..4],
        chunk_hex,
    });
}

fn putChunkRaw(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8, raw: []const u8) !void {
    try verifyChunkId(chunk_hex, raw);
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.FileOpenFailed;
    const mkdir_cmd = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{dir});
    defer allocator.free(mkdir_cmd);
    const mkdir_z = try allocator.allocSentinel(u8, mkdir_cmd.len, 0);
    defer allocator.free(mkdir_z);
    @memcpy(mkdir_z, mkdir_cmd);
    _ = posix_util.shell(mkdir_z);

    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < raw.len) {
        const n = std.c.write(fd, raw[off..].ptr, raw.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

fn verifyChunkId(chunk_hex: []const u8, raw: []const u8) !void {
    var id: [32]u8 = undefined;
    var hasher: blake3.blake3_hasher = undefined;
    blake3.blake3_hasher_init(&hasher);
    blake3.blake3_hasher_update(&hasher, raw.ptr, raw.len);
    blake3.blake3_hasher_finalize(&hasher, &id, id.len);
    var hex_buf: [64]u8 = undefined;
    for (id, 0..) |b, i| {
        hex_buf[i * 2] = std.fmt.digitToChar(b >> 4, .lower);
        hex_buf[i * 2 + 1] = std.fmt.digitToChar(b & 0xf, .lower);
    }
    if (!std.mem.eql(u8, &hex_buf, chunk_hex)) return error.ChunkIntegrity;
}

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(compressed);
    var stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
    _ = try stream.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

pub const Error = error{
    BadChunkHex,
    RegistryUnset,
    ChunkIntegrity,
    FileOpenFailed,
    FileWriteFailed,
};
