typedef int i4 __attribute__((vector_size(16)));

i4 clzg(i4 a, i4 b) { return __builtin_elementwise_clzg(a, b); }

i4 clzg_no_fallback(i4 a) { return __builtin_elementwise_clzg(a); }

// translate
//
// pub const @"i4" = @Vector(4, c_int);
//
// pub export fn clzg(arg_a: @"i4", arg_b: @"i4") @"i4" {
//     var a = arg_a;
//     _ = &a;
//     var b = arg_b;
//     _ = &b;
//     return __builtin.elementwise_clzg(a, b);
// }
//
// pub export fn clzg_no_fallback(arg_a: @"i4") @"i4" {
//     var a = arg_a;
//     _ = &a;
//     return @clz(@as(@"i4", a));
// }
