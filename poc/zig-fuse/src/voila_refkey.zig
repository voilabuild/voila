const std = @import("std");
const hex_util = @import("hex_util.zig");

/// Matches imagestore.RefKey: sanitize ref + 8-hex sha256 suffix.
pub fn refKey(allocator: std.mem.Allocator, ref: []const u8) ![]const u8 {
    var sanitized: std.ArrayList(u8) = .empty;
    for (ref) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        try sanitized.append(allocator, if (ok) c else '_');
    }
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ref, &hash, .{});
    var hex8: [8]u8 = undefined;
    hex_util.encodeHexLower(&hex8, hash[0..4]);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ sanitized.items, &hex8 });
}

/// Matches imagestore.LooksLikeRef (':' or '/' present).
pub fn looksLikeRef(query: []const u8) bool {
    for (query) |c| {
        if (c == ':' or c == '/') return true;
    }
    return false;
}
