//! User-facing messages for CLI errors. Subcommands return errors; `app` prints these.
const std = @import("std");

pub fn print(err: anyerror) void {
    switch (err) {
        error.SqlitePrepare, error.NoImageMatch => {
            std.debug.print("voila: image not found locally; run `voila import <ref>`\n", .{});
        },
        error.SqliteOpen => {
            std.debug.print("voila: cannot open the image store (check VOILA_ROOT)\n", .{});
        },
        error.FetchFailed, error.HttpStatus => {
            std.debug.print("voila: registry request failed (chunk missing or not authorized)\n", .{});
        },
        error.ExecNotFound => {
            std.debug.print("voila: command not found in image\n", .{});
        },
        error.AccessDenied => {
            std.debug.print("voila: permission denied\n", .{});
        },
        error.NameInUse => {
            std.debug.print("voila: container name is already in use; `voila rm <name>` first\n", .{});
        },
        error.NotFound => {
            std.debug.print("voila: no such container\n", .{});
        },
        error.NotRunning => {
            std.debug.print("voila: container is not running\n", .{});
        },
        error.NoRegistry => {
            std.debug.print("voila: no registry configured (run `voila login`)\n", .{});
        },
        error.NeedImage => {
            std.debug.print("voila: missing image ref\n", .{});
        },
        error.NeedCommand => {
            std.debug.print("voila: missing command\n", .{});
        },
        error.NeedContextId => {
            std.debug.print("voila: missing container id\n", .{});
        },
        error.NeedTag, error.NeedContext, error.BadBuildArgs => {
            std.debug.print("voila: bad build arguments\n", .{});
        },
        error.NeedVoilaRoot, error.BadRunArgs => {
            std.debug.print("voila: bad arguments\n", .{});
        },
        error.UnknownFlag => {
            std.debug.print("voila: unknown flag\n", .{});
        },
        error.NeedFuse, error.UserNamespacesRequired, error.FuseServerFailed, error.OverlayFailed, error.MountFailed, error.MountNotReady => {
            std.debug.print("voila: could not set up the sandbox (needs /dev/fuse and user namespaces)\n", .{});
        },
        error.InvalidApiKey => {
            std.debug.print("voila: invalid API key (run `voila login`)\n", .{});
        },
        else => {
            std.debug.print("voila: {s} (please report this with `voila --version`)\n", .{@errorName(err)});
        },
    }
}

pub fn exitStatus(err: anyerror) u8 {
    return switch (err) {
        error.ExecNotFound => 127,
        error.NeedFuse,
        error.UserNamespacesRequired,
        error.FuseServerFailed,
        error.OverlayFailed,
        error.MountFailed,
        error.MountNotReady,
        => 125,
        error.UnknownFlag,
        error.BadRunArgs,
        error.NeedImage,
        error.NeedCommand,
        error.NeedContextId,
        error.NeedTag,
        error.NeedContext,
        error.BadBuildArgs,
        error.NeedVoilaRoot,
        => 2,
        else => 1,
    };
}

test "ExecNotFound is 127 and SqlitePrepare is not a Zig name in the message" {
    try std.testing.expectEqual(@as(u8, 127), exitStatus(error.ExecNotFound));
    try std.testing.expectEqual(@as(u8, 125), exitStatus(error.NeedFuse));
    try std.testing.expectEqual(@as(u8, 2), exitStatus(error.UnknownFlag));
    try std.testing.expectEqual(@as(u8, 1), exitStatus(error.SqlitePrepare));
}
