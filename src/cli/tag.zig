const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const voila_image_tag = @import("registry").voila_image_tag;

/// `voila tag <source> <target>`, like `docker tag`.
pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    var root: ?[]const u8 = null;
    defer if (root) |r| gpa.free(r);
    var refs: [2][]const u8 = undefined;
    var n: usize = 0;
    while (ctx.args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root") or std.mem.eql(u8, arg, "-root")) {
            if (root) |r| gpa.free(r);
            root = try gpa.dupe(u8, ctx.args.next() orelse return error.BadRunArgs);
            continue;
        }
        if (n == refs.len) return error.BadRunArgs;
        refs[n] = arg;
        n += 1;
    }
    if (n != 2) return error.NeedImage;
    const store_root = try flags.resolveStoreRoot(gpa, root);
    defer gpa.free(store_root);
    voila_image_tag.tagImage(gpa, store_root, refs[0], refs[1]) catch |e| switch (e) {
        error.NoImageMatch, error.SqliteOpen, error.SqlitePrepare => {
            std.debug.print("voila tag: no such image {s}\n", .{refs[0]});
            std.process.exit(1);
        },
        else => return e,
    };
}
