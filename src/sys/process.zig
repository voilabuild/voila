//! Child processes and credentials via raw syscalls (safe to call between fork and exec).
const std = @import("std");
const linux = std.os.linux;

pub const RunError = error{ SpawnFailed, NameTooLong, TooManyArgs };

const max_args = 16;

/// Runs `argv[0]` (an absolute path, no shell, empty environment) and returns its exit
/// status; a signal death is reported as 128 + signal.
pub fn run(argv: []const []const u8) RunError!u8 {
    if (argv.len == 0 or argv.len > max_args) return error.TooManyArgs;
    var storage: [max_args][256:0]u8 = undefined;
    var ptrs: [max_args:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, i| {
        if (arg.len >= storage[i].len) return error.NameTooLong;
        @memcpy(storage[i][0..arg.len], arg);
        storage[i][arg.len] = 0;
        ptrs[i] = &storage[i];
    }
    const envp: [0:null]?[*:0]const u8 = .{};
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SpawnFailed;
    const pid: linux.pid_t = @intCast(rc);
    if (pid == 0) {
        _ = linux.execve(ptrs[0].?, &ptrs, &envp);
        linux.exit(127);
    }
    var status: i32 = 0;
    while (true) {
        const w = linux.wait4(pid, &status, 0, null);
        if (linux.errno(w) == .SUCCESS) break;
        if (linux.errno(w) != .INTR) return error.SpawnFailed;
    }
    const st: u32 = @bitCast(status);
    if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
    return 128 +| @as(u8, @truncate(@backingInt(linux.W.TERMSIG(st))));
}

pub const CredError = error{ SetGroupsFailed, SetGidFailed, SetUidFailed };

/// Drops to `uid`/`gid`; `groups` replaces the supplementary list unless setgroups is
/// denied (single-id user namespace), in which case the inherited list is kept.
pub fn switchUser(uid: u32, gid: u32, groups: []const u32) CredError!void {
    const g = linux.setgroups(groups.len, groups.ptr);
    switch (linux.errno(g)) {
        .SUCCESS, .PERM => {},
        else => return error.SetGroupsFailed,
    }
    if (linux.errno(linux.setresgid(gid, gid, gid)) != .SUCCESS) return error.SetGidFailed;
    if (linux.errno(linux.setresuid(uid, uid, uid)) != .SUCCESS) return error.SetUidFailed;
}
