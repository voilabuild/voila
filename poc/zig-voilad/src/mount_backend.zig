const std = @import("std");
const posix_util = @import("posix_util");
const nbd_linux = @import("voilad_nbd").nbd_linux;

pub const Backend = enum { fuse, erofs };

pub const Pick = struct {
    backend: Backend,
    reason: []const u8,
};

pub fn resolve(env: ?[]const u8) Pick {
    const raw: ?[]const u8 = if (env) |e| e else if (std.c.getenv("VOILA_MOUNT_BACKEND")) |z| std.mem.span(z) else null;
    if (raw) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, "fuse")) return .{ .backend = .fuse, .reason = "VOILA_MOUNT_BACKEND=fuse" };
        if (std.ascii.eqlIgnoreCase(trimmed, "erofs")) return .{ .backend = .erofs, .reason = "VOILA_MOUNT_BACKEND=erofs" };
        if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) {
            return probeAuto();
        }
        return .{ .backend = .fuse, .reason = "unknown VOILA_MOUNT_BACKEND, using fuse" };
    }
    return probeAuto();
}

fn probeAuto() Pick {
    if (!kernelAtLeast(5, 15)) return .{ .backend = .fuse, .reason = "kernel < 5.15" };
    _ = posix_util.shell("modprobe erofs 2>/dev/null");
    _ = posix_util.shell("modprobe nbd 2>/dev/null");
    const fs = posix_util.readFileAlloc(std.heap.page_allocator, "/proc/filesystems", 4096) catch {
        return .{ .backend = .fuse, .reason = "erofs filesystem not available" };
    };
    defer std.heap.page_allocator.free(fs);
    if (!filesystemsHas(fs, "erofs")) return .{ .backend = .fuse, .reason = "erofs filesystem not available" };
    if (!nbd_linux.canUseNBD("/dev/nbd0")) return .{ .backend = .fuse, .reason = "no usable /dev/nbd*" };
    return .{ .backend = .erofs, .reason = "erofs+nbd ready" };
}

fn filesystemsHas(data: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, data, " \t\n\r");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}

fn kernelAtLeast(maj: u32, min: u32) bool {
    var uts: std.os.linux.utsname = undefined;
    if (std.os.linux.uname(&uts) != 0) return false;
    var rel: [256]u8 = undefined;
    var i: usize = 0;
    while (i < uts.release.len and uts.release[i] != 0) : (i += 1) {
        rel[i] = @intCast(uts.release[i]);
    }
    const release = rel[0..i];
    const dot = std.mem.indexOfScalar(u8, release, '.') orelse return false;
    const maj_s = release[0..dot];
    const rest = release[dot + 1 ..];
    const dot2 = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const min_s = rest[0..dot2];
    const got_maj = std.fmt.parseInt(u32, maj_s, 10) catch return false;
    const got_min = std.fmt.parseInt(u32, min_s, 10) catch return false;
    if (got_maj != maj) return got_maj > maj;
    return got_min >= min;
}

pub fn nbdDevicePath() []const u8 {
    if (std.c.getenv("VOILA_NBD_DEV")) |p| return std.mem.span(p);
    return "/dev/nbd0";
}
