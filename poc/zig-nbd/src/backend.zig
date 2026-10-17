const std = @import("std");
const constants = @import("constants.zig");
const voila_store = @import("voila_store.zig");
const erofs_build = @import("erofs_build.zig");

pub const ChunkSize = constants.chunk_size;

pub const Device = struct {
    metadata: []u8,
    data_offset: u64,
    device_size: u64,
    slot_names: []const []const u8,
    slot_chunks: [][]const u8,
    fixture_dir: []const u8,
    voila_root: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Device) void {
        self.allocator.free(self.metadata);
        for (self.slot_names) |n| self.allocator.free(n);
        self.allocator.free(self.slot_names);
        for (self.slot_chunks) |c| if (c.len != 0) self.allocator.free(c);
        self.allocator.free(self.slot_chunks);
        self.allocator.free(self.fixture_dir);
        self.allocator.free(self.voila_root);
    }

    pub fn fromBuildResult(allocator: std.mem.Allocator, voila_root: []const u8, built: *const erofs_build.BuildResult) !Device {
        const root_owned = try allocator.dupe(u8, voila_root);
        errdefer allocator.free(root_owned);

        const metadata = try allocator.dupe(u8, built.metadata);
        errdefer allocator.free(metadata);

        const slot_names = try allocator.alloc([]const u8, built.slot_hex.len);
        errdefer allocator.free(slot_names);
        for (built.slot_hex, 0..) |hex, i| {
            slot_names[i] = try allocator.dupe(u8, hex);
        }

        const slot_chunks = try allocator.alloc([]const u8, slot_names.len);
        @memset(slot_chunks, &.{});

        return .{
            .metadata = metadata,
            .data_offset = built.data_offset,
            .device_size = built.device_size,
            .slot_names = slot_names,
            .slot_chunks = slot_chunks,
            .fixture_dir = try allocator.dupe(u8, ""),
            .voila_root = root_owned,
            .allocator = allocator,
        };
    }

    pub fn loadFromFixture(allocator: std.mem.Allocator, fixture_dir: []const u8) !Device {
        const dir_owned = try allocator.dupe(u8, fixture_dir);
        errdefer allocator.free(dir_owned);

        const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.bin", .{dir_owned});
        defer allocator.free(meta_path);
        const metadata = try readFileAlloc(allocator, meta_path);

        const slot_names = try parseSlotNames(allocator, dir_owned);
        const slot_chunks = try allocator.alloc([]const u8, slot_names.len);
        @memset(slot_chunks, &.{});

        const data_offset: u64 = @intCast(metadata.len);
        const device_size = data_offset + @as(u64, @intCast(slot_names.len)) * ChunkSize;

        return .{
            .metadata = metadata,
            .data_offset = data_offset,
            .device_size = device_size,
            .slot_names = slot_names,
            .slot_chunks = slot_chunks,
            .fixture_dir = dir_owned,
            .voila_root = try allocator.dupe(u8, ""),
            .allocator = allocator,
        };
    }

    pub fn ensureSlotLoaded(self: *Device, io: std.Io, slot: usize) !void {
        _ = io;
        return self.ensureSlotLoadedSync(slot);
    }

    /// Load one chunk from disk without zio (safe from the NBD serve thread).
    pub fn ensureSlotLoadedSync(self: *Device, slot: usize) !void {
        if (slot >= self.slot_chunks.len) return;
        if (self.slot_chunks[slot].len != 0) return;
        const name = self.slot_names[slot];
        if (name.len == 0) return;

        const data = if (self.voila_root.len != 0 and name.len == 64) blk: {
            const raw = try voila_store.loadChunkRaw(self.allocator, self.voila_root, name);
            if (raw.len < ChunkSize) {
                const padded = try self.allocator.alloc(u8, ChunkSize);
                @memset(padded, 0);
                @memcpy(padded[0..raw.len], raw);
                self.allocator.free(raw);
                break :blk padded;
            }
            if (raw.len > ChunkSize) {
                const trimmed = try self.allocator.dupe(u8, raw[0..ChunkSize]);
                self.allocator.free(raw);
                break :blk trimmed;
            }
            break :blk raw;
        } else blk: {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/chunks/{s}", .{ self.fixture_dir, name });
            defer self.allocator.free(path);
            const file_data = try readFileAlloc(self.allocator, path);
            if (file_data.len != ChunkSize) {
                self.allocator.free(file_data);
                return error.BadChunkSize;
            }
            break :blk file_data;
        };
        self.slot_chunks[slot] = data;
    }

    pub fn readAt(self: *Device, io: std.Io, buf: []u8, off: u64) !void {
        try self.preloadSlotsForRange(io, off, buf.len);
        self.readAtSync(buf, off);
    }

    /// Synchronous read; slots must already be resident (see `ensureSlotLoaded`).
    pub fn readAtSync(self: *Device, buf: []u8, off: u64) void {
        @memset(buf, 0);
        var done: usize = 0;
        var pos = off;
        while (done < buf.len) {
            const n = self.readAtOnceSync(buf[done..], pos);
            if (n == 0) break;
            done += n;
            pos += n;
        }
    }

    fn readAtOnceSync(self: *Device, buf: []u8, off: u64) usize {
        if (off >= self.device_size) return 0;

        if (off < self.data_offset) {
            const meta_end = @min(off + buf.len, self.data_offset);
            const n = meta_end - off;
            @memcpy(buf[0..n], self.metadata[off..meta_end]);
            return n;
        }

        const data_off = off - self.data_offset;
        const slot: usize = @intCast(data_off / ChunkSize);
        const chunk_off: usize = @intCast(data_off % ChunkSize);
        if (slot >= self.slot_chunks.len) return 0;

        const chunk = self.slot_chunks[slot];
        if (chunk.len == 0) return 0;

        const avail = chunk.len - chunk_off;
        const n = @min(buf.len, avail);
        @memcpy(buf[0..n], chunk[chunk_off..][0..n]);
        return n;
    }

    /// Preload all slots touched by a read range (may fan out on zio).
    pub fn preloadSlotsForRange(self: *Device, io: std.Io, off: u64, len: u64) !void {
        if (off >= self.device_size) return;
        const end = @min(off + len, self.device_size);
        if (off < self.data_offset and end > self.data_offset) {
            const d1 = end - self.data_offset;
            try self.preloadDataSlots(io, 0, d1);
        } else if (off >= self.data_offset) {
            try self.preloadDataSlots(io, off - self.data_offset, end - self.data_offset);
        }
    }

    /// Sequential slot preload for the blocking NBD transmission loop.
    pub fn preloadSlotsForRangeSync(self: *Device, off: u64, len: u64) !void {
        if (off >= self.device_size) return;
        const end = @min(off + len, self.device_size);
        if (off < self.data_offset and end > self.data_offset) {
            const d1 = end - self.data_offset;
            try self.preloadDataSlotsSync(0, d1);
        } else if (off >= self.data_offset) {
            try self.preloadDataSlotsSync(off - self.data_offset, end - self.data_offset);
        }
    }

    fn preloadDataSlots(self: *Device, io: std.Io, data_off_start: u64, data_off_end: u64) !void {
        const slot_first: usize = @intCast(data_off_start / ChunkSize);
        const slot_last: usize = @intCast((data_off_end - 1) / ChunkSize);
        if (slot_first == slot_last) {
            try self.ensureSlotLoaded(io, slot_first);
            return;
        }
        try loadSlotsConcurrent(io, self, slot_first, slot_last);
    }

    fn preloadDataSlotsSync(self: *Device, data_off_start: u64, data_off_end: u64) !void {
        if (data_off_end <= data_off_start) return;
        const slot_first: usize = @intCast(data_off_start / ChunkSize);
        const slot_last: usize = @intCast((data_off_end - 1) / ChunkSize);
        var slot = slot_first;
        while (slot <= slot_last) : (slot += 1) {
            try self.ensureSlotLoadedSync(slot);
        }
    }
};

fn parseSlotNames(allocator: std.mem.Allocator, fixture_dir: []const u8) ![]const []const u8 {
    const slots_path = try std.fmt.allocPrint(allocator, "{s}/slots.txt", .{fixture_dir});
    defer allocator.free(slots_path);
    const slots_text = try readFileAlloc(allocator, slots_path);
    defer allocator.free(slots_text);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, slots_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const name = trimmed[space + 1 ..];
        if (name.len == 0) {
            try out.append(allocator, &.{});
        } else {
            try out.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return out.toOwnedSlice(allocator);
}

const posix_util = @import("posix_util.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return posix_util.readFileAlloc(allocator, path, ChunkSize + (1 << 22));
}

fn readFileAllocIo(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    _ = io;
    return readFileAlloc(allocator, path);
}

pub fn loadSlotsConcurrent(io: std.Io, dev: *Device, slot_a: usize, slot_b: usize) !void {
    const LoadCtx = struct {
        dev: *Device,
        slot: usize,
        err: ?anyerror,
    };

    var ctx_a = LoadCtx{ .dev = dev, .slot = slot_a, .err = null };
    var ctx_b = LoadCtx{ .dev = dev, .slot = slot_b, .err = null };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const Runner = struct {
        fn run(io_inner: std.Io, ctx: *LoadCtx) std.Io.Cancelable!void {
            ctx.dev.ensureSlotLoaded(io_inner, ctx.slot) catch |e| {
                ctx.err = e;
            };
        }
    };

    try group.concurrent(io, Runner.run, .{ io, &ctx_a });
    try group.concurrent(io, Runner.run, .{ io, &ctx_b });
    try group.await(io);

    if (ctx_a.err != null) return ctx_a.err.?;
    if (ctx_b.err != null) return ctx_b.err.?;
}

// ----- unit tests (no root / NBD) -----

test "readAt spans 1 MiB slot boundary" {
    const allocator = std.testing.allocator;

    const meta = try allocator.alloc(u8, constants.block_size);
    @memset(meta, 0x11);
    const data_offset: u64 = constants.block_size;

    const slot_a = try filledChunk(allocator, 0xAA);
    const slot_c = try filledChunk(allocator, 0xCC);
    const slots = try allocator.alloc([]const u8, 2);
    slots[0] = slot_a;
    slots[1] = slot_c;

    var dev: Device = .{
        .metadata = meta,
        .data_offset = data_offset,
        .device_size = data_offset + 2 * ChunkSize,
        .slot_names = &.{},
        .slot_chunks = slots,
        .fixture_dir = try allocator.dupe(u8, ""),
        .voila_root = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
    defer dev.deinit();

    var buf: [8]u8 = undefined;
    const off = data_offset + ChunkSize - 4;
    dev.readAtSync(&buf, off);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[3]);
    try std.testing.expectEqual(@as(u8, 0xCC), buf[4]);
    try std.testing.expectEqual(@as(u8, 0xCC), buf[7]);

    const big = try allocator.alloc(u8, 2 * ChunkSize);
    defer allocator.free(big);
    dev.readAtSync(big, data_offset);
    try std.testing.expectEqual(@as(u8, 0xAA), big[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), big[ChunkSize - 1]);
    try std.testing.expectEqual(@as(u8, 0xCC), big[ChunkSize]);
    try std.testing.expectEqual(@as(u8, 0xCC), big[2 * ChunkSize - 1]);
}

test "readAt spans metadata and data" {
    const allocator = std.testing.allocator;

    const meta = try allocator.alloc(u8, constants.block_size);
    @memset(meta, 0x11);
    const slot_a = try filledChunk(allocator, 0xAA);
    const slots = try allocator.alloc([]const u8, 1);
    slots[0] = slot_a;

    var dev: Device = .{
        .metadata = meta,
        .data_offset = constants.block_size,
        .device_size = constants.block_size + ChunkSize,
        .slot_names = &.{},
        .slot_chunks = slots,
        .fixture_dir = try allocator.dupe(u8, ""),
        .voila_root = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
    defer dev.deinit();

    var buf: [16]u8 = undefined;
    dev.readAtSync(&buf, constants.block_size - 8);
    for (0..8) |i| try std.testing.expectEqual(@as(u8, 0x11), buf[i]);
    for (8..16) |i| try std.testing.expectEqual(@as(u8, 0xAA), buf[i]);
}

fn filledChunk(allocator: std.mem.Allocator, fill: u8) ![]u8 {
    const b = try allocator.alloc(u8, ChunkSize);
    @memset(b, fill);
    return b;
}
