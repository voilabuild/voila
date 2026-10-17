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

fn addCurlBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    header: std.Build.LazyPath,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    return translate.createModule();
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

    const curl_mod = addCurlBindings(b, target, optimize, b.path(fuse ++ "/src/curl_shim.h"));

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

    const voila_http_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_http.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "curl_c", .module = curl_mod },
        },
    });

    const voila_registry_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_registry_hub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const voila_refkey_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_refkey.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hex_util", .module = hex_mod },
        },
    });

    const voila_manifest_json_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_manifest_json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const posix_util_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/posix_util.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const voilad_nbd_mod = b.createModule(.{
        .root_source_file = b.path("../zig-nbd/src/voilad_bundle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const voila_image_pull_mod = b.createModule(.{
        .root_source_file = b.path(fuse ++ "/src/voila_image_pull.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = sqlite_mod },
            .{ .name = "voila_http", .module = voila_http_mod },
            .{ .name = "voila_manifest_json", .module = voila_manifest_json_mod },
            .{ .name = "voila_refkey", .module = voila_refkey_mod },
            .{ .name = "voila_registry", .module = voila_registry_mod },
            .{ .name = "voila_ocireg", .module = ocireg_mod },
            .{ .name = "posix_util", .module = posix_util_mod },
        },
    });
    voila_image_pull_mod.linkSystemLibrary("sqlite3", .{});

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

    const image_totals_mod = b.createModule(.{
        .root_source_file = b.path("src/image_totals.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = sqlite_mod },
        },
    });
    image_totals_mod.linkSystemLibrary("sqlite3", .{});

    const registry_creds_mod = b.createModule(.{
        .root_source_file = b.path("src/registry_creds.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "posix_util", .module = posix_util_mod },
        },
    });

    const compile_grpc = b.addSystemCommand(&.{ "bash", "scripts/compile_grpc.sh" });
    compile_grpc.setCwd(b.path("."));

    const grpc_shim_mod = b.createModule(.{
        .root_source_file = b.path("src/grpc_shim.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mount_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/mount_backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "posix_util", .module = posix_util_mod },
            .{ .name = "voilad_nbd", .module = voilad_nbd_mod },
        },
    });

    const erofs_mount_mod = b.createModule(.{
        .root_source_file = b.path("src/erofs_mount.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "posix_util", .module = posix_util_mod },
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "voilad_nbd", .module = voilad_nbd_mod },
            .{ .name = "mount_backend", .module = mount_backend_mod },
        },
    });

    const sync_util_mod = b.createModule(.{
        .root_source_file = b.path("src/sync_util.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ring_mod = b.createModule(.{
        .root_source_file = b.path("src/ring.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_util", .module = sync_util_mod },
        },
    });

    const events_mod = b.createModule(.{
        .root_source_file = b.path("src/events.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_util", .module = sync_util_mod },
        },
    });

    const contexts_mod = b.createModule(.{
        .root_source_file = b.path("src/contexts.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ring", .module = ring_mod },
            .{ .name = "events", .module = events_mod },
            .{ .name = "sync_util", .module = sync_util_mod },
        },
    });

    const registry_global_mod = b.createModule(.{
        .root_source_file = b.path("src/registry_global.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contexts", .module = contexts_mod },
        },
    });

    const launch_mod = b.createModule(.{
        .root_source_file = b.path("src/launch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "voila_resolve", .module = voila_resolve_mod },
            .{ .name = "voila_image_pull", .module = voila_image_pull_mod },
            .{ .name = "voila_registry", .module = voila_registry_mod },
            .{ .name = "image_totals", .module = image_totals_mod },
            .{ .name = "grpc_shim", .module = grpc_shim_mod },
            .{ .name = "posix_util", .module = posix_util_mod },
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "contexts", .module = contexts_mod },
            .{ .name = "registry_global", .module = registry_global_mod },
            .{ .name = "registry_creds", .module = registry_creds_mod },
            .{ .name = "mount_backend", .module = mount_backend_mod },
            .{ .name = "erofs_mount", .module = erofs_mount_mod },
        },
    });

    const lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("src/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "events", .module = events_mod },
            .{ .name = "ring", .module = ring_mod },
            .{ .name = "launch", .module = launch_mod },
            .{ .name = "grpc_shim", .module = grpc_shim_mod },
            .{ .name = "registry_global", .module = registry_global_mod },
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
            .{ .name = "registry_global", .module = registry_global_mod },
            .{ .name = "lifecycle", .module = lifecycle_mod },
            .{ .name = "registry_creds", .module = registry_creds_mod },
            .{ .name = "voila_registry", .module = voila_registry_mod },
            .{ .name = "mount_backend", .module = mount_backend_mod },
            .{ .name = "erofs_mount", .module = erofs_mount_mod },
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
