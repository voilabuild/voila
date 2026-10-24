const std = @import("std");
const fs = @import("sys").fs;
const dir_walk = @import("store").ingest.ingest_dir_walk;
const manifest_mod = @import("store").ingest.ingest_manifest;
const voila_tree = @import("store").voila_tree;
const VoilaVfs = @import("voila_vfs.zig").VoilaVfs;
const mount_exec = @import("../mount_exec.zig");
const fuse_vfs_mod = @import("./fuse_vfs.zig");

test "reads through the vfs keep the chunk cache bounded" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try fs.makeTempDir(gpa, "voila-vfs-test");
    defer gpa.free(tmp);
    defer fs.removeTree(gpa, tmp) catch {};
    const src = try std.fmt.allocPrint(a, "{s}/src", .{tmp});
    const store = try std.fmt.allocPrint(a, "{s}/store", .{tmp});
    try fs.makePath(src);
    try fs.makePath(store);

    const n_files = 100;
    for (0..n_files) |i| {
        const name = try std.fmt.allocPrint(a, "{s}/f{d}", .{ src, i });
        try fs.writeFile(name, try std.fmt.allocPrint(a, "file {d}\n", .{i}), 0o644);
    }
    var w = try dir_walk.Walker.init(a, store, .{ .mode = .copy });
    defer w.deinit();
    try w.add(src, "");
    const tree = (try w.finish()).tree;
    const root = try manifest_mod.buildAndStoreManifest(a, store, tree, false);

    var vfs = VoilaVfs.initFromTree(gpa, try voila_tree.openTree(gpa, store, &root, null));
    defer vfs.deinit();
    for (0..2) |_| for (0..n_files) |i| {
        const path = try std.fmt.allocPrint(a, "/f{d}", .{i});
        const ino = vfs.inoFromPath(path).?;
        var buf: [64]u8 = undefined;
        const got = vfs.readFuse(ino, &buf, 0);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "file {d}\n", .{i}), buf[0..got]);
        try std.testing.expect(vfs.chunk_cache.count() <= 64);
    };
}

test "inoFromPath follows a symlinked directory prefix (/bin -> usr/bin)" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try fs.makeTempDir(gpa, "voila-vfs-symlink");
    defer gpa.free(tmp);
    defer fs.removeTree(gpa, tmp) catch {};
    const src = try std.fmt.allocPrint(a, "{s}/src", .{tmp});
    const store = try std.fmt.allocPrint(a, "{s}/store", .{tmp});
    try fs.makePath(try std.fmt.allocPrint(a, "{s}/usr/bin", .{src}));
    try fs.writeFile(try std.fmt.allocPrint(a, "{s}/usr/bin/sh", .{src}), "#!/bin/sh\n", 0o755);
    try fs.symlink("usr/bin", try std.fmt.allocPrint(a, "{s}/bin", .{src}));

    var w = try dir_walk.Walker.init(a, store, .{ .mode = .copy });
    defer w.deinit();
    try w.add(src, "");
    const tree = (try w.finish()).tree;
    const root = try manifest_mod.buildAndStoreManifest(a, store, tree, false);

    var vfs = VoilaVfs.initFromTree(gpa, try voila_tree.openTree(gpa, store, &root, null));
    try std.testing.expect(vfs.inoFromPath("/usr/bin/sh") != null);
    try std.testing.expect(vfs.inoFromPath("/bin/sh") != null);

    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = vfs };
    defer fuse_vfs.deinit();
    const exec = try mount_exec.resolveArgv0VfsPath(gpa, &fuse_vfs, "/bin/sh");
    defer gpa.free(exec);
    try std.testing.expectEqualStrings("/bin/sh", exec);
}
