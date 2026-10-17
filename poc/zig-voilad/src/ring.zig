const std = @import("std");
const sync_util = @import("sync_util");

pub const max_chunk_bytes = 32 << 10;
pub const default_ring_bytes = 1 << 20;

pub const Chunk = struct {
    data: []const u8,
    stderr: bool,
    ts_ns: i64,
};

const StoredChunk = struct {
    data: []u8,
    stderr: bool,
    ts_ns: i64,
};

pub const Ring = struct {
    mu: sync_util.Mutex = .{},
    cond: sync_util.Cond = .{},
    budget: usize,
    chunks: std.ArrayList(StoredChunk) = .empty,
    size: usize = 0,
    finished: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, budget: usize) Ring {
        var b = budget;
        if (b == 0) b = default_ring_bytes;
        return .{ .budget = b, .allocator = allocator };
    }

    pub fn deinit(self: *Ring) void {
        self.mu.lock();
        for (self.chunks.items) |c| self.allocator.free(c.data);
        self.chunks.deinit(self.allocator);
        self.mu.unlock();
    }

    pub fn append(self: *Ring, data: []const u8, stderr: bool, ts_ns: i64) void {
        if (data.len == 0) return;
        self.mu.lock();
        defer self.mu.unlock();
        var rest = data;
        while (rest.len > 0) {
            const n = @min(rest.len, max_chunk_bytes);
            const owned = self.allocator.dupe(u8, rest[0..n]) catch return;
            const c = StoredChunk{ .data = owned, .stderr = stderr, .ts_ns = ts_ns };
            self.chunks.append(self.allocator, c) catch {
                self.allocator.free(owned);
                return;
            };
            self.size += owned.len;
            rest = rest[n..];
        }
        self.evictLocked();
        self.cond.broadcast();
    }

    fn evictLocked(self: *Ring) void {
        while (self.size > self.budget and self.chunks.items.len > 1) {
            const c = self.chunks.orderedRemove(0);
            self.size -= c.data.len;
            self.allocator.free(c.data);
        }
    }

    pub fn replay(self: *Ring, allocator: std.mem.Allocator) ![]Chunk {
        self.mu.lock();
        defer self.mu.unlock();
        var out: std.ArrayList(Chunk) = .empty;
        for (self.chunks.items) |c| {
            try out.append(allocator, .{
                .data = c.data,
                .stderr = c.stderr,
                .ts_ns = c.ts_ns,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn chunkCount(self: *Ring) usize {
        self.mu.lock();
        const n = self.chunks.items.len;
        self.mu.unlock();
        return n;
    }

    pub fn isFinished(self: *Ring) bool {
        self.mu.lock();
        const f = self.finished;
        self.mu.unlock();
        return f;
    }

    pub fn finish(self: *Ring) void {
        self.mu.lock();
        self.finished = true;
        self.cond.broadcast();
        self.mu.unlock();
    }

    pub fn waitForChunk(self: *Ring, after: usize, stop: *volatile i32) ?Chunk {
        self.mu.lock();
        while (self.chunks.items.len <= after and !self.finished and stop.* == 0) {
            self.mu.unlock();
            var req: std.c.timespec = .{ .sec = 0, .nsec = 20_000_000 };
            _ = std.c.nanosleep(&req, null);
            self.mu.lock();
        }
        if (self.chunks.items.len <= after) {
            self.mu.unlock();
            return null;
        }
        const c = self.chunks.items[after];
        const out = Chunk{ .data = c.data, .stderr = c.stderr, .ts_ns = c.ts_ns };
        self.mu.unlock();
        return out;
    }
};
