//! Fetches missing chunks on worker threads. A read waits only for its own chunks;
//! queued chunks (the rest of a file) download in parallel behind it.
const std = @import("std");
const voila_store = @import("store").voila_store;
const voila_chunk_load = @import("store").voila_chunk_load;

pub const worker_count = 8;

const State = enum { queued, inflight, done, failed };

pub const FetchPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fetcher: voila_chunk_load.Fetcher,
    voila_root: []const u8,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Keys are owned; `queue` items point at them.
    states: std.StringHashMap(State),
    queue: std.ArrayList([]const u8) = .empty,
    head: usize = 0,
    stopping: bool = false,
    threads: [worker_count]?std.Thread = @splat(null),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, fetcher: voila_chunk_load.Fetcher, voila_root: []const u8) FetchPool {
        return .{
            .allocator = allocator,
            .io = io,
            .fetcher = fetcher,
            .voila_root = voila_root,
            .states = .init(allocator),
        };
    }

    /// Starts the workers; `self` must not move afterwards.
    pub fn start(self: *FetchPool) void {
        for (&self.threads) |*t| t.* = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
    }

    pub fn deinit(self: *FetchPool) void {
        self.mu.lockUncancelable(self.io);
        self.stopping = true;
        self.cond.broadcast(self.io);
        self.mu.unlock(self.io);
        for (&self.threads) |*t| if (t.*) |th| {
            th.join();
            t.* = null;
        };
        var it = self.states.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.states.deinit();
        self.queue.deinit(self.allocator);
    }

    /// Queues chunks for background fetch, skipping known and local ones.
    pub fn enqueue(self: *FetchPool, hexes: []const []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var added = false;
        for (hexes) |h| {
            if (self.states.contains(h)) continue;
            if (voila_store.hasChunk(self.voila_root, h)) continue;
            const key = self.allocator.dupe(u8, h) catch continue;
            self.states.put(key, .queued) catch {
                self.allocator.free(key);
                continue;
            };
            self.queue.append(self.allocator, key) catch {
                _ = self.states.remove(key);
                self.allocator.free(key);
                continue;
            };
            added = true;
        }
        if (added) self.cond.broadcast(self.io);
    }

    /// Returns once `hex` is local. Fetches it on this thread unless another thread
    /// already is, in which case it waits for that fetch.
    pub fn ensure(self: *FetchPool, hex: []const u8) error{FetchFailed}!void {
        if (voila_store.hasChunk(self.voila_root, hex)) return;
        self.mu.lockUncancelable(self.io);
        while (true) {
            if (self.states.getPtr(hex)) |st| switch (st.*) {
                .done => {
                    self.mu.unlock(self.io);
                    return;
                },
                .inflight => {
                    self.cond.waitUncancelable(self.io, &self.mu);
                    continue;
                },
                .queued, .failed => {
                    st.* = .inflight;
                    break;
                },
            } else {
                const key = self.allocator.dupe(u8, hex) catch {
                    self.mu.unlock(self.io);
                    return error.FetchFailed;
                };
                self.states.put(key, .inflight) catch {
                    self.allocator.free(key);
                    self.mu.unlock(self.io);
                    return error.FetchFailed;
                };
                break;
            }
        }
        self.mu.unlock(self.io);
        const ok = self.fetchOne(hex);
        self.finish(hex, ok);
        if (!ok) return error.FetchFailed;
    }

    fn finish(self: *FetchPool, hex: []const u8, ok: bool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.states.getPtr(hex)) |st| st.* = if (ok) .done else .failed;
        self.cond.broadcast(self.io);
    }

    fn fetchOne(self: *FetchPool, hex: []const u8) bool {
        if (voila_store.hasChunk(self.voila_root, hex)) return true;
        const data = self.fetcher.fetch(self.allocator, self.voila_root, hex) catch return false;
        self.allocator.free(data);
        return true;
    }

    fn workerMain(self: *FetchPool) void {
        self.mu.lockUncancelable(self.io);
        while (true) {
            while (!self.stopping and self.head == self.queue.items.len) {
                self.cond.waitUncancelable(self.io, &self.mu);
            }
            if (self.stopping) break;
            const hex = self.queue.items[self.head];
            self.head += 1;
            if (self.head == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.head = 0;
            }
            const st = self.states.getPtr(hex) orelse continue;
            if (st.* != .queued) continue;
            st.* = .inflight;
            self.mu.unlock(self.io);
            const ok = self.fetchOne(hex);
            self.finish(hex, ok);
            self.mu.lockUncancelable(self.io);
        }
        self.mu.unlock(self.io);
    }
};

fn countingFetch(f: voila_chunk_load.Fetcher, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) voila_chunk_load.FetchError![]u8 {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(f.hub.?));
    _ = counter.fetchAdd(1, .monotonic);
    var raw: [16]u8 = undefined;
    @memset(&raw, chunk_hex[0]);
    voila_store.putChunkRaw(allocator, voila_root, chunk_hex, &raw) catch {}; // fake chunk fails verification; the test counts fetches, not stores
    return allocator.dupe(u8, &raw) catch error.OutOfMemory;
}

test "ensure and enqueue fetch each chunk once" {
    const fs = @import("sys").fs;
    const a = std.testing.allocator;
    const root = try fs.makeTempDir(a, "voila-fetch-pool-test");
    defer a.free(root);
    defer fs.removeTree(a, root) catch {}; // leftover temp dir is fine

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    var counter: std.atomic.Value(u32) = .init(0);
    const f: voila_chunk_load.Fetcher = .{ .io = threaded.io(), .hub = &counter, .fetchFn = countingFetch };

    var pool = FetchPool.init(a, threaded.io(), f, root);
    pool.start();
    defer pool.deinit();

    var hexes: [6][64]u8 = undefined;
    var slices: [6][]const u8 = undefined;
    for (&hexes, 0..) |*h, i| {
        @memset(h, '0');
        h[63] = "123456"[i];
        slices[i] = h;
    }
    pool.enqueue(&slices);
    for (slices) |s| pool.ensure(s) catch {}; // only the fetch count matters here
    pool.enqueue(&slices);
    // putChunkRaw rejects these fake chunks, so the count shows fetches, not store hits.
    try std.testing.expectEqual(@as(u32, 6), counter.load(.monotonic));
}
