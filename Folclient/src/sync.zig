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

/// Монотонные миллисекунды. Все тайминги дисплея и светодиодов считаются от них,
/// а не от числа кадров: цикл микрофона крутится на 25 FPS, и «кадры» как единица
/// времени уже один раз привели к тому, что эмоции и громкость показывались в 6 раз короче.
pub fn nowMs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(@intCast(c.CLOCK_MONOTONIC), &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}
