const std = @import("std");
const voila_login_creds = @import("registry").voila_login_creds;

pub fn run(allocator: std.mem.Allocator) !void {
    try voila_login_creds.deleteLoginCreds(allocator);
    std.debug.print("logged out\n", .{});
}
