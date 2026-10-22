const std = @import("std");
const zio = @import("zio");
const backend = @import("./backend.zig");
const nbd_linux = @import("./nbd_linux.zig");
const posix_util = @import("./posix_util.zig");
const capacity_wait = @import("./capacity_wait.zig");
const erofs_build = @import("./erofs_build.zig");
const voila_tree = @import("./voila_tree.zig");
const image_resolve = @import("./image_resolve.zig");
const fixture_build = @import("./fixture_build.zig");

extern "c" fn clock_gettime(clk_id: i32, tp: *std.posix.timespec) i32;
const CLOCK_MONOTONIC: i32 = 1;

fn monotonicNs() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);

    _ = args.next();
    const sub = args.next() orelse "prove";

    if (std.mem.eql(u8, sub, "prove")) {
        const fixture_dir = args.next() orelse "fixture-out";
        try prove(io, init, fixture_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "prove-build")) {
        const out_dir = args.next() orelse "/tmp/zig-nbd-zigfixture";
        try proveZigBuilt(io, init, out_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "serve")) {
        const fixture_dir = args.next() orelse "fixture-out";
        const nbd = args.next() orelse "/dev/nbd0";
        var dev = try backend.Device.loadFromFixture(init.gpa, fixture_dir);
        defer dev.deinit();
        try nbd_linux.attachAndServe(io, &dev, nbd, null);
        return;
    }
    if (std.mem.eql(u8, sub, "build")) {
        const store = args.next() orelse return printUsage();
        const image_query = args.next() orelse return printUsage();
        var out_path: ?[]const u8 = null;
        var bench = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--bench")) bench = true else if (std.mem.startsWith(u8, arg, "-o")) {
                if (arg.len > 2) out_path = arg[2..] else out_path = args.next();
            } else if (std.mem.eql(u8, arg, "-o")) {
                out_path = args.next();
            }
        }
        try cmdBuild(init, store, image_query, bench, out_path);
        return;
    }
    return printUsage();
}

fn printUsage() !void {
    std.debug.print(
        \\usage:
        \\  zig-nbd prove [fixture-dir]
        \\  zig-nbd prove-build [out-dir]
        \\  zig-nbd serve [fixture-dir] [/dev/nbdX]
        \\  zig-nbd build <store-root> <image-ref|root-hex> [--bench]
        \\
    , .{});
}

fn dropCaches() void {
    _ = posix_util.shell("sync");
    _ = posix_util.shell("sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'");
}

fn cmdBuild(init: std.process.Init, store: []const u8, image_query: []const u8, bench: bool, out_path: ?[]const u8) !void {
    const root_chunk = try image_resolve.resolveRoot(init.gpa, store, image_query);
    defer init.gpa.free(root_chunk);

    var tree = try voila_tree.openTreeEager(init.gpa, store, root_chunk);
    defer tree.deinit();

    const runs: usize = if (bench) 7 else 1;
    var times: [7]f64 = undefined;
    var result: ?erofs_build.BuildResult = null;
    var last_ms: f64 = 0;
    for (0..runs) |i| {
        dropCaches();
        const t0 = monotonicNs();
        const built = try erofs_build.build(init.gpa, &tree);
        const ms = @as(f64, @floatFromInt(monotonicNs() - t0)) / 1e6;
        last_ms = ms;
        if (bench) times[i] = ms;
        if (result) |*prev| prev.deinit();
        result = built;
    }
    var r = result orelse return;
    defer r.deinit();

    const report_ms = if (bench) median(times[0..runs]) else last_ms;
    const ms_thou = @as(u64, @intFromFloat(report_ms * 1000));
    std.debug.print("build_ms={d}.{d:0>3}\n", .{ ms_thou / 1000, ms_thou % 1000 });
    if (bench) {
        var min = times[0];
        var max = times[0];
        for (times[0..runs]) |t| {
            min = @min(min, t);
            max = @max(max, t);
        }
        std.debug.print("build_ms_median={d} min={d} max={d} runs={d}\n", .{ median(times[0..runs]), min, max, runs });
    }
    std.debug.print("meta_bytes={d}\n", .{r.metadata.len});
    std.debug.print("device_bytes={d}\n", .{r.device_size});
    std.debug.print("data_offset={d}\n", .{r.data_offset});
    std.debug.print("slots={d}\n", .{r.slot_hex.len});
    std.debug.print("files={d} dirs={d} symlinks={d} devices={d}\n", .{ r.files, r.dirs, r.symlinks, r.devices });
    if (out_path) |path| {
        try writeFile(init.gpa, path, r.metadata);
    }
}

fn median(values: []const f64) f64 {
    var buf: [7]f64 = undefined;
    @memcpy(buf[0..values.len], values);
    const slice = buf[0..values.len];
    std.mem.sort(f64, slice, {}, std.sort.asc(f64));
    return slice[values.len / 2];
}

fn proveZigBuilt(io: std.Io, init: std.process.Init, out_dir: []const u8) !void {
    var built = try fixture_build.buildBoundaryFixture(init.gpa);
    defer built.deinit();
    try writeBuildFixture(init.gpa, out_dir, &built);
    try prove(io, init, out_dir);
}

fn writeBuildFixture(allocator: std.mem.Allocator, dir: []const u8, built: *const erofs_build.BuildResult) !void {
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
        const n = std.c.write(@intCast(fd), data.ptr + off, data.len - off);
        if (n < 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
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
    umountDir(init.gpa, mount_dir);
    nbd_linux.disconnect(nbd_path);
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
    defer thread.join();

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
    umountDir(init.gpa, mount_dir);
    nbd_linux.disconnect(nbd_path);
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
    const umount_cmd = std.fmt.allocPrint(allocator, "umount -l {s}", .{mount_dir}) catch return;
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
