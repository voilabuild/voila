//! The `registry` layer. Registry client: pull, push, import, image records.

pub const ingest_registry = @import("ingest_registry.zig");
pub const ocireg_client = @import("ocireg_client.zig");
pub const registry_session = @import("registry_session.zig");
pub const voila_fetch_stats = @import("voila_fetch_stats.zig");
pub const voila_http = @import("voila_http.zig");
pub const voila_hub_import = @import("voila_hub_import.zig");
pub const voila_image_import = @import("voila_image_import.zig");
pub const voila_image_pull = @import("voila_image_pull.zig");
pub const voila_image_push = @import("voila_image_push.zig");
pub const voila_login_creds = @import("voila_login_creds.zig");
pub const voila_manifest_cache = @import("voila_manifest_cache.zig");
pub const voila_ocireg = @import("voila_ocireg.zig");
pub const voila_reachable = @import("voila_reachable.zig");
pub const voila_registry = @import("voila_registry.zig");
pub const voila_registry_creds = @import("voila_registry_creds.zig");
pub const voila_registry_fetch = @import("voila_registry_fetch.zig");
pub const voila_registry_hub = @import("voila_registry_hub.zig");
pub const voila_registry_ref = @import("voila_registry_ref.zig");
pub const voila_resolve = @import("voila_resolve.zig");

test {
    _ = @import("ingest_registry.zig");
    _ = @import("ocireg_client.zig");
    _ = @import("registry_session.zig");
    _ = @import("voila_fetch_stats.zig");
    _ = @import("voila_http.zig");
    _ = @import("voila_hub_import.zig");
    _ = @import("voila_image_import.zig");
    _ = @import("voila_image_pull.zig");
    _ = @import("voila_image_push.zig");
    _ = @import("voila_login_creds.zig");
    _ = @import("voila_manifest_cache.zig");
    _ = @import("voila_ocireg.zig");
    _ = @import("voila_reachable.zig");
    _ = @import("voila_registry.zig");
    _ = @import("voila_registry_creds.zig");
    _ = @import("voila_registry_fetch.zig");
    _ = @import("voila_registry_hub.zig");
    _ = @import("voila_registry_ref.zig");
    _ = @import("voila_registry_ref_test.zig");
    _ = @import("voila_resolve.zig");
}
