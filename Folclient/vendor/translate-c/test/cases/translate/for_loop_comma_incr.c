void foo(void) {
    int count = 0;
    for (int i = 0; i < 3; i++, count++);
    for (int i = 0; i < 3; i++, count++, ++count);
}

// translate
//
// pub export fn foo() void {
//     var count: c_int = 0;
//     _ = &count;
//     {
//         var i: c_int = 0;
//         _ = &i;
//         while (i < @as(c_int, 3)) : ({
//             i += 1;
//             count += 1;
//         }) {}
//     }
//     {
//         var i: c_int = 0;
//         _ = &i;
//         while (i < @as(c_int, 3)) : ({
//             i += 1;
//             count += 1;
//             count += 1;
//         }) {}
//     }
// }
