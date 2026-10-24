const std = @import("std");
const sqlite = @import("sqlite_c");
const voila_http = @import("./voila_http.zig");
const voila_manifest_json = @import("../codec/voila_manifest_json.zig");
const voila_refkey = @import("../core/voila_refkey.zig");
const registry_ref = @import("./voila_registry_ref.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_registry = @import("./voila_registry.zig");
const ocireg = @import("./voila_ocireg.zig");
const posix_util = @import("../sys/posix_util.zig");
const voila_hub_import = @import("./voila_hub_import.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_resolve = @import("./voila_resolve.zig");
const proto_wire = @import("../codec/proto_wire.zig");

pub fn pullManifestOnce(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    ref: []const u8,
) !voila_manifest_json.Manifest {
    const escaped = try voila_http.queryEscape(allocator, ref);
    defer allocator.free(escaped);
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped });
    defer allocator.free(url);
    const body = try voila_http.httpGet(io, allocator, url, cfg.token);
    defer allocator.free(body);
    const man = try voila_manifest_json.parse(allocator, body);
    const store_ref = if (man.image_ref.len != 0) man.image_ref else ref;
    try voila_manifest_cache.save(allocator, voila_root, store_ref, body);
    try persistManifest(allocator, voila_root, ref, body, man);
    return man;
}

pub fn pullManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    ref: []const u8,
) !voila_manifest_json.Manifest {
    const candidates = try registry_ref.registryPullCandidates(allocator, ref, cfg.org);
    defer {
        for (candidates) |c| allocator.free(c);
        allocator.free(candidates);
    }
    var last_err: ?anyerror = null;
    for (candidates) |candidate| {
        const man = pullManifestOnce(io, allocator, voila_root, cfg, candidate) catch |e| {
            last_err = e;
            continue;
        };
        return man;
    }
    voila_hub_import.tryImportFromHub(io, allocator, cfg, voila_root, ref) catch |e| {
        if (e == voila_hub_import.Error.SkipDockerImport) {} else if (last_err == null) last_err = e;
    };
    if (last_err != null) {
        for (candidates) |candidate| {
            const man = pullManifestOnce(io, allocator, voila_root, cfg, candidate) catch |e| {
                last_err = e;
                continue;
            };
            return man;
        }
    }
    if (last_err) |e| return e;
    return error.HttpStatus;
}

pub fn autoPull(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    query: []const u8,
) !voila_manifest_json.Manifest {
    const cfg = voila_registry.getConfigCopy(allocator) orelse return error.NoRegistry;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }
    if (query.len == 0) return error.Skip;
    if (!voila_refkey.looksLikeRef(query)) return error.Skip;
    if (voila_resolve.resolveImage(allocator, voila_root, query)) |rec| {
        defer allocator.free(rec.ref);
        defer allocator.free(rec.image_digest);
        defer allocator.free(rec.merged_root_manifest);
        if (try imageArtifactsPresent(allocator, voila_root, rec.ref)) return error.Skip;
    } else |_| {}
    return pullManifest(io, allocator, voila_root, cfg, query);
}

fn imageArtifactsPresent(allocator: std.mem.Allocator, voila_root: []const u8, store_ref: []const u8) !bool {
    const key = try voila_refkey.refKey(allocator, store_ref);
    defer allocator.free(key);
    const pb_path = try std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, key });
    defer allocator.free(pb_path);
    if (!posix_util.access(pb_path)) return false;
    const man_path = try voila_manifest_cache.manifestPath(allocator, voila_root, store_ref);
    defer allocator.free(man_path);
    return posix_util.access(man_path);
}

pub fn persistManifest(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    ref: []const u8,
    manifest_json: []const u8,
    man: voila_manifest_json.Manifest,
) !void {
    var store_ref = man.image_ref;
    if (store_ref.len == 0) store_ref = ref;

    try upsertImagesDb(allocator, voila_root, store_ref, man);
    try writeManifestPbStub(allocator, voila_root, store_ref, manifest_json);
}

fn upsertImagesDb(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    store_ref: []const u8,
    man: voila_manifest_json.Manifest,
) !void {
    const db_path = try std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return error.SqliteOpen;
    const db_ptr = db orelse return error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);

    const schema =
        \\CREATE TABLE IF NOT EXISTS images (
        \\  ref TEXT PRIMARY KEY,
        \\  image_digest BLOB NOT NULL,
        \\  merged_root_manifest_chunk BLOB NOT NULL,
        \\  total_size INTEGER NOT NULL,
        \\  chunk_count INTEGER NOT NULL,
        \\  ingested_ns INTEGER NOT NULL,
        \\  last_used_ns INTEGER NOT NULL
        \\);
    ;
    _ = sqlite.sqlite3_exec(db_ptr, schema, null, null, null);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    const sql =
        \\INSERT INTO images (ref, image_digest, merged_root_manifest_chunk, total_size, chunk_count, ingested_ns, last_used_ns)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(ref) DO UPDATE SET
        \\  image_digest=excluded.image_digest,
        \\  merged_root_manifest_chunk=excluded.merged_root_manifest_chunk,
        \\  total_size=excluded.total_size,
        \\  chunk_count=excluded.chunk_count,
        \\  ingested_ns=excluded.ingested_ns,
        \\  last_used_ns=excluded.last_used_ns
    ;
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);

    const ref_z = try allocator.allocSentinel(u8, store_ref.len, 0);
    defer allocator.free(ref_z);
    @memcpy(ref_z, store_ref);
    _ = sqlite.sqlite3_bind_text(stmt, 1, ref_z, -1, sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_blob(stmt, 2, man.image_digest.ptr, @intCast(man.image_digest.len), sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_blob(stmt, 3, man.merged_root.ptr, @intCast(man.merged_root.len), sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_int64(stmt, 4, @intCast(man.total_size));
    _ = sqlite.sqlite3_bind_int64(stmt, 5, @intCast(man.chunk_count));
    _ = sqlite.sqlite3_bind_int64(stmt, 6, now);
    _ = sqlite.sqlite3_bind_int64(stmt, 7, now);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) return error.SqliteStep;
}

/// Write minimal ImageManifest protobuf (config_chunk field) for defaultArgv.
fn writeManifestPbStub(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    store_ref: []const u8,
    manifest_json: []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const cc = parsed.value.object.get("config_chunk") orelse return;
    if (cc != .string or cc.string.len != 64) return;
    var config_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&config_id, cc.string);

    var pb: std.ArrayList(u8) = .empty;
    try proto_wire.writeBytes(&pb, allocator, 3, &config_id);
    const bytes = try pb.toOwnedSlice(allocator);
    defer allocator.free(bytes);

    const img_dir = try std.fmt.allocPrint(allocator, "{s}/images", .{voila_root});
    defer allocator.free(img_dir);
    try posix_util.makePath(img_dir);
    const key = try voila_refkey.refKey(allocator, store_ref);
    defer allocator.free(key);
    const path = try std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, key });
    defer allocator.free(path);
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub const Error = error{
    NoRegistry,
    Skip,
    SqliteOpen,
    SqlitePrepare,
    SqliteStep,
    FileOpenFailed,
    FileWriteFailed,
};
