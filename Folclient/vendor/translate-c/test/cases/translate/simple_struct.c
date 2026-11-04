struct Foo {
    int x;
};

// translate
//
// const struct_Foo = extern struct {
//     x: c_int,
// };
// 
// pub const Foo = struct_Foo;
