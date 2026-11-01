struct a { int x; int y[]; };
struct b { int x; int y[0]; };
struct c { int x; int y[1]; };
struct d { int x; int y[2]; };

// translate
// args = -fdefault-init -fstrict-flex-arrays=3
//
// pub const struct_a = extern struct {
//     x: c_int = 0,
//     _y: [0]c_int = @import("std").mem.zeroes([0]c_int),
//     pub fn y(_self: anytype) __helpers.FlexibleArrayType(@TypeOf(_self), @typeInfo(@TypeOf(_self.*._y)).array.child) {
//         return @ptrCast(@alignCast(&_self.*._y));
//     }
// };
//
// pub const struct_b = extern struct {
//     x: c_int = 0,
//     y: [0]c_int = @import("std").mem.zeroes([0]c_int),
// };
//
// pub const struct_c = extern struct {
//     x: c_int = 0,
//     y: [1]c_int = @import("std").mem.zeroes([1]c_int),
// };
//
// pub const struct_d = extern struct {
//     x: c_int = 0,
//     y: [2]c_int = @import("std").mem.zeroes([2]c_int),
// };
