const std = @import("std");
const c = @import("c");
const sync = @import("sync.zig");

// Защита от перебора пароля: после BAN_AFTER неверных паролей с одного IP
// он отсекается на BAN_SEC секунд. Считается и для TCP (hello/model), и для HTTP (/yt).
pub const BAN_AFTER: u32 = 5;
pub const BAN_SEC: i64 = 15 * 60;
const SLOTS = 256;

const Entry = struct {
    ip: u32 = 0,
    fails: u32 = 0,
    until: i64 = 0,
    used: bool = false,
};

var tab: [SLOTS]Entry = @splat(.{});
var lock: sync.Mutex = .{};

fn now() i64 {
    return @intCast(c.time(null));
}

/// IPv4-адрес пира (в сетевом порядке) или 0, если не удалось узнать.
pub fn peerIp(fd: c_int) u32 {
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    var len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getpeername(fd, @ptrCast(&addr), &len) != 0) return 0;
    return addr.sin_addr.s_addr;
}

fn findLocked(ip: u32) ?*Entry {
    for (&tab) |*e| {
        if (e.used and e.ip == ip) return e;
    }
    return null;
}

pub fn isBanned(ip: u32) bool {
    if (ip == 0) return false;
    lock.lock();
    defer lock.unlock();
    const e = findLocked(ip) orelse return false;
    return e.until > now();
}

pub fn noteFail(ip: u32) void {
    if (ip == 0) return;
    lock.lock();
    defer lock.unlock();
    var e = findLocked(ip);
    if (e == null) {
        // свободный слот, а если нет — самый «старый» (с наименьшим временем бана)
        var best: *Entry = &tab[0];
        for (&tab) |*x| {
            if (!x.used) {
                best = x;
                break;
            }
            if (x.until < best.until) best = x;
        }
        best.* = .{ .ip = ip, .fails = 0, .until = 0, .used = true };
        e = best;
    }
    const ent = e.?;
    ent.fails += 1;
    if (ent.fails >= BAN_AFTER) {
        ent.until = now() + BAN_SEC;
        ent.fails = 0;
    }
}

pub fn noteOk(ip: u32) void {
    if (ip == 0) return;
    lock.lock();
    defer lock.unlock();
    if (findLocked(ip)) |e| e.* = .{};
}
