#ifndef VOILA_FUSE3_SHIM_H
#define VOILA_FUSE3_SHIM_H

#define FUSE_USE_VERSION 312
#include <fuse3/fuse.h>

/* Stable C entry for Zig: libfuse 3.18+ implements fuse_new as a macro over
 * static inline helpers; translate-c may not expose a usable fuse_new symbol. */
struct fuse *voila_fuse_new(struct fuse_args *args, const struct fuse_operations *op,
                            size_t op_size, void *user_data);

#endif
