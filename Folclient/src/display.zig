const std = @import("std");
const protocol = @import("protocol");
const c = @import("c");
const zfmt = @import("zfmt");

pub const Mode = enum {
    clock,
    emotion,
};

const MOUTH: u5 = 16;

pub const Display = struct {
    brightness: u8 = 120,
    default_brightness: u8 = 120,
    night_mode: bool = false,

    mode: Mode = .clock,
    current_emotion: protocol.Emotion = .def,
    emotion_frames_left: u32 = 0,

    blink_timer: u32 = 20,
    blinking: bool = false,

    current_mask: u32 = 0,
    written: [30]u8 = @splat(255),
    has_leds: bool = false,

    vol_frames_left: u32 = 0,
    vol_value: u8 = 0,

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
        self.night_mode = enable;
        self.brightness = if (enable) 5 else self.default_brightness;
        self.forceRedraw();
    }

    pub fn showEmotion(self: *Display, em: protocol.Emotion, duration_sec: u32) void {
        self.current_emotion = em;
        self.mode = .emotion;
        self.emotion_frames_left = duration_sec * 4;
        self.forceRedraw();
    }

    pub fn showVolume(self: *Display, v: u8) void {
        self.vol_value = v;
        self.vol_frames_left = 6;
    }

    pub fn toggleFaceOrClock(self: *Display) void {
        if (self.mode == .clock) {
            self.mode = .emotion;
            self.current_emotion = .def;
            self.emotion_frames_left = std.math.maxInt(u32);
        } else {
            self.mode = .clock;
            self.emotion_frames_left = 0;
        }
        self.forceRedraw();
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
        if (!self.has_leds) return;

        if (self.vol_frames_left > 0) {
            self.vol_frames_left -= 1;
            self.applyMask(volumeMask(self.vol_value));
            return;
        }

        if (self.mode == .emotion) {
            if (self.blink_timer > 0) {
                self.blink_timer -= 1;
            } else {
                self.blinking = !self.blinking;
                self.blink_timer = if (self.blinking) 1 else 20;
            }
            if (self.emotion_frames_left > 0) {
                self.emotion_frames_left -= 1;
            } else {
                self.mode = .clock;
                self.blinking = false;
            }
        } else {
            self.blinking = false;
        }

        if (self.mode == .emotion) {
            var mask: u32 = ledBit(MOUTH);
            if (self.blinking) {
                if (self.current_emotion == .happy) {
                    mask |= ledBit(25) | ledBit(10);
                } else {
                    mask |= ledBit(18) | ledBit(15);
                }
            } else switch (self.current_emotion) {
                .def => {
                    mask |= ledBit(22) | ledBit(18) | ledBit(23) | ledBit(25);
                    mask |= ledBit(12) | ledBit(15) | ledBit(14) | ledBit(10);
                },
                .happy => {
                    mask |= ledBit(30) | ledBit(2) | ledBit(29);
                    mask |= ledBit(9) | ledBit(11) | ledBit(13);
                },
                .sad => {
                    mask |= ledBit(22) | ledBit(18);
                    mask |= ledBit(14) | ledBit(15);
                },
                .what => {
                    mask |= eyeRing(H1) | ledBit(25);
                    mask |= eyeRing(M2) | ledBit(10);
                },
            }
            self.applyMask(mask);
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
