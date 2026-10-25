//! Shared CLI invocation context and small helpers for subcommands.

const std = @import("std");
const voila_runtime = @import("runtime").open;

pub const Ctx = struct {
    io: std.Io,
    init: std.process.Init,
    args: *std.process.Args.Iterator,

    pub fn gpa(self: Ctx) std.mem.Allocator {
        return self.init.gpa;
    }
};

pub fn openRuntime(allocator: std.mem.Allocator, cfg: voila_runtime.Config) !voila_runtime.Runtime {
    return voila_runtime.open(allocator, cfg);
}

pub fn exitIfNotImplemented(e: anyerror) void {
    if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
}
