const std = @import("std");
const Hub = @import("Hub.zig").Hub;

test "hub configure and copy" {
    var hub: Hub = .{};
    try hub.configure(std.testing.allocator, "https://registry.example", "tok", "org");
    const copy = hub.getConfigCopy(std.testing.allocator) orelse return error.TestExpectedEqual;
    defer {
        std.testing.allocator.free(copy.base_url);
        std.testing.allocator.free(copy.token);
        std.testing.allocator.free(copy.org);
    }
    try std.testing.expectEqualStrings("https://registry.example/registry", copy.base_url);
    hub.deinit(std.testing.allocator);
}
