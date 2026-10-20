#include "fuse3_shim.h"

#include <string.h>
#include <sys/stat.h>

struct fuse *voila_fuse_new(struct fuse_args *args, const struct fuse_operations *op,
                            size_t op_size, void *user_data) {
    return fuse_new(args, op, op_size, user_data);
}

void voila_fuse_fill_stat(struct stat *st, uint64_t ino, uint32_t mode, uint32_t nlink,
                          uint32_t uid, uint32_t gid, int64_t size, int64_t blksize, int64_t blocks,
                          int64_t atime_sec, int64_t atime_nsec, int64_t mtime_sec, int64_t mtime_nsec,
                          int64_t ctime_sec, int64_t ctime_nsec) {
    if (!st) {
        return;
    }
    memset(st, 0, sizeof(*st));
    st->st_ino = (ino_t)ino;
    st->st_mode = (mode_t)mode;
    st->st_nlink = (nlink_t)nlink;
    st->st_uid = (uid_t)uid;
    st->st_gid = (gid_t)gid;
    st->st_size = (off_t)size;
    st->st_blksize = (blksize_t)blksize;
    st->st_blocks = (blkcnt_t)blocks;
    st->st_atim.tv_sec = (time_t)atime_sec;
    st->st_atim.tv_nsec = atime_nsec;
    st->st_mtim.tv_sec = (time_t)mtime_sec;
    st->st_mtim.tv_nsec = mtime_nsec;
    st->st_ctim.tv_sec = (time_t)ctime_sec;
    st->st_ctim.tv_nsec = ctime_nsec;
}
