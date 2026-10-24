//! OCI image config JSON: read and edit the `config` section, keep every other field.
const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const dockerfile = @import("../core/dockerfile.zig");

pub const ImageConfig = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    /// Empty input starts a minimal linux config.
    pub fn parse(gpa: std.mem.Allocator, json: []const u8) !ImageConfig {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const text = if (std.mem.trim(u8, json, " \t\r\n").len == 0) "{\"os\":\"linux\"}" else json;
        const root = try std.json.parseFromSliceLeaky(Value, a, text, .{});
        if (root != .object) return error.BadConfig;
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *ImageConfig) void {
        self.arena.deinit();
    }

    pub fn serialize(self: *const ImageConfig, gpa: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, self.root, .{});
    }

    fn config(self: *ImageConfig) !*ObjectMap {
        const a = self.arena.allocator();
        const top = &self.root.object;
        const key = if (top.contains("Config")) "Config" else "config";
        const gop = try top.getOrPut(a, key);
        if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
        return &gop.value_ptr.object;
    }

    pub fn getString(self: *ImageConfig, field: []const u8) ![]const u8 {
        const v = (try self.config()).get(field) orelse return "";
        return if (v == .string) v.string else "";
    }

    pub fn setString(self: *ImageConfig, field: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        try (try self.config()).put(a, try a.dupe(u8, field), .{ .string = try a.dupe(u8, value) });
    }

    /// String array field (`Env`, `Cmd`, `Entrypoint`); null or missing is empty.
    pub fn getStrings(self: *ImageConfig, gpa: std.mem.Allocator, field: []const u8) ![]const []const u8 {
        const v = (try self.config()).get(field) orelse return gpa.alloc([]const u8, 0);
        if (v != .array) return gpa.alloc([]const u8, 0);
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (v.array.items) |item| if (item == .string) try out.append(gpa, item.string);
        return out.toOwnedSlice(gpa);
    }

    /// null writes JSON null (Docker's "unset").
    pub fn setStrings(self: *ImageConfig, field: []const u8, items: ?[]const []const u8) !void {
        const a = self.arena.allocator();
        const cfg = try self.config();
        const list = items orelse return cfg.put(a, try a.dupe(u8, field), .null);
        var arr = std.json.Array.init(a);
        for (list) |s| try arr.append(.{ .string = try a.dupe(u8, s) });
        try cfg.put(a, try a.dupe(u8, field), .{ .array = arr });
    }

    /// Sets `key` in `Env`, replacing an existing entry in place.
    pub fn setEnv(self: *ImageConfig, key: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        const cfg = try self.config();
        const gop = try cfg.getOrPut(a, "Env");
        if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = .{ .array = std.json.Array.init(a) };
        const entry: Value = .{ .string = try std.fmt.allocPrint(a, "{s}={s}", .{ key, value }) };
        for (gop.value_ptr.array.items) |*item| {
            if (item.* != .string) continue;
            const eq = std.mem.indexOfScalar(u8, item.string, '=') orelse item.string.len;
            if (std.mem.eql(u8, item.string[0..eq], key)) {
                item.* = entry;
                return;
            }
        }
        try gop.value_ptr.array.append(entry);
    }

    /// Adds to an object-valued set field (`ExposedPorts`, `Labels`).
    pub fn putMapEntry(self: *ImageConfig, field: []const u8, key: []const u8, value: Value) !void {
        const a = self.arena.allocator();
        const cfg = try self.config();
        const gop = try cfg.getOrPut(a, field);
        if (!gop.found_existing or gop.value_ptr.* != .object) {
            gop.key_ptr.* = try a.dupe(u8, field);
            gop.value_ptr.* = .{ .object = .empty };
        }
        try gop.value_ptr.object.put(a, try a.dupe(u8, key), value);
    }

    /// `Healthcheck` with only the fields that were given; durations in nanoseconds.
    pub fn setHealthcheck(self: *ImageConfig, hc: dockerfile.Healthcheck) !void {
        const a = self.arena.allocator();
        var obj: ObjectMap = .empty;
        var test_arr = std.json.Array.init(a);
        for (hc.test_cmd) |s| try test_arr.append(.{ .string = try a.dupe(u8, s) });
        try obj.put(a, "Test", .{ .array = test_arr });
        if (hc.interval_ns) |v| try obj.put(a, "Interval", .{ .integer = @intCast(v) });
        if (hc.timeout_ns) |v| try obj.put(a, "Timeout", .{ .integer = @intCast(v) });
        if (hc.start_period_ns) |v| try obj.put(a, "StartPeriod", .{ .integer = @intCast(v) });
        if (hc.retries) |v| try obj.put(a, "Retries", .{ .integer = v });
        try (try self.config()).put(a, "Healthcheck", .{ .object = obj });
    }

    pub fn addVolume(self: *ImageConfig, path: []const u8) !void {
        try self.putMapEntry("Volumes", path, .{ .object = .empty });
    }

    /// Top-level `author` (not part of `config`).
    pub fn setAuthor(self: *ImageConfig, author: []const u8) !void {
        const a = self.arena.allocator();
        try self.root.object.put(a, "author", .{ .string = try a.dupe(u8, author) });
    }

    pub fn setLabel(self: *ImageConfig, key: []const u8, value: []const u8) !void {
        try self.putMapEntry("Labels", key, .{ .string = try self.arena.allocator().dupe(u8, value) });
    }

    /// `80` becomes `80/tcp`, as Docker does.
    pub fn addExposedPort(self: *ImageConfig, port: []const u8) !void {
        const a = self.arena.allocator();
        const p = if (std.mem.indexOfScalar(u8, port, '/') == null) try std.fmt.allocPrint(a, "{s}/tcp", .{port}) else port;
        try self.putMapEntry("ExposedPorts", p, .{ .object = .empty });
    }
};

pub const Error = error{BadConfig};

const testing = std.testing;

test "edit config keeps unrelated fields and round-trips" {
    const base =
        \\{"architecture":"amd64","os":"linux","config":{"Env":["PATH=/bin","A=1"],"Cmd":["sh"],"WorkingDir":""},"rootfs":{"type":"layers","diff_ids":[]}}
    ;
    var c = try ImageConfig.parse(testing.allocator, base);
    defer c.deinit();
    try c.setEnv("A", "2");
    try c.setEnv("B", "x y");
    try c.setStrings("Entrypoint", &.{"/app"});
    try c.setStrings("Cmd", null);
    try c.setString("WorkingDir", "/app");
    try c.addExposedPort("80");
    try c.setLabel("org.x", "y");

    const out = try c.serialize(testing.allocator);
    defer testing.allocator.free(out);
    var again = try ImageConfig.parse(testing.allocator, out);
    defer again.deinit();
    const env = try again.getStrings(testing.allocator, "Env");
    defer testing.allocator.free(env);
    try testing.expectEqual(@as(usize, 3), env.len);
    try testing.expectEqualStrings("A=2", env[1]);
    try testing.expectEqualStrings("B=x y", env[2]);
    const cmd = try again.getStrings(testing.allocator, "Cmd");
    defer testing.allocator.free(cmd);
    try testing.expectEqual(@as(usize, 0), cmd.len);
    try testing.expectEqualStrings("/app", try again.getString("WorkingDir"));
    try testing.expect(std.mem.indexOf(u8, out, "\"80/tcp\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rootfs\":{\"type\":\"layers\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"architecture\":\"amd64\"") != null);
}

test "empty input starts a minimal config" {
    var c = try ImageConfig.parse(testing.allocator, "");
    defer c.deinit();
    try c.setString("User", "app");
    const out = try c.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"os\":\"linux\",\"config\":{\"User\":\"app\"}}", out);
}
