pub const FUSE_LOOKUP: u32 = 1;
pub const FUSE_FORGET: u32 = 2;
pub const FUSE_RELEASE: u32 = 18;
pub const FUSE_FLUSH: u32 = 25;
pub const FUSE_RELEASEDIR: u32 = 29;
pub const FUSE_GETATTR: u32 = 3;
pub const FUSE_OPEN: u32 = 14;
pub const FUSE_OPENDIR: u32 = 27;
pub const FUSE_READ: u32 = 15;
pub const FUSE_READLINK: u32 = 5;
pub const FUSE_ACCESS: u32 = 34;
pub const FUSE_STATX: u32 = 52;
pub const FUSE_INIT: u32 = 26;
pub const FUSE_READDIR: u32 = 28;

pub const FUSE_ATTR_RDONLY: u32 = 1 << 11;

pub const DT_DIR: u32 = 4;
pub const DT_REG: u32 = 8;
pub const DT_LNK: u32 = 10;

pub const ENOENT: i32 = 2;
pub const EISDIR: i32 = 21;
pub const EINVAL: i32 = 22;
pub const EROFS: i32 = 30;
pub const EOPNOTSUPP: i32 = 95;

pub const InHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
};

pub const OutHeader = extern struct {
    len: u32,
    @"error": i32,
    unique: u64,
};

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atime_nsec: u32,
    mtime_nsec: u32,
    ctime_nsec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    _pad: u32,
};

pub const EntryOut = extern struct {
    nodeid: u64,
    generation: u64,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: Attr,
};

pub const OpenIn = extern struct {
    flags: u32,
    unused: u32,
};

pub const OpenOut = extern struct {
    fh: u64,
    open_flags: u32,
    padding: u32,
};

pub const ReadInCompat = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
};

pub const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub fn readInFrom(payload: []const u8) !ReadInCompat {
    if (payload.len < @sizeOf(ReadInCompat)) return error.BadFuseRead;
    return @as(*const ReadInCompat, @ptrCast(@alignCast(payload.ptr))).*;
}

pub const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
};

pub const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
};

pub const init_out_compat_22_size: usize = 24;
pub const init_out_compat_size: usize = 8;

pub const LookupIn = extern struct {
    parent: u64,
};

pub const GetattrIn = extern struct {
    getattr_flags: u32,
    dummy: u32,
    fh: u64,
};

pub const SxTime = extern struct {
    sec: u64,
    nsec: u32,
    __reserved: u32,
};

pub const Statx = extern struct {
    mask: u32,
    blksize: u32,
    attributes: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    mode: u16,
    _spare0: u16,
    ino: u64,
    size: u64,
    blocks: u64,
    attributes_mask: u64,
    atime: SxTime,
    btime: SxTime,
    ctime: SxTime,
    mtime: SxTime,
    rdev_major: u32,
    rdev_minor: u32,
    dev_major: u32,
    dev_minor: u32,
    _spare2: [14]u64,
};

pub const StatxOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    flags: u32,
    spare: [2]u64,
    stat: Statx,
};

pub const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32,
    attr: Attr,
};

pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type: u32,
};

pub fn direntSize(name_len: usize) usize {
    const base = @sizeOf(Dirent);
    const with_name = base + name_len;
    return (with_name + 7) & ~@as(usize, 7);
}
