int x = ~((5 >= 3));

// translate
//
// pub export var x: c_int = ~@as(c_int, @intFromBool(@as(c_int, 5) >= @as(c_int, 3)));
