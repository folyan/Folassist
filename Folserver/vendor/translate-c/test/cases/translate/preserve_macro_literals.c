#define ret_macro return 1
#define foo /*foo*/1
#define bar 1.2
#define baz 'a'
int func(void) {
    int a = foo;
    double b = bar;
    char c = baz;
    ret_macro;
}

// translate
//
// pub export fn func() c_int {
//     var a: c_int = foo;
//     _ = &a;
//     var b: f64 = bar;
//     _ = &b;
//     var c: u8 = baz;
//     _ = &c;
//     return 1;
// }
//
// pub const foo = @as(c_int, 1);
// pub const bar = @as(f64, 1.2);
// pub const baz = 'a';