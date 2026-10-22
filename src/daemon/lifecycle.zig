const std = @import("std");
const ring = @import("ring");
const launch = @import("launch");
const grpc_shim = @import("grpc_shim");
const registry_global = @import("registry_global");
const events = @import("events");

pub const ContextInfoC = extern struct {
    id: [*:0]const u8,
    image_ref: [*:0]const u8,
    status: [*:0]const u8,
    started_ns: i64,
    pid: i32,
    exit_code: i32,
};

pub const LogChunkC = extern struct {
    data: [*]const u8,
    len: usize,
    stderr: i32,
    timestamp_ns: i64,
};

pub const EventC = extern struct {
    context_id: [*:0]const u8,
    type: i32,
    timestamp_ns: i64,
    exit_code: i32,
};

fn dupZ(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return try allocator.allocSentinel(u8, s.len, 0);
}

export fn voilad_list_visit(
    add_fn: ?*const fn (?*anyopaque, *const ContextInfoC) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) void {
    if (add_fn == null) return;
    const allocator = std.heap.c_allocator;
    const snaps = registry_global.get().listSnapshots(allocator) catch return;
    defer allocator.free(snaps);
    for (snaps) |s| {
        const id_z = dupZ(allocator, s.id) catch continue;
        defer allocator.free(id_z);
        @memcpy(id_z, s.id);
        const ref_z = dupZ(allocator, s.image_ref) catch continue;
        defer allocator.free(ref_z);
        @memcpy(ref_z, s.image_ref);
        const st_z = dupZ(allocator, s.status.asStr()) catch continue;
        defer allocator.free(st_z);
        @memcpy(st_z, s.status.asStr());
        const ci = ContextInfoC{
            .id = id_z.ptr,
            .image_ref = ref_z.ptr,
            .status = st_z.ptr,
            .started_ns = s.started_ns,
            .pid = s.pid,
            .exit_code = s.exit_code,
        };
        add_fn.?(ctx, &ci);
    }
}

export fn voilad_kill(ctx_id: [*:0]const u8, signal: i32) callconv(.c) i32 {
    const id = std.mem.span(ctx_id);
    launch.killContext(id, signal) catch |e| switch (e) {
        error.NotFound => return 1,
        error.NotRunning => return 2,
        else => return 3,
    };
    return 0;
}

export fn voilad_logs_replay(
    ctx_id: [*:0]const u8,
    chunk_fn: ?*const fn (?*anyopaque, *const LogChunkC) callconv(.c) i32,
    ctx: ?*anyopaque,
) callconv(.c) i32 {
    if (chunk_fn == null) return 1;
    const id = std.mem.span(ctx_id);
    const vctx = registry_global.get().get(id) orelse return 1;
    const allocator = std.heap.c_allocator;
    const chunks = vctx.ring.replay(allocator) catch return 3;
    defer allocator.free(chunks);
    for (chunks) |c| {
        const lc = LogChunkC{
            .data = c.data.ptr,
            .len = c.data.len,
            .stderr = if (c.stderr) 1 else 0,
            .timestamp_ns = c.ts_ns,
        };
        if (chunk_fn.?(ctx, &lc) != 0) return 3;
    }
    return 0;
}

export fn voilad_logs_follow(
    ctx_id: [*:0]const u8,
    chunk_fn: ?*const fn (?*anyopaque, *const LogChunkC) callconv(.c) i32,
    ctx: ?*anyopaque,
    stop: *volatile i32,
) callconv(.c) void {
    if (chunk_fn == null) return;
    const id = std.mem.span(ctx_id);
    const vctx = registry_global.get().get(id) orelse return;
    const start = vctx.ring.chunkCount();
    var idx = start;
    while (stop.* == 0) {
        if (vctx.ring.waitForChunk(idx, stop)) |c| {
            const lc = LogChunkC{
                .data = c.data.ptr,
                .len = c.data.len,
                .stderr = if (c.stderr) 1 else 0,
                .timestamp_ns = c.ts_ns,
            };
            if (chunk_fn.?(ctx, &lc) != 0) break;
            idx += 1;
            continue;
        }
        if (vctx.ring.isFinished()) break;
        std.Thread.yield() catch {};
    }
}

export fn voilad_events_stream(
    filter_ctx: [*:0]const u8,
    event_fn: ?*const fn (?*anyopaque, *const EventC) callconv(.c) i32,
    ctx: ?*anyopaque,
    stop: *volatile i32,
) callconv(.c) void {
    if (event_fn == null) return;
    const filter = std.mem.span(filter_ctx);
    const hub = &registry_global.get().hub;
    const allocator = std.heap.c_allocator;
    const sub = hub.subscribe(filter) catch return;
    defer hub.unsubscribe(sub);
    while (stop.* == 0) {
        const ev = hub.waitPop(sub, stop) orelse break;
        const id_z = dupZ(allocator, ev.context_id) catch {
            allocator.free(ev.context_id);
            continue;
        };
        defer allocator.free(id_z);
        @memcpy(id_z, ev.context_id);
        defer allocator.free(ev.context_id);
        const ec = EventC{
            .context_id = id_z.ptr,
            .type = @backingInt(ev.type),
            .timestamp_ns = ev.timestamp_ns,
            .exit_code = ev.exit_code,
        };
        if (event_fn.?(ctx, &ec) != 0) break;
    }
}

pub fn handleExec(
    ctx_id: [*:0]const u8,
    args: [*][*:0]const u8,
    args_len: usize,
    cb: *grpc_shim.ExecCallbacks,
) i32 {
    const allocator = std.heap.c_allocator;
    const id = std.mem.span(ctx_id);
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var i: usize = 0;
    while (i < args_len) : (i += 1) {
        args_list.append(allocator, std.mem.span(args[i])) catch return -1;
    }
    const code = launch.execInContext(allocator, id, args_list.items, cb) catch return -1;
    return code;
}
