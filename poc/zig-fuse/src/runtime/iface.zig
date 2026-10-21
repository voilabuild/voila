const std = @import("std");
const types = @import("types.zig");

pub const RunSpec = types.RunSpec;
pub const PsRow = types.PsRow;
pub const LogsOptions = types.LogsOptions;
pub const KillSpec = types.KillSpec;
pub const PullSpec = types.PullSpec;
pub const ImageInfo = types.ImageInfo;
pub const ContextRef = types.ContextRef;
pub const ExecSpec = types.ExecSpec;
pub const RmiSpec = types.RmiSpec;

pub const Kind = enum { local, remote };

pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: RunSpec) anyerror!u8,
        ps: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror!void,
        logs: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, opts: LogsOptions) anyerror!void,
        kill: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: KillSpec) anyerror!void,
        stop: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, ref: ContextRef) anyerror!void,
        rm: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, ref: ContextRef) anyerror!void,
        pull: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: PullSpec) anyerror!void,
        images: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror!void,
        exec: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: ExecSpec) anyerror!u8,
        rmi: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: RmiSpec) anyerror!void,
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

    pub fn stop(self: Runtime, io: std.Io, allocator: std.mem.Allocator, ref: ContextRef) !void {
        return self.vtable.stop(self.ptr, io, allocator, ref);
    }

    pub fn rm(self: Runtime, io: std.Io, allocator: std.mem.Allocator, ref: ContextRef) !void {
        return self.vtable.rm(self.ptr, io, allocator, ref);
    }

    pub fn pull(self: Runtime, io: std.Io, allocator: std.mem.Allocator, spec: PullSpec) !void {
        return self.vtable.pull(self.ptr, io, allocator, spec);
    }

    pub fn images(self: Runtime, io: std.Io, allocator: std.mem.Allocator) !void {
        return self.vtable.images(self.ptr, io, allocator);
    }

    pub fn exec(self: Runtime, io: std.Io, allocator: std.mem.Allocator, spec: ExecSpec) !u8 {
        return self.vtable.exec(self.ptr, io, allocator, spec);
    }

    pub fn rmi(self: Runtime, io: std.Io, allocator: std.mem.Allocator, spec: RmiSpec) !void {
        return self.vtable.rmi(self.ptr, io, allocator, spec);
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
    NoRegistry,
};
