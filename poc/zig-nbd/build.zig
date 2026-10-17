const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-nbd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    b.installArtifact(exe);

    const test_modules = [_]std.Build.LazyPath{
        b.path("src/backend.zig"),
        b.path("src/capacity_wait.zig"),
        b.path("src/erofs_build.zig"),
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_modules) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = root,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zio", .module = zio.module("zio") },
                },
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
