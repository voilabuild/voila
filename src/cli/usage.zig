const std = @import("std");

pub fn printUsage() void {
    std.debug.print(
        \\voila — daemonless voila container CLI (Linux, rootless FUSE)
        \\
        \\  voila login [registry-url]
        \\  voila logout
        \\  voila pull|push|import [-root <dir>] <image-ref>
        \\  voila build -t <ref> [-f Dockerfile] [--build-arg K=V] [--no-cache] [--push] <context>
        \\  voila run [-root <dir>] [-d] [--name NAME] [--rm] <image-ref> -- <cmd> [args...]
        \\  voila exec <id> -- <cmd> [args...]
        \\  voila ps|logs|images|rmi|stop|kill|rm [-root <dir>] ...
        \\
        \\  voila prove [fixture-dir]
        \\
    ,
        .{},
    );
}
