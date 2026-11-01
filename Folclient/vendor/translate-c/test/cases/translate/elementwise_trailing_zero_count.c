typedef int i4 __attribute__((vector_size(16)));

i4 ctzg(i4 a, i4 b) { return __builtin_elementwise_ctzg(a, b); }

i4 ctzg_no_fallback(i4 a) { return __builtin_elementwise_ctzg(a); }

// translate
//
// pub const @"i4" = @Vector(4, c_int);
//
// pub export fn ctzg(arg_a: @"i4", arg_b: @"i4") @"i4" {
//     var a = arg_a;
//     _ = &a;
//     var b = arg_b;
//     _ = &b;
//     return __builtin.elementwise_ctzg(a, b);
// }
//
// pub export fn ctzg_no_fallback(arg_a: @"i4") @"i4" {
//     var a = arg_a;
//     _ = &a;
//     return @ctz(@as(@"i4", a));
// }
