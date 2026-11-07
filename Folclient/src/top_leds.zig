const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");
const sync = @import("sync.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const red = Color{ .r = 255, .g = 0, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255 };
    pub const off = Color{ .r = 0, .g = 0, .b = 0 };
};

pub const INDICATOR_BRIGHTNESS: u8 = 5;
// Время в миллисекундах: раньше тут были «кадры по 4 в секунду», а tick() зовут 25 раз
// в секунду, поэтому синий индикатор гас через 1.6 с вместо 10.
const LISTEN_MAX_MS: u64 = 10_000;

pub const TopLeds = struct {
    muted: bool = false,
    listen_until_ms: u64 = 0,
    has_leds: bool = false,
    state: [36]u8 = @splat(255),
    // startListening/stopListening зовёт поток-обработчик, tick/apply — главный цикл.
    lock: sync.Mutex = .{},

    pub fn init() TopLeds {
        var tl = TopLeds{};
        if (c.access("/sys/class/leds/top-led1/brightness", c.W_OK) == 0) {
            tl.has_leds = true;
            tl.apply();
        }
        return tl;
    }

    pub fn setMuted(self: *TopLeds, mute: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.muted = mute;
        self.applyLocked();
    }

    pub fn startListening(self: *TopLeds) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.listen_until_ms = sync.nowMs() + LISTEN_MAX_MS;
        self.applyLocked();
    }

    pub fn stopListening(self: *TopLeds) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.listen_until_ms == 0) return;
        self.listen_until_ms = 0;
        self.applyLocked();
    }

    pub fn tick(self: *TopLeds) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.listen_until_ms != 0 and sync.nowMs() >= self.listen_until_ms) {
            self.listen_until_ms = 0;
            self.applyLocked();
        }
    }

    fn writeChannel(idx: usize, val: u8) bool {
        var path_buf: [64]u8 = undefined;
        const path = zfmt.bufPrintZ(&path_buf, "/sys/class/leds/top-led{d}/brightness", .{idx}) catch return false;
        var val_buf: [16]u8 = undefined;
        const val_str = std.fmt.bufPrint(&val_buf, "{d}\n", .{val}) catch return false;

        const f = c.open(path.ptr, c.O_WRONLY);
        if (f < 0) return false;
        defer _ = c.close(f);
        const n = c.write(f, val_str.ptr, val_str.len);
        return n > 0;
    }

    fn setChan(self: *TopLeds, idx: usize, val: u8) void {
        if (writeChannel(idx, val)) self.state[idx - 1] = val;
    }

    fn currentColor(self: *const TopLeds) struct { col: Color, br: u8 } {
        if (self.listen_until_ms != 0) return .{ .col = Color.blue, .br = INDICATOR_BRIGHTNESS };
        if (self.muted) return .{ .col = Color.red, .br = INDICATOR_BRIGHTNESS };
        return .{ .col = Color.off, .br = 0 };
    }

    pub fn apply(self: *TopLeds) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.applyLocked();
    }

    fn applyLocked(self: *TopLeds) void {
        if (!self.has_leds) return;

        const cur = self.currentColor();
        const r_val: u8 = @intCast((@as(u16, cur.col.r) * @as(u16, cur.br)) / 255);
        const g_val: u8 = @intCast((@as(u16, cur.col.g) * @as(u16, cur.br)) / 255);
        const b_val: u8 = @intCast((@as(u16, cur.col.b) * @as(u16, cur.br)) / 255);

        var x: usize = 1;
        while (x <= 12) : (x += 1) {
            const g_idx = (x * 3) - 2;
            const r_idx = (x * 3) - 1;
            const b_idx = x * 3;

            if (self.state[g_idx - 1] != g_val) self.setChan(g_idx, g_val);
            if (self.state[r_idx - 1] != r_val) self.setChan(r_idx, r_val);
            if (self.state[b_idx - 1] != b_val) self.setChan(b_idx, b_val);
        }
    }
};

