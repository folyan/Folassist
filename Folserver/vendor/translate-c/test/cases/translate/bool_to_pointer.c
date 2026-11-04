#include <stdbool.h>
void func(bool b) {
    void* x = (void*)b;
}

// translate
//
// pub export fn func(arg_b: bool) void {
//     var b = arg_b;
//     _ = &b;
//     var x: ?*anyopaque = @ptrFromInt(@intFromBool(b));
//     _ = &x;
// }