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

pub fn verifyChunkIdPublic(chunk_hex: []const u8, raw: []const u8) !void {
    return verifyChunkId(chunk_hex, raw);
}

pub fn decompressZstdPublic(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    return decompressZstd(allocator, compressed);
}

/// Write raw chunk bytes to local store (chunkstore.LocalStore.Put semantics).
pub fn putChunkRaw(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8, raw: []const u8) !void {
    verifyChunkId(chunk_hex, raw) catch return error.ChunkIntegrity;
    const enc = encodeStored(allocator, raw);
    defer allocator.free(enc.data);
    const stored = enc.data;
    const algo = enc.algo;

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
    while (off < stored.len) {
        const n = std.c.write(fd, stored[off..].ptr, stored.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }

    try upsertChunkIndex(allocator, voila_root, chunk_hex, raw.len, stored.len, algo);
}

const Encoded = struct { data: []const u8, algo: i32 };

fn encodeStored(allocator: std.mem.Allocator, buf: []const u8) Encoded {
    const copy = allocator.dupe(u8, buf) catch return .{ .data = buf, .algo = AlgoRaw };
    return .{ .data = copy, .algo = AlgoRaw };
}

fn upsertChunkIndex(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
    logical_len: usize,
    stored_len: usize,
    algo: i32,
) !void {
    const sqlite = @import("sqlite_c");
    var id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id, chunk_hex);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/index.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return error.SqliteOpen;
    const db_ptr = db orelse return error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);

    const schema =
        \\CREATE TABLE IF NOT EXISTS chunks (
        \\  id BLOB PRIMARY KEY,
        \\  logical_len INTEGER NOT NULL,
        \\  stored_len INTEGER NOT NULL,
        \\  comp_algo INTEGER NOT NULL,
        \\  created_ns INTEGER NOT NULL,
        \\  last_access_ns INTEGER NOT NULL
        \\);
    ;
    _ = sqlite.sqlite3_exec(db_ptr, schema, null, null, null);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    const sql =
        \\INSERT INTO chunks (id, logical_len, stored_len, comp_algo, created_ns, last_access_ns)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(id) DO NOTHING
    ;
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);
    _ = sqlite.sqlite3_bind_blob(stmt, 1, &id, 32, sqlite.SQLITE_TRANSIENT);
    _ = sqlite.sqlite3_bind_int64(stmt, 2, @intCast(logical_len));
    _ = sqlite.sqlite3_bind_int64(stmt, 3, @intCast(stored_len));
    _ = sqlite.sqlite3_bind_int64(stmt, 4, algo);
    _ = sqlite.sqlite3_bind_int64(stmt, 5, now);
    _ = sqlite.sqlite3_bind_int64(stmt, 6, now);
    _ = sqlite.sqlite3_step(stmt);
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
