typedef unsigned int u4 __attribute__((vector_size(16)));

u4 fshl(u4 a, u4 b, u4 c) {
    return __builtin_elementwise_fshl(a, b, c);
}

u4 fshr(u4 a, u4 b, u4 c) {
    return __builtin_elementwise_fshr(a, b, c);
}

// translate
//
// pub const @"u4" = @Vector(4, c_uint);
//
// pub export fn fshl(arg_a: @"u4", arg_b: @"u4", arg_c: @"u4") @"u4" {
//     var a = arg_a;
//     _ = &a;
//     var b = arg_b;
//     _ = &b;
//     var c = arg_c;
//     _ = &c;
//     return __builtin.elementwise_fshl(a, b, c);
// }
//
// pub export fn fshr(arg_a: @"u4", arg_b: @"u4", arg_c: @"u4") @"u4" {
//     var a = arg_a;
//     _ = &a;
//     var b = arg_b;
//     _ = &b;
//     var c = arg_c;
//     _ = &c;
//     return __builtin.elementwise_fshr(a, b, c);
// }
