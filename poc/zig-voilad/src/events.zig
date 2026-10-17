const std = @import("std");
const sync_util = @import("sync_util");

pub const EventType = enum(i32) {
    unspecified = 0,
    scheduled = 1,
    started = 2,
    ready = 3,
    finished = 4,
};

pub const Event = struct {
    context_id: []const u8,
    type: EventType,
    timestamp_ns: i64,
    exit_code: i32,
};

pub const Hub = struct {
    mu: sync_util.Mutex = .{},
    subs: std.ArrayList(*Sub) = .empty,
    next_id: i64 = 0,
    allocator: std.mem.Allocator,

    pub const Sub = struct {
        id: i64,
        filter: []u8,
        q: std.ArrayList(Event),
        mu: sync_util.Mutex = .{},
        cond: sync_util.Cond = .{},
        done: bool = false,
        hub: *Hub,
    };

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub) void {
        self.mu.lock();
        for (self.subs.items) |s| {
            self.allocator.free(s.filter);
            s.q.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.subs.deinit(self.allocator);
        self.mu.unlock();
    }

    pub fn publish(self: *Hub, ev: Event) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.subs.items) |s| {
            if (s.filter.len != 0 and !std.mem.eql(u8, s.filter, ev.context_id)) continue;
            s.mu.lock();
            const owned_id = self.allocator.dupe(u8, ev.context_id) catch {
                s.mu.unlock();
                continue;
            };
            s.q.append(self.allocator, .{
                .context_id = owned_id,
                .type = ev.type,
                .timestamp_ns = ev.timestamp_ns,
                .exit_code = ev.exit_code,
            }) catch {
                self.allocator.free(owned_id);
            };
            s.cond.signal();
            s.mu.unlock();
        }
    }

    pub fn subscribe(self: *Hub, filter: []const u8) !*Sub {
        const owned_filter = try self.allocator.dupe(u8, filter);
        const s = try self.allocator.create(Sub);
        s.* = .{
            .id = 0,
            .filter = owned_filter,
            .q = .empty,
            .hub = self,
        };
        self.mu.lock();
        self.next_id += 1;
        s.id = self.next_id;
        try self.subs.append(self.allocator, s);
        self.mu.unlock();
        return s;
    }

    pub fn unsubscribe(self: *Hub, s: *Sub) void {
        s.mu.lock();
        s.done = true;
        s.cond.broadcast();
        s.mu.unlock();
        self.mu.lock();
        for (self.subs.items, 0..) |sub, i| {
            if (sub == s) {
                _ = self.subs.orderedRemove(i);
                break;
            }
        }
        self.mu.unlock();
        for (s.q.items) |ev| self.allocator.free(ev.context_id);
        s.q.deinit(self.allocator);
        self.allocator.free(s.filter);
        self.allocator.destroy(s);
    }

    pub fn waitPop(_: *Hub, s: *Sub, stop: *volatile i32) ?Event {
        s.mu.lock();
        while (s.q.items.len == 0 and !s.done and stop.* == 0) {
            s.mu.unlock();
            var req: std.c.timespec = .{ .sec = 0, .nsec = 20_000_000 };
            _ = std.c.nanosleep(&req, null);
            s.mu.lock();
        }
        if (s.q.items.len == 0) {
            s.mu.unlock();
            return null;
        }
        const ev = s.q.orderedRemove(0);
        s.mu.unlock();
        return ev;
    }
};
