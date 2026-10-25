const command = @import("command.zig");
const pull = @import("pull.zig");
const registry_session = @import("registry").registry_session;
const voila_registry = @import("registry").voila_registry;
const voila_image_import = @import("registry").voila_image_import;
const registry_ref_mod = @import("registry").voila_registry_ref;

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try pull.parseArgs(gpa, ctx.args);
    defer gpa.free(parsed.runtime_cfg.store_root);
    defer gpa.free(parsed.image);
    try registry_session.prepare(ctx.io, gpa, parsed.runtime_cfg.store_root);
    const cfg = voila_registry.getConfigCopy(gpa) orelse return error.NoRegistry;
    defer {
        gpa.free(cfg.base_url);
        gpa.free(cfg.token);
        gpa.free(cfg.org);
    }
    const hub_ref = try registry_ref_mod.normalizeUserRef(gpa, parsed.image);
    defer gpa.free(hub_ref);
    const push_ref = if (cfg.org.len != 0)
        try registry_ref_mod.hubPushRef(gpa, hub_ref, cfg.org)
    else
        try gpa.dupe(u8, hub_ref);
    defer gpa.free(push_ref);
    try voila_image_import.importImage(ctx.io, gpa, parsed.runtime_cfg.store_root, cfg, hub_ref, push_ref, .{});
}
