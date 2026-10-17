const std = @import("std");
const zio = @import("zio");
const backend = @import("backend.zig");
const nbd_linux = @import("nbd_linux.zig");
const posix_util = @import("posix_util.zig");
const capacity_wait = @import("capacity_wait.zig");

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);

    _ = args.next();
    const sub = args.next() orelse "prove";
    const fixture_dir = args.next() orelse "fixture-out";

    if (std.mem.eql(u8, sub, "prove")) {
        try prove(io, init, fixture_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "serve")) {
        const nbd = args.next() orelse "/dev/nbd0";
        var dev = try backend.Device.loadFromFixture(init.gpa, fixture_dir);
        defer dev.deinit();
        try nbd_linux.attachAndServe(io, &dev, nbd, null);
        return;
    }
    std.debug.print("usage: zig-nbd prove [fixture-dir]\n       zig-nbd serve [fixture-dir] [/dev/nbdX]\n", .{});
}

fn prove(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    try ensureFixture(init, fixture_dir);

    var dev = try backend.Device.loadFromFixture(init.gpa, fixture_dir);
    defer dev.deinit();

    try backend.loadSlotsConcurrent(io, &dev, 0, 2);
    if (dev.slot_chunks[0][0] != 0xAA or dev.slot_chunks[2][0] != 0xCC) {
        return error.ConcurrentSlotBytes;
    }

    const nbd_path = "/dev/nbd0";
    if (!nbd_linux.canUseNBD(nbd_path)) {
        std.debug.print("skip: need root and {s} (readAt unit tests: zig build test)\n", .{nbd_path});
        return;
    }

    try rootMountProve(io, init, fixture_dir, nbd_path);
}

fn rootMountProve(_: std.Io, init: std.process.Init, fixture_dir: []const u8, nbd_path: []const u8) !void {
    const mount_dir = "/tmp/zig-nbd-erofs";
    try posix_util.makePath(mount_dir);

    var serve_err: ?anyerror = null;
    var connected = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(gpa: std.mem.Allocator, fixture: []const u8, nbd: []const u8, err: *?anyerror, flag: *std.atomic.Value(bool)) void {
            var rt = zio.Runtime.init(gpa, .{}) catch |e| {
                err.* = e;
                return;
            };
            defer rt.deinit();
            const io_inner = rt.io();
            var device = backend.Device.loadFromFixture(gpa, fixture) catch |e| {
                err.* = e;
                return;
            };
            defer device.deinit();
            nbd_linux.attachAndServe(io_inner, &device, nbd, flag) catch |e| {
                err.* = e;
            };
        }
    }.run, .{ init.gpa, fixture_dir, nbd_path, &serve_err, &connected });

    for (0..20_000) |_| {
        if (connected.load(.acquire)) break;
        if (serve_err != null) return serve_err.?;
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    if (!connected.load(.acquire)) return error.DeviceCapacityTimeout;

    const mount_cmd = try std.fmt.allocPrint(init.gpa, "mount -t erofs -o ro {s} {s}", .{ nbd_path, mount_dir });
    defer init.gpa.free(mount_cmd);
    const mount_z = try init.gpa.allocSentinel(u8, mount_cmd.len, 0);
    defer init.gpa.free(mount_z);
    @memcpy(mount_z, mount_cmd);
    if (posix_util.shell(mount_z) != 0) return error.MountFailed;
    defer umountDir(init.gpa, mount_dir);

    const c_path = try std.fmt.allocPrint(init.gpa, "{s}/c.bin", .{mount_dir});
    defer init.gpa.free(c_path);
    const data = try posix_util.readFileAlloc(init.gpa, c_path, 3 * backend.ChunkSize);
    defer init.gpa.free(data);

    std.debug.print("byte[0]=0x{x:02} byte[1048575]=0x{x:02} byte[1048576]=0x{x:02}\n", .{
        data[0],
        data[backend.ChunkSize - 1],
        data[backend.ChunkSize],
    });
    if (data[0] != 0xAA or data[backend.ChunkSize - 1] != 0xAA or data[backend.ChunkSize] != 0xCC) {
        return error.BoundaryBytesWrong;
    }
    nbd_linux.disconnect(nbd_path);
    thread.join();
    if (serve_err != null) return serve_err.?;
}

fn ensureFixture(init: std.process.Init, dir: []const u8) !void {
    const meta = try std.fmt.allocPrint(init.gpa, "{s}/meta.bin", .{dir});
    defer init.gpa.free(meta);
    if (posix_util.access(meta)) return;

    try posix_util.makePath(dir);
    const voila_root = try findVoilaRoot(init.gpa);
    defer init.gpa.free(voila_root);
    const cmd = try std.fmt.allocPrint(init.gpa, "cd {s} && go run -tags zig_nbd_fixture ./poc/zig-nbd/fixture -o {s}", .{ voila_root, dir });
    defer init.gpa.free(cmd);
    const cmd_z = try init.gpa.allocSentinel(u8, cmd.len, 0);
    @memcpy(cmd_z, cmd);
    defer init.gpa.free(cmd_z);
    const rc = posix_util.shell(cmd_z);
    if (rc != 0) return error.FixtureFailed;
}

fn umountDir(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    const umount_cmd = std.fmt.allocPrint(allocator, "umount {s}", .{mount_dir}) catch return;
    defer allocator.free(umount_cmd);
    const umount_z = allocator.allocSentinel(u8, umount_cmd.len, 0) catch return;
    defer allocator.free(umount_z);
    @memcpy(umount_z, umount_cmd);
    _ = posix_util.shell(umount_z);
}

fn findVoilaRoot(allocator: std.mem.Allocator) ![]const u8 {
    const seeds = [_][]const u8{
        "/agent/repos/voila",
        "../../..",
        "../..",
    };
    for (seeds) |seed| {
        const gomod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{seed});
        defer allocator.free(gomod);
        if (posix_util.access(gomod)) return allocator.dupe(u8, seed);
    }
    return error.NoVoilaRoot;
}
