const std = @import("std");
const iface = @import("iface.zig");
const types = @import("types.zig");
const run_attached = @import("../run_attached.zig");

const Local = struct {
    store_root: []const u8,
};

pub fn open(allocator: std.mem.Allocator, store_root: []const u8) !iface.Runtime {
    const self = try allocator.create(Local);
    self.* = .{ .store_root = try allocator.dupe(u8, store_root) };
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: iface.Runtime.VTable = .{
    .run = runImpl,
    .ps = notImplPs,
    .logs = notImplLogs,
    .kill = notImplKill,
    .deinit = deinitImpl,
};

fn runImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.RunSpec) !u8 {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return run_attached.run(io, allocator, self.store_root, spec.image, spec.argv);
}

fn notImplPs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) !void {
    _ = ptr;
    std.debug.print("local runtime: ps requires detached containers (not implemented)\n", .{});
    return iface.Error.NotImplemented;
}

fn notImplLogs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.LogsOptions) !void {
    _ = ptr;
    std.debug.print("local runtime: logs requires detached containers (not implemented)\n", .{});
    return iface.Error.NotImplemented;
}

fn notImplKill(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.KillSpec) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    allocator.free(self.store_root);
    allocator.destroy(self);
}
