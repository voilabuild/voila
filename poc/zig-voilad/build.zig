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

fn createStaticBlake3(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    blake3_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const c_root = blake3_dep.path("c");
    const lib = b.addLibrary(.{
        .name = "blake3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addCSourceFiles(.{
        .root = c_root,
        .files = &.{
            "blake3.c",
            "blake3_dispatch.c",
            "blake3_portable.c",
        },
    });
    lib.root_module.addIncludePath(c_root);
    return lib;
}

fn linkStaticBlake3(mod: *std.Build.Module, blake3_lib: *std.Build.Step.Compile) void {
    mod.linkLibrary(blake3_lib);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuse = "../zig-fuse";

    const blake3_dep = b.dependency("blake3", .{
        .target = target,
        .optimize = optimize,
    });
    const blake3_lib = createStaticBlake3(b, target, optimize, blake3_dep);

    const blake3_translate = b.addTranslateC(.{
        .root_source_file = b.path(fuse ++ "/src/blake3_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    blake3_translate.addIncludePath(blake3_dep.path("c"));
    const blake3_mod = blake3_translate.createModule();
    linkStaticBlake3(blake3_mod, blake3_lib);

    const zstd_translate = b.addTranslateC(.{
        .root_source_file = b.path(fuse ++ "/src/zstd_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zstd_mod = zstd_translate.createModule();
    linkStaticZstd(b, target, optimize, zstd_mod);

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path(fuse ++ "/src/sqlite_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const sqlite_mod = sqlite_translate.createModule();
    sqlite_mod.linkSystemLibrary("sqlite3", .{});

    const hex_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/hex_util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ocireg_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_ocireg.zig"),
        .target = target,
        .optimize = optimize,
    });

    const voila_resolve_mod = b.createModule(.{
        .root_source_file = b.path("src/voila_resolve.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = sqlite_mod },
            .{ .name = "voila_ocireg", .module = ocireg_mod },
            .{ .name = "hex_util", .module = hex_mod },
        },
    });
    voila_resolve_mod.linkSystemLibrary("sqlite3", .{});

    const compile_grpc = b.addSystemCommand(&.{ "bash", "scripts/compile_grpc.sh" });
    compile_grpc.setCwd(b.path("."));

    const grpc_shim_mod = b.createModule(.{
        .root_source_file = b.path("src/grpc_shim.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const posix_util_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/posix_util.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const launch_mod = b.createModule(.{
        .root_source_file = b.path("src/launch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "voila_resolve", .module = voila_resolve_mod },
            .{ .name = "grpc_shim", .module = grpc_shim_mod },
            .{ .name = "posix_util", .module = posix_util_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "launch", .module = launch_mod },
            .{ .name = "grpc_shim", .module = grpc_shim_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    root_mod.link_libcpp = false;

    const zig_obj = b.addObject(.{
        .name = "zig_voilad_zig",
        .root_module = root_mod,
    });

    const link = b.addSystemCommand(&.{ "bash", "scripts/link_voilad.sh" });
    link.addFileArg(zig_obj.getEmittedBin());
    link.setCwd(b.path("."));
    link.step.dependOn(&zig_obj.step);
    link.step.dependOn(&compile_grpc.step);

    b.getInstallStep().dependOn(&link.step);
}
