//! Rootless RUN: the step's image is FUSE-mounted read-only, overlayfs on top captures
//! writes in `upper_dir`, and the command runs pivoted into it in a user + mount + PID namespace.
const std = @import("std");
const steps = @import("steps.zig");
const fs = @import("../../sys/fs.zig");
const container_fuse_sibling = @import("../oci/container_fuse_sibling.zig");
const container_bind = @import("../oci/container_bind.zig");
const container_root = @import("../oci/container_root.zig");

extern "c" fn unshare(flags: c_int) c_int;
extern "c" fn mount(source: ?[*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: usize, data: ?*const anyopaque) c_int;

const CLONE_NEWNS: c_int = 0x00020000;
const MS_BIND: usize = 4096;
const MS_REC: usize = 16384;
const MS_PRIVATE: usize = 1 << 18;

/// Exit status the child uses when the sandbox itself could not be set up.
const setup_failed: u8 = 125;

pub const NamespaceRunner = struct {
    allocator: std.mem.Allocator,

    pub fn runner(self: *NamespaceRunner) steps.StepRunner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, io: std.Io, req: steps.RunRequest) steps.RunnerError!u8 {
        const self: *NamespaceRunner = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const lower = try std.fmt.allocPrint(a, "{s}/lower", .{req.scratch_dir});
        const work = try std.fmt.allocPrint(a, "{s}/work", .{req.scratch_dir});
        const merged = try std.fmt.allocPrint(a, "{s}/merged", .{req.scratch_dir});
        for ([_][]const u8{ lower, work, merged }) |d| fs.mkdir(d, 0o755) catch return error.MountFailed;

        const hex = std.fmt.bytesToHex(req.root, .lower);
        const image = try std.fmt.allocPrint(a, "@{s}", .{&hex});
        var fuse = container_fuse_sibling.startWith(io, a, req.voila_root, image, lower, .{ .map_root = true }) catch return error.MountFailed;
        defer fuse.deinit();

        const plan = try Plan.init(a, req, lower, work, merged);
        const pid = std.c.fork();
        if (pid < 0) return error.SpawnFailed;
        if (pid == 0) {
            plan.exec();
            std.c._exit(setup_failed);
        }
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {}
        defer chmodTree(a, work);
        const st: u32 = @bitCast(status);
        if (std.posix.W.IFEXITED(st)) {
            const code = std.posix.W.EXITSTATUS(st);
            if (code == setup_failed) return error.OverlayFailed;
            return code;
        }
        return 128 +| @as(u8, @truncate(@backingInt(std.posix.W.TERMSIG(st))));
    }
};

/// Everything the child needs, prepared before fork so the child only makes syscalls.
const Plan = struct {
    merged_z: [:0]const u8,
    overlay_opts: [:0]const u8,
    workdir_z: ?[:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    /// Candidate executable paths: argv[0] as is, or joined with each PATH entry.
    candidates: []const [:0]const u8,
    resolv_src: [:0]const u8 = "/etc/resolv.conf",
    resolv_dst: [:0]const u8,
    root_ops: []const container_root.Op,

    fn init(a: std.mem.Allocator, req: steps.RunRequest, lower: []const u8, work: []const u8, merged: []const u8) !Plan {
        const argv = try a.allocSentinel(?[*:0]const u8, req.argv.len, null);
        for (req.argv, 0..) |s, i| argv[i] = try a.dupeSentinel(u8, s, 0);
        const envp = try a.allocSentinel(?[*:0]const u8, req.env.len, null);
        var path_var: []const u8 = steps.default_path["PATH=".len..];
        for (req.env, 0..) |s, i| {
            envp[i] = try a.dupeSentinel(u8, s, 0);
            if (std.mem.startsWith(u8, s, "PATH=")) path_var = s["PATH=".len..];
        }
        var cands: std.ArrayList([:0]const u8) = .empty;
        const exe = req.argv[0];
        if (std.mem.indexOfScalar(u8, exe, '/') != null) {
            try cands.append(a, try a.dupeSentinel(u8, exe, 0));
        } else {
            var it = std.mem.tokenizeScalar(u8, path_var, ':');
            while (it.next()) |dir| try cands.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, exe }, 0));
        }
        return .{
            .merged_z = try a.dupeSentinel(u8, merged, 0),
            .overlay_opts = try std.fmt.allocPrintSentinel(a, "lowerdir={s},upperdir={s},workdir={s},userxattr", .{ lower, req.upper_dir, work }, 0),
            .workdir_z = if (req.workdir.len > 0) try a.dupeSentinel(u8, req.workdir, 0) else null,
            .argv = argv,
            .envp = envp,
            .candidates = try cands.toOwnedSlice(a),
            .resolv_dst = try std.fmt.allocPrintSentinel(a, "{s}/etc/resolv.conf", .{merged}, 0),
            .root_ops = try container_root.plan(a, merged),
        };
    }

    fn exec(self: Plan) void {
        if (!container_bind.enterUserNamespaceOnly()) return;
        if (unshare(CLONE_NEWNS) != 0) return;
        _ = mount(null, "/", null, MS_REC | MS_PRIVATE, null);
        if (mount("overlay", self.merged_z, "overlay", 0, self.overlay_opts.ptr) != 0) return;
        // A created mountpoint is fine: steps.mountpoints keeps it out of the layer.
        const fd = std.c.open(self.resolv_dst, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) _ = std.c.close(fd);
        _ = mount(self.resolv_src, self.resolv_dst, null, MS_BIND, null);
        if (container_root.enterPidNamespace(&.{}) catch return) |c| std.c._exit(c);
        container_root.apply(self.root_ops);
        container_root.pivotInto(self.merged_z) catch return;
        if (container_root.forkCommand(&.{}) catch return) |c| std.c._exit(c);
        if (self.workdir_z) |wd| {
            makePathZ(wd);
            if (std.c.chdir(wd) != 0) return;
        }
        _ = std.c.umask(0o022);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) _ = std.c.dup2(devnull, 0);
        for (self.candidates) |c| _ = std.c.execve(c, self.argv.ptr, self.envp.ptr);
        std.c._exit(127);
    }
};

fn makePathZ(path: [:0]const u8) void {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = std.c.mkdir(buf[0..i :0], 0o755);
    }
}

/// overlayfs leaves `work/work` mode 000; make it removable by the build user.
fn chmodTree(a: std.mem.Allocator, dir: []const u8) void {
    const names = fs.listDir(a, dir) catch return;
    for (names) |n| {
        const p = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, n }, 0) catch return;
        _ = std.c.chmod(p, 0o700);
    }
}
