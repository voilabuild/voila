pub const chunk_size: u64 = 1 << 20;
pub const block_size: u64 = 4096;

pub const nbd_cmd_read: u32 = 0;
pub const nbd_cmd_write: u32 = 1;
pub const nbd_cmd_disc: u32 = 2;

pub const transmission_magic_request: u32 = 0x25609513;
pub const transmission_magic_reply: u32 = 0x67446698;

pub const negotiation_magic_oldstyle: u64 = 0x4e42444d41474943;
pub const negotiation_magic_option: u64 = 0x49484156454f5054;
pub const negotiation_magic_reply: u64 = 0x3e889045565a9;

pub const negotiation_id_option_go: u32 = 7;
pub const negotiation_type_reply_ack: u32 = 1;
pub const negotiation_type_reply_info: u32 = 3;
pub const negotiation_type_info_export: u16 = 0;
pub const negotiation_type_info_name: u16 = 1;
pub const negotiation_type_info_description: u16 = 2;
pub const negotiation_type_info_blocksize: u16 = 3;

pub const nbd_set_sock: u64 = 0xab00;
pub const nbd_set_blksize: u64 = 0xab01;
pub const nbd_do_it: u64 = 0xab03;
pub const nbd_clear_sock: u64 = 0xab04;
pub const nbd_set_size_blocks: u64 = 0xab07;
pub const nbd_disconnect: u64 = 0xab08;
pub const nbd_set_flags: u64 = 0xab0a;

pub const nbd_flag_has_flags: u32 = 1 << 0;
pub const nbd_flag_read_only: u32 = 1 << 1;
