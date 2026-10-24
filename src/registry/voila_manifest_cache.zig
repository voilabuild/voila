const std = @import("std");
const voila_refkey = @import("core").voila_refkey;
const posix_util = @import("sys").posix_util;

pub fn manifestPath(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) ![]const u8 {
    const key = try voila_refkey.refKey(allocator, image_ref);
    defer allocator.free(key);
    return std.fmt.allocPrint(allocator, "{s}/manifests/{s}.json", .{ voila_root, key });
}

pub fn save(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8, body: []const u8) !void {
    const path = try manifestPath(allocator, voila_root, image_ref);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try posix_util.makePath(dir);
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < body.len) {
        const n = std.c.write(fd, body[off..].ptr, body.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub fn load(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) ![]u8 {
    const path = try manifestPath(allocator, voila_root, image_ref);
    defer allocator.free(path);
    return posix_util.readFileAlloc(allocator, path, 32 * 1024 * 1024);
}

pub const Error = error{
    BadPath,
    FileOpenFailed,
    FileWriteFailed,
};
