const std = @import("std");
const fs = @import("../../sys/fs.zig");
const dir_walk = @import("ingest_dir_walk.zig");
const layer_walk = @import("ingest_layer_walk.zig");
const from_manifest = @import("ingest_from_manifest.zig");
const manifest_mod = @import("ingest_manifest.zig");
const merge_mod = @import("ingest_merge.zig");
const tree_mod = @import("ingest_tree.zig");
const idmap = @import("../../core/idmap.zig");

const mtime = 1_700_000_000;

const Fixture = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: []u8,

    fn init(gpa: std.mem.Allocator) !Fixture {
        const tmp = try fs.makeTempDir(gpa, "voila-dirwalk-test");
        return .{ .gpa = gpa, .arena = .init(gpa), .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        fs.removeTree(self.gpa, self.tmp) catch {};
        self.gpa.free(self.tmp);
        self.arena.deinit();
    }

    fn path(self: *Fixture, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.tmp, rel }) catch unreachable;
    }

    fn file(self: *Fixture, rel: []const u8, body: []const u8, perm: u32) !void {
        try fs.writeFile(self.path(rel), body, perm);
        try fs.setMtime(self.path(rel), mtime);
    }

    fn dir(self: *Fixture, rel: []const u8) !void {
        try fs.makePath(self.path(rel));
    }

    fn walk(self: *Fixture, voila_root: []const u8, rel: []const u8, dest: []const u8, mode: dir_walk.Mode) !*tree_mod.LayerTree {
        var w = try dir_walk.Walker.init(self.arena.allocator(), voila_root, .{ .mode = mode });
        defer w.deinit();
        try w.add(self.path(rel), dest);
        return (try w.finish()).tree;
    }
};

/// Pins every directory mtime under `rel` (children first, since writes bump it).
fn pinDirTimes(fx: *Fixture, rel: []const u8) !void {
    const a = fx.arena.allocator();
    const names = try fs.listDir(a, fx.path(rel));
    for (names) |n| {
        const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, n });
        if ((try fs.lstat(fx.path(child))).kind == .dir) try pinDirTimes(fx, child);
    }
    try fs.setMtime(fx.path(rel), mtime);
}

fn tarHeader(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, st: fs.Stat, typeflag: u8, size: u64, link: []const u8) !void {
    var h: [512]u8 = @splat(0);
    if (name.len > 100) {
        const cut = std.mem.lastIndexOfScalar(u8, name[0..@min(name.len, 155)], '/').?;
        @memcpy(h[345 .. 345 + cut], name[0..cut]);
        @memcpy(h[0 .. name.len - cut - 1], name[cut + 1 ..]);
    } else @memcpy(h[0..name.len], name);
    _ = try std.fmt.bufPrint(h[100..107], "{o:0>7}", .{st.perm});
    _ = try std.fmt.bufPrint(h[108..115], "{o:0>7}", .{0});
    _ = try std.fmt.bufPrint(h[116..123], "{o:0>7}", .{0});
    _ = try std.fmt.bufPrint(h[124..135], "{o:0>11}", .{size});
    _ = try std.fmt.bufPrint(h[136..147], "{o:0>11}", .{st.mtime_ns / std.time.ns_per_s});
    h[156] = typeflag;
    @memcpy(h[157 .. 157 + link.len], link);
    @memcpy(h[257..265], "ustar\x0000");
    try out.appendSlice(a, &h);
}

const Links = std.AutoHashMap(u64, []const u8);

/// Minimal ustar writer over a host directory, as an independent oracle for `walkLayer`.
fn tarDir(a: std.mem.Allocator, out: *std.ArrayList(u8), links: *Links, root: []const u8, rel: []const u8) !void {
    const abs = if (rel.len == 0) root else try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
    const names = try fs.listDir(a, abs);
    for (names) |n| {
        const child_rel = if (rel.len == 0) n else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, n });
        const child_abs = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, child_rel });
        const st = try fs.lstat(child_abs);
        switch (st.kind) {
            .dir => {
                try tarHeader(out, a, child_rel, st, '5', 0, "");
                try tarDir(a, out, links, root, child_rel);
            },
            .symlink => try tarHeader(out, a, child_rel, st, '2', 0, try fs.readLink(a, child_abs)),
            .file => {
                if (st.nlink > 1) {
                    if (links.get(st.ino)) |first| {
                        try tarHeader(out, a, child_rel, st, '1', 0, first);
                        continue;
                    }
                    try links.put(st.ino, child_rel);
                }
                try tarHeader(out, a, child_rel, st, '0', st.size, "");
                const f = try fs.File.openRead(child_abs);
                defer f.close();
                const body = try a.alloc(u8, st.size);
                _ = try f.readFull(body);
                try out.appendSlice(a, body);
                try out.appendNTimes(a, 0, (512 - st.size % 512) % 512);
            },
            else => {},
        }
    }
}

test "walkDir and tar ingest of the same tree produce the same manifest" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();
    const a = fx.arena.allocator();
    const store = fx.path("store");
    try fx.dir("store");
    try fx.dir("src/bin");
    try fx.dir("src/empty");
    try fx.dir("src/nested/deep");
    try fx.file("src/a.txt", "hello\n", 0o644);
    try fx.file("src/bin/run.sh", "#!/bin/sh\necho hi\n", 0o755);
    try fx.file("src/nested/deep/f", "", 0o600);
    const big = try a.alloc(u8, layer_walk.chunk_size + layer_walk.chunk_size / 2);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try fx.file("src/big.bin", big, 0o644);
    try fs.symlink("a.txt", fx.path("src/link"));
    try fs.hardLink(fx.path("src/a.txt"), fx.path("src/z-hard"));
    const long_dir = "src/node_modules/@scope/package-with-a-long-name/dist/__generated__/google/protobuf";
    try fx.dir(long_dir);
    try fx.file(long_dir ++ "/descriptor_with_long_name.js", "x\n", 0o644);
    try pinDirTimes(&fx, "src");

    const walked = try fx.walk(store, "src", "", .copy);
    var tar: std.ArrayList(u8) = .empty;
    var links: Links = .init(a);
    try tarDir(a, &tar, &links, fx.path("src"), "");
    try tar.appendNTimes(a, 0, 1024);
    const from_tar = try layer_walk.walkLayer(a, store, tar.items);

    try std.testing.expectEqual(@as(usize, 2), walked.lookup("big.bin").?.blocks.items.len);
    try std.testing.expect(from_tar.tree.lookup(long_dir[4..] ++ "/descriptor_with_long_name.js") != null);
    try std.testing.expect(from_tar.tree.lookup("z-hard").? == from_tar.tree.lookup("a.txt").?);
    const m1 = try manifest_mod.buildAndStoreManifest(a, store, walked, false);
    const m2 = try manifest_mod.buildAndStoreManifest(a, store, from_tar.tree, false);
    try std.testing.expectEqualSlices(u8, &m2, &m1);
}

test "manifest -> tree -> manifest is the identity" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();
    const a = fx.arena.allocator();
    const store = fx.path("store");
    try fx.dir("store");
    try fx.dir("src/etc");
    try fx.file("src/etc/os-release", "ID=test\n", 0o644);
    try fx.file("src/etc/hosts", "127.0.0.1 localhost\n", 0o644);
    try fs.symlink("etc/hosts", fx.path("src/hosts"));
    try pinDirTimes(&fx, "src");

    const tree = try fx.walk(store, "src", "", .copy);
    const root = try manifest_mod.buildAndStoreManifest(a, store, tree, false);
    const loaded = try from_manifest.loadTree(a, store, root);
    const again = try manifest_mod.buildAndStoreManifest(a, store, loaded, false);
    try std.testing.expectEqualSlices(u8, &root, &again);
}

test "upper-dir diff merges over a base: add, modify, whiteout, opaque" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();
    const a = fx.arena.allocator();
    const store = fx.path("store");
    try fx.dir("store");
    try fx.dir("base/etc");
    try fx.dir("base/cache/old");
    try fx.file("base/etc/keep", "keep", 0o644);
    try fx.file("base/etc/motd", "welcome", 0o644);
    try fx.file("base/etc/conf", "v1", 0o644);
    try fx.file("base/cache/old/x", "stale", 0o644);
    try fx.dir("upper/etc");
    try fx.dir("upper/cache/new");
    try fx.file("upper/etc/conf", "v2", 0o644);
    try fx.file("upper/etc/added", "new", 0o644);
    try fx.file("upper/cache/new/y", "fresh", 0o644);

    const base_tree = try fx.walk(store, "base", "", .copy);
    const base_root = try manifest_mod.buildAndStoreManifest(a, store, base_tree, false);
    const state = try from_manifest.loadTree(a, store, base_root);

    const diff = try fx.walk(store, "upper", "", .overlay_upper);
    // A real upper dir encodes these as a 0/0 char device and an opaque xattr.
    layer_walk.recordWhiteout(diff, a, "etc", "motd");
    layer_walk.recordOpaque(diff, a, "cache");

    var layers = [_]*tree_mod.LayerTree{ state, diff };
    const merged = try merge_mod.mergeTrees(a, &layers);
    const out_root = try manifest_mod.buildAndStoreManifest(a, store, merged, false);
    const out = try from_manifest.loadTree(a, store, out_root);

    try std.testing.expect(out.lookup("etc/keep") != null);
    try std.testing.expect(out.lookup("etc/added") != null);
    try std.testing.expect(out.lookup("etc/motd") == null);
    try std.testing.expect(out.lookup("cache/old") == null);
    try std.testing.expect(out.lookup("cache/new/y") != null);
    const conf = out.lookup("etc/conf").?;
    const upper_conf = diff.lookup("etc/conf").?;
    try std.testing.expectEqualSlices(u8, &upper_conf.blocks.items[0].chunk_id, &conf.blocks.items[0].chunk_id);
}

test "classifyUpper recognizes overlay whiteouts and opaque dirs" {
    var st: fs.Stat = std.mem.zeroes(fs.Stat);
    st.kind = .char_dev;
    try std.testing.expectEqual(dir_walk.UpperClass.whiteout, dir_walk.classifyUpper(st, null));
    st.rdev_major = 1;
    st.rdev_minor = 3;
    try std.testing.expectEqual(dir_walk.UpperClass.normal, dir_walk.classifyUpper(st, null));
    st.kind = .dir;
    try std.testing.expectEqual(dir_walk.UpperClass.opaque_dir, dir_walk.classifyUpper(st, "y"));
    try std.testing.expectEqual(dir_walk.UpperClass.normal, dir_walk.classifyUpper(st, null));
}

test "overlay mode maps the host build user to root" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();
    try fx.dir("store");
    try fx.dir("upper");
    try fx.file("upper/f", "x", 0o644);
    const st = try fs.lstat(fx.path("upper/f"));
    var w = try dir_walk.Walker.init(fx.arena.allocator(), fx.path("store"), .{
        .mode = .overlay_upper,
        .ids = idmap.Mapping.single(st.uid, st.gid),
    });
    defer w.deinit();
    try w.add(fx.path("upper"), "");
    const node = (try w.finish()).tree.lookup("f").?;
    try std.testing.expectEqual(@as(u32, 0), node.uid);
    try std.testing.expectEqual(@as(u32, 0), node.gid);
}

test "overlay mode maps subordinate ids and honors recorded owners" {
    var fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit();
    const a = fx.arena.allocator();
    try fx.dir("store");
    try fx.dir("upper");
    try fx.dir("upper/home");
    try fx.file("upper/home/f", "x", 0o644);
    try fx.file("upper/g", "y", 0o600);
    const st = try fs.lstat(fx.path("upper/home/f"));
    const ids: idmap.Mapping = .{
        .uid = .{ .host = st.uid, .sub = .{ .start = 100000, .count = 65536 } },
        .gid = .{ .host = st.gid, .sub = .{ .start = 100000, .count = 65536 } },
    };
    var sub = st;
    sub.uid = 101233;
    sub.gid = 100041;
    try std.testing.expectEqual(dir_walk.Owner{ .uid = 1234, .gid = 42 }, dir_walk.upperOwner(ids, sub));
    try std.testing.expectEqual(dir_walk.Owner{ .uid = 0, .gid = 0 }, dir_walk.upperOwner(ids, st));

    var rec: std.ArrayList(u8) = .empty;
    try dir_walk.appendOwner(a, &rec, "home/f", .{ .uid = 1234, .gid = 1234 });
    try dir_walk.appendOwner(a, &rec, "odd name", .{ .uid = 7, .gid = 8 });
    var owners = try dir_walk.parseOwners(a, rec.items);
    try std.testing.expectEqual(dir_walk.Owner{ .uid = 7, .gid = 8 }, owners.get("odd name").?);
    try std.testing.expectError(error.BadOwners, dir_walk.parseOwners(a, "x 1 p\x00"));

    var w = try dir_walk.Walker.init(a, fx.path("store"), .{ .mode = .overlay_upper, .ids = ids, .owners = &owners });
    defer w.deinit();
    try w.add(fx.path("upper"), "");
    const tree = (try w.finish()).tree;
    try std.testing.expectEqual(@as(u32, 1234), tree.lookup("home/f").?.uid);
    try std.testing.expectEqual(@as(u32, 0), tree.lookup("home").?.uid);
    try std.testing.expectEqual(@as(u32, 0), tree.lookup("g").?.gid);
}
