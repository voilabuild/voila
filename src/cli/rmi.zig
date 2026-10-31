const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    images: [][]const u8,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        for (self.images) |img| allocator.free(img);
        allocator.free(self.images);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var images: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (images.items) |img| allocator.free(img);
        images.deinit(allocator);
        if (root) |r| allocator.free(r);
    }
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        try images.append(allocator, try allocator.dupe(u8, arg));
    }
    if (images.items.len == 0) return error.NeedImage;
    const cfg = try flags.finishRuntimeConfig(allocator, root, kind);
    root = null;
    return .{
        .runtime_cfg = cfg,
        .images = try images.toOwnedSlice(allocator),
    };
}

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try parseArgs(gpa, ctx.args);
    defer parsed.deinit(gpa);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    var failed = false;
    for (parsed.images) |image| {
        worker.rmi(ctx.io, gpa, .{ .image = image }) catch |e| {
            if (e == error.NoImageMatch) {
                std.debug.print("voila rmi: no such image {s}\n", .{image});
                failed = true;
                continue;
            }
            return e;
        };
    }
    if (failed) std.process.exit(1);
}

test "rmi parseArgs keeps every image" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "--root", "/voila-test-root", "a:1", "b:2" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    const parsed = try parseArgs(alloc, &it);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), parsed.images.len);
    try std.testing.expectEqualStrings("a:1", parsed.images[0]);
    try std.testing.expectEqualStrings("b:2", parsed.images[1]);
}
