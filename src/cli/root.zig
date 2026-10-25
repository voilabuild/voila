//! Voila CLI library: argv parsing, shared flags, and one module per subcommand.

pub const build = @import("build.zig");
pub const command = @import("command.zig");
pub const commands = @import("commands.zig");
pub const context = @import("context.zig");
pub const dispatch = @import("dispatch.zig");
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
