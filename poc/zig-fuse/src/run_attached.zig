//! Attached run: mount store image FUSE, exec one command, unmount.
const std = @import("std");
const fuse_linux = @import("fuse_linux.zig");
const fuse_vfs_mod = @import("fuse_vfs.zig");
const voila_vfs_mod = @import("voila_vfs.zig");
const voila_loader = @import("voila_loader.zig");
const voila_registry = @import("voila_registry.zig");
const voila_registry_creds = @import("voila_registry_creds.zig");
const posix_util = @import("posix_util.zig");
const mount_exec = @import("mount_exec.zig");

const ServeCtx = struct {
    session: fuse_linux.Session,
    err: ?anyerror,
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    image: []const u8,
    cmd_argv: []const []const u8,
) !u8 {
    if (!fuse_linux.canUseFuse()) return error.NeedFuse;
    if (cmd_argv.len == 0) return error.NeedCommand;

    voila_registry.setIo(io, allocator);
    try voila_registry_creds.loadFromCredsFile(allocator, voila_root);
    try voila_registry.loadFromEnv(allocator);

    const tree = try voila_loader.loadTreeRoot(io, allocator, voila_root, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();

    const mount_dir = try std.fmt.allocPrint(allocator, "/tmp/voila-run-mnt-{d}", .{std.c.getpid()});
    defer allocator.free(mount_dir);
    const vfs_exec = try mount_exec.resolveArgv0VfsPath(allocator, &fuse_vfs, cmd_argv[0]);
    defer allocator.free(vfs_exec);
    const host_argv0 = try mount_exec.hostPathForVfsExec(allocator, mount_dir, vfs_exec);
    defer allocator.free(host_argv0);

    try posix_util.makePath(mount_dir);

    var ctx: ServeCtx = .{
        .session = try fuse_linux.mountSession(allocator, mount_dir, &fuse_vfs),
        .err = null,
    };

    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(shared: *ServeCtx) void {
            fuse_linux.serveSession(&shared.session) catch |e| {
                shared.err = e;
            };
        }
    }.serve, .{&ctx});

    const result = execChild(io, allocator, mount_dir, host_argv0, cmd_argv);
    teardown(allocator, mount_dir, &ctx, thread);
    return result;
}

fn teardown(allocator: std.mem.Allocator, mount_dir: []const u8, ctx: *ServeCtx, thread: std.Thread) void {
    ctx.session.stop();
    fusermountU(allocator, mount_dir);
    thread.join();
    ctx.session.deinit();
}

fn execChild(io: std.Io, allocator: std.mem.Allocator, mount_dir: []const u8, host_argv0: []const u8, cmd_argv: []const []const u8) !u8 {
    try mount_exec.waitMountListed(mount_dir, io);

    var argv_host: std.ArrayList([]const u8) = .empty;
    defer argv_host.deinit(allocator);
    try argv_host.append(allocator, host_argv0);
    for (cmd_argv[1..]) |arg| try argv_host.append(allocator, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv_host.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn fusermountU(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "fusermount3 -u {s} 2>/dev/null || umount {s} 2>/dev/null", .{ mount_dir, mount_dir }) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
}

pub const Error = error{
    NeedFuse,
    NeedCommand,
    MountNotReady,
};
