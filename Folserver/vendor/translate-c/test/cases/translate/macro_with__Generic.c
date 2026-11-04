#define type_name(X) _Generic((X), \
    int: "int",                    \
    float: "float"                 \
)

#define type_name_default(X) _Generic((X), \
    int: "int",                            \
    float: "float",                        \
    default: "unknown"                     \
)

// translate
//
// pub inline fn type_name(X: anytype) @TypeOf(switch (@TypeOf(X)) {
//     c_int => "int",
//     f32 => "float",
//     else => comptime unreachable,
// }) {
//     _ = &X;
//     return switch (@TypeOf(X)) {
//         c_int => "int",
//         f32 => "float",
//         else => comptime unreachable,
//     };
// }
// pub inline fn type_name_default(X: anytype) @TypeOf(switch (@TypeOf(X)) {
//     c_int => "int",
//     f32 => "float",
//     else => "unknown",
// }) {
//     _ = &X;
//     return switch (@TypeOf(X)) {
//         c_int => "int",
//         f32 => "float",
//         else => "unknown",
//     };
// }
