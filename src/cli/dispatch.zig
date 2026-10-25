//! Subcommand dispatch table: one handler per `commands.Name`.

const commands = @import("commands.zig");
const command = @import("command.zig");

const build = @import("build.zig");
const container_fuse_serve = @import("container_fuse_serve.zig");
const container_isolated_exec = @import("container_isolated_exec.zig");
const exec_cmd = @import("exec.zig");
const images = @import("images.zig");
const import_cmd = @import("import.zig");
const kill = @import("kill.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const logs = @import("logs.zig");
const prove = @import("prove.zig");
const prove_store = @import("prove_store.zig");
const ps = @import("ps.zig");
const pull = @import("pull.zig");
const push = @import("push.zig");
const rm = @import("rm.zig");
const rmi = @import("rmi.zig");
const run_cmd = @import("run.zig");
const serve = @import("serve.zig");
const serve_index = @import("serve_index.zig");
const serve_store = @import("serve_store.zig");
const stop = @import("stop.zig");
const userns_probe = @import("userns_probe.zig");
const worker = @import("worker.zig");

pub fn run(sub: commands.Name, ctx: command.Ctx) !void {
    switch (sub) {
        .userns_probe => try userns_probe.execute(ctx),
        .login => try login.execute(ctx),
        .logout => try logout.execute(ctx),
        .prove => try prove.execute(ctx),
        .prove_store => try prove_store.execute(ctx),
        .serve => try serve.execute(ctx),
        .serve_index => try serve_index.execute(ctx),
        .container_fuse_serve => try container_fuse_serve.execute(ctx),
        .container_isolated_exec => try container_isolated_exec.execute(ctx),
        .container_worker => try worker.execute(ctx),
        .build => try build.execute(ctx),
        .run => try run_cmd.execute(ctx),
        .exec => try exec_cmd.execute(ctx),
        .ps => try ps.execute(ctx),
        .logs => try logs.execute(ctx),
        .pull => try pull.executePull(ctx),
        .push => try push.execute(ctx),
        .import => try import_cmd.execute(ctx),
        .rmi => try rmi.execute(ctx),
        .images => try images.execute(ctx),
        .kill => try kill.execute(ctx),
        .stop => try stop.execute(ctx),
        .rm => try rm.execute(ctx),
        .serve_store => try serve_store.execute(ctx),
    }
}
