static void foo(void){
    char arr[10] ={1};
    char *arr1[10] ={0};
    int arr2[5] = {0, [1] = 1, [3] = 3, 4};
    int arr3[6] = {0, [0] = 10, [2] = 2, [0] = 100, 4, 5};
    int arr4[7] = {[1] = 1, [2] = 2, [5] = 5};
    int arr5[0] = {};
    int arr6[9] = {};
}
struct S {
    char label[8];
} s = { .label = "start" };
union U {
    char label[8];
} u = { .label = "start" };
char a[2][8] = {"start"};

// translate
//
// pub fn foo() callconv(.c) void {
//     var arr: [10]u8 = [1]u8{
//         1,
//     } ++ @as([9]u8, @splat(0));
//     _ = &arr;
//     var arr1: [10][*c]u8 = [1][*c]u8{
//         null,
//     } ++ @as([9][*c]u8, @splat(null));
//     _ = &arr1;
//     var arr2: [5]c_int = [2]c_int{
//         0,
//         1,
//     } ++ @as([1]c_int, @splat(0)) ++ [2]c_int{
//         3,
//         4,
//     };
//     _ = &arr2;
//     var arr3: [6]c_int = [3]c_int{
//         100,
//         4,
//         5,
//     } ++ @as([3]c_int, @splat(0));
//     _ = &arr3;
//     var arr4: [7]c_int = @as([1]c_int, @splat(0)) ++ [2]c_int{
//         1,
//         2,
//     } ++ @as([2]c_int, @splat(0)) ++ [1]c_int{
//         5,
//     } ++ @as([1]c_int, @splat(0));
//     _ = &arr4;
//     var arr5: [0]c_int = .{};
//     _ = &arr5;
//     var arr6: [9]c_int = @as([9]c_int, @splat(0));
//     _ = &arr6;
// }
//
// pub export var s: struct_S = struct_S{
//     .label = "start"[0..5].* ++ @as([3]u8, @splat(0)),
// };
//
// pub export var u: union_U = union_U{
//     .label = "start"[0..5].* ++ @as([3]u8, @splat(0)),
// };
//
// pub export var a: [2][8]u8 = [1][8]u8{
//     "start"[0..5].* ++ @as([3]u8, @splat(0)),
// } ++ @as([1][8]u8, @splat(@import("std").mem.zeroes([8]u8)));
