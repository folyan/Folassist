const std = @import("std");
const c = @import("c");

pub const Mutex = struct {
    m: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.m);
    }
};

// translate-c делает struct timespec opaque, поэтому объявляем clock_gettime сами.
// Раскладка timespec на linux/aarch64 (musl): два long — секунды и наносекунды.
const CLOCK_MONOTONIC: c_int = 1;
extern "c" fn clock_gettime(clk: c_int, ts: *[2]c_long) c_int;

/// Монотонные миллисекунды. Все тайминги дисплея, светодиодов и громкости считаются от них.
pub fn nowMs() u64 {
    var ts: [2]c_long = .{ 0, 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts[0])) * 1000 + @as(u64, @intCast(ts[1])) / 1_000_000;
}
