//! Resolve COPY/ADD sources in the build context and digest them for the step cache.
const std = @import("std");
const fs = @import("../../sys/fs.zig");
const glob = @import("../../core/glob.zig");
const cache_key = @import("../../core/build_cache_key.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");

pub const Source = struct {
    /// Path relative to the context root.
    rel: []const u8,
    abs: []const u8,
    is_dir: bool,
};

pub const Error = error{ CopySourceMissing, CopyEscapesContext, UnsupportedWildcard };

/// Context-relative, `.`/`..`-resolved form of a COPY source; it may not leave the context.
pub fn cleanSource(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, src, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return error.CopyEscapesContext;
            _ = parts.pop();
            continue;
        }
        try parts.append(a, p);
    }
    return std.mem.join(a, "/", parts.items);
}

/// Expands each source (wildcards only in the last path segment) against the context.
pub fn resolve(a: std.mem.Allocator, context: []const u8, srcs: []const []const u8, ignore: glob.Ignore) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    for (srcs) |raw| {
        const rel = try cleanSource(a, raw);
        const dir = std.fs.path.dirname(rel) orelse "";
        const base = std.fs.path.basename(rel);
        if (glob.hasWildcard(dir)) return error.UnsupportedWildcard;
        if (!glob.hasWildcard(base)) {
            const abs = try join(a, context, rel);
            const st = fs.lstat(abs) catch |e| switch (e) {
                error.FileNotFound => return error.CopySourceMissing,
                else => return e,
            };
            try out.append(a, .{ .rel = rel, .abs = abs, .is_dir = st.kind == .dir });
            continue;
        }
        const dir_abs = try join(a, context, dir);
        const names = fs.listDir(a, dir_abs) catch return error.CopySourceMissing;
        var matched = false;
        for (names) |n| {
            if (!glob.matchSegment(base, n)) continue;
            const r = try join(a, dir, n);
            if (ignore.excluded(r)) continue;
            const abs = try join(a, context, r);
            try out.append(a, .{ .rel = r, .abs = abs, .is_dir = (try fs.lstat(abs)).kind == .dir });
            matched = true;
        }
        if (!matched) return error.CopySourceMissing;
    }
    return out.toOwnedSlice(a);
}

/// Digest of every file the sources contribute: path, permissions and content (or link target).
pub fn digest(a: std.mem.Allocator, sources: []const Source, ignore: glob.Ignore) ![32]u8 {
    var h: cache_key.InputsHasher = .{};
    const buf = try a.alloc(u8, 1 << 20);
    defer a.free(buf);
    for (sources) |s| try digestPath(a, &h, buf, s.abs, s.rel, ignore);
    return h.final();
}

fn digestPath(a: std.mem.Allocator, h: *cache_key.InputsHasher, buf: []u8, abs: []const u8, rel: []const u8, ignore: glob.Ignore) !void {
    const st = try fs.lstat(abs);
    switch (st.kind) {
        .dir => {
            h.entry(rel, st.perm | 0o40000, "");
            const names = try fs.listDir(a, abs);
            defer fs.freeNames(a, names);
            for (names) |n| {
                const child_rel = try join(a, rel, n);
                defer a.free(child_rel);
                if (ignore.excluded(child_rel)) continue;
                const child_abs = try join(a, abs, n);
                defer a.free(child_abs);
                try digestPath(a, h, buf, child_abs, child_rel, ignore);
            }
        },
        .symlink => {
            const target = try fs.readLink(a, abs);
            defer a.free(target);
            h.entry(rel, 0o120000, target);
        },
        .file => {
            var fh = std.crypto.hash.Blake3.init(.{});
            const f = try fs.File.openRead(abs);
            defer f.close();
            while (true) {
                const n = try f.readFull(buf);
                fh.update(buf[0..n]);
                if (n < buf.len) break;
            }
            var d: [32]u8 = undefined;
            fh.final(&d);
            h.entry(rel, st.perm, &d);
        },
        else => {},
    }
}

/// `.dockerignore` filter for a walk rooted at context path `prefix`.
pub const IgnoreSkip = struct {
    ignore: glob.Ignore,
    prefix: []const u8,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

    pub fn skip(self: *IgnoreSkip) dir_walk.Skip {
        return .{ .ctx = self, .func = check };
    }

    fn check(ctx: *const anyopaque, rel: []const u8, _: bool) bool {
        const self: *IgnoreSkip = @ptrCast(@alignCast(@constCast(ctx)));
        if (self.prefix.len == 0) return self.ignore.excluded(rel);
        const full = std.fmt.bufPrint(&self.buf, "{s}/{s}", .{ self.prefix, rel }) catch return false;
        return self.ignore.excluded(full);
    }
};

fn join(a: std.mem.Allocator, x: []const u8, y: []const u8) ![]u8 {
    if (x.len == 0) return a.dupe(u8, y);
    if (y.len == 0) return a.dupe(u8, x);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ x, y });
}

test "cleanSource stays inside the context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a/b", try cleanSource(a, "./a//b/"));
    try std.testing.expectEqualStrings("b", try cleanSource(a, "/a/../b"));
    try std.testing.expectEqualStrings("", try cleanSource(a, "."));
    try std.testing.expectError(error.CopyEscapesContext, cleanSource(a, "../x"));
    try std.testing.expectError(error.CopyEscapesContext, cleanSource(a, "a/../../x"));
}
