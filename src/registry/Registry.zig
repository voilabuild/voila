const std = @import("std");
const Hub = @import("Hub.zig").Hub;
const fetch_mod = @import("voila_registry_fetch.zig");

pub const Registry = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fetch_chunk: *const fn (
            ptr: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            voila_root: []const u8,
            chunk_hex: []const u8,
        ) anyerror![]u8,
    };

    pub fn fetchChunk(
        self: Registry,
        io: std.Io,
        allocator: std.mem.Allocator,
        voila_root: []const u8,
        chunk_hex: []const u8,
    ) anyerror![]u8 {
        return self.vtable.fetch_chunk(self.ptr, io, allocator, voila_root, chunk_hex);
    }
};

const http_vtable = Registry.VTable{
    .fetch_chunk = httpFetchChunk,
};

fn httpFetchChunk(
    ptr: *anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
) anyerror![]u8 {
    const reg_hub: *Hub = @ptrCast(@alignCast(ptr));
    return fetch_mod.fetchChunkRaw(reg_hub, io, allocator, voila_root, chunk_hex);
}

/// HTTP/OCI registry client backed by a `Hub` (credentials + chunk origin).
pub fn http(hub: *Hub) Registry {
    return .{ .ptr = hub, .vtable = &http_vtable };
}
