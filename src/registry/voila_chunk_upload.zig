//! Parallel chunk PUTs for `voila push`. One HTTP session per in-flight upload.
const std = @import("std");
const voila_http = @import("./voila_http.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_store = @import("store").voila_store;

const window: usize = 16;
const zstd_magic: [4]u8 = .{ 0x28, 0xb5, 0x2f, 0xfd };

pub const Result = struct { uploaded: usize, bytes: u64 };

pub fn uploadMissing(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    missing: []const []const u8,
) !Result {
    if (missing.len == 0) return .{ .uploaded = 0, .bytes = 0 };

    var ctx = Ctx{
        .allocator = allocator,
        .voila_root = voila_root,
        .cfg = cfg,
        .missing = missing,
        .next = .init(0),
        .done = .init(0),
        .bytes = .init(0),
        .failed = .init(false),
    };

    const n = @min(window, missing.len);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var started: usize = 0;
    while (started < n) : (started += 1) {
        group.concurrent(io, worker, .{ io, &ctx }) catch break;
    }
    if (started == 0) {
        var http = voila_http.Session.init(io, allocator);
        defer http.deinit();
        try workerLoop(&http, &ctx);
    } else {
        try group.await(io);
    }
    if (ctx.failed.load(.acquire)) return error.ChunkPut;
    return .{ .uploaded = ctx.done.load(.monotonic), .bytes = ctx.bytes.load(.monotonic) };
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    missing: []const []const u8,
    next: std.atomic.Value(usize),
    done: std.atomic.Value(usize),
    bytes: std.atomic.Value(u64),
    failed: std.atomic.Value(bool),
};

fn worker(io: std.Io, ctx: *Ctx) std.Io.Cancelable!void {
    var session_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_arena.deinit();
    var http = voila_http.Session.init(io, session_arena.allocator());
    defer http.deinit();
    workerLoop(&http, ctx) catch {
        ctx.failed.store(true, .release);
    };
}

fn workerLoop(http: *voila_http.Session, ctx: *Ctx) !void {
    while (!ctx.failed.load(.acquire)) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.missing.len) return;
        var chunk_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer chunk_arena.deinit();
        const raw_len = try putOne(http, chunk_arena.allocator(), ctx, ctx.missing[i]);
        const n = ctx.done.fetchAdd(1, .monotonic) + 1;
        _ = ctx.bytes.fetchAdd(raw_len, .monotonic);
        std.debug.print("uploading {d}/{d}\n", .{ n, ctx.missing.len });
    }
}

fn putOne(http: *voila_http.Session, allocator: std.mem.Allocator, ctx: *Ctx, chunk_hex: []const u8) !u64 {
    const wire = try chunkWireBody(allocator, ctx.voila_root, chunk_hex);
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chunks/{s}", .{ ctx.cfg.base_url, chunk_hex });
    const code = http.put(url, ctx.cfg.token, wire, "application/octet-stream", "zstd") catch return error.ChunkPut;
    if (code != 200 and code != 201) return error.ChunkPut;
    const cid = chunkIdFromHex(chunk_hex);
    const algo = @import("store").voila_chunk_index.compAlgoForChunk(ctx.voila_root, &cid) catch voila_store.AlgoRaw;
    const raw = voila_store.loadChunkRaw(allocator, ctx.voila_root, chunk_hex, algo) catch return error.MissingChunk;
    return raw.len;
}

fn chunkIdFromHex(hex: []const u8) [32]u8 {
    var id: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch return @splat(0);
    return id;
}

fn chunkWireBody(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    const stored = try voila_store.loadStoredBytes(allocator, voila_root, chunk_hex);
    defer allocator.free(stored);
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], &zstd_magic)) {
        return allocator.dupe(u8, stored);
    }
    const cid = chunkIdFromHex(chunk_hex);
    const algo = @import("store").voila_chunk_index.compAlgoForChunk(voila_root, &cid) catch voila_store.AlgoRaw;
    const raw = voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch return error.MissingChunk;
    defer allocator.free(raw);
    return voila_store.compressZstdPublic(allocator, raw);
}

pub const Error = error{ ChunkPut, MissingChunk };
