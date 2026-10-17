const std = @import("std");

pub const ReadSizeFn = *const fn (nbd_path: []const u8) ReadSizeError!u64;

pub const ReadSizeError = error{
    SysfsMissing,
    SysfsParse,
};

pub fn readSysfsDeviceSizeBytes(nbd_path: []const u8) ReadSizeError!u64 {
    const name = blockName(nbd_path);
    var path_buf: [128]u8 = undefined;
    const sysfs = std.fmt.bufPrint(&path_buf, "/sys/block/{s}/size", .{name}) catch return error.SysfsMissing;
    const data = std.fs.openFileAbsolute(sysfs, .{}) catch return error.SysfsMissing;
    defer data.close();
    var raw: [32]u8 = undefined;
    const n = data.read(&raw) catch return error.SysfsMissing;
    const trimmed = std.mem.trim(u8, raw[0..n], " \t\n\r");
    const sectors = std.fmt.parseInt(u64, trimmed, 10) catch return error.SysfsParse;
    return sectors * 512;
}

fn blockName(dev_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, dev_path, '/')) |i| {
        return dev_path[i + 1 ..];
    }
    return dev_path;
}

pub fn capacitySatisfied(want_bytes: u64, got_bytes: u64) bool {
    return want_bytes == 0 or got_bytes >= want_bytes;
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
    const deadline = io.monotonicNow() + std.Io.Duration.fromMilliseconds(timeout_ms);
    while (io.monotonicNow() < deadline) {
        const got = read_size(nbd_path) catch 0;
        if (capacitySatisfied(want_bytes, got)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
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
