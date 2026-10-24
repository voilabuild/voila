//! Build step cache: step key -> resulting image root, under `<root>/build-cache/`.
const std = @import("std");
const fs = @import("sys").fs;

pub const StepResult = struct {
    /// Merged root manifest chunk after the step.
    root: [32]u8,
    /// Per-layer manifest chunk of the step's diff.
    layer: [32]u8,
    whiteouts: u64,
};

fn entryPath(allocator: std.mem.Allocator, voila_root: []const u8, key: [32]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(key, .lower);
    return std.fmt.allocPrint(allocator, "{s}/build-cache/{s}/{s}", .{ voila_root, hex[0..2], hex });
}

/// A missing or unreadable entry is a miss, never an error.
pub fn get(allocator: std.mem.Allocator, voila_root: []const u8, key: [32]u8) ?StepResult {
    const path = entryPath(allocator, voila_root, key) catch return null;
    defer allocator.free(path);
    var buf: [256]u8 = undefined;
    const f = fs.File.openRead(path) catch return null;
    defer f.close();
    const n = f.readFull(&buf) catch return null;
    return parse(buf[0..n]);
}

fn parse(body: []const u8) ?StepResult {
    var it = std.mem.tokenizeAny(u8, body, " \n");
    var out: StepResult = undefined;
    _ = std.fmt.hexToBytes(&out.root, it.next() orelse return null) catch return null;
    _ = std.fmt.hexToBytes(&out.layer, it.next() orelse return null) catch return null;
    out.whiteouts = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return out;
}

pub fn put(allocator: std.mem.Allocator, voila_root: []const u8, key: [32]u8, res: StepResult) !void {
    const path = try entryPath(allocator, voila_root, key);
    defer allocator.free(path);
    try fs.makePath(std.fs.path.dirname(path).?);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    var line: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(&line, "{s} {s} {d}\n", .{
        std.fmt.bytesToHex(res.root, .lower),
        std.fmt.bytesToHex(res.layer, .lower),
        res.whiteouts,
    });
    try fs.writeFile(tmp, body, 0o644);
    try fs.rename(tmp, path);
}

test "build cache round trip, miss and corrupt entry" {
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-build-cache-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {};

    const key: [32]u8 = @splat(7);
    try std.testing.expect(get(a, root, key) == null);
    const res: StepResult = .{ .root = @splat(1), .layer = @splat(2), .whiteouts = 3 };
    try put(a, root, key, res);
    const got = get(a, root, key).?;
    try std.testing.expectEqualSlices(u8, &res.root, &got.root);
    try std.testing.expectEqualSlices(u8, &res.layer, &got.layer);
    try std.testing.expectEqual(@as(u64, 3), got.whiteouts);

    const path = try entryPath(a, root, key);
    defer a.free(path);
    try fs.writeFile(path, "garbage", 0o644);
    try std.testing.expect(get(a, root, key) == null);
}
