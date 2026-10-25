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
        .compression = true,
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
    switch (target.result.cpu.arch) {
        .x86_64 => {
            if (target.result.os.tag == .windows) {
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_sse2_x86-64_windows_gnu.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_sse41_x86-64_windows_gnu.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_avx2_x86-64_windows_gnu.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_avx512_x86-64_windows_gnu.S"));
            } else {
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_sse2_x86-64_unix.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_sse41_x86-64_unix.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_avx2_x86-64_unix.S"));
                lib.root_module.addAssemblyFile(blake3_dep.path("c/blake3_avx512_x86-64_unix.S"));
            }
        },
        .aarch64, .aarch64_be => {
            lib.root_module.addCSourceFiles(.{
                .root = c_root,
                .files = &.{"blake3_neon.c"},
            });
        },
        else => {},
    }
    lib.root_module.addIncludePath(c_root);
    return lib;
}

fn linkStaticBlake3(mod: *std.Build.Module, blake3_lib: *std.Build.Step.Compile) void {
    mod.linkLibrary(blake3_lib);
}

const Layer = struct {
    name: []const u8,
    /// Lower layers this one may import.
    deps: []const []const u8,
    /// Third-party and C modules this one may import.
    ext: []const []const u8,
};

const CLibs = struct {
    fuse: *std.Build.Step.Compile,
    sqlite: *std.Build.Step.Compile,
    blake3: *std.Build.Step.Compile,
};

fn linkCLibs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    libs: CLibs,
) void {
    mod.linkLibrary(libs.fuse);
    mod.linkLibrary(libs.sqlite);
    linkStaticZstd(b, target, optimize, mod);
    linkStaticBlake3(mod, libs.blake3);
}

const fuse_c_flags = [_][]const u8{
    "-std=gnu11",
    "-D_GNU_SOURCE",
    "-D_REENTRANT",
    "-D_FILE_OFFSET_BITS=64",
    "-DHAVE_LIBFUSE_PRIVATE_CONFIG_H",
    "-DFUSE_USE_VERSION=317",
    "-DFUSERMOUNT_DIR=\"/usr/bin\"",
};

fn createStaticFuse(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const fuse_dep = b.dependency("libfuse", .{});
    const lib = b.addLibrary(.{
        .name = "fuse3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(b.path("src/c"));
    lib.root_module.addIncludePath(fuse_dep.path("include"));
    lib.root_module.addIncludePath(fuse_dep.path("lib"));
    lib.root_module.addCSourceFiles(.{
        .root = fuse_dep.path("lib"),
        .files = &.{
            "fuse.c",
            "fuse_loop.c",
            "fuse_loop_mt.c",
            "fuse_lowlevel.c",
            "fuse_opt.c",
            "fuse_signals.c",
            "buffer.c",
            "cuse_lowlevel.c",
            "helper.c",
            "modules/subdir.c",
            "mount_util.c",
            "fuse_log.c",
            "compat.c",
            "util.c",
            "mount.c",
        },
        .flags = &fuse_c_flags,
    });
    lib.root_module.addCSourceFiles(.{
        .root = b.path("src/c"),
        .files = &.{"fuse3_shim.c"},
        .flags = &fuse_c_flags,
    });
    lib.root_module.addIncludePath(b.path("src/c"));
    return lib;
}

fn addFuse3Module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fuse_lib: *std.Build.Step.Compile,
) *std.Build.Module {
    const fuse_dep = b.dependency("libfuse", .{});
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/fuse3_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(b.path("src/c"));
    translate.addIncludePath(fuse_dep.path("include"));
    translate.addIncludePath(b.path("src/c"));
    const mod = translate.createModule();
    mod.linkLibrary(fuse_lib);
    return mod;
}

fn createStaticSqlite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const sqlite_dep = b.dependency("sqlite", .{});
    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(sqlite_dep.path("."));
    lib.root_module.addCSourceFiles(.{
        .root = sqlite_dep.path("."),
        .files = &.{"sqlite3.c"},
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
        },
    });
    return lib;
}

pub fn build(b: *std.Build) void {
    // musl by default so `zig build` emits one static binary. GNU libc cannot
    // be statically linked; a dynamic glibc CLI breaks across FUSE SONAMEs.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    const privileged = b.option(bool, "privileged", "Run tests needing /dev/fuse and user namespaces") orelse false;
    const test_options = b.addOptions();
    test_options.addOption(bool, "privileged", privileged);

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const blake3_dep = b.dependency("blake3", .{
        .target = target,
        .optimize = optimize,
    });
    const blake3_lib = createStaticBlake3(b, target, optimize, blake3_dep);

    const blake3_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/blake3_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    blake3_translate.addIncludePath(blake3_dep.path("c"));
    const blake3_mod = blake3_translate.createModule();
    linkStaticBlake3(blake3_mod, blake3_lib);

    const zstd_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/zstd_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zstd_mod = zstd_translate.createModule();
    linkStaticZstd(b, target, optimize, zstd_mod);

    const sqlite_dep = b.dependency("sqlite", .{});
    const sqlite_lib = createStaticSqlite(b, target, optimize);
    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/sqlite_shim.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_translate.addIncludePath(sqlite_dep.path("."));
    const sqlite_mod = sqlite_translate.createModule();
    sqlite_mod.linkLibrary(sqlite_lib);

    const fuse_lib = createStaticFuse(b, target, optimize);
    const fuse3_mod = addFuse3Module(b, target, optimize, fuse_lib);

    const ext: []const std.Build.Module.Import = &.{
        .{ .name = "zio", .module = zio.module("zio") },
        .{ .name = "fuse3", .module = fuse3_mod },
        .{ .name = "zstd", .module = zstd_mod },
        .{ .name = "blake3_c", .module = blake3_mod },
        .{ .name = "sqlite_c", .module = sqlite_mod },
        .{ .name = "build_options", .module = test_options.createModule() },
    };

    // One module per layer. Each may import only the layers listed before it
    // (AGENTS.md § Layers), so an upward import fails to compile. C bindings
    // are scoped the same way.
    const layer_specs = [_]Layer{
        .{ .name = "core", .deps = &.{}, .ext = &.{} },
        .{ .name = "codec", .deps = &.{"core"}, .ext = &.{} },
        .{ .name = "sys", .deps = &.{"core"}, .ext = &.{"build_options"} },
        .{ .name = "store", .deps = &.{ "core", "codec", "sys" }, .ext = &.{ "blake3_c", "sqlite_c", "zstd" } },
        .{ .name = "registry", .deps = &.{ "core", "codec", "sys", "store" }, .ext = &.{"sqlite_c"} },
        .{ .name = "mount", .deps = &.{ "core", "codec", "sys", "store", "registry" }, .ext = &.{ "fuse3", "zio" } },
        .{ .name = "runtime", .deps = &.{ "core", "codec", "sys", "store", "registry", "mount" }, .ext = &.{} },
        .{ .name = "cli", .deps = &.{ "core", "sys", "registry", "mount", "runtime" }, .ext = &.{} },
        .{ .name = "app", .deps = &.{ "core", "codec", "sys", "store", "registry", "mount", "runtime", "cli" }, .ext = &.{"zio"} },
    };
    var layers: [layer_specs.len]*std.Build.Module = undefined;
    for (layer_specs, 0..) |spec, i| {
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        for (spec.ext) |name| {
            const e = for (ext) |imp| {
                if (std.mem.eql(u8, imp.name, name)) break imp;
            } else std.debug.panic("layer {s}: unknown external module {s}", .{ spec.name, name });
            imports.append(b.allocator, e) catch @panic("OOM");
        }
        for (spec.deps) |dep| {
            const j = for (layer_specs[0..i], 0..) |prev, k| {
                if (std.mem.eql(u8, prev.name, dep)) break k;
            } else std.debug.panic("layer {s}: {s} must come first", .{ spec.name, dep });
            imports.append(b.allocator, .{ .name = dep, .module = layers[j] }) catch @panic("OOM");
        }
        layers[i] = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{spec.name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports.items,
        });
    }
    const app_mod = layers[layers.len - 1];

    const root_mod = b.createModule(.{
        .root_source_file = b.path("cmd/voila/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "voila",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    for (layers) |layer| {
        const unit_tests = b.addTest(.{ .root_module = layer });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
