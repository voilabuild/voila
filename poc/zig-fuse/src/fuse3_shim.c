#include "fuse3_shim.h"

struct fuse *voila_fuse_new(struct fuse_args *args, const struct fuse_operations *op,
                            size_t op_size, void *user_data) {
    return fuse_new(args, op, op_size, user_data);
}
