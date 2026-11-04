#define INT8_MAX         127i8
#define INT16_MAX        32767i16
#define INT32_MAX        2147483647i32
#define INT64_MAX        9223372036854775807i64
#define UINT8_MAX        0xffui8
#define UINT16_MAX       0xffffui16
#define UINT32_MAX       0xffffffffui32
#define UINT64_MAX       0xffffffffffffffffui64

// translate
// target=native-windows-msvc
//
// pub const INT8_MAX = @as(i8, 127);
// pub const INT16_MAX = @as(i16, 32767);
// pub const INT32_MAX = @as(i32, 2147483647);
// pub const INT64_MAX = @as(i64, 9223372036854775807);
// pub const UINT8_MAX = @as(u8, 0xff);
// pub const UINT16_MAX = @as(u16, 0xffff);
// pub const UINT32_MAX = @as(u32, 0xffffffff);
// pub const UINT64_MAX = @as(u64, 0xffffffffffffffff);
