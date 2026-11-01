 int a, b, c;
#define FOO a ? b : c

// translate
//
// pub inline fn FOO() @TypeOf(if (__helpers.cast(bool, a)) b else c) {
//     return if (__helpers.cast(bool, a)) b else c;
// }
