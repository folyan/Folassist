int log2(unsigned a, int b) {
    int i = 0;
    while (a > 0) {
        a >>= 1;
    }
    a >>= b;
    return i;
}

// translate
//
// pub export fn log2(arg_a: c_uint, arg_b: c_int) c_int {
//     var a = arg_a;
//     _ = &a;
//     var b = arg_b;
//     _ = &b;
//     var i: c_int = 0;
//     _ = &i;
//     while (a > @as(c_uint, 0)) {
//         a >>= @intCast(@as(c_uint, 1));
//     }
//     a >>= @intCast(@as(c_uint, @bitCast(@as(c_int, b))));
//     return i;
// }
