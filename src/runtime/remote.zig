const std = @import("std");
const iface = @import("./iface.zig");
const types = @import("./types.zig");

const Remote = struct {
    store_root: []const u8,
    remote_addr: []const u8,
};

pub fn open(allocator: std.mem.Allocator, cfg: iface.Config) !iface.Runtime {
    const self = try allocator.create(Remote);
    self.* = .{
        .store_root = try allocator.dupe(u8, cfg.store_root),
        .remote_addr = try allocator.dupe(u8, cfg.remote_addr),
    };
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: iface.Runtime.VTable = .{
    .run = stubRun,
    .ps = stubPs,
    .logs = stubLogs,
    .kill = stubKill,
    .stop = stubStop,
    .rm = stubRm,
    .pull = stubPull,
    .images = stubImages,
    .exec = stubExec,
    .rmi = stubRmi,
    .deinit = deinitImpl,
};

fn stubRun(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.RunSpec) !u8 {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubPs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) !void {
    _ = ptr;
    std.debug.print("remote runtime: not implemented (no worker client in this build)\n", .{});
    return iface.Error.NotImplemented;
}

fn stubLogs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.LogsOptions) !void {
    _ = ptr;
    std.debug.print("remote runtime: not implemented (no worker client in this build)\n", .{});
    return iface.Error.NotImplemented;
}

fn stubKill(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.KillSpec) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubStop(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.ContextRef) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubRm(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.ContextRef) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubPull(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.PullSpec) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubImages(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubExec(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.ExecSpec) !u8 {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn stubRmi(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.RmiSpec) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *Remote = @ptrCast(@alignCast(ptr));
    allocator.free(self.store_root);
    allocator.free(self.remote_addr);
    allocator.destroy(self);
}
