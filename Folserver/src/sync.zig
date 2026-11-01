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
