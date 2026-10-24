//! Multi-stage builds: stage references, `--target`, and which stages a target needs.
const std = @import("std");
const dockerfile = @import("dockerfile.zig");

pub const Ref = union(enum) {
    stage: usize,
    image: []const u8,
};

pub const Error = dockerfile.Error || error{ UnknownTarget, StageNotFound };

/// Resolves an expanded FROM image or `COPY --from` value seen in stage `current`.
/// Names match earlier stages only; numbers are stage indexes when `allow_index`.
pub fn resolve(df: *const dockerfile.Dockerfile, current: usize, ref: []const u8, allow_index: bool) Error!Ref {
    if (allow_index) if (std.fmt.parseInt(usize, ref, 10)) |i| {
        if (i >= current) return error.StageNotFound;
        return .{ .stage = i };
    } else |_| {};
    var i = current;
    while (i > 0) {
        i -= 1;
        const name = df.stages[i].name;
        if (name.len > 0 and std.ascii.eqlIgnoreCase(name, ref)) return .{ .stage = i };
    }
    return .{ .image = ref };
}

/// Index of the stage named `name` (case-insensitive); empty means the last stage.
pub fn targetIndex(df: *const dockerfile.Dockerfile, name: []const u8) Error!usize {
    if (name.len == 0) return df.stages.len - 1;
    for (df.stages, 0..) |s, i| if (std.ascii.eqlIgnoreCase(s.name, name)) return i;
    return error.UnknownTarget;
}

/// Marks the stages `target` depends on (itself included). References are
/// expanded with `vars` (the global ARGs), as FROM sees them.
pub fn needed(a: std.mem.Allocator, df: *const dockerfile.Dockerfile, target: usize, vars: *const std.StringHashMapUnmanaged([]const u8)) Error![]bool {
    const out = try a.alloc(bool, df.stages.len);
    @memset(out, false);
    out[target] = true;
    var i = target + 1;
    while (i > 0) {
        i -= 1;
        if (!out[i]) continue;
        for (df.stages[i].instructions) |ins| {
            const raw, const allow_index = switch (ins.op) {
                .from => |f| .{ f.image, false },
                .copy => |c| .{ c.from, true },
                else => continue,
            };
            if (raw.len == 0) continue;
            const ref = try dockerfile.expand(a, raw, vars);
            switch (resolve(df, i, ref, allow_index) catch continue) {
                .stage => |d| out[d] = true,
                .image => {},
            }
        }
    }
    return out;
}

const testing = std.testing;

test "stage resolution, target and dependency pruning" {
    var diag: dockerfile.Diagnostic = .{};
    var df = try dockerfile.parse(testing.allocator,
        \\ARG B=base
        \\FROM alpine AS base
        \\FROM ${B} AS tools
        \\FROM alpine AS unused
        \\FROM scratch AS final
        \\COPY --from=tools /a /a
        \\COPY --from=busybox:1 /bin/sh /bin/
    , &diag);
    defer df.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(Ref{ .stage = 0 }, try resolve(&df, 1, "BASE", false));
    try testing.expectEqualStrings("base", (try resolve(&df, 0, "base", false)).image);
    try testing.expectEqualStrings("7", (try resolve(&df, 3, "7", false)).image);
    try testing.expectEqual(Ref{ .stage = 2 }, try resolve(&df, 3, "2", true));
    try testing.expectError(error.StageNotFound, resolve(&df, 1, "1", true));

    try testing.expectEqual(@as(usize, 3), try targetIndex(&df, ""));
    try testing.expectEqual(@as(usize, 1), try targetIndex(&df, "Tools"));
    try testing.expectError(error.UnknownTarget, targetIndex(&df, "nope"));

    var vars: std.StringHashMapUnmanaged([]const u8) = .empty;
    try vars.put(a, "B", "base");
    try testing.expectEqualSlices(bool, &.{ true, true, false, true }, try needed(a, &df, 3, &vars));
    try testing.expectEqualSlices(bool, &.{ false, false, true, false }, try needed(a, &df, 2, &vars));
}
