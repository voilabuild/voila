//! Shared pieces of build steps: the RUN executor interface and path/argv helpers.
const std = @import("std");
const dockerfile = @import("core").dockerfile;
const dir_walk = @import("store").ingest.ingest_dir_walk;
const idmap = @import("core").idmap;

pub const default_path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub const RunRequest = struct {
    voila_root: []const u8,
    /// Merged root manifest chunk the command runs on.
    root: [32]u8,
    /// Private scratch directory, removed after the step.
    scratch_dir: []const u8,
    /// Empty directory inside `scratch_dir`; every write of the command must land here
    /// in overlayfs upper-dir format.
    upper_dir: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    workdir: []const u8,
    user: []const u8,
    /// Where the runner may write `dir_walk.appendOwner` records for entries it handed
    /// back to the build user; absent when it had none.
    owners_path: []const u8,
};

pub const RunResult = struct {
    code: u8,
    /// Id map the command ran under; null means the single invoking uid/gid.
    ids: ?idmap.Mapping = null,
    /// `USER` was set but its ids are not mapped, so the command ran as root.
    user_not_applied: bool = false,
    /// When non-zero, the upper dir is a tmpfs in this process's mount namespace
    /// (`/proc/<pid>/root<scratch>/ram/upper`). Close `hold_ack` and wait for it
    /// after the upper has been read.
    hold_pid: i32 = 0,
    hold_ack: i32 = -1,
};

pub const RunnerError = error{
    OutOfMemory,
    MountFailed,
    UserNamespacesRequired,
    OverlayFailed,
    OverlayUpperUnsupported,
    ReleaseFailed,
    SpawnFailed,
    UnknownUser,
    UnknownGroup,
    UserSwitchFailed,
};

/// Executes one RUN command.
pub const StepRunner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, io: std.Io, req: RunRequest) RunnerError!RunResult,

    pub fn run(self: StepRunner, io: std.Io, req: RunRequest) RunnerError!RunResult {
        return self.runFn(self.ptr, io, req);
    }
};

pub const default_shell = [_][]const u8{ "/bin/sh", "-c" };

/// Shell form runs through `shell` (default `/bin/sh -c`) with the command appended.
pub fn formArgv(a: std.mem.Allocator, form: dockerfile.Form, shell: []const []const u8) ![]const []const u8 {
    return switch (form) {
        .exec => |argv| argv,
        .shell => |cmd| {
            const argv = try a.alloc([]const u8, shell.len + 1);
            @memcpy(argv[0..shell.len], shell);
            argv[shell.len] = cmd;
            return argv;
        },
    };
}

/// Docker: `.`, `./`, a trailing `/`, or an empty dest means copy into a directory.
pub fn destIsDirectory(dest_raw: []const u8) bool {
    if (std.mem.endsWith(u8, dest_raw, "/")) return true;
    const trimmed = std.mem.trimEnd(u8, dest_raw, "/");
    if (trimmed.len == 0) return true;
    return std.mem.eql(u8, std.fs.path.basename(trimmed), ".");
}

/// Absolute, normalized path of `p` relative to `cwd` (empty cwd is `/`).
pub fn joinPath(a: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (p.len == 0 or p[0] != '/') {
        var it = std.mem.tokenizeScalar(u8, cwd, '/');
        while (it.next()) |s| try parts.append(a, s);
    }
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |s| {
        if (std.mem.eql(u8, s, ".")) continue;
        if (std.mem.eql(u8, s, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, s);
    }
    const body = try std.mem.join(a, "/", parts.items);
    return std.fmt.allocPrint(a, "/{s}", .{body});
}

pub fn joinRel(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

pub const ChownError = error{UnsupportedChown};

/// `--chown=uid[:gid]` with numeric ids; empty means root.
pub fn parseChown(s: []const u8) ChownError!dir_walk.Owner {
    if (s.len == 0) return .{ .uid = 0, .gid = 0 };
    const colon = std.mem.indexOfScalar(u8, s, ':');
    const uid = std.fmt.parseInt(u32, s[0 .. colon orelse s.len], 10) catch return error.UnsupportedChown;
    const gid = if (colon) |c| std.fmt.parseInt(u32, s[c + 1 ..], 10) catch return error.UnsupportedChown else uid;
    return .{ .uid = uid, .gid = gid };
}

/// Paths the RUN sandbox mounts over; never part of a layer (Docker does the same).
pub const mountpoints = [_][]const u8{ "proc", "sys", "dev", "etc/resolv.conf", "etc/hosts" };

pub const MountpointSkip = struct {
    pub fn skip(self: *MountpointSkip) dir_walk.Skip {
        return .{ .ctx = self, .func = check };
    }

    fn check(_: *const anyopaque, rel: []const u8, _: bool) bool {
        for (mountpoints) |m| if (std.mem.eql(u8, rel, m)) return true;
        return false;
    }
};

const testing = std.testing;

test "destIsDirectory treats dot and trailing slash as a directory" {
    try testing.expect(destIsDirectory("."));
    try testing.expect(destIsDirectory("./"));
    try testing.expect(destIsDirectory("foo/"));
    try testing.expect(destIsDirectory("foo/."));
    try testing.expect(destIsDirectory(""));
    try testing.expect(!destIsDirectory("app.py"));
    try testing.expect(!destIsDirectory("/usr/local/bin/t"));
}

test "joinPath resolves relative to the working directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/app/src", try joinPath(a, "/app", "src"));
    try testing.expectEqualStrings("/etc", try joinPath(a, "/app", "/etc/"));
    try testing.expectEqualStrings("/x", try joinPath(a, "", "x"));
    try testing.expectEqualStrings("/", try joinPath(a, "/a", ".."));
    try testing.expectEqualStrings("/", try joinPath(a, "/", "../.."));
    try testing.expectEqualStrings("/a/c", try joinPath(a, "/a/b", "./../c"));
}

test "formArgv appends the command to the shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const def = try formArgv(a, .{ .shell = "echo hi" }, &default_shell);
    try testing.expectEqualStrings("/bin/sh", def[0]);
    try testing.expectEqualStrings("echo hi", def[2]);
    const custom = try formArgv(a, .{ .shell = "x" }, &.{ "/bin/bash", "-eo", "pipefail", "-c" });
    try testing.expectEqual(@as(usize, 5), custom.len);
    try testing.expectEqualStrings("x", custom[4]);
    const exec = try formArgv(a, .{ .exec = &.{ "a", "b" } }, &default_shell);
    try testing.expectEqual(@as(usize, 2), exec.len);
}

test "parseChown accepts numeric ids only" {
    try testing.expectEqual(dir_walk.Owner{ .uid = 0, .gid = 0 }, try parseChown(""));
    try testing.expectEqual(dir_walk.Owner{ .uid = 1000, .gid = 1000 }, try parseChown("1000"));
    try testing.expectEqual(dir_walk.Owner{ .uid = 1, .gid = 2 }, try parseChown("1:2"));
    try testing.expectError(error.UnsupportedChown, parseChown("app:app"));
}
