const std = @import("std");
const voila_resolve = @import("voila_resolve");
const grpc_shim = @import("grpc_shim");
const posix_util = @import("posix_util");
const runtime = @import("runtime");

fn runCmd(argv: []const []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    const term = try child.wait(runtime.io);
    switch (term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0) return error.FileWriteFailed;
        if (n == 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub fn runContainer(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    zig_fuse_bin: []const u8,
    image: []const u8,
    args: []const []const u8,
    cb: *grpc_shim.RunCallbacks,
) !i32 {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, image);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }

    const t: u32 = @intCast(std.c.getpid());
    var rnd: [4]u8 = undefined;
    @memcpy(&rnd, @as(*const [4]u8, @ptrCast(&t)));
    const ctx_id = try std.fmt.allocPrint(allocator, "voila-{x:0>8}", .{std.mem.readInt(u32, &rnd, .little)});
    defer allocator.free(ctx_id);
    const ctx_id_z = try allocator.allocSentinel(u8, ctx_id.len, 0);
    defer allocator.free(ctx_id_z);
    @memcpy(ctx_id_z, ctx_id);
    if (cb.on_context_id(cb.ctx, ctx_id_z) != 0) return -1;

    const ctx_dir = try std.fmt.allocPrint(allocator, "{s}/ctx/{s}", .{ voila_root, ctx_id });
    defer allocator.free(ctx_dir);
    const lower = try std.fmt.allocPrint(allocator, "{s}/lower", .{ctx_dir});
    defer allocator.free(lower);
    const upper = try std.fmt.allocPrint(allocator, "{s}/upper", .{ctx_dir});
    defer allocator.free(upper);
    const work = try std.fmt.allocPrint(allocator, "{s}/work", .{ctx_dir});
    defer allocator.free(work);
    const rootfs = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{ctx_dir});
    defer allocator.free(rootfs);
    const bundle = try std.fmt.allocPrint(allocator, "{s}/bundle", .{ctx_dir});
    defer allocator.free(bundle);

    const ctx_parent = try std.fmt.allocPrint(allocator, "{s}/ctx", .{voila_root});
    defer allocator.free(ctx_parent);
    try posix_util.makePath(ctx_parent);
    try posix_util.makePath(ctx_dir);
    try runCmd(&.{ "mount", "-t", "tmpfs", "tmpfs", ctx_dir });
    defer runCmd(&.{ "umount", ctx_dir }) catch {};
    for ([_][]const u8{ lower, upper, work, rootfs, bundle }) |d| {
        try posix_util.makePath(d);
    }

    var fuse = try std.process.spawn(runtime.io, .{
        .argv = &[_][]const u8{ zig_fuse_bin, "serve-store", voila_root, rec.ref, lower },
    });
    defer {
        fuse.kill(runtime.io);
        if (fuse.id != null) _ = fuse.wait(runtime.io) catch {};
    }
    const probe = try std.fmt.allocPrint(allocator, "{s}/etc/os-release", .{lower});
    defer allocator.free(probe);
    var fuse_ready = false;
    for (0..200) |_| {
        if (posix_util.access(probe)) {
            fuse_ready = true;
            break;
        }
        _ = posix_util.shell("sleep 0.05");
    }
    if (!fuse_ready) return -1;

    const overlay_opt = try std.fmt.allocPrint(allocator, "lowerdir={s},upperdir={s},workdir={s}", .{ lower, upper, work });
    defer allocator.free(overlay_opt);
    try runCmd(&.{ "mount", "-t", "overlay", "overlay", "-o", overlay_opt, rootfs });
    defer runCmd(&.{ "umount", rootfs }) catch {};

    const spec_line = try std.fmt.allocPrint(allocator, "cd {s} && /usr/sbin/runc spec", .{bundle});
    defer allocator.free(spec_line);
    const spec_sh = try allocator.allocSentinel(u8, spec_line.len, 0);
    defer allocator.free(spec_sh);
    @memcpy(spec_sh, spec_line);
    if (posix_util.shell(spec_sh) != 0) {
        const spec_line2 = try std.fmt.allocPrint(allocator, "cd {s} && runc spec", .{bundle});
        defer allocator.free(spec_line2);
        const spec_sh2 = try allocator.allocSentinel(u8, spec_line2.len, 0);
        defer allocator.free(spec_sh2);
        @memcpy(spec_sh2, spec_line2);
        if (posix_util.shell(spec_sh2) != 0) return -1;
    }

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{bundle});
    defer allocator.free(config_path);
    var args_json: std.ArrayList(u8) = .empty;
    defer args_json.deinit(allocator);
    try args_json.appendSlice(allocator, "[");
    if (args.len == 0) {
        try args_json.appendSlice(allocator, "\"/bin/sh\"");
    } else {
        for (args, 0..) |a, idx| {
            if (idx > 0) try args_json.appendSlice(allocator, ",");
            try args_json.appendSlice(allocator, "\"");
            for (a) |c| {
                switch (c) {
                    '\\', '"' => {
                        try args_json.append(allocator, '\\');
                        try args_json.append(allocator, c);
                    },
                    else => try args_json.append(allocator, c),
                }
            }
            try args_json.appendSlice(allocator, "\"");
        }
    }
    try args_json.appendSlice(allocator, "]");
    const patched = try std.fmt.allocPrint(allocator,
        \\{{"ociVersion":"1.0.2","process":{{"terminal":false,"user":{{"uid":0,"gid":0}},"args":{s},"env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"cwd":"/","noNewPrivileges":true}},"root":{{"path":"{s}","readonly":false}},"hostname":"voila","linux":{{"namespaces":[{{"type":"pid"}},{{"type":"ipc"}},{{"type":"uts"}},{{"type":"mount"}},{{"type":"network"}}]}}}}
    , .{ args_json.items, rootfs });
    defer allocator.free(patched);
    try writeFile(allocator, config_path, patched);

    var child = try std.process.spawn(runtime.io, .{
        .argv = &[_][]const u8{ "/usr/sbin/runc", "run", "--bundle", bundle, ctx_id },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io);
    const code: i32 = switch (term) {
        .exited => |c| @intCast(c),
        else => 255,
    };
    _ = cb.on_exit(cb.ctx, code);
    _ = std.process.spawn(runtime.io, .{ .argv = &[_][]const u8{ "/usr/sbin/runc", "delete", ctx_id, "--force" } }) catch {};
    return code;
}
