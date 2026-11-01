#ifndef VOILA_FUSE3_SHIM_H
#define VOILA_FUSE3_SHIM_H

#ifndef FUSE_USE_VERSION
#define FUSE_USE_VERSION 312
#endif
#include "fuse.h"

/* Stable C entry for Zig: libfuse 3.18+ implements fuse_new as a macro over
 * static inline helpers; translate-c may not expose a usable fuse_new symbol. */
struct fuse *voila_fuse_new(struct fuse_args *args, const struct fuse_operations *op,
                            size_t op_size, void *user_data);

/* fuse_loop_mt with up to `max_threads` workers; fuse_loop_mt is a versioned macro. */
int voila_fuse_loop_mt(struct fuse *f, unsigned int max_threads);

/* struct stat from musl is opaque to translate-c. Fill it in C. */
void voila_fuse_fill_stat(struct stat *st, uint64_t ino, uint32_t mode, uint32_t nlink,
                          uint32_t uid, uint32_t gid, int64_t size, int64_t blksize, int64_t blocks,
                          int64_t atime_sec, int64_t atime_nsec, int64_t mtime_sec, int64_t mtime_nsec,
                          int64_t ctime_sec, int64_t ctime_nsec);

#endif
