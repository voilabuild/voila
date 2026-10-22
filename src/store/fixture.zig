const std = @import("std");
const constants = @import("../core/constants.zig");
const posix_util = @import("../sys/posix_util.zig");

pub const ChunkSize = constants.chunk_size;

pub const FileEntry = struct {
    name: []const u8,
    size: u64,
    chunk_names: []const []const u8,
};

pub const SymlinkEntry = struct {
    name: []const u8,
    target: []const u8,
};

pub const Tree = struct {
    file: ?FileEntry,
    symlink: ?SymlinkEntry,
    fixture_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Tree) void {
        if (self.file) |*f| {
            self.allocator.free(f.name);
            for (f.chunk_names) |n| self.allocator.free(n);
            self.allocator.free(f.chunk_names);
        }
        if (self.symlink) |*s| {
            self.allocator.free(s.name);
            self.allocator.free(s.target);
        }
        self.allocator.free(self.fixture_dir);
    }

    pub fn load(allocator: std.mem.Allocator, fixture_dir: []const u8) !Tree {
        const dir_owned = try allocator.dupe(u8, fixture_dir);
        errdefer allocator.free(dir_owned);

        const tree_path = try std.fmt.allocPrint(allocator, "{s}/tree.txt", .{dir_owned});
        defer allocator.free(tree_path);
        const tree_text = try posix_util.readFileAlloc(allocator, tree_path, 1 << 20);
        defer allocator.free(tree_text);

        var file_entry: ?FileEntry = null;
        var symlink_entry: ?SymlinkEntry = null;

        var lines = std.mem.splitScalar(u8, tree_text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            const kind = parts.next() orelse continue;
            if (std.mem.eql(u8, kind, "file")) {
                const name = parts.next() orelse return error.BadTree;
                const size_str = parts.next() orelse return error.BadTree;
                const size: u64 = try std.fmt.parseInt(u64, size_str, 10);
                var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
                while (parts.next()) |chunk_name| {
                    try chunks.append(allocator, try allocator.dupe(u8, chunk_name));
                }
                file_entry = .{
                    .name = try allocator.dupe(u8, name),
                    .size = size,
                    .chunk_names = try chunks.toOwnedSlice(allocator),
                };
            } else if (std.mem.eql(u8, kind, "symlink")) {
                const name = parts.next() orelse return error.BadTree;
                const target = parts.next() orelse return error.BadTree;
                symlink_entry = .{
                    .name = try allocator.dupe(u8, name),
                    .target = try allocator.dupe(u8, target),
                };
            } else {
                return error.BadTree;
            }
        }

        if (file_entry == null or symlink_entry == null) return error.BadTree;

        return .{
            .file = file_entry,
            .symlink = symlink_entry,
            .fixture_dir = dir_owned,
            .allocator = allocator,
        };
    }
};
