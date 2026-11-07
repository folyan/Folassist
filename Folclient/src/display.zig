const std = @import("std");
const protocol = @import("protocol");
const c = @import("c");
const zfmt = @import("zfmt");
const sync = @import("sync.zig");

pub const Mode = enum {
    clock,
    emotion,
};

const MOUTH: u5 = 16;

// Все времена в миллисекундах (см. sync.nowMs).
const VOLUME_SHOW_MS: u64 = 1500;
const BLINK_EVERY_MS: u64 = 3500;
const BLINK_LEN_MS: u64 = 140;
pub const FOREVER_MS: u64 = std.math.maxInt(u64) / 2;

/// Какой глаз у «what» (непонимание) двойной высоты. Второй глаз как у def.
const WHAT_TALL_EYE: u1 = 0; // 0 = левый (H1), 1 = правый (M2)

pub const Display = struct {
    brightness: u8 = 120,
    default_brightness: u8 = 120,
    night_mode: bool = false,

    mode: Mode = .clock,
    current_emotion: protocol.Emotion = .def,
    emotion_until_ms: u64 = 0,
    blink_phase_ms: u64 = 0,

    current_mask: u32 = 0,
    written: [30]u8 = @splat(255),
    has_leds: bool = false,

    vol_until_ms: u64 = 0,
    vol_value: u8 = 0,

    // showEmotion зовут из потока-обработчика ответов, tick — из главного цикла.
    lock: sync.Mutex = .{},

    pub fn init(default_br: u8) Display {
        var d = Display{
            .brightness = default_br,
            .default_brightness = default_br,
        };
        if (c.access("/sys/class/leds/clock-led1/brightness", c.W_OK) == 0) {
            d.has_leds = true;
        }
        return d;
    }

    pub fn setNightMode(self: *Display, enable: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.night_mode = enable;
        self.brightness = if (enable) 5 else self.default_brightness;
        self.forceRedraw();
    }

    /// Показать эмоцию на duration_ms. Рисуется сразу, не дожидаясь следующего tick.
    pub fn showEmotion(self: *Display, em: protocol.Emotion, duration_ms: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        const now = sync.nowMs();
        self.current_emotion = em;
        self.mode = .emotion;
        self.emotion_until_ms = now +| duration_ms;
        if (self.blink_phase_ms == 0) self.blink_phase_ms = now;
        if (self.vol_until_ms <= now) self.draw(now);
    }

    pub fn showVolume(self: *Display, v: u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        const now = sync.nowMs();
        self.vol_value = v;
        self.vol_until_ms = now + VOLUME_SHOW_MS;
        self.draw(now);
    }

    pub fn toggleFaceOrClock(self: *Display) void {
        self.lock.lock();
        defer self.lock.unlock();
        const now = sync.nowMs();
        if (self.mode == .clock) {
            self.mode = .emotion;
            self.current_emotion = .def;
            self.emotion_until_ms = FOREVER_MS;
            self.blink_phase_ms = now;
        } else {
            self.mode = .clock;
            self.emotion_until_ms = 0;
        }
        self.draw(now);
    }

    fn forceRedraw(self: *Display) void {
        self.written = @splat(255);
        self.applyMask(self.current_mask);
    }

    fn ledBit(num: u5) u32 {
        return @as(u32, 1) << (num - 1);
    }

    const H1 = 0;
    const M2 = 1;

    fn eyeRing(which: u1) u32 {
        if (which == H1) {
            return ledBit(2) | ledBit(29) | ledBit(22) | ledBit(18) | ledBit(23) | ledBit(30);
        }
        return ledBit(11) | ledBit(13) | ledBit(12) | ledBit(15) | ledBit(14) | ledBit(9);
    }

    fn digitH1(d: u8) u32 {
        var m: u32 = 0;
        const a = ledBit(2);
        const b = ledBit(29);
        const c_seg = ledBit(22);
        const d_seg = ledBit(18);
        const e = ledBit(23);
        const f = ledBit(30);
        const g = ledBit(25);
        switch (d) {
            0 => m = a | b | c_seg | d_seg | e | f,
            1 => m = b | c_seg,
            2 => m = a | b | g | e | d_seg,
            3 => m = a | b | g | c_seg | d_seg,
            4 => m = f | g | b | c_seg,
            5 => m = a | f | g | c_seg | d_seg,
            6 => m = a | f | e | d_seg | c_seg | g,
            7 => m = a | b | c_seg,
            8 => m = a | b | c_seg | d_seg | e | f | g,
            9 => m = a | b | c_seg | d_seg | f | g,
            else => {},
        }
        return m;
    }

    fn digitH2(d: u8) u32 {
        var m: u32 = 0;
        const a = ledBit(27);
        const b = ledBit(26);
        const c_seg = ledBit(20);
        const d_seg = ledBit(19);
        const e = ledBit(24);
        const f = ledBit(28);
        const g = ledBit(21);
        switch (d) {
            0 => m = a | b | c_seg | d_seg | e | f,
            1 => m = b | c_seg,
            2 => m = a | b | g | e | d_seg,
            3 => m = a | b | g | c_seg | d_seg,
            4 => m = f | g | b | c_seg,
            5 => m = a | f | g | c_seg | d_seg,
            6 => m = a | f | e | d_seg | c_seg | g,
            7 => m = a | b | c_seg,
            8 => m = a | b | c_seg | d_seg | e | f | g,
            9 => m = a | b | c_seg | d_seg | f | g,
            else => {},
        }
        return m;
    }

    fn digitM1(d: u8) u32 {
        var m: u32 = 0;
        const a = ledBit(1);
        const b = ledBit(3);
        const c_seg = ledBit(8);
        const d_seg = ledBit(6);
        const e = ledBit(7);
        const f = ledBit(5);
        const g = ledBit(4);
        switch (d) {
            0 => m = a | b | c_seg | d_seg | e | f,
            1 => m = b | c_seg,
            2 => m = a | b | g | e | d_seg,
            3 => m = a | b | g | c_seg | d_seg,
            4 => m = f | g | b | c_seg,
            5 => m = a | f | g | c_seg | d_seg,
            6 => m = a | f | e | d_seg | c_seg | g,
            7 => m = a | b | c_seg,
            8 => m = a | b | c_seg | d_seg | e | f | g,
            9 => m = a | b | c_seg | d_seg | f | g,
            else => {},
        }
        return m;
    }

    fn digitM2(d: u8) u32 {
        var m: u32 = 0;
        const a = ledBit(11);
        const b = ledBit(13);
        const c_seg = ledBit(12);
        const d_seg = ledBit(15);
        const e = ledBit(14);
        const f = ledBit(9);
        const g = ledBit(10);
        switch (d) {
            0 => m = a | b | c_seg | d_seg | e | f,
            1 => m = b | c_seg,
            2 => m = a | b | g | e | d_seg,
            3 => m = a | b | g | c_seg | d_seg,
            4 => m = f | g | b | c_seg,
            5 => m = a | f | g | c_seg | d_seg,
            6 => m = a | f | e | d_seg | c_seg | g,
            7 => m = a | b | c_seg,
            8 => m = a | b | c_seg | d_seg | e | f | g,
            9 => m = a | b | c_seg | d_seg | f | g,
            else => {},
        }
        return m;
    }

    fn writeLed(idx: usize, br: u8) bool {
        var path_buf: [64]u8 = undefined;
        const path = zfmt.bufPrintZ(&path_buf, "/sys/class/leds/clock-led{d}/brightness", .{idx}) catch return false;
        var val_buf: [16]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "{d}\n", .{br}) catch return false;

        const f = c.open(path.ptr, c.O_WRONLY);
        if (f < 0) return false;
        defer _ = c.close(f);
        const n = c.write(f, val.ptr, val.len);
        return n > 0;
    }

    fn applyMask(self: *Display, mask: u32) void {
        if (!self.has_leds) return;
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            const bit = @as(u32, 1) << @intCast(i);
            const br: u8 = if ((mask & bit) != 0) self.brightness else 0;
            if (self.written[i] != br) {
                if (writeLed(i + 1, br)) self.written[i] = br;
            }
        }
        self.current_mask = mask;
    }

    fn volumeMask(v: u8) u32 {
        const val: u8 = if (v > 100) 100 else v;
        var m: u32 = 0;
        if (val >= 100) {
            m |= digitH2(1) | digitM1(0) | digitM2(0);
            return m;
        }
        if (val >= 10) m |= digitM1(val / 10);
        m |= digitM2(val % 10);
        return m;
    }

    pub fn tick(self: *Display) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.draw(sync.nowMs());
    }

    fn isBlinking(self: *const Display, now: u64) bool {
        const t = (now -| self.blink_phase_ms) % (BLINK_EVERY_MS + BLINK_LEN_MS);
        return t >= BLINK_EVERY_MS;
    }

    fn eyesMask(self: *const Display, blinking: bool) u32 {
        if (blinking) {
            // моргание: у всех эмоций глаза схлопываются в нижнюю/среднюю чёрточку
            if (self.current_emotion == .happy) return ledBit(25) | ledBit(10);
            return ledBit(18) | ledBit(15);
        }
        const def_l = ledBit(22) | ledBit(18) | ledBit(23) | ledBit(25);
        const def_r = ledBit(12) | ledBit(15) | ledBit(14) | ledBit(10);
        return switch (self.current_emotion) {
            .def => def_l | def_r,
            .happy => ledBit(30) | ledBit(2) | ledBit(29) | ledBit(9) | ledBit(11) | ledBit(13),
            .sad => ledBit(22) | ledBit(18) | ledBit(14) | ledBit(15),
            // непонимание: один глаз — цифра «0» (кольцо из 6 сегментов, без средней
            // черты), второй как у def
            .what => if (WHAT_TALL_EYE == H1)
                eyeRing(H1) | def_r
            else
                def_l | eyeRing(M2),
        };
    }

    /// Рисует текущее состояние. Вызывать только под self.lock.
    fn draw(self: *Display, now: u64) void {
        if (!self.has_leds) return;

        if (self.vol_until_ms > now) {
            self.applyMask(volumeMask(self.vol_value));
            return;
        }

        if (self.mode == .emotion and now >= self.emotion_until_ms) {
            self.mode = .clock;
        }

        if (self.mode == .emotion) {
            self.applyMask(ledBit(MOUTH) | self.eyesMask(self.isBlinking(now)));
            return;
        }

        var t = c.time(null);
        var tm_val: c.struct_tm = undefined;
        _ = c.localtime_r(&t, &tm_val);

        const h = @as(u8, @intCast(tm_val.tm_hour));
        const m = @as(u8, @intCast(tm_val.tm_min));

        var mask: u32 = ledBit(16) | ledBit(17);
        mask |= digitH1(h / 10);
        mask |= digitH2(h % 10);
        mask |= digitM1(m / 10);
        mask |= digitM2(m % 10);

        self.applyMask(mask);
    }
};
