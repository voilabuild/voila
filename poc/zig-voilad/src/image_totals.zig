const std = @import("std");
const sqlite = @import("sqlite_c");

pub fn loadForRef(allocator: std.mem.Allocator, voila_root: []const u8, ref: []const u8) struct { chunks: u64, bytes: u64 } {
    const db_path = std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root}) catch return .{ .chunks = 0, .bytes = 0 };
    defer allocator.free(db_path);
    const db_path_z = allocator.allocSentinel(u8, db_path.len, 0) catch return .{ .chunks = 0, .bytes = 0 };
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return .{ .chunks = 0, .bytes = 0 };
    const db_ptr = db orelse return .{ .chunks = 0, .bytes = 0 };
    defer _ = sqlite.sqlite3_close(db_ptr);

    const sql = "SELECT total_size, chunk_count FROM images WHERE ref = ?";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return .{ .chunks = 0, .bytes = 0 };
    defer _ = sqlite.sqlite3_finalize(stmt);
    const ref_z = allocator.allocSentinel(u8, ref.len, 0) catch return .{ .chunks = 0, .bytes = 0 };
    defer allocator.free(ref_z);
    @memcpy(ref_z, ref);
    _ = sqlite.sqlite3_bind_text(stmt, 1, ref_z, -1, sqlite.SQLITE_TRANSIENT);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW) return .{ .chunks = 0, .bytes = 0 };
    const bytes: u64 = @intCast(sqlite.sqlite3_column_int64(stmt, 0));
    const chunks: u64 = @intCast(sqlite.sqlite3_column_int64(stmt, 1));
    return .{ .chunks = chunks, .bytes = bytes };
}
