const std = @import("std");
const voila_loader = @import("./voila_loader.zig");
const voila_ocireg = @import("../registry/voila_ocireg.zig");
const posix_util = @import("../sys/posix_util.zig");

test "ocireg canonical alpine short ref" {
    const gpa = std.testing.allocator;
    const canon = try voila_ocireg.canonical(gpa, "alpine:latest");
    defer gpa.free(canon.?);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:latest", canon.?);
}

test "load index from voila store when present" {
    const root = "/tmp/voila-bench-fuse";
    if (!posix_util.access(root)) return;
    const gpa = std.testing.allocator;
    var idx = try voila_loader.loadIndex(null, gpa, root, "bench:40m");
    defer idx.deinit();
    try std.testing.expect(idx.root_ino > 0);
    try std.testing.expect(idx.files.count() > 0);
}
