const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");
const sync = @import("sync.zig");

pub const Action = enum {
    none,
    wake,
    vol_down,
    vol_up,
    mic_mute_toggle,
    toggle_face_clock,
};

const InputEvent = extern struct {
    time_sec: usize,
    time_usec: usize,
    type: u16,
    code: u16,
    value: i32,
};

const EV_KEY: u16 = 0x01;

pub const KEY_ACTION: u16 = 164;
pub const KEY_VOLDOWN: u16 = 114;
pub const KEY_VOLUP: u16 = 115;
pub const KEY_MICMUTE: u16 = 248;
pub const KEY_CENTER: u16 = 704;

pub const Buttons = struct {
    fd: c_int = -1,

    pub fn init(path: [:0]const u8) Buttons {
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Buttons) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn poll(self: *Buttons) Action {
        if (self.fd < 0) return .none;

        var ev: InputEvent = undefined;
        while (true) {
            const n = c.read(self.fd, &ev, @sizeOf(InputEvent));
            if (n < @sizeOf(InputEvent)) break;

            if (ev.type == EV_KEY and (ev.value == 1 or ev.value == 2)) {
                switch (ev.code) {
                    KEY_ACTION => if (ev.value == 1) return .wake,
                    KEY_VOLDOWN => return .vol_down,
                    KEY_VOLUP => return .vol_up,
                    KEY_MICMUTE => if (ev.value == 1) return .mic_mute_toggle,
                    KEY_CENTER => if (ev.value == 1) return .toggle_face_clock,
                    else => {},
                }
            }
        }
        return .none;
    }
};

pub var volume: u8 = 30;

// amixer запускается в фоне и не чаще раза в VOL_APPLY_GAP_MS. Раньше тут был c.system(),
// который блокировал главный цикл на десятки миллисекунд при каждом нажатии (а при
// удержании кнопки — на каждый repeat), и лица/цифры на дисплее «подмигивали».
const VOL_APPLY_GAP_MS: u64 = 120;
var vol_dirty: bool = false;
var vol_applied_ms: u64 = 0;

fn runAmixer(v: u8) void {
    var buf: [192]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&buf, "amixer -q sset StereoVolume {d}% >/dev/null 2>&1 || amixer -q sset Master {d}% >/dev/null 2>&1", .{ v, v }) catch return;
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd.ptr };

    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        // двойной fork: внука усыновляет init, зомби не остаётся и ждать его не нужно
        if (c.fork() == 0) {
            _ = c.execv("/bin/sh", @ptrCast(&argv));
            c._exit(127);
        }
        c._exit(0);
    }
    _ = c.waitpid(pid, null, 0);
}

/// Применяет последнюю запрошенную громкость. Зовётся каждый кадр из главного цикла.
pub fn flushVolume() void {
    if (!vol_dirty) return;
    const now = sync.nowMs();
    if (vol_applied_ms != 0 and now -| vol_applied_ms < VOL_APPLY_GAP_MS) return;
    vol_dirty = false;
    vol_applied_ms = now;
    runAmixer(volume);
}

pub fn setVolume(v: u8) void {
    volume = if (v > 100) 100 else v;
    vol_dirty = true;
    flushVolume();
}

pub fn adjustVolume(up: bool) void {
    if (up) {
        setVolume(if (volume >= 95) 100 else volume + 5);
    } else {
        setVolume(if (volume < 5) 0 else volume - 5);
    }
}

