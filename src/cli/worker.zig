const std = @import("std");
const flags = @import("flags.zig");

pub const Parsed = struct {
    store_root: []const u8,
    container_id: []const u8,
    remove_on_exit: bool,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var container_id: ?[]const u8 = null;
    var remove_on_exit = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rm")) {
            remove_on_exit = true;
        } else if (std.mem.eql(u8, arg, "-root")) {
            root = args.next() orelse return error.NeedVoilaRoot;
        } else if (std.mem.eql(u8, arg, "-id")) {
            container_id = args.next() orelse return error.NeedContextId;
        }
    }
    const r = root orelse return error.NeedVoilaRoot;
    const id = container_id orelse return error.NeedContextId;
    return .{
        .store_root = try flags.resolveAbs(allocator, r),
        .container_id = try allocator.dupe(u8, id),
        .remove_on_exit = remove_on_exit,
    };
}
