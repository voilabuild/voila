const std = @import("std");
const constants = @import("constants.zig");

pub const ChunkSize = constants.chunk_size;

pub const Walker = struct {
    file_size: u64,
    chunk_names: []const []const u8,
    chunk_data: [][]const u8,
    fixture_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Walker) void {
        for (self.chunk_data) |c| if (c.len != 0) self.allocator.free(c);
        self.allocator.free(self.chunk_data);
        self.allocator.free(self.fixture_dir);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        fixture_dir: []const u8,
        file_size: u64,
        chunk_names: []const []const u8,
    ) !Walker {
        const dir_owned = try allocator.dupe(u8, fixture_dir);
        const data = try allocator.alloc([]const u8, chunk_names.len);
        @memset(data, &.{});

        return .{
            .file_size = file_size,
            .chunk_names = chunk_names,
            .chunk_data = data,
            .fixture_dir = dir_owned,
            .allocator = allocator,
        };
    }

    pub fn read(self: *Walker, io: std.Io, buf: []u8, off: u64) !void {
        try self.preloadForRange(io, off, buf.len);
        self.readSync(buf, off);
    }

    pub fn readSync(self: *Walker, buf: []u8, off: u64) void {
        @memset(buf, 0);
        if (off >= self.file_size) return;
        const max = @min(off + buf.len, self.file_size);
        var done: usize = 0;
        var pos = off;
        while (pos < max) {
            const n = self.readOnce(buf[done..], pos);
            if (n == 0) break;
            done += n;
            pos += n;
        }
    }

    fn readOnce(self: *Walker, buf: []u8, off: u64) usize {
        if (off >= self.file_size) return 0;
        const slot: usize = @intCast(off / ChunkSize);
        const chunk_off: usize = @intCast(off % ChunkSize);
        if (slot >= self.chunk_names.len) {
            const avail = @min(buf.len, @as(usize, @intCast(self.file_size - off)));
            return avail;
        }
        const chunk = self.chunk_data[slot];
        if (chunk.len == 0) {
            const avail = @min(buf.len, ChunkSize - chunk_off);
            const to_eof = @min(avail, @as(usize, @intCast(self.file_size - off)));
            return to_eof;
        }
        const avail = chunk.len - chunk_off;
        const n = @min(buf.len, avail);
        const capped = @min(n, @as(usize, @intCast(self.file_size - off)));
        @memcpy(buf[0..capped], chunk[chunk_off..][0..capped]);
        return capped;
    }

    pub fn preloadForRange(self: *Walker, io: std.Io, off: u64, len: usize) !void {
        if (off >= self.file_size) return;
        const end = @min(off + len, self.file_size);
        const slot_first: usize = @intCast(off / ChunkSize);
        const slot_last: usize = @intCast((end - 1) / ChunkSize);
        try self.ensureChunkLoaded(io, slot_first);
        if (slot_last != slot_first) try self.ensureChunkLoaded(io, slot_last);
    }

    pub fn ensureChunkLoaded(self: *Walker, io: std.Io, slot: usize) !void {
        if (slot >= self.chunk_names.len) return;
        if (self.chunk_data[slot].len != 0) return;
        const name = self.chunk_names[slot];
        if (name.len == 0) return;

        const path = try std.fmt.allocPrint(self.allocator, "{s}/chunks/{s}", .{ self.fixture_dir, name });
        defer self.allocator.free(path);

        const data = try readChunkFile(io, self.allocator, path);
        if (data.len != ChunkSize) {
            self.allocator.free(data);
            return error.BadChunkSize;
        }
        self.chunk_data[slot] = data;
    }
};

const posix_util = @import("posix_util.zig");

fn readChunkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    _ = io;
    return posix_util.readFileAlloc(allocator, path, ChunkSize);
}

pub fn loadChunksConcurrent(io: std.Io, w: *Walker, slot_a: usize, slot_b: usize) !void {
    const LoadCtx = struct {
        walker: *Walker,
        slot: usize,
        err: ?anyerror,
    };

    var ctx_a = LoadCtx{ .walker = w, .slot = slot_a, .err = null };
    var ctx_b = LoadCtx{ .walker = w, .slot = slot_b, .err = null };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const Runner = struct {
        fn run(io_inner: std.Io, ctx: *LoadCtx) std.Io.Cancelable!void {
            ctx.walker.ensureChunkLoaded(io_inner, ctx.slot) catch |e| {
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

// ----- unit tests (no root / FUSE) -----

test "read spans 1 MiB chunk boundary" {
    const allocator = std.testing.allocator;

    const slot_a = try filledChunk(allocator, 0xAA);
    const slot_c = try filledChunk(allocator, 0xCC);
    const names = [_][]const u8{ "a", "c" };
    const data = try allocator.alloc([]const u8, 2);
    data[0] = slot_a;
    data[1] = slot_c;

    var w: Walker = .{
        .file_size = 2 * ChunkSize,
        .chunk_names = &names,
        .chunk_data = data,
        .fixture_dir = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
    defer w.deinit();

    var buf: [8]u8 = undefined;
    const off: u64 = ChunkSize - 4;
    w.readSync(&buf, off);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[3]);
    try std.testing.expectEqual(@as(u8, 0xCC), buf[4]);
    try std.testing.expectEqual(@as(u8, 0xCC), buf[7]);
}

test "read zero-fills hole chunk" {
    const allocator = std.testing.allocator;

    const slot_a = try filledChunk(allocator, 0xAA);
    const names = [_][]const u8{ "a", "", "c" };
    const data = try allocator.alloc([]const u8, 3);
    data[0] = slot_a;
    data[1] = &.{};
    data[2] = &.{};

    var w: Walker = .{
        .file_size = 3 * ChunkSize,
        .chunk_names = &names,
        .chunk_data = data,
        .fixture_dir = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
    defer w.deinit();

    var mid: [ChunkSize]u8 = undefined;
    w.readSync(&mid, ChunkSize);
    for (mid) |b| try std.testing.expectEqual(@as(u8, 0), b);

    var buf: [4]u8 = undefined;
    w.readSync(&buf, ChunkSize - 2);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
}

fn filledChunk(allocator: std.mem.Allocator, fill: u8) ![]u8 {
    const b = try allocator.alloc(u8, ChunkSize);
    @memset(b, fill);
    return b;
}
