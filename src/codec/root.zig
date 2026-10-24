//! The `codec` layer. Wire formats: manifest proto/JSON, OCI JSON.

pub const oci_image_config = @import("oci_image_config.zig");
pub const proto_wire = @import("proto_wire.zig");
pub const voila_manifest_json = @import("voila_manifest_json.zig");
pub const voila_manifest_proto = @import("voila_manifest_proto.zig");

test {
    _ = @import("oci_image_config.zig");
    _ = @import("proto_wire.zig");
    _ = @import("voila_manifest_json.zig");
    _ = @import("voila_manifest_proto.zig");
}
