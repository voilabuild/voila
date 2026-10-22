const std = @import("std");
const posix_util = @import("posix_util");
const runtime = @import("runtime");
const nbd = @import("voilad_nbd");
const voila_tree = nbd.voila_tree;
const erofs_build = nbd.erofs_build;
const backend = nbd.backend;
const nbd_linux = nbd.nbd_linux;
const fixture_build = nbd.fixture_build;
const mount_backend = @import("mount_backend");

pub const NbdSession = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    device: *backend.Device,
    nbd_path: []const u8,
    lower_dir: []const u8,
    serve_err: ?anyerror,
    connected: std.atomic.Value(bool),
    stopped: std.atomic.Value(bool),

    pub fn stop(self: *NbdSession) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        unmountLower(self.allocator, self.lower_dir);
        nbd_linux.disconnect(self.nbd_path);
        self.thread.join();
        self.device.deinit();
        self.allocator.destroy(self.device);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

pub fn mountStoreRoot(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    merged_root_hex: []const u8,
    lower_dir: []const u8,
    nbd_path: []const u8,
) !*NbdSession {
    voila_tree.prefetch_io = runtime.io;
    var tree = try voila_tree.openTreeEager(allocator, voila_root, merged_root_hex);
    defer tree.deinit();

    var built = try erofs_build.build(allocator, &tree);
    defer built.deinit();

    const device = try allocator.create(backend.Device);
    device.* = try backend.Device.fromBuildResult(allocator, voila_root, &built);
    return startSession(allocator, device, lower_dir, nbd_path);
}

fn startSession(allocator: std.mem.Allocator, device: *backend.Device, lower_dir: []const u8, nbd_path: []const u8) !*NbdSession {
    nbd_linux.disconnect(nbd_path);
    const session = try allocator.create(NbdSession);
    session.* = .{
        .allocator = allocator,
        .thread = undefined,
        .device = device,
        .nbd_path = nbd_path,
        .lower_dir = lower_dir,
        .serve_err = null,
        .connected = std.atomic.Value(bool).init(false),
        .stopped = std.atomic.Value(bool).init(false),
    };

    session.thread = try std.Thread.spawn(.{}, nbdServeThread, .{session});

    for (0..20_000) |_| {
        if (session.connected.load(.acquire)) break;
        if (session.serve_err) |_| {
            session.thread.join();
            device.deinit();
            allocator.destroy(device);
            allocator.destroy(session);
            return error.NbdServeFailed;
        }
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    if (!session.connected.load(.acquire)) {
        nbd_linux.disconnect(nbd_path);
        session.thread.join();
        device.deinit();
        allocator.destroy(device);
        allocator.destroy(session);
        return error.NbdConnectTimeout;
    }

    const mount_cmd = try std.fmt.allocPrint(allocator, "mount -t erofs -o ro {s} {s}", .{ nbd_path, lower_dir });
    defer allocator.free(mount_cmd);
    const mount_z = try allocator.allocSentinel(u8, mount_cmd.len, 0);
    defer allocator.free(mount_z);
    @memcpy(mount_z, mount_cmd);
    if (posix_util.shell(mount_z) != 0) {
        nbd_linux.disconnect(nbd_path);
        session.thread.join();
        device.deinit();
        allocator.destroy(device);
        allocator.destroy(session);
        return error.ErofsMountFailed;
    }

    return session;
}

fn nbdServeThread(session: *NbdSession) void {
    nbd_linux.attachAndServe(runtime.io, session.device, session.nbd_path, &session.connected) catch |e| {
        session.serve_err = e;
    };
}

pub fn unmountLower(allocator: std.mem.Allocator, lower_dir: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "umount -l {s}", .{lower_dir}) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
}

pub fn proveBoundaryFixture(allocator: std.mem.Allocator) !void {
    const nbd_path = mount_backend.nbdDevicePath();
    if (!nbd_linux.canUseNBD(nbd_path)) {
        std.debug.print("skip: need root and {s}\n", .{nbd_path});
        return;
    }

    var built = try fixture_build.buildBoundaryFixture(allocator);
    defer built.deinit();

    const out_dir = "/tmp/voilad-erofs-prove";
    try writeProveFixture(allocator, out_dir, &built);

    const device_ptr = try allocator.create(backend.Device);
    device_ptr.* = try backend.Device.loadFromFixture(allocator, out_dir);

    try backend.loadSlotsConcurrent(runtime.io, device_ptr, 0, 2);
    if (device_ptr.slot_chunks[0][0] != 0xAA or device_ptr.slot_chunks[2][0] != 0xCC) return error.ConcurrentSlotBytes;

    const mount_dir = "/tmp/voilad-erofs-mount";
    try posix_util.makePath(mount_dir);
    defer unmountLower(allocator, mount_dir);
    nbd_linux.disconnect(nbd_path);

    const session = try startSession(allocator, device_ptr, mount_dir, nbd_path);
    defer session.stop();

    const c_path = try std.fmt.allocPrint(allocator, "{s}/c.bin", .{mount_dir});
    defer allocator.free(c_path);
    const data = try posix_util.readFileAlloc(allocator, c_path, 3 * backend.ChunkSize);
    defer allocator.free(data);

    std.debug.print("byte[0]=0x{x:02} byte[1048575]=0x{x:02} byte[1048576]=0x{x:02}\n", .{
        data[0],
        data[backend.ChunkSize - 1],
        data[backend.ChunkSize],
    });
    if (data[0] != 0xAA or data[backend.ChunkSize - 1] != 0xAA or data[backend.ChunkSize] != 0xCC) {
        return error.BoundaryBytesWrong;
    }
    std.debug.print("voilad prove-erofs: ok (zig erofs_build + nbd + mount)\n", .{});
}

fn writeProveFixture(allocator: std.mem.Allocator, dir: []const u8, built: *const erofs_build.BuildResult) !void {
    try posix_util.makePath(dir);
    const chunks_dir = try std.fmt.allocPrint(allocator, "{s}/chunks", .{dir});
    defer allocator.free(chunks_dir);
    try posix_util.makePath(chunks_dir);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.bin", .{dir});
    defer allocator.free(meta_path);
    try writeFile(allocator, meta_path, built.metadata);

    var slots_text: std.ArrayList(u8) = .empty;
    defer slots_text.deinit(allocator);
    const fills = [_]u8{ 0xAA, 0xBB, 0xCC };
    for (built.slot_hex, 0..) |hex, i| {
        const fill: u8 = if (i < fills.len) fills[i] else 0x00;
        if (hex.len != 0) {
            const path = try std.fmt.allocPrint(allocator, "{s}/chunks/{s}", .{ dir, hex });
            defer allocator.free(path);
            const chunk = try filledChunk(allocator, fill);
            defer allocator.free(chunk);
            try writeFile(allocator, path, chunk);
        }
        const line = try std.fmt.allocPrint(allocator, "{d} {s}\n", .{ i, hex });
        defer allocator.free(line);
        try slots_text.appendSlice(allocator, line);
    }
    const slots_path = try std.fmt.allocPrint(allocator, "{s}/slots.txt", .{dir});
    defer allocator.free(slots_path);
    try writeFile(allocator, slots_path, slots_text.items);
}

fn filledChunk(allocator: std.mem.Allocator, fill: u8) ![]u8 {
    const b = try allocator.alloc(u8, backend.ChunkSize);
    @memset(b, fill);
    return b;
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
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}
