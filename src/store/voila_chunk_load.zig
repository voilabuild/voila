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

/// Local chunk read, falling back to `fetcher` on a miss.
pub fn loadChunkRaw(
    fetcher: ?Fetcher,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
    algo: i32,
) ![]u8 {
    return voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch |e| {
        if (fetcher) |f| return f.fetch(allocator, voila_root, chunk_hex) catch e;
        return e;
    };
}
