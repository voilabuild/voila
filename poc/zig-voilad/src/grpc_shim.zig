const std = @import("std");

pub const RunCallbacks = struct {
    ctx: ?*anyopaque,
    on_context_id: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) i32,
    on_stdout: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) i32,
    on_stderr: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) i32,
    on_exit: *const fn (?*anyopaque, i32) callconv(.c) i32,
};

pub const RunRequest = extern struct {
    image: [*:0]const u8,
    args: [*][*:0]const u8,
    args_len: usize,
    memory_limit_bytes: i64,
    cpu_quota_percent: i32,
    attach_stdin: i32,
};

pub extern fn voilad_grpc_serve_unix(
    socket_path: [*:0]const u8,
    voila_root: [*:0]const u8,
    handle_run: ?*const fn (*const RunRequest, *RunCallbacks) callconv(.c) i32,
) i32;
