typedef int (*fn_ptr_old_style)();
typedef int (*fn_ptr_void)(void);

struct api_table {
    int (*create_thing)();
    int (*destroy_thing)(void);
};

int no_proto_func();

// translate
// target=wasm32-emscripten
//
// pub const fn_ptr_old_style = ?*const fn () callconv(.c) c_int;
// pub const fn_ptr_void = ?*const fn () callconv(.c) c_int;
// pub const struct_api_table = extern struct {
//     create_thing: ?*const fn () callconv(.c) c_int,
//     destroy_thing: ?*const fn () callconv(.c) c_int,
// };
// pub extern fn no_proto_func() c_int;
