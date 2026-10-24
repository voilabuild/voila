const std = @import("std");
const fs = @import("../../sys/fs.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");
const manifest_mod = @import("../../store/ingest/ingest_manifest.zig");
const voila_tree = @import("../../core/voila_tree.zig");
const VoilaVfs = @import("voila_vfs.zig").VoilaVfs;

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

    var vfs = VoilaVfs.initFromTree(gpa, try voila_tree.openTree(gpa, store, &root));
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
