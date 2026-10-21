const std = @import("std");
const posix_util = @import("posix_util.zig");

pub const default_registry_url = "https://drift-registry-production.up.railway.app/registry";

/// XDG config path: ~/.config/voila/credentials
pub fn loginCredsPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/voila/credentials", .{std.mem.span(home)});
}

pub fn defaultVoilaRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("VOILA_ROOT")) |p| return allocator.dupe(u8, std.mem.span(p));
    if (posix_util.access("/var/lib/voila")) {
        return allocator.dupe(u8, "/var/lib/voila");
    }
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/voila", .{std.mem.span(home)});
}

pub fn normalizeRegistryUrl(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0) return error.EmptyRegistry;
    if (std.mem.endsWith(u8, s, "/registry")) return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "{s}/registry", .{s});
}

pub const Error = error{
    NoHome,
    EmptyRegistry,
};
