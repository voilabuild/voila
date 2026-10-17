const std = @import("std");
const launch = @import("launch");
const grpc_shim = @import("grpc_shim");
const runtime = @import("runtime");
const registry_global = @import("registry_global");
const lifecycle = @import("lifecycle");
const registry_creds = @import("registry_creds");
const voila_registry = @import("voila_registry");
const mount_backend = @import("mount_backend");
const erofs_mount = @import("erofs_mount");

var g_voila_root: []const u8 = "";
var g_zig_fuse: []const u8 = "";

export fn voilad_handle_run(req: *const grpc_shim.RunRequest, cb: *grpc_shim.RunCallbacks) callconv(.c) i32 {
    const allocator = std.heap.c_allocator;
    const image = std.mem.span(req.image);
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    const n = req.args_len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ptr = req.args[i];
        args_list.append(allocator, std.mem.span(ptr)) catch return -1;
    }
    const code = launch.runContainer(allocator, g_voila_root, g_zig_fuse, image, args_list.items, cb) catch return -1;
    return if (code < 0) -1 else 0;
}

export fn voilad_handle_exec(
    ctx_id: [*:0]const u8,
    args: [*][*:0]const u8,
    args_len: usize,
    cb: *grpc_shim.ExecCallbacks,
) callconv(.c) i32 {
    return lifecycle.handleExec(ctx_id, args, args_len, cb);
}

export fn voilad_handle_set_registry(url: [*:0]const u8, token: [*:0]const u8) callconv(.c) i32 {
    const allocator = std.heap.c_allocator;
    const registry_url = std.mem.span(url);
    const tok = std.mem.span(token);
    voila_registry.configure(allocator, registry_url, tok) catch return -1;
    registry_creds.write(allocator, g_voila_root, registry_url, tok) catch return -1;
    return 0;
}

pub fn main(init: std.process.Init) !void {
    runtime.io = init.io;
    const allocator = init.gpa;

    registry_global.init();

    var cmd_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = cmd_iter.next();
    if (cmd_iter.next()) |sub| {
        if (std.mem.eql(u8, sub, "prove-erofs")) {
            try erofs_mount.proveBoundaryFixture(allocator);
            return;
        }
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var root: ?[]const u8 = null;
    var socket: ?[]const u8 = null;
    var zig_fuse: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            root = args.next();
        } else if (std.mem.eql(u8, arg, "-socket")) {
            socket = args.next();
        } else if (std.mem.eql(u8, arg, "-zig-fuse")) {
            zig_fuse = args.next();
        }
    }
    const voila_root = root orelse "/var/lib/voila";
    const sock = socket orelse "/var/run/voila.sock";
    g_voila_root = voila_root;
    g_zig_fuse = zig_fuse orelse "../zig-fuse/zig-out/bin/zig-fuse";

    voila_registry.setIo(init.io, allocator);
    const creds = registry_creds.load(allocator, voila_root) catch registry_creds.RegistryCreds{ .registry = "", .token = "" };
    if (creds.registry.len != 0) {
        voila_registry.configure(allocator, creds.registry, creds.token) catch {};
    }

    const sock_z_probe = try allocator.allocSentinel(u8, sock.len, 0);
    defer allocator.free(sock_z_probe);
    @memcpy(sock_z_probe, sock);
    if (std.c.access(sock_z_probe, 0) == 0) {
        _ = std.c.unlink(sock_z_probe);
    }
    const root_z = try allocator.allocSentinel(u8, voila_root.len, 0);
    defer allocator.free(root_z);
    @memcpy(root_z, voila_root);
    const sock_z = try allocator.allocSentinel(u8, sock.len, 0);
    defer allocator.free(sock_z);
    @memcpy(sock_z, sock);

    const hooks = grpc_shim.WorkerHooks{
        .handle_run = voilad_handle_run,
        .handle_exec = voilad_handle_exec,
        .handle_set_registry = voilad_handle_set_registry,
    };

    const mount_pick = mount_backend.resolve(null);
    const backend_name = if (mount_pick.backend == .erofs) "erofs" else "fuse";
    std.debug.print("zig-voilad listening on {s} root={s} mount={s} ({s})\n", .{
        sock,
        voila_root,
        backend_name,
        mount_pick.reason,
    });
    const rc = grpc_shim.voilad_grpc_serve_unix(sock_z, root_z, &hooks);
    registry_global.deinit();
    if (rc != 0) std.process.exit(1);
}
