typedef struct {
    int a : 2;
} Foo;

int foo(Foo foo) {
    return foo.a;
}

// translate
//
// pub const Foo = opaque {};
//
// warning: unable to translate function, demoted to extern
// pub extern fn foo(arg_foo_1: Foo) c_int;
