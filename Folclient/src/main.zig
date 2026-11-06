const std = @import("std");
const builtin = @import("builtin");
const zfmt = @import("zfmt");
const pubkey = @import("pubkey");
const events = @import("events.zig");
const protocol = @import("protocol");
const display_mod = @import("display.zig");
const top_leds_mod = @import("top_leds.zig");
const buttons_mod = @import("buttons.zig");
const c = @import("c");
const net = protocol.Net(c);

const alloc = std.heap.c_allocator;

const RATE = 16000;
const FRAME = 4000;
const FPS = 4;
const GATE_HOLD_FRAMES = 10;

extern "c" fn signal(sig: c_int, handler: usize) usize;

const Config = struct {
    id: u8 = 0,
    id_set: bool = false,
    pass: []const u8 = "",
    server_ip: [:0]const u8 = "127.0.0.1",
    server_port: u16 = 9000,
    http_port: u16 = 9001,
    model: [:0]const u8 = "/dev/shm/model",
    mic: [:0]const u8 = "single_plugin",
    spk: [:0]const u8 = "plug:stereo_playback",
    input_dev: [:0]const u8 = "/dev/input/event0",
    brightness: u8 = 120,
    wake_sound: ?[]const u8 = null,
    city: []const u8 = "Омске",
    lat: f64 = 54.99,
    lon: f64 = 73.37,
    wait_sec: u32 = 4,
    collect_sec: u32 = 1,
    dialog_sec: u32 = 0,
    prompt_path: ?[]const u8 = null,
    verbose: bool = false,
    ringtone: ?[]const u8 = null,
    remind_sound: ?[]const u8 = null,
    store: ?[]const u8 = null,
    gate: u32 = 200,
    gain: f32 = 3.0,
    cmd_sim: u32 = 60,
    cloud: bool = true,
    level: bool = false,
};

var cfg: Config = .{};
var disp: display_mod.Display = undefined;
var top_leds: top_leds_mod.TopLeds = undefined;
var btns: buttons_mod.Buttons = undefined;
var mic_muted: bool = false;

var client_prompt: ?[]u8 = null;

var acc: std.ArrayList(u8) = .empty;
var acc_force_ai = false;
var collect_frames: u32 = 0;
var saved_argv: []?[*:0]const u8 = &.{};

var utt: std.ArrayList(u8) = .empty;
const MAX_UTT_BYTES = 16000 * 2 * 30;
var pending_reminder: ?i64 = null;
var reminder_deadline: i64 = 0;
const REMINDER_WAIT_SEC: i64 = 30;

var stop_buf: [16][]const u8 = undefined;
var stop_count: usize = 0;

fn addStop(w: []const u8) void {
    if (stop_count < stop_buf.len and w.len > 0) {
        stop_buf[stop_count] = w;
        stop_count += 1;
    }
}

fn isStopPhrase(s: []const u8) bool {
    for (stop_buf[0..stop_count]) |w| {
        if (std.mem.eql(u8, s, w)) return true;
        if (std.mem.startsWith(u8, s, w) and s.len > w.len and s[w.len] == ' ') return true;
    }
    return false;
}

var wake_buf: [16][]const u8 = undefined;
var wake_count: usize = 0;

fn addWake(w: []const u8) void {
    if (wake_count < wake_buf.len and w.len > 0) {
        wake_buf[wake_count] = w;
        wake_count += 1;
    }
}
var sock: c_int = -1;
var stream_pid: c.pid_t = 0;
var ring_pid: c.pid_t = 0;
var pending_play: ?[]u8 = null;

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!cfg.verbose) return;
    std.debug.print("[folclient] " ++ fmt ++ "\n", args);
}

const USAGE =
    \\folclient [опции]
    \\  --server=IP[:порт]   сервер, по умолчанию 127.0.0.1:9000
    \\  --http-port=N        порт HTTP-релея сервера, по умолчанию 9001
    \\  --id=N               номер клиента 0-255, по умолчанию случайный
    \\  --pass=ПАРОЛЬ        пароль сервера (без символа ;)
    \\  --model=ПАПКА        папка ONNX стриминговой модели, по умолчанию /dev/shm/model
    \\  --mic=УСТРОЙСТВО     ALSA устройство записи, по умолчанию single_plugin
    \\  --spk=УСТРОЙСТВО     ALSA устройство воспроизведения, по умолчанию plug:stereo_playback
    \\  --input=ФАЙЛ         файл кнопок input_event, по умолчанию /dev/input/event0
    \\  --brightness=N       яркость дисплея и верхнего кольца (0-255), по умолчанию 120
    \\  --wake=СЛОВО         слово активации, можно несколько, по умолчанию фокус, фокс и фкус
    \\  --stop=СЛОВО         слово остановки, можно несколько, по умолчанию стоп и хватит
    \\  --wake-sound=ФАЙЛ    звук после активации
    \\  --ringtone=ФАЙЛ      мелодия будильника, играет по кругу до остановки
    \\  --remind-sound=ФАЙЛ  звук перед напоминанием
    \\  --store=ФАЙЛ         файл будильников и напоминаний
    \\  --prompt=ФАЙЛ        дополнительный промпт для ИИ
    \\  --city=ТЕКСТ         город для погоды, по умолчанию Омске
    \\  --lat=N --lon=N      координаты для погоды
    \\  --wait=СЕК           ожидание команды после слова активации, по умолчанию 5
    \\  --collect=СЕК        сбор фраз в одну команду, по умолчанию 3
    \\  --dialog=СЕК         окно диалога с ИИ без слова активации, по умолчанию 10
    \\  --gate=N             не распознавать тишину ниже уровня N, по умолчанию 550, 0 выключает
    \\  --level              печатать уровень звука, чтобы подобрать --gate
    \\  --gain=N             усиление перед распознаванием, по умолчанию 3
    \\  --no-cloud          не отправлять фразу на облачное распознавание
    \\  --cmd-sim=N         похожесть слова команды в процентах, по умолчанию 80
    \\  --verbose            подробный лог
    \\  --help               эта справка
;

fn frameRms(buf: *const [FRAME]i16) u32 {
    var sum: u64 = 0;
    for (buf) |s| {
        const v: i32 = s;
        sum += @intCast(v * v);
    }
    return std.math.sqrt(sum / FRAME);
}

fn val(arg: []const u8, comptime key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, key ++ "=")) return arg[key.len + 1 ..];
    return null;
}

fn openCapture() !*c.FILE {
    var b: [256]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "arecord -q -D {s} -c 1 -f S16_LE -r {d} -t raw", .{ cfg.mic, RATE }) catch return error.AudioDeviceError;
    return c.popen(cmd.ptr, "r") orelse error.AudioDeviceError;
}

fn readFrame(f: *c.FILE, buf: *[FRAME]i16) !void {
    const bytes: [*]u8 = @ptrCast(buf);
    var got: usize = 0;
    while (got < FRAME * 2) {
        const n = c.fread(bytes + got, 1, FRAME * 2 - got, f);
        if (n == 0) return error.CaptureFailed;
        got += n;
    }
}

fn flushMic(f: *c.FILE) void {
    _ = f;
}

const Speaker = struct {
    handle: ?*c.snd_pcm_t = null,
    rate: u32 = 0,

    fn open(self: *Speaker, rate: u32) !void {
        var h: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&h, cfg.spk.ptr, c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.AudioDeviceError;
        errdefer _ = c.snd_pcm_close(h.?);
        if (c.snd_pcm_set_params(h.?, c.SND_PCM_FORMAT_S16_LE, c.SND_PCM_ACCESS_RW_INTERLEAVED, 1, rate, 1, 500_000) < 0) return error.AudioDeviceError;
        self.handle = h;
        self.rate = rate;
    }

    fn write(self: *Speaker, rate: u32, pcm: []const u8) void {
        if (self.handle != null and self.rate != rate) self.close();
        if (self.handle == null) self.open(rate) catch return;
        const h = self.handle.?;

        const total = pcm.len / 2;
        deaf_frames += @as(u32, @intCast((total / rate + 1) * FPS));
        var off: usize = 0;
        var failures: u32 = 0;
        while (off < total) {
            const r = c.snd_pcm_writei(h, pcm.ptr + off * 2, total - off);
            if (r < 0) {
                failures += 1;
                if (failures > 20 or c.snd_pcm_recover(h, @intCast(r), 1) < 0) return;
                continue;
            }
            off += @intCast(r);
        }
        if (c.snd_pcm_state(h) == c.SND_PCM_STATE_PREPARED) _ = c.snd_pcm_start(h);
    }

    fn close(self: *Speaker) void {
        const h = self.handle orelse return;
        _ = c.snd_pcm_drain(h);
        _ = c.snd_pcm_close(h);
        self.handle = null;
    }
};

var speaker: Speaker = .{};
var deaf_frames: u32 = 0;

fn playOnce(rate: u32, pcm: []const u8) void {
    speaker.write(rate, pcm);
    speaker.close();
}

fn playWakeSound() void {
    const p = cfg.wake_sound orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    var b: [512]u8 = undefined;
    const redirect: []const u8 = if (cfg.verbose) "" else " 2>/dev/null";
    const cmd = zfmt.bufPrintZ(&b, "aplay -D {s} -q '{s}'{s}", .{ cfg.spk, p, redirect }) catch return;
    const rc = c.system(@ptrCast(cmd.ptr));
    if (rc != 0) log("wake-sound: aplay вернул {d} для «{s}»", .{ rc, p });
}

fn spawnShell(cmd: [*:0]const u8) c.pid_t {
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", cmd };
    const pid = c.fork();
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    return pid;
}

fn killGroup(pid: *c.pid_t) void {
    if (pid.* <= 0) return;
    _ = c.kill(-pid.*, c.SIGCONT);
    _ = c.kill(-pid.*, c.SIGTERM);
    _ = c.waitpid(pid.*, null, 0);
    pid.* = 0;
}

fn stopStream() void {
    killGroup(&stream_pid);
}

var stream_paused = false;
var stream_pause_frames: u32 = 0;

fn pauseStream() void {
    if (stream_pid <= 0 or stream_paused) return;
    _ = c.kill(-stream_pid, c.SIGSTOP);
    stream_paused = true;
    stream_pause_frames = 10 * FPS;
}

fn resumeStream() void {
    stream_pause_frames = 0;
    if (!stream_paused) return;
    stream_paused = false;
    if (stream_pid > 0) _ = c.kill(-stream_pid, c.SIGCONT);
}

fn stopRing() void {
    killGroup(&ring_pid);
}

fn startRing() void {
    const p = cfg.ringtone orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    stopRing();
    var b: [512]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "while :; do aplay -D {s} -q '{s}' >/dev/null 2>&1 || sleep 1; done", .{ cfg.spk, p }) catch return;
    const pid = spawnShell(cmd.ptr);
    if (pid > 0) ring_pid = pid;
}

fn reapStream() void {
    if (stream_pid > 0 and c.waitpid(stream_pid, null, c.WNOHANG) != 0) stream_pid = 0;
}

fn startStream(path: []const u8) void {
    if (std.mem.indexOfScalar(u8, path, '\'') != null or path.len == 0 or path[0] != '/') return;
    stopStream();
    var b: [768]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "wget -qO- 'http://{s}:{d}{s}' | aplay -D {s} -q", .{ cfg.server_ip, cfg.http_port, path, cfg.spk }) catch return;
    const pid = spawnShell(cmd.ptr);
    if (pid <= 0) return;
    stream_pid = pid;
    stream_paused = false;
    log("поток запущен (pid {d})", .{pid});
}

fn dial() !c_int {
    const fd = c.socket(@intCast(c.AF_INET), @intCast(c.SOCK_STREAM), 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = std.mem.nativeToBig(u16, cfg.server_port);
    if (c.inet_pton(@intCast(c.AF_INET), @ptrCast(cfg.server_ip.ptr), &addr.sin_addr) != 1) return error.BadServerAddr;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) return error.ConnectFailed;

    var one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_KEEPALIVE, &one, @sizeOf(c_int));
    var tv = std.mem.zeroes(c.struct_timeval);
    tv.tv_sec = 60;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    return fd;
}

const CacheEntry = struct {
    text: []u8,
    rate: u32,
    pcm: []u8,
};
var cache_list: std.ArrayList(CacheEntry) = .empty;

const REMIND_PHRASE = "Напоминаю";

fn cachedEntry(text: []const u8) ?*const CacheEntry {
    for (cache_list.items) |*e| {
        if (std.mem.eql(u8, e.text, text)) return e;
    }
    return null;
}

fn parseCache(payload: []const u8) void {
    for (cache_list.items) |e| {
        alloc.free(e.text);
        alloc.free(e.pcm);
    }
    cache_list.clearRetainingCapacity();

    var off: usize = 0;
    while (off + 10 <= payload.len) {
        const klen = std.mem.readInt(u16, payload[off..][0..2], .little);
        const rate = std.mem.readInt(u32, payload[off + 2 ..][0..4], .little);
        const plen = std.mem.readInt(u32, payload[off + 6 ..][0..4], .little);
        off += 10;
        if (off + klen + plen > payload.len) break;

        const text = alloc.dupe(u8, payload[off .. off + klen]) catch break;
        off += klen;
        const pcm = alloc.dupe(u8, payload[off .. off + plen]) catch {
            alloc.free(text);
            break;
        };
        off += plen;
        cache_list.append(alloc, .{ .text = text, .rate = rate, .pcm = pcm }) catch {
            alloc.free(text);
            alloc.free(pcm);
            break;
        };
    }
    log("кэш с сервера: {d} фраз", .{cache_list.items.len});
}

fn randomId() u8 {
    const f = c.fopen(@ptrCast("/dev/urandom"), @ptrCast("rb")) orelse return @truncate(@as(u64, @intCast(c.time(null))));
    defer _ = c.fclose(f);
    var b: [1]u8 = .{1};
    _ = c.fread(&b, 1, 1, f);
    return b[0];
}

fn capitalizeFirst(buf: []u8, w: []const u8) []const u8 {
    const n = @min(w.len, buf.len);
    @memcpy(buf[0..n], w[0..n]);
    if (n >= 2 and buf[0] == 0xD0 and buf[1] >= 0xB0 and buf[1] <= 0xBF) {
        buf[1] -= 0x20;
    } else if (n >= 2 and buf[0] == 0xD1 and buf[1] >= 0x80 and buf[1] <= 0x8F) {
        buf[0] = 0xD0;
        buf[1] += 0x20;
    } else if (n >= 1 and buf[0] >= 'a' and buf[0] <= 'z') {
        buf[0] -= 0x20;
    }
    return buf[0..n];
}

fn connectServer() !c_int {
    const fd = try dial();
    errdefer _ = c.close(fd);
    var hb: [256]u8 = undefined;
    hb[0] = cfg.id;
    const info = try std.fmt.bufPrint(hb[1..], "{d:.4};{d:.4};{s};{s};{s}", .{ cfg.lat, cfg.lon, cfg.city, assetName(), cfg.pass });
    try net.sendFrame(fd, .hello, &.{hb[0 .. 1 + info.len]});
    if (client_prompt) |p| try net.sendFrame(fd, .prompt, &.{p});

    const f = try net.recvFrame(alloc, fd);
    defer f.deinit(alloc);
    if (f.msg_type == .cache) {
        if ((f.flags & protocol.CACHE_ID) != 0 and f.payload.len >= 1) {
            if (f.payload[0] != cfg.id) log("id занят, сервер выдал {d}", .{f.payload[0]});
            cfg.id = f.payload[0];
            parseCache(f.payload[1..]);
        } else parseCache(f.payload);
    }
    return fd;
}

fn closeSock() void {
    if (sock >= 0) _ = c.close(sock);
    sock = -1;
}

fn fetchModel() !void {
    log("модели нет, запрашиваю у сервера (код 00)", .{});
    const fd = try dial();
    defer _ = c.close(fd);

    try net.sendFrameF(fd, .cmd, @intFromEnum(protocol.Op.model_req), &.{cfg.pass});
    const h = try net.recvHeader(fd);
    if (h.msg_type != .model or h.len == 0) return error.ModelUnavailable;

    log("архив модели: {d} байт, распаковываю потоком в /dev/shm/", .{h.len});
    _ = signal(c.SIGPIPE, 1);
    const p = c.popen("gzip -dc | tar -x -f - -C /dev/shm/", "w") orelse return error.UntarFailed;
    var closed = false;
    defer {
        if (!closed) _ = c.pclose(p);
    }

    var chunk: [64 * 1024]u8 = undefined;
    var left: usize = h.len;
    while (left > 0) {
        const want = @min(left, chunk.len);
        try net.readAll(fd, chunk[0..want]);
        if (c.fwrite(&chunk, 1, want, p) != want) return error.UntarFailed;
        left -= want;
    }
    closed = true;
    if (c.pclose(p) != 0) return error.UntarFailed;
}

fn assetName() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm => "folclient-armhf",
        .aarch64 => "folclient-aarch64",
        else => "folclient",
    };
}

fn verifySums(sums_path: []const u8, sig_path: []const u8) bool {
    const msg = zfmt.readFile(c, alloc, sums_path) catch return false;
    defer alloc.free(msg);
    const sig_bytes = zfmt.readFile(c, alloc, sig_path) catch return false;
    defer alloc.free(sig_bytes);
    if (sig_bytes.len != 64) return false;
    var pub_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pub_bytes, pubkey.HEX) catch return false;
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_bytes) catch return false;
    var sig_arr: [64]u8 = undefined;
    @memcpy(&sig_arr, sig_bytes[0..64]);
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_arr);
    sig.verify(msg, pk) catch return false;
    return true;
}

fn handleUpdate(payload: []const u8) void {
    const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse return;
    const ver = payload[0..nl];
    const asset = payload[nl + 1 ..];
    if (ver.len == 0 or asset.len == 0) return;
    const new_ver = std.fmt.parseInt(u8, ver, 10) catch return;
    if (new_ver <= protocol.VERSION) return;
    if (c.getenv("FOLCLIENT_UPDATED_TO")) |e| {
        if (std.mem.eql(u8, std.mem.span(e), ver)) return;
    }
    if (std.mem.indexOfAny(u8, asset, "/'\" ") != null) return;

    var exe_buf: [512]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (n <= 0) return;
    const exe = exe_buf[0..@intCast(n)];

    log("обновление до {s}", .{ver});
    var fetch_buf: [512]u8 = undefined;
    const fetch = zfmt.bufPrintZ(&fetch_buf,
        "set -e; E='{s}'; wget -qO \"$E.sums\" 'http://{s}:{d}/update/sha256sums.txt'; " ++
        "wget -qO \"$E.sig\" 'http://{s}:{d}/update/sha256sums.txt.sig'",
        .{ exe, cfg.server_ip, cfg.http_port, cfg.server_ip, cfg.http_port }) catch return;
    if (c.system(fetch.ptr) != 0) {
        log("не скачал sums или подпись", .{});
        return;
    }
    var sums_buf: [600]u8 = undefined;
    var sig_buf: [600]u8 = undefined;
    const sums_p = zfmt.bufPrintZ(&sums_buf, "{s}.sums", .{exe}) catch return;
    const sig_p = zfmt.bufPrintZ(&sig_buf, "{s}.sig", .{exe}) catch return;
    if (!verifySums(sums_p, sig_p)) {
        log("подпись обновления неверна, отказ", .{});
        return;
    }
    var cmd_buf: [1536]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&cmd_buf,
        "set -e; E='{s}'; S=\"$E.sums\"; " ++
        "wget -qO \"$E.new\" 'http://{s}:{d}/update/{s}'; " ++
        "W=$(grep ' {s}$' \"$S\" | cut -d' ' -f1); " ++
        "echo \"$W  $E.new\" | sha256sum -c -; " ++
        "chmod +x \"$E.new\"; mv -f \"$E.new\" \"$E\"",
        .{ exe, cfg.server_ip, cfg.http_port, asset, asset }) catch return;
    if (c.system(cmd.ptr) != 0) {
        log("обновление не прошло проверку", .{});
        return;
    }

    var ver_z: [8:0]u8 = @splat(0);
    if (ver.len < ver_z.len) {
        @memcpy(ver_z[0..ver.len], ver);
        _ = c.setenv("FOLCLIENT_UPDATED_TO", &ver_z, 1);
    }
    log("обновлено до {s}, завершаюсь (перезапустит watchdog)", .{ver});
    std.process.exit(0);
}

fn askServer(op: protocol.Op, text: []const u8, played: *bool) !void {
    if (sock < 0) sock = try connectServer();
    errdefer closeSock();
    defer speaker.close();
    try net.sendFrameF(sock, .cmd, @intFromEnum(op), &.{text});
    try readReplies(played);
}

fn askAudio(flags: u8, pcm: []const u8, played: *bool, sent: *bool) !void {
    if (sock < 0) sock = try connectServer();
    errdefer closeSock();
    defer speaker.close();
    try net.sendFrameF(sock, .cmd, flags, &.{pcm});
    sent.* = true;
    try readReplies(played);
}

fn cloudCommand(pcm: []const u8, force_ai: bool) bool {
    const op_bits: u8 = if (force_ai) @intFromEnum(protocol.Op.ai) else @intFromEnum(protocol.Op.music);
    var played = false;
    var sent = false;
    askAudio(protocol.AUDIO_FLAG | op_bits, pcm, &played, &sent) catch |e| {
        log("облако: {s}", .{@errorName(e)});
        return sent or played;
    };
    if (pending_play) |p| {
        startStream(p);
        alloc.free(p);
        pending_play = null;
    }
    return true;
}

const UTT_MAX_BYTES: usize = 16000 * 2 * 10;
var utt_audio: std.ArrayList(u8) = .empty;
var utt_audio_on = false;

fn utteranceStart() void {
    if (!cfg.cloud) return;
    utt_audio.clearRetainingCapacity();
    utt_audio_on = true;
}

fn readReplies(played: *bool) !void {
    while (true) {
        const f = try net.recvFrame(alloc, sock);
        switch (f.msg_type) {
            .reply => {
                const emotion = protocol.getEmotion(f.flags);
                disp.showEmotion(emotion, 5);

                if (f.payload.len > 4) {
                    const rate = std.mem.readInt(u32, f.payload[0..4], .little);
                    speaker.write(rate, f.payload[4..]);
                    played.* = true;
                }
                const more = (f.flags & protocol.REPLY_MORE) != 0;
                f.deinit(alloc);
                if (!more) return;
            },
            .play => {
                if (pending_play) |old| alloc.free(old);
                pending_play = f.payload;
            },
            .update => {
                handleUpdate(f.payload);
                f.deinit(alloc);
            },
            else => f.deinit(alloc),
        }
    }
}

fn exchange(op: protocol.Op, text: []const u8) void {
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        var played = false;
        askServer(op, text, &played) catch |e| {
            log("сервер: {s}", .{@errorName(e)});
            if (played) return;
            continue;
        };
        return;
    }
    log("ответ не получен", .{});
}

var wake_fired = false;
var wake_fired_last = false;

fn checkPartialWake(rec: *const c.SherpaOnnxOnlineRecognizer, stream: *const c.SherpaOnnxOnlineStream) void {
    if (wake_fired) return;
    const r = c.SherpaOnnxGetOnlineStreamResult(rec, stream);
    if (r == null) return;
    defer c.SherpaOnnxDestroyOnlineRecognizerResult(r);

    if (r.*.text != null) {
        const text = std.mem.span(r.*.text);
        const p = std.mem.trim(u8, text, " ");
        if (commandAfterWake(p) != null) {
            wake_fired = true;
            disp.showEmotion(.def, 3);
            top_leds.startListening();
            utteranceStart();
            pauseStream();
            playWakeSound();
        }
    }
}

fn feedSherpa(rec: *const c.SherpaOnnxOnlineRecognizer, stream: *const c.SherpaOnnxOnlineStream, buf: *const [FRAME]i16) !?[]u8 {
    var fbuf: [FRAME]f32 = undefined;
    for (buf, 0..) |s, i| {
        fbuf[i] = @as(f32, @floatFromInt(s)) / 32768.0;
    }
    c.SherpaOnnxOnlineStreamAcceptWaveform(stream, @intCast(RATE), @ptrCast(&fbuf), @intCast(FRAME));

    while (c.SherpaOnnxIsOnlineStreamReady(rec, stream) == 1) {
        c.SherpaOnnxDecodeOnlineStream(rec, stream);
    }

    checkPartialWake(rec, stream);

    if (c.SherpaOnnxOnlineStreamIsEndpoint(rec, stream) == 1) {
        wake_fired_last = wake_fired;
        wake_fired = false;
        const r = c.SherpaOnnxGetOnlineStreamResult(rec, stream);
        defer if (r != null) c.SherpaOnnxDestroyOnlineRecognizerResult(r);

        var text_copy: []u8 = &.{};
        if (r != null and r.*.text != null) {
            text_copy = try alloc.dupe(u8, std.mem.span(r.*.text));
        }
        c.SherpaOnnxOnlineStreamReset(rec, stream);
        return text_copy;
    }
    return null;
}

fn commandAfterWake(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " ");
    for (wake_buf[0..wake_count]) |w| {
        if (!std.mem.startsWith(u8, t, w)) continue;
        const rest = t[w.len..];
        if (rest.len > 0 and rest[0] != ' ') continue;
        return std.mem.trim(u8, rest, " ");
    }
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    const first = t[0..sp];
    if (first.len < 6) return null;
    for (wake_buf[0..wake_count]) |w| {
        if (similarity(first, w) >= 70) {
            return if (sp < t.len) std.mem.trim(u8, t[sp..], " ") else t[t.len..];
        }
    }
    return null;
}

fn similarity(a: []const u8, b: []const u8) u32 {
    if (a.len == 0 and b.len == 0) return 100;
    if (a.len == 0 or b.len == 0) return 0;

    const max_size = 64;
    var buf: [max_size * max_size]u16 = undefined;
    const alen: usize = @min(a.len, max_size - 1);
    const blen: usize = @min(b.len, max_size - 1);

    var i: usize = 0;
    while (i <= alen) : (i += 1) {
        buf[i * max_size] = @intCast(i);
    }
    var j: usize = 0;
    while (j <= blen) : (j += 1) {
        buf[j] = @intCast(j);
    }

    i = 1;
    while (i <= alen) : (i += 1) {
        j = 1;
        while (j <= blen) : (j += 1) {
            const cost: u16 = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = buf[(i - 1) * max_size + j] + 1;
            const ins = buf[i * max_size + (j - 1)] + 1;
            const sub = buf[(i - 1) * max_size + (j - 1)] + cost;
            buf[i * max_size + j] = @min(del, @min(ins, sub));
        }
    }

    const dist = buf[alen * max_size + blen];
    const max_len = @max(alen, blen);
    if (max_len == 0) return 100;

    return @intCast(((max_len - dist) * 100) / max_len);
}

fn matchesFuzzy(word: []const u8, target: []const u8, threshold: u32) bool {
    return similarity(word, target) >= threshold;
}

fn defaultStorePath() []const u8 {
    var exe_buf: [512]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (n <= 0) return "folassist_events.txt";
    const exe = exe_buf[0..@intCast(n)];
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return "folassist_events.txt";
    return std.fmt.allocPrint(alloc, "{s}/folassist_events.txt", .{exe[0..slash]}) catch "folassist_events.txt";
}

fn opFor(cmd: []const u8) protocol.Op {
    if (std.mem.indexOf(u8, cmd, "погод") != null) return .weather;
    if (std.mem.indexOf(u8, cmd, "будильник") != null or std.mem.indexOf(u8, cmd, "напомни") != null or std.mem.indexOf(u8, cmd, "таймер") != null) return .ai;
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |word| {
        if (matchesFuzzy(word, "погода", cfg.cmd_sim) or matchesFuzzy(word, "погоду", cfg.cmd_sim) or matchesFuzzy(word, "погодка", cfg.cmd_sim)) {
            return .weather;
        }
        if (matchesFuzzy(word, "включи", cfg.cmd_sim) or matchesFuzzy(word, "вруби", cfg.cmd_sim) or matchesFuzzy(word, "сыграй", cfg.cmd_sim)) {
            return .music;
        }
    }
    return .ai;
}

var dialog_frames: u32 = 0;
var gate_hold: u32 = 0;

fn playFile(path: ?[]const u8) void {
    const p = path orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    var b: [512]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "aplay -D {s} -q '{s}' >/dev/null 2>&1", .{ cfg.spk, p }) catch return;
    _ = c.system(@ptrCast(cmd.ptr));
}

fn fire(ev: events.Event, mic: *c.FILE) void {
    switch (ev.kind) {
        .alarm => {
            log("будильник", .{});
            disp.showEmotion(.what, 10);
            startRing();
        },
        .reminder => {
            log("напоминание", .{});
            disp.showEmotion(.happy, 6);
            if (cfg.remind_sound) |s| {
                playFile(s);
            } else if (cachedEntry(REMIND_PHRASE)) |e| {
                playOnce(e.rate, e.pcm);
            }
            if (ev.pcm) |p| {
                if (zfmt.readFile(c, alloc, p)) |bytes| {
                    playOnce(RATE, bytes);
                    alloc.free(bytes);
                } else |_| {}
                events.unlinkPath(p);
                alloc.free(p);
            }
        },
    }
    flushMic(mic);
}

fn handleEvent(piece: []const u8) bool {
    const p = events.parseCommand(piece) orelse return false;
    switch (p.kind) {
        .alarm => {
            events.addAlarm(p.at);
            log("будильник на {d}", .{p.at});
        },
        .reminder => {
            pending_reminder = p.at;
            reminder_deadline = events.now() + REMINDER_WAIT_SEC;
            log("напоминание на {d}, жду сообщение", .{p.at});
        },
    }
    disp.showEmotion(.happy, 3);
    playWakeSound();
    return true;
}

fn dispatchBatch(rec: *const c.SherpaOnnxOnlineRecognizer, stream: *const c.SherpaOnnxOnlineStream, mic: *c.FILE) void {
    const sent = utt_audio_on and utt_audio.items.len > 0 and cloudCommand(utt_audio.items, acc_force_ai);
    utt_audio_on = false;
    if (!sent) handleCommand(acc.items, acc_force_ai);
    acc.clearRetainingCapacity();
    utt_audio.clearRetainingCapacity();
    flushMic(mic);
    c.SherpaOnnxOnlineStreamReset(rec, stream);
}

fn handleCommand(cmd: []const u8, force_ai: bool) void {
    top_leds.stopListening();
    resumeStream();
    if (std.mem.indexOf(u8, cmd, "ночной режим") != null) {
        if (std.mem.indexOf(u8, cmd, "выключи") != null or std.mem.indexOf(u8, cmd, "отключи") != null) {
            disp.setNightMode(false);
            disp.showEmotion(.happy, 3);
            log("ночной режим выключен", .{});
            playWakeSound();
            return;
        } else {
            disp.setNightMode(true);
            disp.showEmotion(.happy, 3);
            log("ночной режим включен", .{});
            playWakeSound();
            return;
        }
    }

    const op: protocol.Op = if (force_ai) .ai else opFor(cmd);
    exchange(op, cmd);
    if (op == .ai) dialog_frames = cfg.dialog_sec * FPS;
    if (pending_play) |p| {
        startStream(p);
        alloc.free(p);
        pending_play = null;
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const argv_c = try alloc.alloc(?[*:0]const u8, args.len + 1);
    for (args, 0..) |a, i| argv_c[i] = a.ptr;
    argv_c[args.len] = null;
    saved_argv = argv_c;
    for (args[1..]) |arg| {
        if (val(arg, "--id")) |v| {
            cfg.id = std.fmt.parseInt(u8, v, 10) catch 1;
            cfg.id_set = true;
        } else if (val(arg, "--pass")) |v| {
            if (std.mem.indexOfScalar(u8, v, ';') != null) return error.BadPassword;
            cfg.pass = v;
        } else if (val(arg, "--server")) |v| {
            const i = std.mem.lastIndexOfScalar(u8, v, ':');
            cfg.server_ip = try alloc.dupeSentinel(u8, if (i) |p| v[0..p] else v, 0);
            if (i) |p| cfg.server_port = std.fmt.parseInt(u16, v[p + 1 ..], 10) catch 9000;
        } else if (val(arg, "--http-port")) |v| {
            cfg.http_port = std.fmt.parseInt(u16, v, 10) catch 9001;
        } else if (val(arg, "--model")) |v| {
            cfg.model = try alloc.dupeSentinel(u8, v, 0);
        } else if (val(arg, "--mic")) |v| {
            cfg.mic = try alloc.dupeSentinel(u8, v, 0);
        } else if (val(arg, "--spk")) |v| {
            cfg.spk = try alloc.dupeSentinel(u8, v, 0);
        } else if (val(arg, "--input")) |v| {
            cfg.input_dev = try alloc.dupeSentinel(u8, v, 0);
        } else if (val(arg, "--brightness")) |v| {
            cfg.brightness = std.fmt.parseInt(u8, v, 10) catch 120;
        } else if (val(arg, "--wake")) |v| {
            addWake(v);
        } else if (val(arg, "--wake-sound")) |v| {
            cfg.wake_sound = v;
        } else if (val(arg, "--city")) |v| {
            cfg.city = v;
        } else if (val(arg, "--lat")) |v| {
            cfg.lat = std.fmt.parseFloat(f64, v) catch cfg.lat;
        } else if (val(arg, "--lon")) |v| {
            cfg.lon = std.fmt.parseFloat(f64, v) catch cfg.lon;
        } else if (val(arg, "--stop")) |v| {
            addStop(v);
        } else if (val(arg, "--wait")) |v| {
            cfg.wait_sec = std.fmt.parseInt(u32, v, 10) catch cfg.wait_sec;
        } else if (val(arg, "--collect")) |v| {
            cfg.collect_sec = std.fmt.parseInt(u32, v, 10) catch cfg.collect_sec;
        } else if (val(arg, "--prompt")) |v| {
            cfg.prompt_path = v;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return;
        } else if (std.mem.eql(u8, arg, "--no-cloud")) {
            cfg.cloud = false;
        } else if (std.mem.eql(u8, arg, "--level")) {
            cfg.level = true;
        } else if (val(arg, "--cmd-sim")) |v| {
            cfg.cmd_sim = std.fmt.parseInt(u32, v, 10) catch 80;
        } else if (val(arg, "--gain")) |v| {
            cfg.gain = std.fmt.parseFloat(f32, v) catch 3.0;
        } else if (val(arg, "--gate")) |v| {
            cfg.gate = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (val(arg, "--ringtone")) |v| {
            cfg.ringtone = v;
        } else if (val(arg, "--remind-sound")) |v| {
            cfg.remind_sound = v;
        } else if (val(arg, "--store")) |v| {
            cfg.store = v;
        } else if (val(arg, "--dialog")) |v| {
            cfg.dialog_sec = std.fmt.parseInt(u32, v, 10) catch cfg.dialog_sec;
        } else {
            std.debug.print("folclient: неизвестная опция {s}, список: --help\n", .{arg});
            return error.UnknownOption;
        }
    }

    disp = display_mod.Display.init(cfg.brightness);
    top_leds = top_leds_mod.TopLeds.init();
    btns = buttons_mod.Buttons.init(cfg.input_dev);


    buttons_mod.setVolume(30);

    if (!cfg.id_set) cfg.id = randomId();
    if (wake_count == 0) {
        addWake("фокус");
        addWake("фокс");
        addWake("фкус");
        addWake("фокуз");
        addWake("фукус");
        addWake("вокус");
        addWake("фокуш");
        addWake("куш");
    }
    {
        const file_txt: []const u8 = if (cfg.prompt_path) |p| try zfmt.readFile(c, alloc, p) else &.{};
        defer if (cfg.prompt_path != null) alloc.free(file_txt);
        var name_buf: [64]u8 = undefined;
        const name = capitalizeFirst(&name_buf, wake_buf[0]);
        client_prompt = try std.fmt.allocPrint(alloc, "Тебя зовут {s}.{s}{s}", .{ name, if (file_txt.len > 0) "\n" else "", file_txt });
    }
    events.store_path = cfg.store orelse defaultStorePath();
    events.load();
    sock = connectServer() catch -1;

    if (stop_count == 0) {
        addStop("стоп");
        addStop("хватит");
    }

    const test_file = try alloc.printSentinel("{s}/tokens.txt", .{cfg.model}, 0);
    defer alloc.free(test_file);
    if (c.access(test_file.ptr, c.F_OK) != 0) try fetchModel();

    const enc_p = try alloc.printSentinel("{s}/encoder.int8.onnx", .{cfg.model}, 0);
    defer alloc.free(enc_p);
    const dec_p = try alloc.printSentinel("{s}/decoder.int8.onnx", .{cfg.model}, 0);
    defer alloc.free(dec_p);
    const join_p = try alloc.printSentinel("{s}/joiner.int8.onnx", .{cfg.model}, 0);
    defer alloc.free(join_p);
    const tok_p = try alloc.printSentinel("{s}/tokens.txt", .{cfg.model}, 0);
    defer alloc.free(tok_p);

    var sonnx_cfg: c.SherpaOnnxOnlineRecognizerConfig = std.mem.zeroes(c.SherpaOnnxOnlineRecognizerConfig);
    sonnx_cfg.feat_config.sample_rate = @intCast(RATE);
    sonnx_cfg.feat_config.feature_dim = 80;
    sonnx_cfg.model_config.tokens = tok_p.ptr;
    sonnx_cfg.model_config.transducer.encoder = enc_p.ptr;
    sonnx_cfg.model_config.transducer.decoder = dec_p.ptr;
    sonnx_cfg.model_config.transducer.joiner = join_p.ptr;
    sonnx_cfg.model_config.num_threads = 1;
    sonnx_cfg.model_config.provider = "cpu";
    sonnx_cfg.decoding_method = "greedy_search";
    sonnx_cfg.max_active_paths = 4;
    sonnx_cfg.enable_endpoint = 1;
    sonnx_cfg.rule1_min_trailing_silence = 0.8;
    sonnx_cfg.rule2_min_trailing_silence = 0.5;
    sonnx_cfg.rule3_min_utterance_length = 30.0;

    log("загружаю модель Sherpa-ONNX...", .{});
    const rec = c.SherpaOnnxCreateOnlineRecognizer(&sonnx_cfg) orelse return error.SherpaModelLoadError;
    defer c.SherpaOnnxDestroyOnlineRecognizer(rec);

    log("создаю аудиопоток...", .{});
    const stream = c.SherpaOnnxCreateOnlineStream(rec) orelse return error.SherpaStreamError;
    defer c.SherpaOnnxDestroyOnlineStream(stream);

    log("открываю захват звука через arecord ({s})...", .{cfg.mic});
    var mic = try openCapture();
    log("микрофон готов!", .{});

    log("слушаю, слова активации: {d} шт., сервер {s}:{d}", .{ wake_count, cfg.server_ip, cfg.server_port });

    var buf: [FRAME]i16 = undefined;
    var armed: u32 = 0;

    while (true) {
        disp.tick();
        top_leds.tick();
        top_leds.apply();
        reapStream();

        switch (btns.poll()) {
            .wake => {
                log("кнопка: действие (активация)", .{});
                if (!wake_fired_last) playWakeSound();
                disp.showEmotion(.def, 3);
                top_leds.startListening();
                utteranceStart();
                pauseStream();
                armed = cfg.wait_sec * FPS;
            },
            .vol_up => {
                log("кнопка: громкость +", .{});
                buttons_mod.adjustVolume(true);
                disp.showVolume(buttons_mod.volume);
            },
            .vol_down => {
                log("кнопка: громкость -", .{});
                buttons_mod.adjustVolume(false);
                disp.showVolume(buttons_mod.volume);
            },
            .mic_mute_toggle => {
                mic_muted = !mic_muted;
                top_leds.setMuted(mic_muted);
                log("микрофон {s}", .{if (mic_muted) "ВЫКЛЮЧЕН (красный)" else "ВКЛЮЧЕН (белый)"});
                if (mic_muted) {
                    disp.showEmotion(.sad, 5);
                } else {
                    disp.showEmotion(.happy, 2);
                    playWakeSound();
                }
            },
            .toggle_face_clock => {
                log("кнопка: переключение часы/мордочка", .{});
                disp.toggleFaceOrClock();
            },
            .none => {},
        }

        readFrame(mic, &buf) catch {
            log("захват звука оборвался, переоткрываю", .{});
            _ = c.pclose(mic);
            _ = c.usleep(500_000);
            mic = openCapture() catch return error.CaptureFailed;
            continue;
        };
        if (utt_audio_on) {
            if (utt_audio.items.len + FRAME * 2 <= UTT_MAX_BYTES) {
                utt_audio.appendSlice(alloc, std.mem.sliceAsBytes(&buf)) catch {};
            } else utt_audio_on = false;
        }

        if (mic_muted) {
            _ = c.usleep(50_000);
            continue;
        }
        if (armed > 0) armed -= 1;
        if (dialog_frames > 0) dialog_frames -= 1;
        if (pending_reminder != null) {
            try utt.appendSlice(alloc, std.mem.sliceAsBytes(buf[0..]));
            if (utt.items.len > MAX_UTT_BYTES) utt.clearRetainingCapacity();
        }

        if (events.popDue(events.now())) |ev| fire(ev, mic);

        if (pending_reminder != null and events.now() > reminder_deadline) {
            pending_reminder = null;
            utt.clearAndFree(alloc);
            log("сообщение для напоминания не дождался, отмена", .{});
        }

        if (collect_frames > 0) {
            collect_frames -= 1;
            if (collect_frames == 0 and acc.items.len > 0) dispatchBatch(rec, stream, mic);
        }

        if (stream_pause_frames > 0) {
            stream_pause_frames -= 1;
            if (stream_pause_frames == 0) resumeStream();
        }

        if (deaf_frames > 0) {
            deaf_frames -= 1;
            if (deaf_frames == 0) c.SherpaOnnxOnlineStreamReset(rec, stream);
            continue;
        }

        if (cfg.gate > 0 or cfg.level) {
            const rms = frameRms(&buf);
            if (cfg.level) std.debug.print("уровень: {d}\n", .{rms});
            if (rms >= cfg.gate) {
                gate_hold = GATE_HOLD_FRAMES;
            } else if (gate_hold > 0) {
                gate_hold -= 1;
            } else if (cfg.gate > 0 and pending_reminder == null) {
                continue;
            }
        }

        const got = try feedSherpa(rec, stream, &buf);
        const text = got orelse continue;
        defer alloc.free(text);

        if (pending_reminder) |at| {
            if (text.len == 0) continue;
            pending_reminder = null;
            const rt = std.mem.trim(u8, text, " ");
            if (isStopPhrase(commandAfterWake(rt) orelse rt)) {
                utt.clearAndFree(alloc);
                log("напоминание отменено", .{});
                continue;
            }
            events.addReminder(at, utt.items);
            utt.clearAndFree(alloc);
            log("сообщение для напоминания сохранено", .{});
            disp.showEmotion(.happy, 3);
            playWakeSound();
            continue;
        }
        if (text.len == 0) continue;
        log("услышал: «{s}»", .{text});

        const trimmed = std.mem.trim(u8, text, " ");
        const wake_rest = commandAfterWake(trimmed);
        const body = wake_rest orelse trimmed;

        if (isStopPhrase(body)) {
            log("стоп", .{});
            stopStream();
            stopRing();
            dialog_frames = 0;
            armed = 0;
            collect_frames = 0;
            acc.clearRetainingCapacity();
            c.SherpaOnnxOnlineStreamReset(rec, stream);
            continue;
        }

        var piece: []const u8 = undefined;
        var phrase_ai = false;
        if (wake_rest) |rest| {
            if (!wake_fired_last) playWakeSound();
            disp.showEmotion(.def, 3);
            top_leds.startListening();
            pauseStream();
            if (rest.len == 0) {
                armed = cfg.wait_sec * FPS;
                continue;
            }
            piece = rest;
        } else if (armed > 0) {
            piece = trimmed;
        } else if (dialog_frames > 0) {
            piece = trimmed;
            phrase_ai = true;
        } else continue;
        armed = 0;

        if (!phrase_ai and handleEvent(piece)) continue;

        if (acc.items.len == 0) acc_force_ai = phrase_ai;
        if (acc.items.len > 0) try acc.append(alloc, ' ');
        try acc.appendSlice(alloc, piece);

        collect_frames = cfg.collect_sec * FPS;
        if (collect_frames == 0) dispatchBatch(rec, stream, mic);
    }
}
