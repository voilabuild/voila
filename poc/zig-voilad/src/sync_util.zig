const std = @import("std");

pub const Mutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *Mutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.locked.store(false, .release);
    }
};

pub const Cond = struct {
    pub fn wait(_: *Cond, _: *Mutex) void {
        std.Thread.yield() catch {};
    }
    pub fn signal(_: *Cond) void {}
    pub fn broadcast(_: *Cond) void {}
};
