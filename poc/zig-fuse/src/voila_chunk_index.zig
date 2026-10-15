const std = @import("std");
const sqlite = @import("sqlite_c");

pub fn compAlgoForChunk(voila_root: []const u8, chunk_id: []const u8) !i32 {
    if (chunk_id.len != 32) return error.BadChunkId;
    const db_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/index.db", .{voila_root}) catch return error.SqliteOpen;
    defer std.heap.page_allocator.free(db_path);
    const db_path_z = std.heap.page_allocator.allocSentinel(u8, db_path.len, 0) catch return error.SqliteOpen;
    defer std.heap.page_allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db);

    const sql = "SELECT comp_algo FROM chunks WHERE id = ?";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);

    _ = sqlite.sqlite3_bind_blob(stmt, 1, chunk_id.ptr, @intCast(chunk_id.len), sqlite.SQLITE_TRANSIENT);
    const step = sqlite.sqlite3_step(stmt);
    if (step == sqlite.SQLITE_DONE) return error.ChunkNotFound;
    if (step != sqlite.SQLITE_ROW) return error.SqliteStep;
    return @intCast(sqlite.sqlite3_column_int64(stmt, 0));
}

pub const Error = error{
    SqliteOpen,
    SqlitePrepare,
    SqliteStep,
    BadChunkId,
    ChunkNotFound,
};
