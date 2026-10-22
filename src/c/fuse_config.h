#pragma once

/* Private config for compiling libfuse into zig-fuse.
 * HAVE_BACKTRACE and HAVE_ICONV are omitted: musl has no execinfo, and the
 * iconv module is not needed for the high-level read-only operations we use. */
#define PACKAGE_VERSION "3.17.1"

#define HAVE_COPY_FILE_RANGE
#define HAVE_FALLOCATE
#define HAVE_FDATASYNC
#define HAVE_FORK
#define HAVE_FSTATAT
#define HAVE_OPENAT
#define HAVE_PIPE2
#define HAVE_POSIX_FALLOCATE
#define HAVE_READLINKAT
#define HAVE_SETXATTR
#define HAVE_SPLICE
#define HAVE_STRUCT_STAT_ST_ATIM
#define HAVE_UTIMENSAT
#define HAVE_VMSPLICE
#undef HAVE_STRUCT_STAT_ST_ATIMESPEC
