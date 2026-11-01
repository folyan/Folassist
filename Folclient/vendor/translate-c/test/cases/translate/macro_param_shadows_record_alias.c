typedef struct stype {
  struct d {
    int a;
    int b;
  } d;
} stype;

int strlen(char const *);

#define MAC(d) strlen(d)

// translate
// 
// pub const struct_d_1 = extern struct {
//     a: c_int,
//     b: c_int,
// };
// pub const struct_stype = extern struct {
//     d: struct_d_1,
// };
// pub const stype = struct_stype;
// pub extern fn strlen([*c]const u8) c_int;
// 
// pub inline fn MAC(d: anytype) @TypeOf(strlen(d)) {
//     _ = &d;
//     return strlen(d);
// }
