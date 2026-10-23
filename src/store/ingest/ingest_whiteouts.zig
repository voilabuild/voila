const std = @import("std");

pub const opaque_base = ".wh..wh..opq";
pub const whiteout_prefix = ".wh.";

pub fn classifyEntry(entry_path: []const u8) struct {
    parent: []const u8,
    name: []const u8,
    explicit: bool,
    is_opaque: bool,
} {
    const base = std.fs.path.basename(entry_path);
    var parent = std.fs.path.dirname(entry_path) orelse "";
    if (std.mem.eql(u8, parent, ".")) parent = "";
    if (std.mem.eql(u8, base, opaque_base)) {
        return .{ .parent = parent, .name = "", .explicit = false, .is_opaque = true };
    }
    if (std.mem.startsWith(u8, base, whiteout_prefix) and base.len > whiteout_prefix.len) {
        return .{ .parent = parent, .name = base[whiteout_prefix.len..], .explicit = true, .is_opaque = false };
    }
    return .{ .parent = parent, .name = "", .explicit = false, .is_opaque = false };
}

pub fn cleanEntryPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "./")) n = n[2..];
    if (n.len == 0 or std.mem.eql(u8, n, ".")) return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, n, "/")) return error.AbsolutePath;
    if (std.mem.eql(u8, n, "..") or std.mem.startsWith(u8, n, "../")) return error.PathEscape;
    return allocator.dupe(u8, n);
}

pub const Error = error{
    BadPath,
    AbsolutePath,
    PathEscape,
};
