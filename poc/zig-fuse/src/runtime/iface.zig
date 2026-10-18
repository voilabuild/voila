const std = @import("std");
const types = @import("types.zig");

pub const RunSpec = types.RunSpec;
pub const PsRow = types.PsRow;
pub const LogsOptions = types.LogsOptions;
pub const KillSpec = types.KillSpec;

pub const Kind = enum { local, remote };

pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: RunSpec) anyerror!u8,
        ps: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror!void,
        logs: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, opts: LogsOptions) anyerror!void,
        kill: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: KillSpec) anyerror!void,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn run(self: Runtime, io: std.Io, allocator: std.mem.Allocator, spec: RunSpec) !u8 {
        return self.vtable.run(self.ptr, io, allocator, spec);
    }

    pub fn ps(self: Runtime, io: std.Io, allocator: std.mem.Allocator) !void {
        return self.vtable.ps(self.ptr, io, allocator);
    }

    pub fn logs(self: Runtime, io: std.Io, allocator: std.mem.Allocator, opts: LogsOptions) !void {
        return self.vtable.logs(self.ptr, io, allocator, opts);
    }

    pub fn kill(self: Runtime, io: std.Io, allocator: std.mem.Allocator, spec: KillSpec) !void {
        return self.vtable.kill(self.ptr, io, allocator, spec);
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const Config = struct {
    kind: Kind = .local,
    store_root: []const u8,
    remote_addr: []const u8 = "",
};

pub const Error = error{
    NotImplemented,
    NeedVoilaRoot,
    NeedImage,
    NeedCommand,
    NeedContextId,
};
