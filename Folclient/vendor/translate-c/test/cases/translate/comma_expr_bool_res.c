int main() {
    int a = 1, b = 0, c;
    c = ((a = b), (1 && 1));
    return 0;
}

// translate
//
// pub export fn main() c_int {
//     var a: c_int = 1;
//     _ = &a;
//     var b: c_int = 0;
//     _ = &b;
//     var c: c_int = undefined;
//     _ = &c;
//     c = blk: {
//         a = b;
//         break :blk @intFromBool(true and true);
//     };
//     return 0;
// }
