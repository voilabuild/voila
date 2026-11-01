//! Raw Linux filesystem access (no libc, no `std.Io`) for walking and staging trees.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    FileNotFound,
    AccessDenied,
    NotDir,
    NameTooLong,
    Exists,
    Unexpected,
    OutOfMemory,
};

pub const Kind = enum { file, dir, symlink, char_dev, block_dev, fifo, socket };

pub const Stat = struct {
    kind: Kind,
    /// Permission bits including setuid/setgid/sticky.
    perm: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime_ns: u64,
    ino: u64,
    dev_major: u32,
    dev_minor: u32,
    nlink: u32,
    rdev_major: u32,
    rdev_minor: u32,
};

const Z = [std.Io.Dir.max_path_bytes:0]u8;

fn toZ(buf: *Z, path: []const u8) Error![:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .EXIST => error.Exists,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

const overlayfs_magic: i64 = 0x794c7630;

const StatFs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// True when `path` is on overlayfs. A user namespace cannot use that as an overlay upper dir.
pub fn onOverlay(path: []const u8) bool {
    var zb: Z = undefined;
    const z = toZ(&zb, path) catch return false;
    var st: StatFs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(z.ptr), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return false;
    return st.f_type == overlayfs_magic;
}

pub fn lstat(path: []const u8) Error!Stat {
    var zb: Z = undefined;
    var sx: linux.Statx = undefined;
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .MTIME = true, .INO = true, .SIZE = true };
    _ = try check(linux.statx(linux.AT.FDCWD, try toZ(&zb, path), linux.AT.SYMLINK_NOFOLLOW, mask, &sx));
    const fmt: u32 = sx.mode & linux.S.IFMT;
    const kind: Kind = switch (fmt) {
        linux.S.IFDIR => .dir,
        linux.S.IFLNK => .symlink,
        linux.S.IFCHR => .char_dev,
        linux.S.IFBLK => .block_dev,
        linux.S.IFIFO => .fifo,
        linux.S.IFSOCK => .socket,
        else => .file,
    };
    const sec: u64 = @intCast(@max(sx.mtime.sec, 0));
    return .{
        .kind = kind,
        .perm = sx.mode & 0o7777,
        .uid = sx.uid,
        .gid = sx.gid,
        .size = sx.size,
        .mtime_ns = sec * std.time.ns_per_s + sx.mtime.nsec,
        .ino = sx.ino,
        .dev_major = sx.dev_major,
        .dev_minor = sx.dev_minor,
        .nlink = sx.nlink,
        .rdev_major = sx.rdev_major,
        .rdev_minor = sx.rdev_minor,
    };
}

/// Entry names of `path`, sorted, without `.` and `..`. Caller frees each name and the slice.
pub fn listDir(allocator: std.mem.Allocator, path: []const u8) Error![][]const u8 {
    var zb: Z = undefined;
    const fd: linux.fd_t = @intCast(try check(linux.openat(linux.AT.FDCWD, try toZ(&zb, path), .{ .DIRECTORY = true, .CLOEXEC = true }, 0)));
    defer _ = linux.close(fd);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = try check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += d.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try names.append(allocator, try allocator.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.toOwnedSlice(allocator);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn freeNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

pub fn readLink(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    var zb: Z = undefined;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try check(linux.readlinkat(linux.AT.FDCWD, try toZ(&zb, path), &buf, buf.len));
    return allocator.dupe(u8, buf[0..n]);
}

/// Value of xattr `name` on `path` (not following symlinks), or null when absent.
pub fn getXattr(allocator: std.mem.Allocator, path: []const u8, name: [:0]const u8) Error!?[]u8 {
    var zb: Z = undefined;
    var buf: [4096]u8 = undefined;
    const rc = linux.lgetxattr(try toZ(&zb, path), name, &buf, buf.len);
    switch (linux.errno(rc)) {
        .NODATA, .OPNOTSUPP => return null,
        else => {},
    }
    const n = try check(rc);
    return try allocator.dupe(u8, buf[0..n]);
}

pub const File = struct {
    fd: linux.fd_t,

    pub fn openRead(path: []const u8) Error!File {
        var zb: Z = undefined;
        const fd = try check(linux.openat(linux.AT.FDCWD, try toZ(&zb, path), .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
        return .{ .fd = @intCast(fd) };
    }

    pub fn create(path: []const u8, perm: u32) Error!File {
        var zb: Z = undefined;
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
        const fd = try check(linux.openat(linux.AT.FDCWD, try toZ(&zb, path), flags, perm));
        return .{ .fd = @intCast(fd) };
    }

    /// Fills `buf` unless EOF comes first; returns the byte count.
    pub fn readFull(self: File, buf: []u8) Error!usize {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try check(linux.read(self.fd, buf[got..].ptr, buf.len - got));
            if (n == 0) break;
            got += n;
        }
        return got;
    }

    pub fn writeAll(self: File, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) off += try check(linux.write(self.fd, bytes[off..].ptr, bytes.len - off));
    }

    pub fn close(self: File) void {
        _ = linux.close(self.fd);
    }
};

pub fn writeFile(path: []const u8, bytes: []const u8, perm: u32) Error!void {
    const f = try File.create(path, perm);
    defer f.close();
    try f.writeAll(bytes);
}

pub fn mkdir(path: []const u8, perm: u32) Error!void {
    var zb: Z = undefined;
    _ = try check(linux.mkdirat(linux.AT.FDCWD, try toZ(&zb, path), perm));
}

/// `mkdir -p`. Tries the deepest directory first, so an existing parent costs one call.
pub fn makePath(path: []const u8) Error!void {
    const p = std.mem.trimEnd(u8, path, "/");
    if (p.len == 0) return;
    mkdir(p, 0o755) catch |e| switch (e) {
        error.Exists => return,
        error.FileNotFound => {
            try makePath(std.fs.path.dirname(p) orelse return e);
            mkdir(p, 0o755) catch |e2| if (e2 != error.Exists) return e2;
        },
        else => return e,
    };
}

pub fn randomBytes(buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) off += try check(linux.getrandom(buf[off..].ptr, buf.len - off, 0));
}

pub fn symlink(target: []const u8, path: []const u8) Error!void {
    var zt: Z = undefined;
    var zp: Z = undefined;
    _ = try check(linux.symlinkat(try toZ(&zt, target), linux.AT.FDCWD, try toZ(&zp, path)));
}

pub fn hardLink(existing: []const u8, path: []const u8) Error!void {
    var ze: Z = undefined;
    var zp: Z = undefined;
    _ = try check(linux.linkat(linux.AT.FDCWD, try toZ(&ze, existing), linux.AT.FDCWD, try toZ(&zp, path), 0));
}

pub fn rename(from: []const u8, to: []const u8) Error!void {
    var zf: Z = undefined;
    var zt: Z = undefined;
    _ = try check(linux.renameat(linux.AT.FDCWD, try toZ(&zf, from), linux.AT.FDCWD, try toZ(&zt, to)));
}

pub fn setMtime(path: []const u8, sec: i64) Error!void {
    var zb: Z = undefined;
    const ts: [2]linux.timespec = .{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
    _ = try check(linux.utimensat(linux.AT.FDCWD, try toZ(&zb, path), &ts, linux.AT.SYMLINK_NOFOLLOW));
}

/// Changes owner without following symlinks.
pub fn lchown(path: []const u8, uid: u32, gid: u32) Error!void {
    var zb: Z = undefined;
    _ = try check(linux.fchownat(linux.AT.FDCWD, try toZ(&zb, path), uid, gid, linux.AT.SYMLINK_NOFOLLOW));
}

/// chmod that fails instead of following a symlink (fchmodat2, Linux 6.6+; older
/// kernels go through an O_NOFOLLOW fd).
pub fn chmodNoFollow(path: []const u8, perm: u32) Error!void {
    var zb: Z = undefined;
    const z = try toZ(&zb, path);
    const rc = linux.fchmodat2(linux.AT.FDCWD, z, perm, linux.AT.SYMLINK_NOFOLLOW);
    if (linux.errno(rc) != .NOSYS) {
        _ = try check(rc);
        return;
    }
    const flags: linux.O = .{ .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true };
    const fd: linux.fd_t = @intCast(try check(linux.openat(linux.AT.FDCWD, z, flags, 0)));
    defer _ = linux.close(fd);
    _ = try check(linux.fchmod(fd, perm));
}

/// `rm -rf`; a missing path is not an error. Owned directories without `u+rwx`
/// (overlayfs leaves `work/work` at 000) are opened up before being emptied.
pub fn removeTree(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const st = lstat(path) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    var zb: Z = undefined;
    if (st.kind != .dir) {
        _ = try check(linux.unlinkat(linux.AT.FDCWD, try toZ(&zb, path), 0));
        return;
    }
    if (st.perm & 0o700 != 0o700) try chmodNoFollow(path, st.perm | 0o700);
    const names = try listDir(allocator, path);
    defer freeNames(allocator, names);
    for (names) |n| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, n });
        defer allocator.free(child);
        try removeTree(allocator, child);
    }
    _ = try check(linux.unlinkat(linux.AT.FDCWD, try toZ(&zb, path), linux.AT.REMOVEDIR));
}

/// Fresh directory under `/tmp` for tests. Caller frees the path.
pub fn makeTempDir(allocator: std.mem.Allocator, prefix: []const u8) Error![]u8 {
    return makeTempDirIn(allocator, "/tmp", prefix);
}

/// Fresh directory under the existing directory `parent`. Caller frees the path.
pub fn makeTempDirIn(allocator: std.mem.Allocator, parent: []const u8, prefix: []const u8) Error![]u8 {
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{d}-{d}-{d}", .{ parent, prefix, linux.getpid(), ts.nsec, attempt });
        mkdir(path, 0o700) catch |e| {
            allocator.free(path);
            if (e == error.Exists) continue;
            return e;
        };
        return path;
    }
    return error.Exists;
}

test "makePath creates missing parents and accepts existing ones" {
    const a = std.testing.allocator;
    const dir = try makeTempDir(a, "voila-fs-test");
    defer a.free(dir);
    defer removeTree(a, dir) catch {};
    const deep = try std.fmt.allocPrint(a, "{s}/a/b/c/", .{dir});
    defer a.free(deep);
    try makePath(deep);
    try makePath(deep);
    try std.testing.expect((try lstat(deep[0 .. deep.len - 1])).kind == .dir);
}

test "fs round trip: write, stat, list, readlink, remove" {
    const a = std.testing.allocator;
    const dir = try makeTempDir(a, "voila-fs-test");
    defer a.free(dir);
    defer removeTree(a, dir) catch {};

    const sub = try std.fmt.allocPrint(a, "{s}/x/y", .{dir});
    defer a.free(sub);
    try makePath(sub);
    const f = try std.fmt.allocPrint(a, "{s}/b.txt", .{dir});
    defer a.free(f);
    try writeFile(f, "hello", 0o640);
    try setMtime(f, 1_700_000_000);
    const l = try std.fmt.allocPrint(a, "{s}/a.lnk", .{dir});
    defer a.free(l);
    try symlink("b.txt", l);

    const st = try lstat(f);
    try std.testing.expectEqual(Kind.file, st.kind);
    try std.testing.expectEqual(@as(u32, 0o640), st.perm);
    try std.testing.expectEqual(@as(u64, 5), st.size);
    try std.testing.expectEqual(@as(u64, 1_700_000_000 * std.time.ns_per_s), st.mtime_ns);
    try std.testing.expectEqual(Kind.symlink, (try lstat(l)).kind);

    const names = try listDir(a, dir);
    defer freeNames(a, names);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("a.lnk", names[0]);
    try std.testing.expectEqualStrings("x", names[2]);

    const target = try readLink(a, l);
    defer a.free(target);
    try std.testing.expectEqualStrings("b.txt", target);
    try std.testing.expect((try getXattr(a, f, "user.voila.absent")) == null);

    try removeTree(a, dir);
    try std.testing.expectError(error.FileNotFound, lstat(dir));
}

test "onOverlay is false for proc" {
    try std.testing.expect(!onOverlay("/proc"));
}

test "removeTree removes directories left at mode 000" {
    const a = std.testing.allocator;
    const dir = try makeTempDir(a, "voila-fs-test");
    defer a.free(dir);
    defer removeTree(a, dir) catch {};
    const inner = try std.fmt.allocPrint(a, "{s}/work/work/x", .{dir});
    defer a.free(inner);
    try makePath(inner);
    try chmodNoFollow(inner, 0);
    try chmodNoFollow(inner[0 .. inner.len - 2], 0);

    try removeTree(a, dir);
    try std.testing.expectError(error.FileNotFound, lstat(dir));
}
