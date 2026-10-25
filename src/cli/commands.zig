const std = @import("std");

pub const Name = enum {
    userns_probe,
    login,
    logout,
    prove,
    prove_store,
    serve,
    serve_index,
    container_fuse_serve,
    container_isolated_exec,
    container_worker,
    build,
    run,
    exec,
    ps,
    logs,
    pull,
    push,
    import,
    rmi,
    images,
    kill,
    stop,
    rm,
    serve_store,
};

pub fn parse(name: []const u8) ?Name {
    if (std.mem.eql(u8, name, "userns-probe")) return .userns_probe;
    if (std.mem.eql(u8, name, "login")) return .login;
    if (std.mem.eql(u8, name, "logout")) return .logout;
    if (std.mem.eql(u8, name, "prove")) return .prove;
    if (std.mem.eql(u8, name, "prove-store")) return .prove_store;
    if (std.mem.eql(u8, name, "serve")) return .serve;
    if (std.mem.eql(u8, name, "serve-index")) return .serve_index;
    if (std.mem.eql(u8, name, "container-fuse-serve")) return .container_fuse_serve;
    if (std.mem.eql(u8, name, "container-isolated-exec")) return .container_isolated_exec;
    if (std.mem.eql(u8, name, "container-worker")) return .container_worker;
    if (std.mem.eql(u8, name, "build")) return .build;
    if (std.mem.eql(u8, name, "run")) return .run;
    if (std.mem.eql(u8, name, "exec")) return .exec;
    if (std.mem.eql(u8, name, "ps")) return .ps;
    if (std.mem.eql(u8, name, "logs")) return .logs;
    if (std.mem.eql(u8, name, "pull")) return .pull;
    if (std.mem.eql(u8, name, "push")) return .push;
    if (std.mem.eql(u8, name, "import")) return .import;
    if (std.mem.eql(u8, name, "rmi")) return .rmi;
    if (std.mem.eql(u8, name, "images")) return .images;
    if (std.mem.eql(u8, name, "kill")) return .kill;
    if (std.mem.eql(u8, name, "stop")) return .stop;
    if (std.mem.eql(u8, name, "rm")) return .rm;
    if (std.mem.eql(u8, name, "serve-store")) return .serve_store;
    return null;
}
