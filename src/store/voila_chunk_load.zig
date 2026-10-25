const std = @import("std");
const voila_store = @import("./voila_store.zig");

pub const FetchError = error{ OutOfMemory, FetchFailed };

/// Fetches a chunk that is not in the local store; the registry provides one.
pub const Fetcher = struct {
    io: std.Io,
    fetchFn: *const fn (io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) FetchError![]u8,

    pub fn fetch(self: Fetcher, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) FetchError![]u8 {
        return self.fetchFn(self.io, allocator, voila_root, chunk_hex);
    }
};

/// Local chunk read, falling back to `fetcher` on a miss; a failed fetch reports the
/// fetch error, not the local miss.
pub fn loadChunkRaw(
    fetcher: ?Fetcher,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
    algo: i32,
) ![]u8 {
    return voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch |e| {
        const f = fetcher orelse return e;
        return f.fetch(allocator, voila_root, chunk_hex);
    };
}

fn failingFetch(_: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8) FetchError![]u8 {
    return error.FetchFailed;
}

test "a failed fetch is reported instead of the local miss" {
    const fs = @import("sys").fs;
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-chunk-load-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {};
    const missing = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.FileNotFound, loadChunkRaw(null, a, root, missing, voila_store.AlgoRaw));
    const f: Fetcher = .{ .io = undefined, .fetchFn = failingFetch };
    try std.testing.expectError(error.FetchFailed, loadChunkRaw(f, a, root, missing, voila_store.AlgoRaw));
}
