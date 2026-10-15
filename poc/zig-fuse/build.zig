const std = @import("std");

fn linkStaticZstd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
) void {
    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .compression = false,
        .decompression = true,
        .dictbuilder = false,
        .deprecated = false,
    });
    mod.linkLibrary(zstd_dep.artifact("zstd"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const zstd_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/zstd_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zstd_mod = zstd_translate.createModule();
    linkStaticZstd(b, target, optimize, zstd_mod);

    const fuse3_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/fuse3_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuse3_translate.addSystemIncludePath(.{ .cwd_relative = "/usr/include/fuse3" });
    const fuse3_mod = fuse3_translate.createModule();
    fuse3_mod.linkSystemLibrary("fuse3", .{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "fuse3", .module = fuse3_mod },
            .{ .name = "zstd", .module = zstd_mod },
        },
    });
    root_mod.linkSystemLibrary("fuse3", .{});
    root_mod.linkSystemLibrary("pthread", .{});
    linkStaticZstd(b, target, optimize, root_mod);

    const exe = b.addExecutable(.{
        .name = "zig-fuse",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuse_abi_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_abi_tests = b.addRunArtifact(tests);

    const walker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/read_walker.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(walker_tests);

    const voila_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/voila_store.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zstd", .module = zstd_mod },
            },
        }),
    });
    linkStaticZstd(b, target, optimize, voila_store_tests.root_module);
    const run_voila_store_tests = b.addRunArtifact(voila_store_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_abi_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_voila_store_tests.step);
}
