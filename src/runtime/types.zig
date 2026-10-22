//! Shared request/response types for the voila runtime interface.
const std = @import("std");
const run_cli_parse = @import("../cli/run_cli_parse.zig");

pub const RunSpec = struct {
    image: []const u8,
    argv: []const []const u8,
    detach: bool = false,
    name: []const u8 = "",
    rm_on_exit: bool = false,
    env: []const run_cli_parse.EnvPair = &.{},
    workdir: []const u8 = "",
    volumes: []const run_cli_parse.Volume = &.{},
    ports: []const run_cli_parse.PortMap = &.{},
    tty: bool = false,
    interactive: bool = false,
};

pub const ExecSpec = struct {
    context_id: []const u8,
    argv: []const []const u8,
    tty: bool = false,
    interactive: bool = false,
};

pub const RmiSpec = struct {
    image: []const u8,
};

pub const PsRow = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    status: []const u8,
    pid: i32,
};

pub const LogsOptions = struct {
    context_id: []const u8,
    follow: bool = false,
};

pub const KillSpec = struct {
    context_id: []const u8,
    signal: i32 = 0,
};

pub const PullSpec = struct {
    image: []const u8,
};

pub const ImageInfo = struct {
    ref: []const u8,
};

pub const ContextRef = struct {
    context_id: []const u8,
};
