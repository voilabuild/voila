const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const container_run = @import("runtime").oci.container_run;

pub const Parsed = struct {
    store_root: []const u8,
    container_id: []const u8,
    remove_on_exit: bool,
    ready_fd: std.posix.fd_t,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var container_id: ?[]const u8 = null;
    var remove_on_exit = false;
    var ready_fd: std.posix.fd_t = -1;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rm")) {
            remove_on_exit = true;
        } else if (std.mem.eql(u8, arg, "-root") or std.mem.eql(u8, arg, "--root")) {
            root = args.next() orelse return error.NeedVoilaRoot;
        } else if (std.mem.eql(u8, arg, "-id")) {
            container_id = args.next() orelse return error.NeedContextId;
        } else if (std.mem.eql(u8, arg, "--ready-fd")) {
            const n = args.next() orelse return error.NeedContextId;
            ready_fd = std.fmt.parseInt(i32, n, 10) catch return error.NeedContextId;
        }
    }
    const r = root orelse return error.NeedVoilaRoot;
    const id = container_id orelse return error.NeedContextId;
    return .{
        .store_root = try flags.resolveAbs(allocator, r),
        .container_id = try allocator.dupe(u8, id),
        .remove_on_exit = remove_on_exit,
        .ready_fd = ready_fd,
    };
}

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try parseArgs(gpa, ctx.args);
    defer gpa.free(parsed.store_root);
    defer gpa.free(parsed.container_id);
    const code = try container_run.runWorker(ctx.io, gpa, parsed.store_root, parsed.container_id, parsed.remove_on_exit, parsed.ready_fd);
    std.process.exit(code);
}
