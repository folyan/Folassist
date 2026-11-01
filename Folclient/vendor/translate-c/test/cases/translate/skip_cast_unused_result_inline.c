struct _obj {
  int refcnt;
};

typedef struct _obj obj;
typedef void*       ptr;
typedef int         bool;

ptr f(ptr x);

#define f(x) ((__typeof__(x)) f(x))

bool g(obj *x) {
  (__typeof__(x)) f(x);
  return 0;
}

// translate
//
// pub const struct__obj = extern struct {
//     refcnt: c_int,
//     pub const g = __root.g;
// };
// pub const obj = struct__obj;
// pub const ptr = ?*anyopaque;
// pub const @"bool" = c_int;
// pub extern fn f(x: ptr) ptr;
// pub export fn g(arg_x: [*c]obj) @"bool" {
//     var x = arg_x;
//     _ = &x;
//     _ = f(@ptrCast(@alignCast(x)));
//     return 0;
// }
