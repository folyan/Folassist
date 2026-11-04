int g;
int main(void) {
    int a = 1;
    int b;
    if ((g |= (b = a))) return 1;
    return 0;
}

// translate
//
// pub export var g: c_int = 0;
// pub export fn main() c_int {
//     var a: c_int = 1;
//     _ = &a;
//     var b: c_int = undefined;
//     _ = &b;
//     if ((blk: {
//         const ref = &g;
//         ref.* |= blk_1: {
//             const tmp = a;
//             b = tmp;
//             break :blk_1 tmp;
//         };
//         break :blk ref.*;
//     }) != 0) return 1;
//     return 0;
// }
