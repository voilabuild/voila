const container_bind = @import("runtime").oci.container_bind;

pub fn exitCode() u8 {
    return if (container_bind.probeUserNamespaces()) 0 else 1;
}
