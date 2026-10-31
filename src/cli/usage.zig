const std = @import("std");
const commands = @import("commands.zig");

pub fn printUsage() void {
    std.debug.print(
        \\voila — daemonless container CLI (Linux, rootless FUSE)
        \\
        \\  voila login [registry-url]
        \\  voila logout
        \\  voila import|pull|push [--root <dir>] <image-ref>
        \\  voila build -t <ref> [-f Dockerfile] [--build-arg K=V] [--target stage] [--no-cache] [--push] [--root <dir>] <context>
        \\  voila run [--root <dir>] [-d] [-it] [--name NAME] [--rm] [-e K=V] [-v host:ctr] [-p host:ctr] [-w dir] <image-ref> [--] [cmd...]
        \\  voila exec <id> [--] <cmd...>
        \\  voila ps|logs|images|rmi|stop|kill|rm [--root <dir>] ...
        \\  voila --version
        \\
        \\  voila <command> --help
        \\
    , .{});
}

pub fn printCommand(name: commands.Name) void {
    const text: []const u8 = switch (name) {
        .login => "voila login [registry-url]",
        .logout => "voila logout",
        .import => "voila import [--root <dir>] <image-ref>",
        .pull => "voila pull [--root <dir>] <image-ref>",
        .push => "voila push [--root <dir>] <image-ref>",
        .build => "voila build -t <ref> [-f Dockerfile] [--build-arg K=V] [--target stage] [--no-cache] [--push] [--root <dir>] <context>",
        .run => "voila run [--root <dir>] [-d] [-it] [--name NAME] [--rm] [-e K=V] [-v host:ctr] [-p host:ctr] [-w dir] <image-ref> [--] [cmd...]",
        .exec => "voila exec [--root <dir>] <id> [--] <cmd...>",
        .ps => "voila ps [--root <dir>]",
        .logs => "voila logs [--root <dir>] [-f|--follow] <id>",
        .images => "voila images [--root <dir>]",
        .rmi => "voila rmi [--root <dir>] <image-ref> [image-ref...]",
        .stop => "voila stop [--root <dir>] <id> [id...]",
        .kill => "voila kill [--root <dir>] [-s signal] <id> [id...]",
        .rm => "voila rm [--root <dir>] <id> [id...]",
        else => "voila <command> [--root <dir>]",
    };
    std.debug.print("usage: {s}\n", .{text});
}
