const std = @import("std");
const zio = @import("zio");
const vfs_mod = @import("vfs.zig");
const fuse_linux = @import("fuse_linux.zig");
const posix_util = @import("posix_util.zig");
const constants = @import("constants.zig");

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub = args.next() orelse "prove";
    const fixture_dir = args.next() orelse "fixture-out";

    if (std.mem.eql(u8, sub, "prove")) {
        try prove(io, init, fixture_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "serve")) {
        const mountpoint = args.next() orelse return error.NeedMountpoint;
        const fixture_abs = try resolveAbs(init.gpa, fixture_dir);
        defer init.gpa.free(fixture_abs);
        var vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
        defer vfs.deinit();
        try vfs.preloadAllChunks(io);
        try fuse_linux.mountAndServe(io, init.gpa, &vfs, mountpoint);
        return;
    }
    std.debug.print("usage: zig-fuse prove [fixture-dir]\n       zig-fuse serve [fixture-dir] <mountpoint>\n", .{});
}

fn prove(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    try ensureFixture(init, fixture_dir);
    const fixture_abs = try resolveAbs(init.gpa, fixture_dir);
    defer init.gpa.free(fixture_abs);

    var vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
    defer vfs.deinit();

    if (!fuse_linux.canUseFuse()) {
        std.debug.print("skip: need root and /dev/fuse (read walker unit tests: zig build test)\n", .{});
        return;
    }

    try rootMountProve(io, init, fixture_abs);
}

fn rootMountProve(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    const mount_dir = try std.fmt.allocPrint(init.gpa, "/tmp/zig-fuse-mnt-{d}", .{std.c.getpid()});
    defer init.gpa.free(mount_dir);
    try posix_util.makePath(mount_dir);

    var vfs = try vfs_mod.Vfs.load(init.gpa, fixture_dir);
    try vfs.preloadAllChunks(io);

    const ServeCtx = struct {
        session: fuse_linux.Session,
        vfs: vfs_mod.Vfs,
        err: ?anyerror,
    };

    var ctx: ServeCtx = undefined;
    ctx.err = null;
    ctx.vfs = vfs;
    ctx.session = fuse_linux.mountSession(init.gpa, mount_dir, &ctx.vfs) catch |e| return e;

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(shared: *ServeCtx) void {
            fuse_linux.serveSession(&shared.session) catch |e| {
                shared.err = e;
            };
        }
    }.run, .{&ctx});

    for (0..3000) |_| {
        if (dirHasEntries(mount_dir)) break;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try checkReaddir(init.gpa, mount_dir);

    const link_target = try std.fmt.allocPrint(init.gpa, "{s}/link", .{mount_dir});
    defer init.gpa.free(link_target);
    const target = try readlinkAlloc(init.gpa, link_target);
    defer init.gpa.free(target);
    if (!std.mem.eql(u8, target, "big.bin")) return error.ReadlinkWrong;

    const big_path = try std.fmt.allocPrint(init.gpa, "{s}/big.bin", .{mount_dir});
    defer init.gpa.free(big_path);
    var pair: [2]u8 = undefined;
    try preadFile(big_path, &pair, constants.chunk_size - 1);
    std.debug.print("byte[1048575]=0x{x:02} byte[1048576]=0x{x:02}\n", .{ pair[0], pair[1] });
    if (pair[0] != 0xAA or pair[1] != 0xCC) return error.BoundaryBytesWrong;
    const big_z = try init.gpa.allocSentinel(u8, big_path.len, 0);
    defer init.gpa.free(big_z);
    @memcpy(big_z, big_path);
    const write_fd = std.c.open(big_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (write_fd >= 0) {
        _ = std.c.close(write_fd);
        return error.WriteShouldFail;
    }

    ctx.session.stop();
    thread.join();
    ctx.session.deinit();
    ctx.vfs.deinit();
    if (ctx.err != null) return ctx.err.?;
    std.debug.print("prove: readdir, readlink, boundary bytes, write EROFS — ok\n", .{});
}

fn checkReaddir(allocator: std.mem.Allocator, mount_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "ls -1 {s}", .{mount_dir});
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    const out_path = "/tmp/zig-fuse-readdir.txt";
    const full = try std.fmt.allocPrint(allocator, "{s} > {s}", .{ cmd, out_path });
    defer allocator.free(full);
    const full_z = try allocator.allocSentinel(u8, full.len, 0);
    defer allocator.free(full_z);
    @memcpy(full_z, full);
    if (posix_util.shell(full_z) != 0) return error.ReaddirMissing;
    const listing = try posix_util.readFileAlloc(allocator, out_path, 4096);
    defer allocator.free(listing);
    var has_big = false;
    var has_link = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "big.bin")) has_big = true;
        if (std.mem.eql(u8, line, "link")) has_link = true;
    }
    if (!has_big or !has_link) return error.ReaddirMissing;
}

fn dirHasEntries(mount_dir: []const u8) bool {
    const probe = std.fmt.allocPrint(std.heap.page_allocator, "{s}/big.bin", .{mount_dir}) catch return false;
    defer std.heap.page_allocator.free(probe);
    return posix_util.access(probe);
}

fn readlinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const n = std.c.readlink(path_z, &buf, buf.len);
    if (n < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn preadFile(path: []const u8, buf: []u8, offset: u64) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    defer _ = std.c.close(fd);
    const rc = std.c.pread(fd, buf.ptr, buf.len, @bitCast(@as(i64, @intCast(offset))));
    if (rc < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    if (@as(usize, @intCast(rc)) != buf.len) return error.ShortRead;
}

fn ensureFixture(init: std.process.Init, dir: []const u8) !void {
    const out_abs = try resolveAbs(init.gpa, dir);
    defer init.gpa.free(out_abs);
    const tree = try std.fmt.allocPrint(init.gpa, "{s}/tree.txt", .{out_abs});
    defer init.gpa.free(tree);
    if (posix_util.access(tree)) return;

    try posix_util.makePath(out_abs);
    const voila_root = try findVoilaRoot(init.gpa);
    defer init.gpa.free(voila_root);
    const cmd = try std.fmt.allocPrint(init.gpa, "cd {s} && go run -tags zig_fuse_fixture ./poc/zig-fuse/fixture -o {s}", .{ voila_root, out_abs });
    defer init.gpa.free(cmd);
    const cmd_z = try init.gpa.allocSentinel(u8, cmd.len, 0);
    defer init.gpa.free(cmd_z);
    @memcpy(cmd_z, cmd);
    const rc = posix_util.shell(cmd_z);
    if (rc != 0) return error.FixtureFailed;
}

fn resolveAbs(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return allocator.dupe(u8, path);
    var cwd: [4096]u8 = undefined;
    const cwd_rc = std.os.linux.getcwd(cwd[0..].ptr, cwd.len);
    const cwd_err = std.posix.errno(cwd_rc);
    if (cwd_err != .SUCCESS) return allocator.dupe(u8, path);
    const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd[0..].ptr)), 0);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_slice, path });
}

fn findVoilaRoot(allocator: std.mem.Allocator) ![]const u8 {
    const seeds = [_][]const u8{
        "/agent/repos/voila",
        "../../..",
        "../..",
    };
    for (seeds) |seed| {
        const gomod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{seed});
        defer allocator.free(gomod);
        if (posix_util.access(gomod)) return allocator.dupe(u8, seed);
    }
    return error.NoVoilaRoot;
}
