const std = @import("std");
const posix_util = @import("sys").posix_util;
const fs = @import("sys").fs;
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

/// True when the chunk's blob is in the local store.
pub fn hasChunk(voila_root: []const u8, chunk_hex: []const u8) bool {
    if (chunk_hex.len != 64) return false;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/chunks/{s}/{s}/{s}", .{
        voila_root,
        chunk_hex[0..2],
        chunk_hex[2..4],
        chunk_hex,
    }) catch return false;
    return posix_util.access(path);
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

/// Stored on-disk bytes (compressed or raw) for registry upload.
pub fn loadStoredBytes(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    if (chunk_hex.len != 64) return error.BadChunkHex;
    const path = try chunkBlobPath(allocator, voila_root, chunk_hex);
    defer allocator.free(path);
    return posix_util.readFileAlloc(allocator, path, 16 * ChunkSize);
}

pub fn compressZstdPublic(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const bound = zstd.ZSTD_compressBound(raw.len);
    if (zstd.ZSTD_isError(bound) != 0) return error.ZstdEncode;
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);
    const n = zstd.ZSTD_compress(out.ptr, out.len, raw.ptr, raw.len, 3);
    if (zstd.ZSTD_isError(n) != 0) return error.ZstdEncode;
    return allocator.realloc(out, n);
}

/// Verifies `raw` against `chunk_hex`, then stores it. Use `ChunkWriter` for bulk writes.
pub fn putChunkRaw(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8, raw: []const u8) !void {
    verifyChunkId(chunk_hex, raw) catch return error.ChunkIntegrity;
    var w = ChunkWriter.init(voila_root);
    defer w.deinit();
    try w.putTrusted(allocator, chunk_hex, raw);
}

const sqlite = @import("sqlite_c");

const batch_size = 64;

const chunks_schema =
    \\CREATE TABLE IF NOT EXISTS chunks (
    \\  id BLOB PRIMARY KEY,
    \\  logical_len INTEGER NOT NULL,
    \\  stored_len INTEGER NOT NULL,
    \\  comp_algo INTEGER NOT NULL,
    \\  created_ns INTEGER NOT NULL,
    \\  last_access_ns INTEGER NOT NULL
    \\);
;

/// A blob with no index row is raw (AlgoRaw).
/// Bulk chunk writer: one SQLite connection, inserts batched per transaction, blobs written atomically.
pub const ChunkWriter = struct {
    voila_root: []const u8,
    db: ?*sqlite.sqlite3 = null,
    insert: ?*sqlite.sqlite3_stmt = null,
    pending: u32 = 0,

    pub fn init(voila_root: []const u8) ChunkWriter {
        return .{ .voila_root = voila_root };
    }

    /// Commits any open batch and closes the index.
    pub fn deinit(self: *ChunkWriter) void {
        self.flush() catch {};
        if (self.insert) |st| _ = sqlite.sqlite3_finalize(st);
        if (self.db) |db| _ = sqlite.sqlite3_close(db);
        self.* = init(self.voila_root);
    }

    /// Commits the open batch. Callers must flush before returning control to code that opens its own connection.
    pub fn flush(self: *ChunkWriter) !void {
        if (self.pending == 0) return;
        self.pending = 0;
        const db = self.db orelse return;
        if (sqlite.sqlite3_exec(db, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_exec(db, "ROLLBACK", null, null, null);
            return error.SqliteCommit;
        }
    }

    /// Caller guarantees `chunk_hex` is the BLAKE3 id of `raw` (no re-hash here).
    pub fn putTrusted(self: *ChunkWriter, allocator: std.mem.Allocator, chunk_hex: []const u8, raw: []const u8) !void {
        if (chunk_hex.len != 64) return error.BadChunkHex;
        const path = try chunkBlobPath(allocator, self.voila_root, chunk_hex);
        defer allocator.free(path);
        try writeBlobAtomic(path, raw);
        try self.indexChunk(allocator, chunk_hex, raw.len, raw.len, AlgoRaw);
    }

    fn open(self: *ChunkWriter, allocator: std.mem.Allocator) !void {
        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/index.db", .{self.voila_root}, 0);
        defer allocator.free(db_path);
        var db: ?*sqlite.sqlite3 = null;
        if (sqlite.sqlite3_open(db_path, &db) != sqlite.SQLITE_OK) {
            if (db) |d| _ = sqlite.sqlite3_close(d);
            return error.SqliteOpen;
        }
        const db_ptr = db orelse return error.SqliteOpen;
        errdefer _ = sqlite.sqlite3_close(db_ptr);
        _ = sqlite.sqlite3_busy_timeout(db_ptr, 5000);
        // Blobs are renamed into place before their row is inserted, and a missing row
        // reads as AlgoRaw, so losing the last commits on power loss is harmless.
        _ = sqlite.sqlite3_exec(db_ptr, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL", null, null, null);
        _ = sqlite.sqlite3_exec(db_ptr, chunks_schema, null, null, null);
        const sql =
            \\INSERT INTO chunks (id, logical_len, stored_len, comp_algo, created_ns, last_access_ns)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(id) DO NOTHING
        ;
        var stmt: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepare;
        self.db = db_ptr;
        self.insert = stmt;
    }

    fn indexChunk(self: *ChunkWriter, allocator: std.mem.Allocator, chunk_hex: []const u8, logical_len: usize, stored_len: usize, algo: i32) !void {
        var id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id, chunk_hex);
        if (self.db == null) try self.open(allocator);
        const db = self.db.?;
        const stmt = self.insert;
        if (self.pending == 0 and sqlite.sqlite3_exec(db, "BEGIN", null, null, null) != sqlite.SQLITE_OK) return error.SqliteBegin;

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now: i64 = @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &id, 32, sqlite.SQLITE_STATIC);
        _ = sqlite.sqlite3_bind_int64(stmt, 2, @intCast(logical_len));
        _ = sqlite.sqlite3_bind_int64(stmt, 3, @intCast(stored_len));
        _ = sqlite.sqlite3_bind_int64(stmt, 4, algo);
        _ = sqlite.sqlite3_bind_int64(stmt, 5, now);
        _ = sqlite.sqlite3_bind_int64(stmt, 6, now);
        const rc = sqlite.sqlite3_step(stmt);
        _ = sqlite.sqlite3_reset(stmt);
        if (rc != sqlite.SQLITE_DONE) {
            self.pending = 0;
            _ = sqlite.sqlite3_exec(db, "ROLLBACK", null, null, null);
            return error.SqliteInsert;
        }
        self.pending += 1;
        if (self.pending >= batch_size) try self.flush();
    }
};

/// Writes `bytes` to `<path>.tmp.<random>` then renames over `path`; creates parent dirs on demand.
pub fn writeBlobAtomic(path: []const u8, bytes: []const u8) !void {
    var rnd: [8]u8 = undefined;
    try fs.randomBytes(&rnd);
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{x}", .{ path, rnd }) catch return error.NameTooLong;

    const f = fs.File.create(tmp, 0o644) catch |e| switch (e) {
        error.FileNotFound => blk: {
            const dir = std.fs.path.dirname(path) orelse return e;
            try fs.makePath(dir);
            break :blk try fs.File.create(tmp, 0o644);
        },
        else => return e,
    };
    errdefer posix_util.unlink(tmp);
    {
        defer f.close();
        try f.writeAll(bytes);
    }
    try fs.rename(tmp, path);
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

test "compressZstdPublic result can be freed and round-trips" {
    const gpa = std.testing.allocator;
    const raw = "hello hello hello hello hello hello hello hello";
    const z = try compressZstdPublic(gpa, raw);
    defer gpa.free(z);
    const back = try decompressZstd(gpa, z);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, raw, back);
}

test "decompress zstd rejects truncated frame" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ZstdDecode, decompressZstd(gpa, "\x28\xb5\x2f"));
}

fn testHex(raw: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    var hasher: blake3_c.blake3_hasher = undefined;
    blake3_c.blake3_hasher_init(&hasher);
    blake3_c.blake3_hasher_update(&hasher, raw.ptr, raw.len);
    blake3_c.blake3_hasher_finalize(&hasher, &digest, blake3_c.BLAKE3_OUT_LEN);
    return std.fmt.bytesToHex(&digest, .lower);
}

fn countIndexRows(allocator: std.mem.Allocator, root: []const u8) !i64 {
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/index.db", .{root}, 0);
    defer allocator.free(db_path);
    var db: ?*sqlite.sqlite3 = null;
    try std.testing.expect(sqlite.sqlite3_open(db_path, &db) == sqlite.SQLITE_OK);
    defer _ = sqlite.sqlite3_close(db);
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try std.testing.expect(sqlite.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks", -1, &stmt, null) == sqlite.SQLITE_OK);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try std.testing.expect(sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW);
    return sqlite.sqlite3_column_int64(stmt, 0);
}

test "ChunkWriter stores chunks atomically and indexes them in batches" {
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-store-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {};

    const n = batch_size + 6;
    var w = ChunkWriter.init(root);
    for (0..n) |i| {
        var payload: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&payload, "chunk-payload-{d:0>18}", .{i});
        const hex = testHex(&payload);
        try w.putTrusted(a, &hex, &payload);
        const back = try loadChunkRaw(a, root, &hex, AlgoRaw);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, &payload, back);
    }
    try w.flush();
    try std.testing.expectEqual(@as(i64, n), try countIndexRows(a, root));
    w.deinit();

    const probe = "chunk-payload-000000000000000000";
    const hex = testHex(probe);
    const path = try chunkBlobPath(a, root, &hex);
    defer a.free(path);
    const dir = std.fs.path.dirname(path).?;
    const names = try fs.listDir(a, dir);
    defer fs.freeNames(a, names);
    for (names) |name| try std.testing.expect(std.mem.indexOf(u8, name, ".tmp.") == null);
}

test "second writer is not blocked by a flushed first writer" {
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-store-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {};

    var w1 = ChunkWriter.init(root);
    defer w1.deinit();
    const p1 = "first-payload";
    const h1 = testHex(p1);
    try w1.putTrusted(a, &h1, p1);
    try w1.flush();

    const p2 = "second-payload";
    const h2 = testHex(p2);
    try putChunkRaw(a, root, &h2, p2);
    try std.testing.expectEqual(@as(i64, 2), try countIndexRows(a, root));
}

test "putChunkRaw verifies the id and tolerates rewriting a chunk" {
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-store-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {};

    const payload = "voila-chunk-verify";
    const bad = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.ChunkIntegrity, putChunkRaw(a, root, bad, payload));

    const hex = testHex(payload);
    try putChunkRaw(a, root, &hex, payload);
    try putChunkRaw(a, root, &hex, payload);
    const back = try loadChunkRaw(a, root, &hex, AlgoRaw);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, payload, back);
    try std.testing.expectEqual(@as(i64, 1), try countIndexRows(a, root));
}
