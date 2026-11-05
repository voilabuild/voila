const std = @import("std");
const container_store = @import("./container_store.zig");
const container_lifecycle = @import("./container_lifecycle.zig");
const container_run = @import("./container_run.zig");
const container_run_opts = @import("./container_run_opts.zig");
const mount_exec = @import("mount").mount_exec;
const ns = @import("sys").ns;
const posix_util = @import("sys").posix_util;

pub const ExecSpec = struct {
    context_id: []const u8,
    argv: []const []const u8,
    tty: bool,
    interactive: bool,
};

pub fn exec(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: ExecSpec) !u8 {
    const id = try container_store.resolveId(allocator, voila_root, spec.context_id);
    defer allocator.free(id);
    const st = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st);
    if (!container_lifecycle.isRunning(st)) return error.NotRunning;
    if (!container_lifecycle.mountStillListed(st.mount_dir)) return error.NotRunning;
    const opts = try container_run_opts.readRunOpts(allocator, voila_root, id);
    defer opts.deinit(allocator);
    // Resolve against the live mount so programs installed at runtime (or via volumes) work.
    const vfs_exec = try mount_exec.resolveArgv0OnMount(allocator, st.mount_dir, spec.argv[0]);
    defer allocator.free(vfs_exec);
    // A pty only when asked for one and stdin is a terminal: piped input must reach EOF.
    const use_tty = (spec.tty or opts.tty) and ns.isTerminal(0);
    return container_run.execInMount(
        io,
        allocator,
        st.mount_dir,
        vfs_exec,
        spec.argv,
        use_tty,
        opts,
        findInit(st.pid) orelse return error.NotRunning,
    );
}

/// The container's PID 1: the first process below the worker in another PID namespace.
fn findInit(worker: i32) ?i32 {
    var queue: [64]i32 = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    queue[0] = worker;
    while (head < tail) : (head += 1) {
        const p = queue[head];
        if (p != worker and !ns.samePidNamespace(worker, p)) return p;
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/proc/{d}/task/{d}/children", .{ p, p }) catch continue;
        const data = posix_util.readFileAlloc(std.heap.page_allocator, path, 1 << 16) catch continue;
        defer std.heap.page_allocator.free(data);
        var it = std.mem.tokenizeScalar(u8, data, ' ');
        while (it.next()) |t| {
            if (tail == queue.len) break;
            queue[tail] = std.fmt.parseInt(i32, std.mem.trim(u8, t, "\n"), 10) catch continue;
            tail += 1;
        }
    }
    return null;
}

pub const Error = error{NotRunning};
