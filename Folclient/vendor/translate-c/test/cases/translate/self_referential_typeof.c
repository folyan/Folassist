void foo(void *ap) {
    int *p = (__typeof__(p))ap + 1;
    int *p2 = (__typeof__(p))ap + 1;
    __typeof__(*p) a = 1; 
}

// translate
//
// pub export fn foo(arg_ap: ?*anyopaque) void {
//     var ap = arg_ap;
//     _ = &ap;
//     var p: [*c]c_int = @as([*c]c_int, @ptrCast(@alignCast(ap))) + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, 1)))));
//     _ = &p;
//     var p2: [*c]c_int = @as(@TypeOf(p), @ptrCast(@alignCast(ap))) + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, 1)))));
//     _ = &p2;
//     var a: @TypeOf(p.*) = 1;
//     _ = &a;
// }
