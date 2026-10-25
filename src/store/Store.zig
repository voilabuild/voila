const std = @import("std");
const voila_chunk_load = @import("voila_chunk_load.zig");

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load_chunk: *const fn (
            ptr: *anyopaque,
            fetcher: ?voila_chunk_load.Fetcher,
            allocator: std.mem.Allocator,
            chunk_hex: []const u8,
            algo: i32,
        ) anyerror![]u8,
    };

    pub fn loadChunk(
        self: Store,
        fetcher: ?voila_chunk_load.Fetcher,
        allocator: std.mem.Allocator,
        chunk_hex: []const u8,
        algo: i32,
    ) ![]u8 {
        return self.vtable.load_chunk(self.ptr, fetcher, allocator, chunk_hex, algo);
    }
};

/// Local on-disk store under one voila root directory.
pub const Local = struct {
    voila_root: []const u8,

    pub fn store(self: *Local) Store {
        return .{ .ptr = self, .vtable = &local_vtable };
    }

    const local_vtable = Store.VTable{
        .load_chunk = localLoadChunk,
    };

    fn localLoadChunk(
        ptr: *anyopaque,
        fetcher: ?voila_chunk_load.Fetcher,
        allocator: std.mem.Allocator,
        chunk_hex: []const u8,
        algo: i32,
    ) ![]u8 {
        const self: *Local = @ptrCast(@alignCast(ptr));
        return voila_chunk_load.loadChunkRaw(fetcher, allocator, self.voila_root, chunk_hex, algo);
    }
};

pub fn local(voila_root: []const u8) Local {
    return .{ .voila_root = voila_root };
}
