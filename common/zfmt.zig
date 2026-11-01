const std = @import("std");

pub const Error = std.fmt.BufPrintError || error{NoSpaceLeft};

pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) Error![:0]u8 {
    const s = try std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub fn readFile(comptime C: type, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pz);
    const f = C.fopen(@ptrCast(pz.ptr), @ptrCast("rb")) orelse return error.FileOpenFailed;
    defer _ = C.fclose(f);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = C.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}
