const std = @import("std");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const HubMod = @import("Hub.zig");

pub const Snapshot = HubMod.FetchStats.Snapshot;

fn stats() *HubMod.FetchStats {
    return &voila_registry_hub.defaultHub().stats;
}

pub fn init(allocator: std.mem.Allocator, stats_path: ?[]const u8) void {
    stats().init(allocator, stats_path);
}

pub fn setImageTotals(chunks: u64, bytes: u64) void {
    stats().setImageTotals(chunks, bytes);
}

pub fn recordChunk(hex: []const u8, nbytes: usize) void {
    stats().recordChunk(hex, nbytes);
}

pub fn snapshot() Snapshot {
    return stats().snapshot();
}

pub fn writeStatsFile() void {
    stats().writeStatsFile();
}
