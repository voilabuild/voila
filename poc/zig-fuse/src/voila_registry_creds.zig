const std = @import("std");
const posix_util = @import("posix_util.zig");
const hub = @import("voila_registry_hub.zig");

pub fn loadFromCredsFile(allocator: std.mem.Allocator, voila_root: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/registry.creds", .{voila_root});
    defer allocator.free(path);
    const data = posix_util.readFileAlloc(allocator, path, 64 * 1024) catch return;
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const obj = parsed.value.object;
    const reg = obj.get("registry");
    const tok = obj.get("token");
    if (reg) |v| {
        if (v == .string) {
            const token_slice: []const u8 = if (tok) |t| if (t == .string) t.string else "" else "";
            try hub.configure(allocator, v.string, token_slice);
        }
    }
}
