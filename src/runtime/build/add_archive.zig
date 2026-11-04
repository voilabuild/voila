//! `ADD <local archive> <dest>`: Docker unpacks local tar archives (plain, gzip, zstd here).
const std = @import("std");
const fs = @import("sys").fs;
const posix_util = @import("sys").posix_util;
const tar = @import("store").ingest.ingest_tar;

pub const Kind = enum { none, tar, unsupported };

fn looksLikeTar(data: []const u8) bool {
    return data.len >= 262 and std.mem.eql(u8, data[257..262], "ustar");
}

/// Classifies by content, as Docker does, not by file name.
/// Compression alone is not enough: a gzip text file is not a tar archive.
pub fn sniff(head: []const u8) Kind {
    switch (tar.sniffCompression(head)) {
        .gzip, .zstd => return .none,
        else => {},
    }
    if (head.len >= 3 and std.mem.eql(u8, head[0..3], "BZh")) return .unsupported;
    if (head.len >= 6 and std.mem.eql(u8, head[0..6], &[_]u8{ 0xfd, '7', 'z', 'X', 'Z', 0 })) return .unsupported;
    if (looksLikeTar(head)) return .tar;
    return .none;
}

pub fn sniffFile(path: []const u8) Kind {
    const blob = posix_util.readFileAlloc(std.heap.page_allocator, path, 1 << 32) catch return .none;
    defer std.heap.page_allocator.free(blob);
    if (blob.len >= 3 and std.mem.eql(u8, blob[0..3], "BZh")) return .unsupported;
    if (blob.len >= 6 and std.mem.eql(u8, blob[0..6], &[_]u8{ 0xfd, '7', 'z', 'X', 'Z', 0 })) return .unsupported;
    switch (tar.sniffCompression(blob)) {
        .gzip, .zstd => {
            const data = tar.decompressLayer(std.heap.page_allocator, blob, .raw) catch return .none;
            defer std.heap.page_allocator.free(data);
            return if (looksLikeTar(data)) .tar else .none;
        },
        else => {},
    }
    return if (looksLikeTar(blob)) .tar else .none;
}

/// Unpacks `archive` under `dest` (an existing empty dir). Entries that would leave
/// `dest`, devices and fifos are skipped; ownership comes from the ADD step, not the archive.
pub fn extract(allocator: std.mem.Allocator, archive: []const u8, dest: []const u8) !void {
    const blob = try posix_util.readFileAlloc(allocator, archive, 1 << 32);
    defer allocator.free(blob);
    const data = try tar.decompressLayer(allocator, blob, .raw);
    defer allocator.free(data);
    var ts = tar.TarStream.init(data);
    while (try ts.next(allocator)) |hdr| {
        defer {
            allocator.free(hdr.name);
            allocator.free(hdr.linkname);
        }
        const rel = cleanPath(hdr.name) orelse continue;
        // Extraction runs on the host: never write through a symlink an earlier entry made.
        if (try parentHasSymlink(allocator, dest, rel)) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, rel });
        defer allocator.free(path);
        if (std.fs.path.dirname(path)) |d| try fs.makePath(d);
        const perm: u32 = hdr.mode & 0o7777;
        switch (hdr.typeflag) {
            '5' => {
                try fs.makePath(path);
                try fs.chmodNoFollow(path, perm | 0o700);
            },
            '0', 0, '7' => {
                const body = try ts.readAll(allocator, hdr.size);
                defer allocator.free(body);
                try fs.writeFileNoFollow(path, body, perm);
                try fs.chmodNoFollow(path, perm);
            },
            '2' => fs.symlink(hdr.linkname, path) catch |e| if (e != error.Exists) return e,
            '1' => {
                const target_rel = cleanPath(hdr.linkname) orelse continue;
                if (try parentHasSymlink(allocator, dest, target_rel)) continue;
                const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, target_rel });
                defer allocator.free(target);
                fs.hardLink(target, path) catch continue; // target missing or later in the archive
            },
            else => {},
        }
    }
}

fn parentHasSymlink(allocator: std.mem.Allocator, dest: []const u8, rel: []const u8) !bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, rel[0..slash] });
        defer allocator.free(p);
        const st = fs.lstat(p) catch continue;
        if (st.kind == .symlink) return true;
    }
    return false;
}

/// Archive path relative to the extraction root, or null for `..` escapes and the root itself.
pub fn cleanPath(name: []const u8) ?[]const u8 {
    var p = name;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    p = std.mem.trim(u8, p, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return null;
    return p;
}

test "sniff tells archives from plain files" {
    var ustar: [512]u8 = @splat(0);
    @memcpy(ustar[257..262], "ustar");
    try std.testing.expectEqual(Kind.tar, sniff(&ustar));
    // Compression magic alone is inconclusive; sniffFile decompresses first.
    try std.testing.expectEqual(Kind.none, sniff(&[_]u8{ 0x1f, 0x8b, 8, 0 }));
    try std.testing.expectEqual(Kind.unsupported, sniff("BZh91AY"));
    try std.testing.expectEqual(Kind.none, sniff("hello world\n"));
}

test "cleanPath rejects escapes and keeps nested names" {
    try std.testing.expectEqualStrings("a/b.txt", cleanPath("./a/b.txt").?);
    try std.testing.expectEqualStrings("dir", cleanPath("dir/").?);
    try std.testing.expect(cleanPath("../etc/passwd") == null);
    try std.testing.expect(cleanPath("a/../../x") == null);
    try std.testing.expect(cleanPath("./") == null);
}

fn tarEntry(out: *std.ArrayList(u8), a: std.mem.Allocator, typeflag: u8, name: []const u8, link: []const u8, body: []const u8) !void {
    var h: [512]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    _ = try std.fmt.bufPrint(h[100..107], "{o:0>7}", .{@as(u32, 0o644)});
    _ = try std.fmt.bufPrint(h[124..135], "{o:0>11}", .{body.len});
    h[156] = typeflag;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..262], "ustar");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |c| sum += c;
    _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum});
    try out.appendSlice(a, &h);
    try out.appendSlice(a, body);
    try out.appendNTimes(a, 0, (512 - body.len % 512) % 512);
}

test "extract writes files and never follows an archive symlink out of dest" {
    const a = std.testing.allocator;
    const tmp = try fs.makeTempDir(a, "voila-add-archive");
    defer a.free(tmp);
    defer fs.removeTree(a, tmp) catch {}; // leftover temp dir is fine
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{tmp});
    defer a.free(outside);
    try fs.makePath(outside);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(a);
    try tarEntry(&t, a, '0', "dir/hello.txt", "", "hi\n");
    try tarEntry(&t, a, '2', "esc", outside, "");
    try tarEntry(&t, a, '0', "esc/pwned", "", "x");
    try t.appendNTimes(a, 0, 1024);
    const archive = try std.fmt.allocPrint(a, "{s}/a.tar", .{tmp});
    defer a.free(archive);
    try fs.writeFile(archive, t.items, 0o644);
    try std.testing.expectEqual(Kind.tar, sniffFile(archive));

    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    try fs.makePath(dest);
    try extract(a, archive, dest);
    const hello = try std.fmt.allocPrint(a, "{s}/dir/hello.txt", .{dest});
    defer a.free(hello);
    const got = try posix_util.readFileAlloc(a, hello, 64);
    defer a.free(got);
    try std.testing.expectEqualStrings("hi\n", got);
    const pwned = try std.fmt.allocPrint(a, "{s}/pwned", .{outside});
    defer a.free(pwned);
    try std.testing.expect(!posix_util.access(pwned));
}

test "extract replaces a final symlink instead of writing through it" {
    const a = std.testing.allocator;
    const tmp = try fs.makeTempDir(a, "voila-add-final-symlink");
    defer a.free(tmp);
    defer fs.removeTree(a, tmp) catch {};
    const outside = try std.fmt.allocPrint(a, "{s}/outside.txt", .{tmp});
    defer a.free(outside);
    try fs.writeFile(outside, "keep\n", 0o644);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(a);
    try tarEntry(&t, a, '2', "link", outside, "");
    try tarEntry(&t, a, '0', "link", "", "pwn\n");
    try t.appendNTimes(a, 0, 1024);
    const archive = try std.fmt.allocPrint(a, "{s}/a.tar", .{tmp});
    defer a.free(archive);
    try fs.writeFile(archive, t.items, 0o644);
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    try fs.makePath(dest);
    try extract(a, archive, dest);
    const kept = try posix_util.readFileAlloc(a, outside, 64);
    defer a.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
    const link = try std.fmt.allocPrint(a, "{s}/link", .{dest});
    defer a.free(link);
    const got = try posix_util.readFileAlloc(a, link, 64);
    defer a.free(got);
    try std.testing.expectEqualStrings("pwn\n", got);
}

test "extract skips hardlinks whose source path crosses a symlink" {
    const a = std.testing.allocator;
    const tmp = try fs.makeTempDir(a, "voila-add-hardlink");
    defer a.free(tmp);
    defer fs.removeTree(a, tmp) catch {};
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{tmp});
    defer a.free(outside);
    try fs.makePath(outside);
    const secret = try std.fmt.allocPrint(a, "{s}/secret", .{outside});
    defer a.free(secret);
    try fs.writeFile(secret, "host-secret\n", 0o644);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(a);
    try tarEntry(&t, a, '2', "esc", outside, "");
    try tarEntry(&t, a, '1', "stolen", "esc/secret", "");
    try t.appendNTimes(a, 0, 1024);
    const archive = try std.fmt.allocPrint(a, "{s}/a.tar", .{tmp});
    defer a.free(archive);
    try fs.writeFile(archive, t.items, 0o644);
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{tmp});
    defer a.free(dest);
    try fs.makePath(dest);
    try extract(a, archive, dest);
    const stolen = try std.fmt.allocPrint(a, "{s}/stolen", .{dest});
    defer a.free(stolen);
    try std.testing.expect(!posix_util.access(stolen));
}
