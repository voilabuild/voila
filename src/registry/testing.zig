const std = @import("std");
const RegistryMod = @import("Registry.zig");
const fetch_mod = @import("voila_registry_fetch.zig");

/// Registry that never fetches chunks (for tests above the registry layer).
pub const NoFetch = struct {
    pub fn registry(self: *NoFetch) RegistryMod.Registry {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = RegistryMod.Registry.VTable{
        .fetch_chunk = noFetch,
    };

    fn noFetch(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
    ) fetch_mod.Error![]u8 {
        return error.RegistryUnset;
    }
};

test "no-fetch registry returns RegistryUnset" {
    var fake: NoFetch = .{};
    try std.testing.expectError(error.RegistryUnset, fake.registry().fetchChunk(undefined, std.testing.allocator, "/tmp", "00"));
}
