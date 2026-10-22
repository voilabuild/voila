const std = @import("std");

pub const ReadSizeFn = *const fn (nbd_path: []const u8) ReadSizeError!u64;

pub const ReadSizeError = error{
    SysfsMissing,
    SysfsParse,
};

const blk_get_size64: u64 = 0x80081272;

pub fn readDeviceSizeWhenReadable(nbd_path: []const u8) ReadSizeError!u64 {
    const size = readSysfsDeviceSizeBytes(nbd_path) catch return error.SysfsMissing;
    if (!deviceReadProbe(nbd_path)) return error.SysfsMissing;
    return size;
}

fn deviceReadProbe(nbd_path: []const u8) bool {
    var path_z: [64]u8 = undefined;
    if (nbd_path.len >= path_z.len) return false;
    @memcpy(path_z[0..nbd_path.len], nbd_path);
    path_z[nbd_path.len] = 0;
    const fd_raw = std.os.linux.open(path_z[0..nbd_path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    const fd_isize: isize = @bitCast(fd_raw);
    if (fd_isize < 0) return false;
    const fd: i32 = @intCast(fd_isize);
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(@intCast(fd), &buf, buf.len);
    const n_isize: isize = @bitCast(n);
    return n_isize > 0;
}

pub fn readSysfsDeviceSizeBytes(nbd_path: []const u8) ReadSizeError!u64 {
    const name = blockName(nbd_path);
    var path_buf: [128]u8 = undefined;
    const sysfs = std.fmt.bufPrint(&path_buf, "/sys/block/{s}/size", .{name}) catch return error.SysfsMissing;
    if (sysfs.len + 1 > path_buf.len) return error.SysfsMissing;
    path_buf[sysfs.len] = 0;
    const fd_raw = std.os.linux.open(path_buf[0..sysfs.len :0], .{ .ACCMODE = .RDONLY }, 0);
    const fd_sysfs: isize = @bitCast(fd_raw);
    if (fd_sysfs >= 0) {
        const fd: i32 = @intCast(fd_sysfs);
        defer _ = std.c.close(fd);
        var raw: [32]u8 = undefined;
        const n = std.c.read(@intCast(fd), &raw, raw.len);
        if (n > 0) {
            const trimmed = std.mem.trim(u8, raw[0..@intCast(n)], " \t\n\r");
            if (std.fmt.parseInt(u64, trimmed, 10)) |sectors| {
                if (sectors > 0) return sectors * 512;
            } else |_| {}
        }
    }
    return readBlkSize64(nbd_path);
}

fn readBlkSize64(nbd_path: []const u8) ReadSizeError!u64 {
    var path_z: [64]u8 = undefined;
    if (nbd_path.len >= path_z.len) return error.SysfsMissing;
    @memcpy(path_z[0..nbd_path.len], nbd_path);
    path_z[nbd_path.len] = 0;
    const fd_raw = std.os.linux.open(path_z[0..nbd_path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    const fd_isize: isize = @bitCast(fd_raw);
    if (fd_isize < 0) return error.SysfsMissing;
    const fd: i32 = @intCast(fd_isize);
    defer _ = std.c.close(fd);
    var size: u64 = 0;
    const rc_raw = std.os.linux.ioctl(fd, blk_get_size64, @intFromPtr(&size));
    const rc: isize = @bitCast(rc_raw);
    if (rc < 0) return error.SysfsMissing;
    return size;
}

fn blockName(dev_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, dev_path, '/')) |i| {
        return dev_path[i + 1 ..];
    }
    return dev_path;
}

pub fn nbdPIDPresent(nbd_path: []const u8) bool {
    const name = blockName(nbd_path);
    var path_buf: [128]u8 = undefined;
    const pid_path = std.fmt.bufPrint(&path_buf, "/sys/block/{s}/pid", .{name}) catch return false;
    if (pid_path.len + 1 > path_buf.len) return false;
    path_buf[pid_path.len] = 0;
    const fd_raw = std.os.linux.open(path_buf[0..pid_path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    const fd_isize: isize = @bitCast(fd_raw);
    if (fd_isize < 0) return false;
    const fd: i32 = @intCast(fd_isize);
    defer _ = std.c.close(fd);
    var raw: [16]u8 = undefined;
    const n = std.c.read(@intCast(fd), &raw, raw.len);
    if (n <= 0) return false;
    return std.mem.trim(u8, raw[0..@intCast(n)], " \t\n\r").len > 0;
}

pub fn capacitySatisfied(want_bytes: u64, got_bytes: u64) bool {
    return want_bytes == 0 or got_bytes >= want_bytes;
}

/// True when the kernel is not running NBD_DO_IT on this device (no pid file).
pub fn nbdSessionActive(nbd_path: []const u8) bool {
    return nbdPIDPresent(nbd_path);
}

pub fn waitNbdConnected(nbd_path: []const u8, want_bytes: u64, max_polls: u32) !void {
    for (0..max_polls) |_| {
        if (nbdPIDPresent(nbd_path)) return;
        const got = readDeviceSizeWhenReadable(nbd_path) catch 0;
        if (capacitySatisfied(want_bytes, got)) return;
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.NbdConnectTimeout;
}

pub fn waitDeviceCapacityWithPolls(
    nbd_path: []const u8,
    want_bytes: u64,
    max_polls: u32,
    read_size: ReadSizeFn,
) !void {
    if (want_bytes == 0) return;
    for (0..max_polls) |_| {
        const got = read_size(nbd_path) catch 0;
        if (capacitySatisfied(want_bytes, got)) return;
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.DeviceCapacityTimeout;
}

pub fn waitDeviceCapacity(
    io: std.Io,
    nbd_path: []const u8,
    want_bytes: u64,
    timeout_ms: u32,
    read_size: ReadSizeFn,
) !void {
    if (want_bytes == 0) return;
    const clock = std.Io.Clock.awake;
    const timeout = std.Io.Clock.Duration{
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        .clock = clock,
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout);
    while (std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, clock), .lt, deadline)) {
        const got = read_size(nbd_path) catch 0;
        if (capacitySatisfied(want_bytes, got)) return;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), clock);
    }
    return error.DeviceCapacityTimeout;
}

var test_poll_calls: u32 = 0;

test "waitDeviceCapacityWithPolls polls until size matches" {
    test_poll_calls = 0;
    const fake: ReadSizeFn = struct {
        fn read(_: []const u8) ReadSizeError!u64 {
            test_poll_calls += 1;
            if (test_poll_calls < 3) return 0;
            return 8192;
        }
    }.read;

    try waitDeviceCapacityWithPolls("/dev/nbd0", 4096, 100, fake);
    try std.testing.expect(test_poll_calls >= 3);
}

test "capacitySatisfied zero want" {
    try std.testing.expect(capacitySatisfied(0, 0));
}

test "waitDeviceCapacityWithPolls times out" {
    const never: ReadSizeFn = struct {
        fn read(_: []const u8) ReadSizeError!u64 {
            return 0;
        }
    }.read;
    try std.testing.expectError(error.DeviceCapacityTimeout, waitDeviceCapacityWithPolls("/dev/nbd0", 4096, 5, never));
}
