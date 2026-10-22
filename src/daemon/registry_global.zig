const std = @import("std");
const contexts = @import("contexts");

var g_registry: ?contexts.Registry = null;

pub fn init() void {
    g_registry = contexts.Registry.init(std.heap.c_allocator);
}

pub fn get() *contexts.Registry {
    return &g_registry.?;
}

pub fn deinit() void {
    if (g_registry) |*r| r.deinit();
    g_registry = null;
}
