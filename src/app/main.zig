const std = @import("std");
const zio = @import("zio");
const vfs_mod = @import("mount").fuse.vfs;
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;
const voila_loader = @import("runtime").voila_loader;
const voila_registry = @import("registry").voila_registry;
const voila_registry_creds = @import("registry").voila_registry_creds;
const voila_fetch_stats = @import("registry").voila_fetch_stats;
const voila_runtime = @import("runtime").open;
const _registry_session = @import("registry").registry_session;
const container_run = @import("runtime").oci.container_run;
const voila_image_run_config = @import("runtime").oci.voila_image_run_config;
const container_isolated_exec = @import("runtime").oci.container_isolated_exec;
const container_fuse_sibling = @import("runtime").oci.container_fuse_sibling;
const voila_login_creds = @import("registry").voila_login_creds;
const run_flags = @import("runtime").run_flags;
const voila_image_import = @import("registry").voila_image_import;
const registry_ref_mod = @import("registry").voila_registry_ref;
const build_cmd = @import("./build_cmd.zig");
const cli = @import("cli");

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const zio_rt = try zio.Runtime.init(init.gpa, .{});
    defer zio_rt.deinit();
    const io = zio_rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub_name = args.next() orelse {
        cli.usage.printUsage();
        std.process.exit(2);
    };

    const sub = cli.commands.parse(sub_name) orelse {
        cli.usage.printUsage();
        return;
    };

    switch (sub) {
        .userns_probe => std.process.exit(cli.userns_probe.exitCode()),
        .login => try cli.login.run(io, init),
        .logout => try cli.logout.run(init.gpa),
        .prove => {
            const fixture_dir = args.next() orelse "fixture-out";
            try cli.prove.run(io, init, fixture_dir);
        },
        .prove_store => {
            const voila_root = args.next() orelse return error.NeedVoilaRoot;
            const image = args.next() orelse return error.NeedImage;
            try cli.prove.runStore(io, init, voila_root, image);
        },
        .serve => {
            const fixture_dir = args.next() orelse "fixture-out";
            const mountpoint = args.next() orelse return error.NeedMountpoint;
            const fixture_abs = try cli.flags.resolveAbs(init.gpa, fixture_dir);
            defer init.gpa.free(fixture_abs);
            var fixture_vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
            defer fixture_vfs.deinit();
            try fixture_vfs.preloadAllChunks(io);
            var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .fixture = fixture_vfs };
            try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        },
        .serve_index => {
            const index_path = args.next() orelse return error.NeedIndex;
            const mountpoint = args.next() orelse return error.NeedMountpoint;
            var voila_vfs = try voila_vfs_mod.VoilaVfs.load(init.gpa, index_path);
            defer voila_vfs.deinit();
            var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs };
            try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        },
        .container_fuse_serve => {
            const parsed = try container_fuse_sibling.parseServeCliArgs(init.gpa, &args);
            container_fuse_sibling.runServe(io, parsed);
            std.process.exit(1);
        },
        .container_isolated_exec => {
            const spec = try container_isolated_exec.parseCliArgs(init.gpa, &args);
            const code = container_isolated_exec.run(spec) catch |e| {
                switch (e) {
                    error.UserNamespacesRequired => std.debug.print("voila: cannot enter a user namespace for the image root (re-run install.sh for the AppArmor voila profile)\n", .{}),
                    error.SetupFailed => std.debug.print("voila: cannot set up the image root for {s}\n", .{spec.vfs_argv0}),
                    else => std.debug.print("voila: cannot exec {s} in the image: {s}\n", .{ spec.vfs_argv0, @errorName(e) }),
                }
                std.process.exit(container_isolated_exec.errorExitCode(e));
            };
            std.process.exit(code);
        },
        .container_worker => {
            const parsed = try cli.worker.parseArgs(init.gpa, &args);
            defer init.gpa.free(parsed.store_root);
            defer init.gpa.free(parsed.container_id);
            const code = try container_run.runWorker(io, init.gpa, parsed.store_root, parsed.container_id, parsed.remove_on_exit);
            std.process.exit(code);
        },
        .build => std.process.exit(try build_cmd.run(io, init.gpa, &args)),
        .run => {
            const parsed = try cli.run.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            try _registry_session.prepare(io, init.gpa, parsed.runtime_cfg.store_root);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            var argv = parsed.cmd;
            var default_argv: ?[]const []const u8 = null;
            if (argv.len == 0) {
                default_argv = try voila_image_run_config.defaultArgv(io, init.gpa, parsed.runtime_cfg.store_root, parsed.image, &.{});
                argv = default_argv.?;
            }
            defer if (default_argv) |a| {
                for (a) |s| init.gpa.free(s);
                init.gpa.free(a);
            };
            const image_env = try voila_image_run_config.imageEnv(io, init.gpa, parsed.runtime_cfg.store_root, parsed.image);
            defer {
                for (image_env) |e| {
                    init.gpa.free(e.key);
                    init.gpa.free(e.value);
                }
                init.gpa.free(image_env);
            }
            const env = try std.mem.concat(init.gpa, run_flags.EnvPair, &.{ image_env, parsed.env });
            defer init.gpa.free(env);
            var workdir = parsed.workdir;
            var workdir_from_image: ?[]const u8 = null;
            if (workdir.len == 0) {
                workdir_from_image = try voila_image_run_config.imageWorkdir(io, init.gpa, parsed.runtime_cfg.store_root, parsed.image);
                workdir = workdir_from_image.?;
            }
            defer if (workdir_from_image) |w| init.gpa.free(w);
            const code = worker.run(io, init.gpa, .{
                .image = parsed.image,
                .argv = argv,
                .detach = parsed.detach,
                .name = parsed.name,
                .rm_on_exit = parsed.rm_on_exit,
                .env = env,
                .workdir = workdir,
                .volumes = parsed.volumes,
                .ports = parsed.ports,
                .tty = parsed.tty,
                .interactive = parsed.interactive,
            }) catch |e| {
                if (e == error.UserNamespacesRequired) std.process.exit(1);
                return e;
            };
            std.process.exit(code);
        },
        .exec => {
            const parsed = try cli.exec.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            const code = try worker.exec(io, init.gpa, .{
                .context_id = parsed.context_id,
                .argv = parsed.cmd,
                .tty = parsed.tty,
                .interactive = parsed.interactive,
            });
            std.process.exit(code);
        },
        .ps => {
            const cfg = try cli.runtime_only.parseArgs(init.gpa, &args);
            defer init.gpa.free(cfg.store_root);
            var worker = try openRuntime(init.gpa, cfg);
            defer worker.deinit(init.gpa);
            worker.ps(io, init.gpa) catch |e| {
                if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
                return e;
            };
        },
        .logs => {
            const parsed = try cli.logs.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            worker.logs(io, init.gpa, parsed.opts) catch |e| {
                if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
                return e;
            };
        },
        .pull => {
            const parsed = try cli.pull.parseArgs(init.gpa, &args);
            defer init.gpa.free(parsed.runtime_cfg.store_root);
            defer init.gpa.free(parsed.image);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            try worker.pull(io, init.gpa, .{ .image = parsed.image });
        },
        .push => {
            const parsed = try cli.pull.parseArgs(init.gpa, &args);
            defer init.gpa.free(parsed.runtime_cfg.store_root);
            defer init.gpa.free(parsed.image);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            try worker.push(io, init.gpa, .{ .image = parsed.image });
        },
        .import => {
            const parsed = try cli.pull.parseArgs(init.gpa, &args);
            defer init.gpa.free(parsed.runtime_cfg.store_root);
            defer init.gpa.free(parsed.image);
            try _registry_session.prepare(io, init.gpa, parsed.runtime_cfg.store_root);
            const cfg = voila_registry.getConfigCopy(init.gpa) orelse return error.NoRegistry;
            defer {
                init.gpa.free(cfg.base_url);
                init.gpa.free(cfg.token);
                init.gpa.free(cfg.org);
            }
            const hub_ref = try registry_ref_mod.normalizeUserRef(init.gpa, parsed.image);
            defer init.gpa.free(hub_ref);
            const push_ref = if (cfg.org.len != 0)
                try registry_ref_mod.hubPushRef(init.gpa, hub_ref, cfg.org)
            else
                try init.gpa.dupe(u8, hub_ref);
            defer init.gpa.free(push_ref);
            try voila_image_import.importImage(io, init.gpa, parsed.runtime_cfg.store_root, cfg, hub_ref, push_ref, .{});
        },
        .rmi => {
            const parsed = try cli.rmi.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            try worker.rmi(io, init.gpa, .{ .image = parsed.image });
        },
        .images => {
            const cfg = try cli.runtime_only.parseArgs(init.gpa, &args);
            defer init.gpa.free(cfg.store_root);
            var worker = try openRuntime(init.gpa, cfg);
            defer worker.deinit(init.gpa);
            try worker.images(io, init.gpa);
        },
        .kill => {
            const parsed = try cli.context.parseKillArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            worker.kill(io, init.gpa, parsed.opts) catch |e| {
                if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
                return e;
            };
        },
        .stop => {
            const parsed = try cli.context.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            worker.stop(io, init.gpa, parsed.ref) catch |e| {
                if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
                return e;
            };
        },
        .rm => {
            const parsed = try cli.context.parseArgs(init.gpa, &args);
            defer parsed.deinit(init.gpa);
            var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
            defer worker.deinit(init.gpa);
            worker.rm(io, init.gpa, parsed.ref) catch |e| {
                if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
                return e;
            };
        },
        .serve_store => {
            const voila_root = args.next() orelse return error.NeedVoilaRoot;
            const image = args.next() orelse return error.NeedImage;
            const mountpoint = args.next() orelse return error.NeedMountpoint;
            const stats_path_arg = args.next();
            const voila_root_abs = try cli.flags.resolveAbs(init.gpa, voila_root);
            defer init.gpa.free(voila_root_abs);
            voila_registry.setIo(io, init.gpa);
            try voila_login_creds.loadIntoHub(init.gpa);
            try voila_registry_creds.loadFromCredsFile(init.gpa, voila_root_abs);
            try voila_registry.loadFromEnv(init.gpa);
            voila_fetch_stats.init(init.gpa, stats_path_arg);
            defer voila_fetch_stats.writeStatsFile();
            const chunks_arg = args.next();
            const bytes_arg = args.next();
            if (chunks_arg) |c| {
                const chunks = std.fmt.parseInt(u64, c, 10) catch 0;
                var bytes: u64 = 0;
                if (bytes_arg) |b| bytes = std.fmt.parseInt(u64, b, 10) catch 0;
                voila_fetch_stats.setImageTotals(chunks, bytes);
            }
            const tree = try voila_loader.loadTreeRoot(io, init.gpa, voila_root_abs, image);
            var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(init.gpa, tree) };
            defer fuse_vfs.deinit();
            try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        },
    }
}

fn openRuntime(allocator: std.mem.Allocator, cfg: voila_runtime.Config) !voila_runtime.Runtime {
    return voila_runtime.open(allocator, cfg);
}
