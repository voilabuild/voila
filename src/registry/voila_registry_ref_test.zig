const std = @import("std");
const registry_ref = @import("./voila_registry_ref.zig");

test "normalize bare alpine to latest tag" {
    const gpa = std.testing.allocator;
    const n = try registry_ref.normalizeUserRef(gpa, "alpine");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("alpine:latest", n);
}

test "pull candidates include org and test catalog" {
    const gpa = std.testing.allocator;
    const list = try registry_ref.registryPullCandidates(gpa, "python:3.13", "saucisse");
    defer {
        for (list) |c| gpa.free(c);
        gpa.free(list);
    }
    try std.testing.expect(list.len >= 3);
    var saw_test = false;
    var saw_org = false;
    for (list) |c| {
        if (std.mem.eql(u8, c, "test/python:3.13")) saw_test = true;
        if (std.mem.eql(u8, c, "saucisse/python:3.13")) saw_org = true;
    }
    try std.testing.expect(saw_test);
    try std.testing.expect(saw_org);
}
