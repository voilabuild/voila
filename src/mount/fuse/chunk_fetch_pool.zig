//! Fetches missing chunks as tasks on a dedicated zio runtime. Callers are libfuse
//! threads, which are not zio tasks: they queue a chunk and block until it is local.
//! Reads go ahead of prefetch, and prefetch never takes the workers kept for reads.
const std = @import("std");
const zio = @import("zio");
const trace = @import("sys").trace;
const voila_store = @import("store").voila_store;
const voila_chunk_load = @import("store").voila_chunk_load;

pub const Options = struct {
    /// Chunk fetches in flight at once, reads and prefetch together. They wait on the
    /// network, so this is what sets cold-start speed (8 → 64 is ~1.8× on a Go build).
    concurrency: u16 = 64,
    /// Threads running the fetch tasks: TLS, zstd and BLAKE3 work happens on them.
    executors: u8 = 4,
};

/// Env var the FUSE server reads to override `Options.concurrency`.
pub const concurrency_env = "VOILA_FETCH_CONCURRENCY";

const State = enum { queued_prefetch, queued_read, inflight, done, failed };

const Job = struct { hex: []const u8, read: bool };

/// Keys in `FetchPool.states` waiting for a worker, in arrival order.
const Fifo = struct {
    items: std.ArrayList([]const u8) = .empty,
    head: usize = 0,

    fn push(self: *Fifo, a: std.mem.Allocator, hex: []const u8) bool {
        self.items.append(a, hex) catch return false;
        return true;
    }

    fn pop(self: *Fifo) ?[]const u8 {
        if (self.head == self.items.items.len) return null;
        const hex = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        return hex;
    }

    fn len(self: *const Fifo) usize {
        return self.items.items.len - self.head;
    }
};

pub const FetchPool = struct {
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    /// Network fetcher; `start` points its `io` at the pool runtime.
    net: voila_chunk_load.Fetcher,
    opts: Options,
    rt: ?*zio.Runtime = null,
    io: std.Io = undefined,
    mu: std.Io.Mutex = .init,
    /// Workers wait here for queued chunks.
    work: std.Io.Condition = .init,
    /// `ensure` callers wait here for a chunk to finish.
    finished: std.Io.Condition = .init,
    /// Keys are owned; the queues point at them.
    states: std.StringHashMap(State),
    reads: Fifo = .{},
    prefetch: Fifo = .{},
    prefetching: usize = 0,
    in_flight: std.atomic.Value(i64) = .init(0),
    stopping: bool = false,
    tasks: std.Io.Group = .init,

    pub fn init(allocator: std.mem.Allocator, net: voila_chunk_load.Fetcher, voila_root: []const u8, opts: Options) FetchPool {
        return .{
            .allocator = allocator,
            .voila_root = voila_root,
            .net = net,
            .opts = .{ .concurrency = @max(opts.concurrency, 1), .executors = @max(opts.executors, 1) },
            .states = .init(allocator),
        };
    }

    /// Starts the runtime and the workers; `self` must not move afterwards. On failure
    /// the pool is unusable and only `deinit` may be called.
    pub fn start(self: *FetchPool) error{RuntimeFailed}!void {
        const rt = zio.Runtime.init(self.allocator, .{
            .executors = .exact(self.opts.executors),
            .enable_main_executor = false,
        }) catch return error.RuntimeFailed;
        self.rt = rt;
        self.io = rt.io();
        self.net.io = self.io;
        for (0..self.opts.concurrency) |i| {
            self.tasks.concurrent(self.io, workerMain, .{self}) catch {
                if (i == 0) return error.RuntimeFailed;
                break; // fewer workers only means slower fetches
            };
        }
    }

    /// Runs `func` as a pool task, stopped with the workers. For best-effort side work
    /// such as opening connections ahead of the first read.
    pub fn spawn(self: *FetchPool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
        if (self.rt == null) return;
        self.tasks.concurrent(self.io, func, args) catch {}; // side work only
    }

    /// Stops the workers, dropping queued prefetch and canceling fetches in flight:
    /// at exit, chunks nobody read are not worth waiting for. No `ensure` may be running.
    pub fn deinit(self: *FetchPool) void {
        if (self.rt) |rt| {
            self.mu.lockUncancelable(self.io);
            self.stopping = true;
            self.work.broadcast(self.io);
            self.finished.broadcast(self.io);
            self.mu.unlock(self.io);
            self.tasks.cancel(self.io);
            rt.deinit();
            self.rt = null;
        }
        var it = self.states.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.states.deinit();
        self.reads.items.deinit(self.allocator);
        self.prefetch.items.deinit(self.allocator);
    }

    /// A fetcher that loads through this pool, for callers that need a chunk's bytes
    /// (lazily loaded manifest chunks, reads retried under the VFS lock).
    pub fn fetcher(self: *FetchPool) voila_chunk_load.Fetcher {
        return .{ .io = self.io, .ctx = self, .fetchFn = fetchThroughPool };
    }

    /// Queues chunks for background fetch, skipping known and local ones.
    pub fn enqueue(self: *FetchPool, hexes: []const []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var added = false;
        for (hexes) |h| {
            if (self.states.contains(h)) continue;
            if (voila_store.hasChunk(self.voila_root, h)) continue;
            const key = self.addState(h, .queued_prefetch) orelse continue;
            if (!self.prefetch.push(self.allocator, key)) {
                self.removeState(key);
                continue;
            }
            added = true;
        }
        if (added) {
            trace.counter("chunks queued", @intCast(self.prefetch.len()));
            self.work.broadcast(self.io);
        }
    }

    /// Returns once `hex` is local. Queues it ahead of all prefetch, or waits for the
    /// fetch already running; a chunk that failed before is tried once more.
    pub fn ensure(self: *FetchPool, hex: []const u8) error{FetchFailed}!void {
        if (voila_store.hasChunk(self.voila_root, hex)) return;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var asked = false;
        var wait: ?trace.Span = null;
        defer if (wait) |w| w.end();
        while (!self.stopping) {
            const st = self.states.getPtr(hex) orelse {
                const key = self.addState(hex, .queued_read) orelse return error.FetchFailed;
                if (!self.queueRead(key)) return error.FetchFailed;
                asked = true;
                continue;
            };
            switch (st.*) {
                .done => return,
                .failed => {
                    if (asked) return error.FetchFailed;
                    st.* = .queued_read;
                    if (!self.queueRead(hex)) return error.FetchFailed;
                    asked = true;
                },
                .queued_prefetch => {
                    st.* = .queued_read;
                    if (!self.queueRead(hex)) return error.FetchFailed;
                    asked = true;
                },
                .queued_read, .inflight => {},
            }
            if (wait == null) wait = trace.begin("wait for chunk");
            self.finished.waitUncancelable(self.io, &self.mu);
        }
        return error.FetchFailed;
    }

    /// Caller holds `mu`. `hex` is a key of `states`.
    fn queueRead(self: *FetchPool, hex: []const u8) bool {
        const key = self.states.getKey(hex).?;
        if (!self.reads.push(self.allocator, key)) {
            self.states.getPtr(key).?.* = .failed;
            return false;
        }
        self.work.signal(self.io);
        return true;
    }

    /// Caller holds `mu`. Returns the owned key, or null when out of memory.
    fn addState(self: *FetchPool, hex: []const u8, st: State) ?[]const u8 {
        const key = self.allocator.dupe(u8, hex) catch return null;
        self.states.put(key, st) catch {
            self.allocator.free(key);
            return null;
        };
        return key;
    }

    fn removeState(self: *FetchPool, key: []const u8) void {
        _ = self.states.remove(key);
        self.allocator.free(key);
    }

    /// Prefetch leaves this many workers to reads, so a read never queues behind it.
    fn prefetchLimit(self: *const FetchPool) usize {
        const n: usize = self.opts.concurrency;
        return n - @min(8, n / 4);
    }

    /// Caller holds `mu`; returns with it held. Null once stopping.
    fn next(self: *FetchPool) ?Job {
        while (!self.stopping) {
            while (self.reads.pop()) |hex| {
                const st = self.states.getPtr(hex).?;
                if (st.* != .queued_read) continue;
                st.* = .inflight;
                return .{ .hex = hex, .read = true };
            }
            if (self.prefetching < self.prefetchLimit()) while (self.prefetch.pop()) |hex| {
                const st = self.states.getPtr(hex).?;
                if (st.* != .queued_prefetch) continue;
                st.* = .inflight;
                self.prefetching += 1;
                trace.counter("chunks queued", @intCast(self.prefetch.len()));
                return .{ .hex = hex, .read = false };
            };
            self.work.waitUncancelable(self.io, &self.mu);
        }
        return null;
    }

    fn workerMain(self: *FetchPool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        while (self.next()) |job| {
            self.mu.unlock(self.io);
            const ok = self.fetchOne(job);
            self.mu.lockUncancelable(self.io);
            if (!job.read) self.prefetching -= 1;
            self.states.getPtr(job.hex).?.* = if (ok) .done else .failed;
            self.finished.broadcast(self.io);
        }
    }

    fn fetchOne(self: *FetchPool, job: Job) bool {
        if (voila_store.hasChunk(self.voila_root, job.hex)) return true;
        const span = trace.begin(if (job.read) "fetch for read" else "prefetch");
        trace.counter("fetches in flight", self.in_flight.fetchAdd(1, .monotonic) + 1);
        defer {
            trace.counter("fetches in flight", self.in_flight.fetchSub(1, .monotonic) - 1);
            span.endArgs("\"chunk\":{f}", .{trace.str(job.hex[0..@min(job.hex.len, 12)])});
        }
        const data = self.net.fetch(self.allocator, self.voila_root, job.hex) catch return false;
        self.allocator.free(data);
        return true;
    }
};

fn fetchThroughPool(f: voila_chunk_load.Fetcher, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) voila_chunk_load.FetchError![]u8 {
    const pool: *FetchPool = @ptrCast(@alignCast(f.ctx.?));
    pool.ensure(chunk_hex) catch return error.FetchFailed;
    return voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, voila_store.AlgoRaw) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FetchFailed,
    };
}

const TestNet = struct {
    fetches: std.atomic.Value(u32) = .init(0),
    /// Prefetch chunks (hex starting with 'b') block here until set.
    gate: std.Io.Event = .unset,
    fail: std.atomic.Value(bool) = .init(false),

    fn fetch(f: voila_chunk_load.Fetcher, allocator: std.mem.Allocator, _: []const u8, chunk_hex: []const u8) voila_chunk_load.FetchError![]u8 {
        const self: *TestNet = @ptrCast(@alignCast(f.ctx.?));
        _ = self.fetches.fetchAdd(1, .monotonic);
        if (chunk_hex[0] == 'b') self.gate.wait(f.io) catch return error.FetchFailed;
        if (self.fail.load(.monotonic)) return error.FetchFailed;
        return allocator.dupe(u8, chunk_hex) catch error.OutOfMemory;
    }
};

fn testHex(buf: *[64]u8, first: u8, i: usize) []const u8 {
    @memset(buf, '0');
    buf[0] = first;
    _ = std.fmt.bufPrint(buf[56..], "{x:0>8}", .{i}) catch unreachable;
    return buf;
}

fn testRoot() ![]const u8 {
    return @import("sys").fs.makeTempDir(std.testing.allocator, "voila-fetch-pool-test");
}

fn removeTestRoot(root: []const u8) void {
    @import("sys").fs.removeTree(std.testing.allocator, root) catch {}; // leftover temp dir is fine
    std.testing.allocator.free(root);
}

test "ensure and enqueue fetch each chunk once" {
    const root = try testRoot();
    defer removeTestRoot(root);
    var net: TestNet = .{};
    var pool = FetchPool.init(std.testing.allocator, .{ .io = undefined, .ctx = &net, .fetchFn = TestNet.fetch }, root, .{ .concurrency = 4, .executors = 2 });
    defer pool.deinit();
    try pool.start();

    var bufs: [6][64]u8 = undefined;
    var hexes: [6][]const u8 = undefined;
    for (&bufs, &hexes, 0..) |*b, *h, i| h.* = testHex(b, 'a', i);
    pool.enqueue(&hexes);
    for (hexes) |h| try pool.ensure(h);
    pool.enqueue(&hexes);
    for (hexes) |h| try pool.ensure(h);
    try std.testing.expectEqual(@as(u32, 6), net.fetches.load(.monotonic));
}

test "a read is fetched while prefetch holds every worker it may use" {
    const root = try testRoot();
    defer removeTestRoot(root);
    var net: TestNet = .{};
    var pool = FetchPool.init(std.testing.allocator, .{ .io = undefined, .ctx = &net, .fetchFn = TestNet.fetch }, root, .{ .concurrency = 4, .executors = 2 });
    defer pool.deinit();
    try pool.start();
    defer net.gate.set(pool.io);

    var bufs: [10][64]u8 = undefined;
    var hexes: [10][]const u8 = undefined;
    for (&bufs, &hexes, 0..) |*b, *h, i| h.* = testHex(b, 'b', i);
    pool.enqueue(&hexes);
    while (net.fetches.load(.monotonic) < pool.prefetchLimit()) @import("sys").posix_util.sleepMs(1);
    var rb: [64]u8 = undefined;
    // Hangs if the read queues behind the blocked prefetch.
    try pool.ensure(testHex(&rb, 'a', 0));
    try std.testing.expectEqual(@as(u32, @intCast(pool.prefetchLimit() + 1)), net.fetches.load(.monotonic));
}

test "a failed chunk is retried by the next read, then reported" {
    const root = try testRoot();
    defer removeTestRoot(root);
    var net: TestNet = .{ .fail = .init(true) };
    var pool = FetchPool.init(std.testing.allocator, .{ .io = undefined, .ctx = &net, .fetchFn = TestNet.fetch }, root, .{ .concurrency = 2, .executors = 1 });
    defer pool.deinit();
    try pool.start();

    var b: [64]u8 = undefined;
    const h = testHex(&b, 'a', 1);
    try std.testing.expectError(error.FetchFailed, pool.ensure(h));
    try std.testing.expectError(error.FetchFailed, pool.ensure(h));
    try std.testing.expectEqual(@as(u32, 2), net.fetches.load(.monotonic));
    net.fail.store(false, .monotonic);
    try pool.ensure(h);
    try std.testing.expectEqual(@as(u32, 3), net.fetches.load(.monotonic));
}
