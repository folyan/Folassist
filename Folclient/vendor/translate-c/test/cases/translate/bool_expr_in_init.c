void entry(void) {
    struct {
        int a;
    } a = { .a = 1 != 0 };
    union {
        int b;
    } b = { .b = 1 != 0 };
    int c[1] = { 1 != 0 };
}

// translate
//
// pub export fn entry() void {
//     const struct_unnamed_1 = extern struct {
//         a: c_int,
//     };
//     _ = &struct_unnamed_1;
//     var a: struct_unnamed_1 = struct_unnamed_1{
//         .a = @intFromBool(@as(c_int, 1) != @as(c_int, 0)),
//     };
//     _ = &a;
//     const union_unnamed_2 = extern union {
//         b: c_int,
//     };
//     _ = &union_unnamed_2;
//     var b: union_unnamed_2 = union_unnamed_2{
//         .b = @intFromBool(@as(c_int, 1) != @as(c_int, 0)),
//     };
//     _ = &b;
//     var c: [1]c_int = [1]c_int{
//         @intFromBool(@as(c_int, 1) != @as(c_int, 0)),
//     };
//     _ = &c;
// }
