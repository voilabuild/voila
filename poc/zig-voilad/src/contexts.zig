const std = @import("std");
const ring = @import("ring");
const events = @import("events");
const sync_util = @import("sync_util");

pub fn nowNs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

pub const Status = enum {
    scheduled,
    running,
    finished,

    pub fn asStr(self: Status) []const u8 {
        return switch (self) {
            .scheduled => "scheduled",
            .running => "running",
            .finished => "finished",
        };
    }
};

pub const Snapshot = struct {
    id: []const u8,
    image_ref: []const u8,
    status: Status,
    started_ns: i64,
    pid: i32,
    exit_code: i32,
};

pub const LaunchState = struct {
    bundle_dir: []const u8,
    ctx_id: []const u8,
};

pub const Context = struct {
    id: []const u8,
    ref: []const u8,
    mu: sync_util.Mutex = .{},
    status: Status = .scheduled,
    started_ns: i64 = 0,
    pid: i32 = 0,
    exit_code: i32 = 0,
    ring: ring.Ring,
    hub: *events.Hub,
    allocator: std.mem.Allocator,
    launch: ?LaunchState = null,

    pub fn emit(self: *Context, typ: events.EventType, exit_code: i32) void {
        self.hub.publish(.{
            .context_id = self.id,
            .type = typ,
            .timestamp_ns = nowNs(),
            .exit_code = exit_code,
        });
    }

    pub fn start(self: *Context, pid: i32) error{IllegalTransition, AlreadyFinished}!void {
        self.mu.lock();
        if (self.status == .finished) {
            self.mu.unlock();
            return error.AlreadyFinished;
        }
        if (self.status != .scheduled) {
            self.mu.unlock();
            return error.IllegalTransition;
        }
        self.status = .running;
        self.pid = pid;
        self.started_ns = nowNs();
        self.mu.unlock();
        self.emit(.started, 0);
    }

    pub fn finish(self: *Context, exit_code: i32) error{AlreadyFinished}!void {
        self.mu.lock();
        if (self.status == .finished) {
            self.mu.unlock();
            return error.AlreadyFinished;
        }
        self.status = .finished;
        self.exit_code = exit_code;
        self.pid = 0;
        self.mu.unlock();
        self.emit(.finished, exit_code);
        self.ring.finish();
    }

    pub fn snapshot(self: *Context) Snapshot {
        self.mu.lock();
        const s = Snapshot{
            .id = self.id,
            .image_ref = self.ref,
            .status = self.status,
            .started_ns = self.started_ns,
            .pid = self.pid,
            .exit_code = self.exit_code,
        };
        self.mu.unlock();
        return s;
    }

    pub fn running(self: *Context) bool {
        self.mu.lock();
        const r = self.status == .running;
        self.mu.unlock();
        return r;
    }

    pub fn setLaunch(self: *Context, bundle_dir: []const u8) !void {
        const b = try self.allocator.dupe(u8, bundle_dir);
        self.launch = .{ .bundle_dir = b, .ctx_id = self.id };
    }

    pub fn clearLaunch(self: *Context) void {
        if (self.launch) |ls| {
            self.allocator.free(ls.bundle_dir);
            self.launch = null;
        }
    }
};

pub const Registry = struct {
    mu: sync_util.Mutex = .{},
    contexts: std.StringHashMap(*Context),
    hub: events.Hub,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .contexts = std.StringHashMap(*Context).init(allocator),
            .hub = events.Hub.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.mu.lock();
        var it = self.contexts.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            c.clearLaunch();
            c.ring.deinit();
            self.allocator.free(c.id);
            self.allocator.free(c.ref);
            self.allocator.destroy(c);
        }
        self.contexts.deinit();
        self.mu.unlock();
        self.hub.deinit();
    }

    pub fn newContext(self: *Registry, id: []const u8, ref: []const u8) !*Context {
        const owned_id = try self.allocator.dupe(u8, id);
        const owned_ref = try self.allocator.dupe(u8, ref);
        const c = try self.allocator.create(Context);
        c.* = .{
            .id = owned_id,
            .ref = owned_ref,
            .ring = ring.Ring.init(self.allocator, 0),
            .hub = &self.hub,
            .allocator = self.allocator,
        };
        c.emit(.scheduled, 0);
        self.mu.lock();
        try self.contexts.put(owned_id, c);
        self.mu.unlock();
        return c;
    }

    pub fn get(self: *Registry, id: []const u8) ?*Context {
        self.mu.lock();
        defer self.mu.unlock();
        return self.contexts.get(id);
    }

    pub fn listSnapshots(self: *Registry, allocator: std.mem.Allocator) ![]Snapshot {
        self.mu.lock();
        var out: std.ArrayList(Snapshot) = .empty;
        var it = self.contexts.valueIterator();
        while (it.next()) |cp| {
            try out.append(allocator, cp.*.snapshot());
        }
        self.mu.unlock();
        return out.toOwnedSlice(allocator);
    }
};
