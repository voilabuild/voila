//! Docker-style `-e`/`-v`/`-p` values: the run option types and their parsers.
const std = @import("std");

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Volume = struct {
    host: []const u8,
    container: []const u8,
    read_only: bool,
};

pub const PortMap = struct {
    host: u16,
    container: u16,
};

pub fn parseEnvArg(arg: []const u8) !EnvPair {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadEnv;
    if (eq == 0) return error.BadEnv;
    return .{
        .key = arg[0..eq],
        .value = arg[eq + 1 ..],
    };
}

pub fn parseVolumeSpec(spec: []const u8) !Volume {
    var ro = false;
    var body = spec;
    if (std.mem.endsWith(u8, body, ":ro")) {
        ro = true;
        body = body[0 .. body.len - 3];
    } else if (std.mem.endsWith(u8, body, ":rw")) {
        body = body[0 .. body.len - 3];
    }
    const colon = std.mem.lastIndexOfScalar(u8, body, ':') orelse return error.BadVolume;
    if (colon == 0 or colon + 1 >= body.len) return error.BadVolume;
    const host = body[0..colon];
    const ctr = body[colon + 1 ..];
    if (ctr.len == 0 or ctr[0] != '/') return error.BadVolume;
    return .{
        .host = host,
        .container = ctr,
        .read_only = ro,
    };
}

pub fn parsePortSpec(spec: []const u8) !PortMap {
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        const host = std.fmt.parseInt(u16, spec[0..colon], 10) catch return error.BadPort;
        const ctr = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return error.BadPort;
        return .{ .host = host, .container = ctr };
    }
    const p = std.fmt.parseInt(u16, spec, 10) catch return error.BadPort;
    return .{ .host = p, .container = p };
}

test "parse env" {
    const p = try parseEnvArg("FOO=bar");
    try std.testing.expectEqualStrings("FOO", p.key);
    try std.testing.expectEqualStrings("bar", p.value);
}

test "parse volume ro" {
    const v = try parseVolumeSpec("/tmp/h:/ctr/data:ro");
    try std.testing.expectEqualStrings("/tmp/h", v.host);
    try std.testing.expectEqualStrings("/ctr/data", v.container);
    try std.testing.expect(v.read_only);
}

test "parse port map" {
    const p = try parsePortSpec("8080:80");
    try std.testing.expectEqual(@as(u16, 8080), p.host);
    try std.testing.expectEqual(@as(u16, 80), p.container);
}

pub const Error = error{
    BadEnv,
    BadVolume,
    BadPort,
};
