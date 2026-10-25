//! The `cli` layer: argv parsing, subcommand names, and command entry points.

pub const commands = @import("commands.zig");
pub const context = @import("context.zig");
pub const exec = @import("exec.zig");
pub const flags = @import("flags.zig");
pub const login = @import("login.zig");
pub const logout = @import("logout.zig");
pub const logs = @import("logs.zig");
pub const prove = @import("prove.zig");
pub const pull = @import("pull.zig");
pub const rmi = @import("rmi.zig");
pub const run = @import("run.zig");
pub const runtime_only = @import("runtime_only.zig");
pub const usage = @import("usage.zig");
pub const userns_probe = @import("userns_probe.zig");
pub const worker = @import("worker.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
