const abi = @import("fuse_abi.zig");
comptime {
    @compileLog(@sizeOf(abi.Attr));
    @compileLog(@sizeOf(abi.EntryOut));
}
pub fn main() {}
