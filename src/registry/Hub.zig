const std = @import("std");
const voila_paths = @import("sys").voila_paths;
const voila_http = @import("voila_http.zig");

pub const Config = struct {
    base_url: []const u8,
    token: []const u8,
    org: []const u8,
};

/// Registry hub state: credentials, chunk origin, and fetch stats (replaces module globals).
pub const Hub = struct {
    mu: std.Io.Mutex = .init,
    io: ?std.Io = null,
    allocator: ?std.mem.Allocator = null,
    cfg: ?Config = null,
    chunk_origin: ?[]const u8 = null,
    chunk_origin_loaded: bool = false,
    /// Serializes the one-time chunk origin lookup across fetch threads.
    origin_mu: std.Io.Mutex = .init,
    /// Idle keep-alive sessions for chunk GETs, tagged with the `Io` they were made for.
    idle_sessions: std.ArrayList(PooledSession) = .empty,
    stats: FetchStats = .{},

    pub const PooledSession = struct {
        io_key: ?*anyopaque,
        session: *voila_http.Session,
    };

    pub fn setIo(self: *Hub, io: std.Io, allocator: std.mem.Allocator) void {
        self.io = io;
        self.allocator = allocator;
        self.stats.setIo(io);
    }

    fn lock(self: *Hub) void {
        if (self.io) |io| self.mu.lockUncancelable(io);
    }

    fn unlock(self: *Hub) void {
        if (self.io) |io| self.mu.unlock(io);
    }

    pub fn configure(self: *Hub, allocator: std.mem.Allocator, base_url: []const u8, token: []const u8, org: []const u8) !void {
        self.lock();
        defer self.unlock();
        if (self.cfg) |*c| {
            allocator.free(c.base_url);
            allocator.free(c.token);
            allocator.free(c.org);
            self.cfg = null;
        }
        if (base_url.len == 0) return;
        const normalized = try voila_paths.normalizeRegistryUrl(allocator, base_url);
        defer allocator.free(normalized);
        var base = normalized;
        while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
        base = try allocator.dupe(u8, base);
        self.cfg = .{
            .base_url = base,
            .token = try allocator.dupe(u8, token),
            .org = try allocator.dupe(u8, org),
        };
    }

    pub fn loadFromEnv(self: *Hub, allocator: std.mem.Allocator) !void {
        const url_z = std.c.getenv("VOILA_REGISTRY") orelse return;
        const url_slice: []const u8 = std.mem.span(url_z);
        const normalized = try voila_paths.normalizeRegistryUrl(allocator, url_slice);
        defer allocator.free(normalized);
        const token_slice: []const u8 = if (std.c.getenv("VOILA_REGISTRY_TOKEN")) |t| std.mem.span(t) else "";
        const org_slice: []const u8 = if (std.c.getenv("VOILA_ORG")) |o| std.mem.span(o) else "";
        try self.configure(allocator, normalized, token_slice, org_slice);
    }

    pub fn getConfigCopy(self: *Hub, allocator: std.mem.Allocator) ?Config {
        self.lock();
        defer self.unlock();
        const c = self.cfg orelse return null;
        return .{
            .base_url = allocator.dupe(u8, c.base_url) catch return null,
            .token = allocator.dupe(u8, c.token) catch return null,
            .org = allocator.dupe(u8, c.org) catch return null,
        };
    }

    pub fn withConfig(self: *Hub, f: *const fn (Config) void) void {
        self.lock();
        defer self.unlock();
        if (self.cfg) |c| f(c);
    }

    /// An idle keep-alive session for `io` (unless `fresh`), or a new one; null before
    /// `setIo`. Hand it back with `releaseSession`.
    pub fn acquireSession(self: *Hub, io: std.Io, fresh: bool) ?*voila_http.Session {
        const allocator = self.allocator orelse return null;
        if (fresh) return self.newSession(io, allocator);
        self.lock();
        var i: usize = self.idle_sessions.items.len;
        while (i > 0) {
            i -= 1;
            if (self.idle_sessions.items[i].io_key == io.userdata) {
                const s = self.idle_sessions.swapRemove(i).session;
                self.unlock();
                return s;
            }
        }
        self.unlock();
        return self.newSession(io, allocator);
    }

    fn newSession(_: *Hub, io: std.Io, allocator: std.mem.Allocator) ?*voila_http.Session {
        const s = allocator.create(voila_http.Session) catch return null;
        s.* = .initKeepAlive(io, allocator);
        return s;
    }

    /// Pools `s` when `reusable`; otherwise closes it.
    pub fn releaseSession(self: *Hub, s: *voila_http.Session, reusable: bool) void {
        const allocator = self.allocator orelse return;
        if (reusable) {
            self.lock();
            defer self.unlock();
            if (self.idle_sessions.append(allocator, .{ .io_key = s.client.io.userdata, .session = s })) |_| return else |_| {}
        }
        s.deinit();
        allocator.destroy(s);
    }

    pub fn deinit(self: *Hub, allocator: std.mem.Allocator) void {
        self.lock();
        defer self.unlock();
        if (self.allocator) |a| {
            for (self.idle_sessions.items) |p| {
                p.session.deinit();
                a.destroy(p.session);
            }
            self.idle_sessions.deinit(a);
        }
        if (self.cfg) |*c| {
            allocator.free(c.base_url);
            allocator.free(c.token);
            allocator.free(c.org);
            self.cfg = null;
        }
        if (self.chunk_origin) |o| {
            allocator.free(o);
            self.chunk_origin = null;
        }
        self.chunk_origin_loaded = false;
        self.stats.deinit(allocator);
    }
};

pub const FetchStats = struct {
    mu: std.Io.Mutex = .init,
    io: ?std.Io = null,
    seen: ?std.StringHashMap(void) = null,
    bytes: u64 = 0,
    image_chunks: u64 = 0,
    image_bytes: u64 = 0,
    allocator: ?std.mem.Allocator = null,
    stats_path: ?[]const u8 = null,

    pub const Snapshot = struct {
        chunks_fetched: u64 = 0,
        bytes_fetched: u64 = 0,
        image_chunks: u64 = 0,
        image_bytes: u64 = 0,
    };

    pub fn setIo(self: *FetchStats, io: std.Io) void {
        self.io = io;
    }

    fn lock(self: *FetchStats) void {
        if (self.io) |io| self.mu.lockUncancelable(io);
    }

    fn unlock(self: *FetchStats) void {
        if (self.io) |io| self.mu.unlock(io);
    }

    pub fn init(self: *FetchStats, allocator: std.mem.Allocator, stats_path: ?[]const u8) void {
        self.lock();
        defer self.unlock();
        self.allocator = allocator;
        if (self.stats_path) |p| allocator.free(p);
        self.stats_path = if (stats_path) |sp| allocator.dupe(u8, sp) catch null else null;
        if (self.seen) |*m| {
            var it = m.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            m.deinit();
        }
        self.seen = std.StringHashMap(void).init(allocator);
        self.bytes = 0;
    }

    pub fn deinit(self: *FetchStats, allocator: std.mem.Allocator) void {
        self.lock();
        defer self.unlock();
        if (self.stats_path) |p| allocator.free(p);
        self.stats_path = null;
        if (self.seen) |*m| {
            var it = m.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            m.deinit();
            self.seen = null;
        }
    }

    pub fn setImageTotals(self: *FetchStats, chunks: u64, bytes: u64) void {
        self.lock();
        defer self.unlock();
        self.image_chunks = chunks;
        self.image_bytes = bytes;
    }

    pub fn recordChunk(self: *FetchStats, hex: []const u8, nbytes: usize) void {
        self.lock();
        defer self.unlock();
        const alloc = self.allocator orelse return;
        const m = &(self.seen orelse return);
        const key = alloc.dupe(u8, hex) catch return;
        const gop = m.getOrPut(key) catch {
            alloc.free(key);
            return;
        };
        if (gop.found_existing) {
            alloc.free(key);
            return;
        }
        self.bytes += @intCast(nbytes);
        self.writeStatsFileUnlocked();
    }

    fn writeStatsFileUnlocked(self: *FetchStats) void {
        const path = self.stats_path orelse return;
        const alloc = self.allocator orelse return;
        const n: u64 = if (self.seen) |*m| @intCast(m.count()) else 0;
        const json = std.fmt.allocPrint(
            alloc,
            "{{\"chunks_fetched\":{d},\"bytes_fetched\":{d},\"image_chunks\":{d},\"image_bytes\":{d}}}\n",
            .{ n, self.bytes, self.image_chunks, self.image_bytes },
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

    pub fn snapshot(self: *FetchStats) Snapshot {
        self.lock();
        defer self.unlock();
        const n: u64 = if (self.seen) |*m| @intCast(m.count()) else 0;
        return .{
            .chunks_fetched = n,
            .bytes_fetched = self.bytes,
            .image_chunks = self.image_chunks,
            .image_bytes = self.image_bytes,
        };
    }

    pub fn writeStatsFile(self: *FetchStats) void {
        self.lock();
        defer self.unlock();
        self.writeStatsFileUnlocked();
    }
};
