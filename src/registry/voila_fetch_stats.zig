const std = @import("std");
const voila_registry_hub = @import("./voila_registry_hub.zig");

pub const Snapshot = struct {
    chunks_fetched: u64 = 0,
    bytes_fetched: u64 = 0,
    image_chunks: u64 = 0,
    image_bytes: u64 = 0,
};

var g_mu: std.Io.Mutex = .init;

fn lockStats() void {
    if (voila_registry_hub.g_io) |io| g_mu.lockUncancelable(io);
}
fn unlockStats() void {
    if (voila_registry_hub.g_io) |io| g_mu.unlock(io);
}

var g_seen: ?std.StringHashMap(void) = null;
var g_bytes: u64 = 0;
var g_image_chunks: u64 = 0;
var g_image_bytes: u64 = 0;
var g_allocator: ?std.mem.Allocator = null;
var g_stats_path: ?[]const u8 = null;

pub fn init(allocator: std.mem.Allocator, stats_path: ?[]const u8) void {
    lockStats();
    defer unlockStats();
    g_allocator = allocator;
    if (g_stats_path) |p| allocator.free(p);
    g_stats_path = if (stats_path) |sp| allocator.dupe(u8, sp) catch null else null;
    if (g_seen) |*m| {
        var it = m.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        m.deinit();
    }
    g_seen = std.StringHashMap(void).init(allocator);
    g_bytes = 0;
}

pub fn setImageTotals(chunks: u64, bytes: u64) void {
    lockStats();
    defer unlockStats();
    g_image_chunks = chunks;
    g_image_bytes = bytes;
}

pub fn recordChunk(hex: []const u8, nbytes: usize) void {
    lockStats();
    defer unlockStats();
    const alloc = g_allocator orelse return;
    const m = &(g_seen orelse return);
    const key = alloc.dupe(u8, hex) catch return;
    const gop = m.getOrPut(key) catch {
        alloc.free(key);
        return;
    };
    if (gop.found_existing) {
        alloc.free(key);
        return;
    }
    g_bytes += @intCast(nbytes);
    writeStatsFileUnlocked();
}

fn writeStatsFileUnlocked() void {
    const path = g_stats_path orelse return;
    const alloc = g_allocator orelse return;
    const n: u64 = if (g_seen) |*m| @intCast(m.count()) else 0;
    const json = std.fmt.allocPrint(
        alloc,
        "{{\"chunks_fetched\":{d},\"bytes_fetched\":{d},\"image_chunks\":{d},\"image_bytes\":{d}}}\n",
        .{ n, g_bytes, g_image_chunks, g_image_bytes },
    ) catch return;
    defer alloc.free(json);
    const path_z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < json.len) {
        const wrote = std.c.write(fd, json[off..].ptr, json.len - off);
        if (wrote <= 0) break;
        off += @intCast(wrote);
    }
}

pub fn snapshot() Snapshot {
    lockStats();
    defer unlockStats();
    const n: u64 = if (g_seen) |*m| @intCast(m.count()) else 0;
    return .{
        .chunks_fetched = n,
        .bytes_fetched = g_bytes,
        .image_chunks = g_image_chunks,
        .image_bytes = g_image_bytes,
    };
}

pub fn writeStatsFile() void {
    lockStats();
    defer unlockStats();
    writeStatsFileUnlocked();
}
