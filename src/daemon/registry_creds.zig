const std = @import("std");
const posix_util = @import("posix_util");

pub const RegistryCreds = struct {
    registry: []const u8,
    token: []const u8,
};

pub fn path(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/registry.creds", .{root});
}

pub fn load(allocator: std.mem.Allocator, root: []const u8) !RegistryCreds {
    const p = try path(allocator, root);
    defer allocator.free(p);
    const data = posix_util.readFileAlloc(allocator, p, 64 * 1024) catch return .{ .registry = "", .token = "" };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const obj = parsed.value.object;
    const reg = obj.get("registry");
    const tok = obj.get("token");
    return .{
        .registry = if (reg) |v| try dupJsonStr(allocator, v) else "",
        .token = if (tok) |v| try dupJsonStr(allocator, v) else "",
    };
}

pub fn write(allocator: std.mem.Allocator, root: []const u8, registry_url: []const u8, token: []const u8) !void {
    if (registry_url.len == 0) return error.EmptyRegistry;
    const p = try path(allocator, root);
    defer allocator.free(p);
    const parent = std.fs.path.dirname(p) orelse root;
    const mkdir_cmd = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{parent});
    defer allocator.free(mkdir_cmd);
    const mkdir_z = try allocator.allocSentinel(u8, mkdir_cmd.len, 0);
    defer allocator.free(mkdir_z);
    @memcpy(mkdir_z, mkdir_cmd);
    _ = posix_util.shell(mkdir_z);
    const body = try std.fmt.allocPrint(allocator, "{{\"registry\":\"{s}\",\"token\":\"{s}\"}}\n", .{ registry_url, token });
    defer allocator.free(body);
    const p_z = try allocator.allocSentinel(u8, p.len, 0);
    defer allocator.free(p_z);
    @memcpy(p_z, p);
    const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < body.len) {
        const n = std.c.write(fd, body[off..].ptr, body.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn dupJsonStr(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    if (v != .string) return allocator.alloc(u8, 0);
    return allocator.dupe(u8, v.string);
}

pub const Error = error{
    EmptyRegistry,
    WriteFailed,
};
