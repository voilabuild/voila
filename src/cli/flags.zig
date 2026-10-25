//! Shared CLI flags (`-root`, `-backend`) and path helpers.

const std = @import("std");
const voila_runtime = @import("runtime").open;
const voila_paths = @import("sys").voila_paths;

pub fn parseBackendArg(arg: []const u8) ?voila_runtime.Kind {
    if (std.mem.eql(u8, arg, "local")) return .local;
    if (std.mem.eql(u8, arg, "remote")) return .remote;
    return null;
}

pub fn resolveStoreRoot(allocator: std.mem.Allocator, root: ?[]const u8) ![]const u8 {
    if (root) |r| return resolveAbs(allocator, r);
    return voila_paths.defaultVoilaRoot(allocator);
}

pub fn resolveAbs(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return allocator.dupe(u8, path);
    var cwd: [4096]u8 = undefined;
    const cwd_rc = std.os.linux.getcwd(cwd[0..].ptr, cwd.len);
    const cwd_err = std.posix.errno(cwd_rc);
    if (cwd_err != .SUCCESS) return allocator.dupe(u8, path);
    const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd[0..].ptr)), 0);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_slice, path });
}

pub fn tryRuntimeFlag(
    allocator: std.mem.Allocator,
    arg: []const u8,
    args: *std.process.Args.Iterator,
    root: *?[]const u8,
    kind: *voila_runtime.Kind,
) !bool {
    if (std.mem.eql(u8, arg, "-root")) {
        const r = args.next() orelse return error.NeedVoilaRoot;
        if (root.*) |owned| allocator.free(owned);
        root.* = try allocator.dupe(u8, r);
        return true;
    }
    if (std.mem.eql(u8, arg, "-backend")) {
        const b = args.next() orelse return error.BadRunArgs;
        kind.* = parseBackendArg(b) orelse return error.BadRunArgs;
        return true;
    }
    return false;
}

pub fn finishRuntimeConfig(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    kind: voila_runtime.Kind,
) !voila_runtime.Config {
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{ .kind = kind, .store_root = root_abs };
}
