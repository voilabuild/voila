const std = @import("std");
const posix_util = @import("sys").posix_util;
const voila_paths = @import("sys").voila_paths;
const voila_http = @import("./voila_http.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");

pub const LoginCreds = struct {
    registry: []const u8,
    token: []const u8,
    org: []const u8,
};

pub fn loadLoginCreds(allocator: std.mem.Allocator) !?LoginCreds {
    const path = try voila_paths.loginCredsPath(allocator);
    defer allocator.free(path);
    const data = posix_util.readFileAlloc(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const obj = parsed.value.object;
    const reg = obj.get("registry");
    const tok = obj.get("token");
    if (reg == null or reg.? != .string) return null;
    const token_slice: []const u8 = if (tok) |t| if (t == .string) t.string else "" else "";
    const org_slice: []const u8 = if (obj.get("org")) |o| if (o == .string) o.string else "" else "";
    return .{
        .registry = try allocator.dupe(u8, reg.?.string),
        .token = try allocator.dupe(u8, token_slice),
        .org = try allocator.dupe(u8, org_slice),
    };
}

pub fn saveLoginCreds(allocator: std.mem.Allocator, registry: []const u8, token: []const u8, org: []const u8) !void {
    const path = try voila_paths.loginCredsPath(allocator);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try posix_util.makePath(dir);
    const out = try std.fmt.allocPrint(allocator, "{{\"registry\":\"{s}\",\"token\":\"{s}\",\"org\":\"{s}\"}}\n", .{
        registry, token, org,
    });
    defer allocator.free(out);
    try writeMode600(path, out);
}

pub fn deleteLoginCreds(allocator: std.mem.Allocator) !void {
    const path = try voila_paths.loginCredsPath(allocator);
    defer allocator.free(path);
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    _ = std.c.unlink(path_z);
}

pub fn probeRegistryAuth(io: std.Io, allocator: std.mem.Allocator, registry_url: []const u8, token: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chunks/missing", .{registry_url});
    defer allocator.free(url);
    const code = try voila_http.httpPostStatus(io, allocator, url, token, "{\"ids\":[]}");
    if (code == 401) return error.InvalidApiKey;
    if (code < 200 or code >= 500) return error.RegistryProbeFailed;
}

pub fn loadIntoHub(allocator: std.mem.Allocator) !void {
    const lc = try loadLoginCreds(allocator);
    if (lc == null) return;
    defer {
        allocator.free(lc.?.registry);
        allocator.free(lc.?.token);
        allocator.free(lc.?.org);
    }
    try voila_registry_hub.configure(allocator, lc.?.registry, lc.?.token, lc.?.org);
}

fn writeMode600(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub const Error = error{
    BadPath,
    FileOpenFailed,
    FileWriteFailed,
    InvalidApiKey,
    RegistryProbeFailed,
};
