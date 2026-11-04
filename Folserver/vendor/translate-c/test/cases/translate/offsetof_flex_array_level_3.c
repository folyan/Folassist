#include <stddef.h>

struct A { int x; char data[]; };
struct B { int x; char data[0]; };
struct C { int x; char data[1]; };
struct D { int x; char data[2]; };

void test(void) {
    size_t a = __builtin_offsetof(struct A, data);
    size_t b = __builtin_offsetof(struct B, data);
    size_t c = __builtin_offsetof(struct C, data);
    size_t d = __builtin_offsetof(struct D, data);
}

// translate
// args = -fstrict-flex-arrays=3
//
// pub const struct_A = extern struct {
//     x: c_int,
//     _data: [0]u8,
//     pub fn data(_self: anytype) __helpers.FlexibleArrayType(@TypeOf(_self), @typeInfo(@TypeOf(_self.*._data)).array.child) {
//         return @ptrCast(@alignCast(&_self.*._data));
//     }
// };
//
// pub const struct_B = extern struct {
//     x: c_int,
//     data: [0]u8,
// };
//
// pub const struct_C = extern struct {
//     x: c_int,
//     data: [1]u8,
// };
//
// pub const struct_D = extern struct {
//     x: c_int,
//     data: [2]u8,
// };
//
// pub export fn @"test"() void {
//     var a: usize = @intFromPtr(&@as(*allowzero struct_A, @ptrFromInt(0))._data);
//     _ = &a;
//     var b: usize = @intFromPtr(&@as(*allowzero struct_B, @ptrFromInt(0)).data);
//     _ = &b;
//     var c: usize = @intFromPtr(&@as(*allowzero struct_C, @ptrFromInt(0)).data);
//     _ = &c;
//     var d: usize = @intFromPtr(&@as(*allowzero struct_D, @ptrFromInt(0)).data);
//     _ = &d;
// }
