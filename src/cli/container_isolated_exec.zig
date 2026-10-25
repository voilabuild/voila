const std = @import("std");
const command = @import("command.zig");
const container_isolated_exec = @import("runtime").oci.container_isolated_exec;

pub fn execute(ctx: command.Ctx) !void {
    const spec = try container_isolated_exec.parseCliArgs(ctx.gpa(), ctx.args);
    const code = container_isolated_exec.run(spec) catch |e| {
        switch (e) {
            error.UserNamespacesRequired => std.debug.print("voila: cannot enter a user namespace for the image root (re-run install.sh for the AppArmor voila profile)\n", .{}),
            error.SetupFailed => std.debug.print("voila: cannot set up the image root for {s}\n", .{spec.vfs_argv0}),
            else => std.debug.print("voila: cannot exec {s} in the image: {s}\n", .{ spec.vfs_argv0, @errorName(e) }),
        }
        std.process.exit(container_isolated_exec.errorExitCode(e));
    };
    std.process.exit(code);
}
