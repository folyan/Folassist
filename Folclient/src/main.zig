const std = @import("std");
const builtin = @import("builtin");
const zfmt = @import("zfmt");
const pubkey = @import("pubkey");
const events = @import("events.zig");
const sync = @import("sync.zig");
const protocol = @import("protocol");
const display_mod = @import("display.zig");
const top_leds_mod = @import("top_leds.zig");
const buttons_mod = @import("buttons.zig");
const c = @import("c");
const net = protocol.Net(c);

const alloc = std.heap.c_allocator;

const RATE: u32 = 16000;
// 640 сэмплов = ровно 40 мс (идеально совпадает с period_size 640 в asound.conf!)
const FRAME: usize = 640; 
const FPS: u32 = 25; // 1000ms / 40ms = 25 кадров в секунду
const GATE_HOLD_FRAMES: u32 = 25;
const UTT_MAX_BYTES: usize = 16000 * 2 * 10;

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
    dialog_sec: u32 = 4,
    prompt_path: ?[]const u8 = null,
    verbose: bool = false,
    ringtone: ?[]const u8 = null,
    remind_sound: ?[]const u8 = null,
    store: ?[]const u8 = null,
    gate: u32 = 30,
    gain: f32 = 4.0,
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
var stream_paused = false;
var stream_pause_frames: u32 = 0;

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!cfg.verbose) return;
    std.debug.print("[folclient] " ++ fmt ++ "\n", args);
}

// «Стоп» приходит из главного потока, а играет рабочий. Закрывать ALSA-handle из чужого
// потока нельзя (use-after-close, плюс drain блокировал главный цикл до конца фразы),
// поэтому главный поток только поднимает флаг, а Speaker сам обрывает вывод через drop.
var speaker_abort = std.atomic.Value(bool).init(false);
// До какого момента (мс, монотонные) динамик играет ответ ассистента. Пока это так,
// микрофон слышит свой же голос: такие куски распознавания отбрасываются.
// На armhf 64-битные атомики не поддерживаются, поэтому тут обычный мьютекс.
var speaking_lock: sync.Mutex = .{};
var speaking_until: u64 = 0;

fn extendSpeaking(dur_ms: u64) void {
    speaking_lock.lock();
    defer speaking_lock.unlock();
    const now = sync.nowMs();
    const start = if (speaking_until > now) speaking_until else now;
    speaking_until = start + dur_ms + 400;
}

fn speakingNow() bool {
    speaking_lock.lock();
    defer speaking_lock.unlock();
    return sync.nowMs() < speaking_until;
}

fn stopSpeakingWindow() void {
    speaking_lock.lock();
    defer speaking_lock.unlock();
    speaking_until = 0;
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
        if (speaker_abort.load(.acquire)) return;
        extendSpeaking((@as(u64, pcm.len / 2) * 1000) / @as(u64, rate));
        if (self.handle != null and self.rate != rate) self.close();
        if (self.handle == null) self.open(rate) catch return;
        const h = self.handle.?;

        // пишем кусками по ~100 мс, чтобы между ними видеть флаг «стоп»
        const chunk: usize = @max(@as(usize, rate / 10), 160);
        const total = pcm.len / 2;
        var off: usize = 0;
        var failures: u32 = 0;
        while (off < total) {
            if (speaker_abort.load(.acquire)) {
                _ = c.snd_pcm_drop(h);
                return;
            }
            const n = @min(total - off, chunk);
            const r = c.snd_pcm_writei(h, pcm.ptr + off * 2, n);
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
        if (speaker_abort.load(.acquire)) {
            _ = c.snd_pcm_drop(h);
        } else {
            _ = c.snd_pcm_drain(h);
        }
        _ = c.snd_pcm_close(h);
        self.handle = null;
    }
};

var speaker: Speaker = .{};

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
    _ = c.system(@ptrCast(cmd.ptr));
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

// Эмоция держится всё время ответа (а не 5 секунд с момента первого кадра),
// после конца ответа остаётся ещё немного.
const REPLY_PIN_MS: u64 = 60_000;
const REPLY_TAIL_MS: u64 = 4_000;

fn readReplies(played: *bool) !void {
    var last_emotion: protocol.Emotion = .def;
    var shown = false;
    defer if (shown) disp.showEmotion(last_emotion, REPLY_TAIL_MS);

    while (true) {
        const f = try net.recvFrame(alloc, sock);
        switch (f.msg_type) {
            .reply => {
                // Эмоция идёт в самом первом кадре (сервер шлёт его до озвучки),
                // так что лицо меняется сразу, а не после того, как ИИ договорил.
                const emotion = protocol.getEmotion(f.flags);
                last_emotion = emotion;
                shown = true;
                disp.showEmotion(emotion, REPLY_PIN_MS);

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

fn askServer(op: protocol.Op, text: []const u8, played: *bool) !void {
    if (sock < 0) sock = try connectServer();
    errdefer closeSock();
    defer speaker.close();
    speaker_abort.store(false, .release);
    try net.sendFrameF(sock, .cmd, @intFromEnum(op), &.{text});
    try readReplies(played);
}

fn askAudio(flags: u8, pcm: []const u8, played: *bool, sent: *bool) !void {
    if (sock < 0) sock = try connectServer();
    errdefer closeSock();
    defer speaker.close();
    speaker_abort.store(false, .release);
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

const TaskKind = enum {
    command,
    cloud_audio,
    event_alarm,
    event_reminder,
    hello,
};

const Task = struct {
    kind: TaskKind,
    text: ?[]u8 = null,
    audio: ?[]u8 = null,
    force_ai: bool = false,
};

var queue: std.ArrayList(Task) = .empty;
var q_mutex = std.mem.zeroes(c.pthread_mutex_t);
var q_cond = std.mem.zeroes(c.pthread_cond_t);

fn enqueueTask(t: Task) void {
    _ = c.pthread_mutex_lock(&q_mutex);
    queue.append(alloc, t) catch {};
    _ = c.pthread_cond_signal(&q_cond);
    _ = c.pthread_mutex_unlock(&q_mutex);
}

fn playFile(path: ?[]const u8) void {
    const p = path orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    var b: [512]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "aplay -D {s} -q '{s}' >/dev/null 2>&1", .{ cfg.spk, p }) catch return;
    _ = c.system(@ptrCast(cmd.ptr));
}

fn handleCommand(cmd: []const u8, force_ai: bool) void {
    resumeStream();
    if (std.mem.indexOf(u8, cmd, "ночной режим") != null) {
        if (std.mem.indexOf(u8, cmd, "выключи") != null or std.mem.indexOf(u8, cmd, "отключи") != null) {
            disp.setNightMode(false);
            disp.showEmotion(.happy, 3 * 1000);
            log("ночной режим выключен", .{});
            playWakeSound();
            return;
        } else {
            disp.setNightMode(true);
            disp.showEmotion(.happy, 3 * 1000);
            log("ночной режим включен", .{});
            playWakeSound();
            return;
        }
    }

    const op: protocol.Op = if (force_ai) .ai else opFor(cmd);
    exchange(op, cmd);
    if (pending_play) |p| {
        startStream(p);
        alloc.free(p);
        pending_play = null;
    }
}

/// Если фраза — будильник или напоминание, ставит его в events и возвращает true.
/// Для напоминания нужна сама запись голоса (audio): её же потом и проиграем.
fn tryScheduleEvent(text: []const u8, audio: ?[]const u8) bool {
    const p = events.parseCommand(text) orelse return false;
    switch (p.kind) {
        .alarm => events.addAlarm(p.at),
        .reminder => {
            const a = audio orelse return false;
            events.addReminder(p.at, a);
        },
    }
    log("запланировано: {s} на {d}", .{ @tagName(p.kind), p.at });
    disp.showEmotion(.happy, 2 * 1000);
    return true;
}

/// Здоровается с сервером сразу при запуске, а не при первой команде. Сервер в ответ
/// на hello шлёт update, если версия клиента устарела, поэтому ждём этот кадр коротко.
fn helloAndCheckUpdate() void {
    if (sock < 0) sock = connectServer() catch return;
    setRecvTimeout(sock, 2);
    const f = net.recvFrame(alloc, sock) catch {
        setRecvTimeout(sock, 60);
        return;
    };
    setRecvTimeout(sock, 60);
    defer f.deinit(alloc);
    if (f.msg_type == .update) handleUpdate(f.payload);
}

fn setRecvTimeout(fd: c_int, sec: c_long) void {
    var tv = std.mem.zeroes(c.struct_timeval);
    tv.tv_sec = sec;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
}

fn workerLoop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        _ = c.pthread_mutex_lock(&q_mutex);
        while (queue.items.len == 0) {
            _ = c.pthread_cond_wait(&q_cond, &q_mutex);
        }
        const task = queue.orderedRemove(0);
        _ = c.pthread_mutex_unlock(&q_mutex);

        switch (task.kind) {
            .command => {
                if (task.text) |t| {
                    if (!tryScheduleEvent(t, null)) handleCommand(t, task.force_ai);
                    alloc.free(t);
                    dialog_open.store(true, .release);
                }
            },
            .cloud_audio => {
                if (task.audio) |a| {
                    if (task.text) |t| {
                        if (tryScheduleEvent(t, a)) {
                            alloc.free(a);
                            alloc.free(t);
                            continue;
                        }
                    }
                    const sent = cloudCommand(a, task.force_ai);
                    if (!sent and task.text != null) {
                        handleCommand(task.text.?, task.force_ai);
                    }
                    alloc.free(a);
                    if (task.text) |t| alloc.free(t);
                    dialog_open.store(true, .release);
                }
            },
            .hello => helloAndCheckUpdate(),
            .event_alarm => {
                log("будильник сработал", .{});
                disp.showEmotion(.what, 10 * 1000);
                startRing();
            },
            .event_reminder => {
                log("напоминание сработало", .{});
                disp.showEmotion(.happy, 6 * 1000);
                if (cfg.remind_sound) |s| {
                    playFile(s);
                } else if (cachedEntry("Напоминаю")) |e| {
                    playOnce(e.rate, e.pcm);
                }
                if (task.text) |p| {
                    if (zfmt.readFile(c, alloc, p)) |bytes| {
                        playOnce(RATE, bytes);
                        alloc.free(bytes);
                    } else |_| {}
                    events.unlinkPath(p);
                    alloc.free(p);
                }
            },
        }
    }
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
    while (i <= alen) : (i += 1) buf[i * max_size] = @intCast(i);
    var j: usize = 0;
    while (j <= blen) : (j += 1) buf[j] = @intCast(j);

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

// Запуск arecord с явным буфером на 500ms и периодом 40ms, чтобы исключить xrun
fn openCapture() !*c.FILE {
    var b: [256]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "arecord -q -D {s} -c 1 -f S16_LE -r {d} --buffer-time=500000 --period-time=40000 -t raw", .{ cfg.mic, RATE }) catch return error.AudioDeviceError;
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
    if (cfg.gain != 1.0) {
        for (buf) |*s| {
            const multiplied = @as(f32, @floatFromInt(s.*)) * cfg.gain;
            s.* = @intFromFloat(std.math.clamp(multiplied, -32768.0, 32767.0));
        }
    }
}

var wake_fired = false;
// Рабочий поток ставит флаг, когда ответ готов: главный цикл открывает окно диалога
// (без повторного «фокус»), и синий горит на время этого окна.
var dialog_open = std.atomic.Value(bool).init(false);
var wake_fired_last = false;
var utt_audio: std.ArrayList(u8) = .empty;
var utt_audio_on = false;

fn utteranceStart() void {
    if (!cfg.cloud) return;
    utt_audio.clearRetainingCapacity();
    utt_audio_on = true;
}

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
            disp.showEmotion(.def, 3 * 1000);
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

fn assetName() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm => "folclient-armhf",
        .aarch64 => "folclient-aarch64",
        else => "folclient",
    };
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
    var cmd_buf: [1536]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&cmd_buf,
        "set -e; E='{s}'; S=\"$E.sums\"; " ++
        "wget -qO \"$E.new\" 'http://{s}:{d}/update/{s}'; " ++
        "chmod +x \"$E.new\"; mv -f \"$E.new\" \"$E\"",
        .{ exe, cfg.server_ip, cfg.http_port, asset }) catch return;
    if (c.system(cmd.ptr) != 0) return;
    std.process.exit(0);
}

fn fetchModel() !void {
    log("модели нет, запрашиваю у сервера (код 00)", .{});
    const fd = try dial();
    defer _ = c.close(fd);

    try net.sendFrameF(fd, .cmd, @intFromEnum(protocol.Op.model_req), &.{cfg.pass});
    const h = try net.recvHeader(fd);
    if (h.msg_type != .model or h.len == 0) return error.ModelUnavailable;

    _ = signal(c.SIGPIPE, 1);
    const p = c.popen("gzip -dc | tar -x -f - -C /dev/shm/", "w") orelse return error.UntarFailed;
    var chunk: [64 * 1024]u8 = undefined;
    var left: usize = h.len;
    while (left > 0) {
        const want = @min(left, chunk.len);
        try net.readAll(fd, chunk[0..want]);
        if (c.fwrite(&chunk, 1, want, p) != want) {
            _ = c.pclose(p);
            return error.UntarFailed;
        }
        left -= want;
    }
    if (c.pclose(p) != 0) return error.UntarFailed;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    for (args[1..]) |arg| {
        if (val(arg, "--id")) |v| {
            cfg.id = std.fmt.parseInt(u8, v, 10) catch 1;
            cfg.id_set = true;
        } else if (val(arg, "--pass")) |v| {
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
        } else if (std.mem.eql(u8, arg, "--no-cloud")) {
            cfg.cloud = false;
        } else if (std.mem.eql(u8, arg, "--level")) {
            cfg.level = true;
        } else if (val(arg, "--cmd-sim")) |v| {
            cfg.cmd_sim = std.fmt.parseInt(u32, v, 10) catch 80;
        } else if (val(arg, "--gain")) |v| {
            cfg.gain = std.fmt.parseFloat(f32, v) catch 1.0;
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
        }
    }

    if (cfg.store) |sp| events.store_path = sp;
    events.load();

    disp = display_mod.Display.init(cfg.brightness);
    top_leds = top_leds_mod.TopLeds.init();
    btns = buttons_mod.Buttons.init(cfg.input_dev);
    buttons_mod.setVolume(30);

    if (wake_count == 0) {
        addWake("фокус");
        addWake("фокс");
        addWake("фкус");
    }
    if (stop_count == 0) {
        addStop("стоп");
        addStop("столб");
        addStop("хватит");
    }

    _ = c.pthread_mutex_init(&q_mutex, null);
    _ = c.pthread_cond_init(&q_cond, null);

    var worker_tid: c.pthread_t = undefined;
    _ = c.pthread_create(&worker_tid, null, workerLoop, null);
    enqueueTask(.{ .kind = .hello });

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

    log("загрузка Sherpa-ONNX...", .{});
    const rec = c.SherpaOnnxCreateOnlineRecognizer(&sonnx_cfg) orelse return error.SherpaModelLoadError;
    defer c.SherpaOnnxDestroyOnlineRecognizer(rec);

    const stream = c.SherpaOnnxCreateOnlineStream(rec) orelse return error.SherpaStreamError;
    defer c.SherpaOnnxDestroyOnlineStream(stream);

    var mic = try openCapture();
    log("микрофон ({s}) готов!", .{cfg.mic});

    var buf: [FRAME]i16 = undefined;
    var armed: u32 = 0;
    var dialog_frames: u32 = 0;
    var acc: std.ArrayList(u8) = .empty;
    var acc_force_ai = false;
    var collect_frames: u32 = 0;
    var gate_hold: u32 = 0;
    var echo_was = false;

    while (true) {
        disp.tick();
        if (dialog_open.swap(false, .acq_rel)) dialog_frames = cfg.dialog_sec * FPS;
        top_leds.pollAmbient();
        top_leds.setListening(armed > 0 or dialog_frames > 0 or collect_frames > 0);
        buttons_mod.flushVolume();
        reapStream();

        switch (btns.poll()) {
            .wake => {
                if (!wake_fired_last) playWakeSound();
                disp.showEmotion(.def, 3 * 1000);
                utteranceStart();
                pauseStream();
                armed = cfg.wait_sec * FPS;
            },
            .vol_up => {
                buttons_mod.adjustVolume(true);
                disp.showVolume(buttons_mod.volume);
            },
            .vol_down => {
                buttons_mod.adjustVolume(false);
                disp.showVolume(buttons_mod.volume);
            },
            .mic_mute_toggle => {
                mic_muted = !mic_muted;
                top_leds.setMuted(mic_muted);
                if (mic_muted) {
                    disp.showEmotion(.sad, 5 * 1000);
                } else {
                    disp.showEmotion(.happy, 2 * 1000);
                    playWakeSound();
                }
            },
            .toggle_face_clock => disp.toggleFaceOrClock(),
            .none => {},
        }

        readFrame(mic, &buf) catch {
            _ = c.pclose(mic);
            _ = c.usleep(50_000);
            mic = openCapture() catch return error.CaptureFailed;
            continue;
        };

        if (utt_audio_on) {
            if (utt_audio.items.len + FRAME * 2 <= UTT_MAX_BYTES) {
                utt_audio.appendSlice(alloc, std.mem.sliceAsBytes(&buf)) catch {};
            } else utt_audio_on = false;
        }

        if (mic_muted) continue;

        if (armed > 0) armed -= 1;
        if (dialog_frames > 0) dialog_frames -= 1;

        if (events.popDue(events.now())) |ev| {
            switch (ev.kind) {
                .alarm => enqueueTask(.{ .kind = .event_alarm }),
                .reminder => {
                    const p = if (ev.pcm) |p| alloc.dupe(u8, p) catch null else null;
                    enqueueTask(.{ .kind = .event_reminder, .text = p });
                },
            }
        }


        if (collect_frames > 0) {
            collect_frames -= 1;
            if (collect_frames == 0 and acc.items.len > 0) {
                const cmd_copy = alloc.dupe(u8, acc.items) catch null;
                if (utt_audio_on and utt_audio.items.len > 0) {
                    const audio_copy = alloc.dupe(u8, utt_audio.items) catch null;
                    if (audio_copy != null) {
                        enqueueTask(.{ .kind = .cloud_audio, .audio = audio_copy, .text = cmd_copy, .force_ai = acc_force_ai });
                    }
                } else if (cmd_copy != null) {
                    enqueueTask(.{ .kind = .command, .text = cmd_copy, .force_ai = acc_force_ai });
                }
                acc.clearRetainingCapacity();
                utt_audio.clearRetainingCapacity();
                utt_audio_on = false;
                c.SherpaOnnxOnlineStreamReset(rec, stream);
            }
        }

        if (stream_pause_frames > 0) {
            stream_pause_frames -= 1;
            if (stream_pause_frames == 0) resumeStream();
        }

        if (cfg.gate > 0 or cfg.level) {
            const rms = frameRms(&buf);
            if (cfg.level) std.debug.print("уровень: {d}\n", .{rms});
            if (rms >= cfg.gate) {
                gate_hold = GATE_HOLD_FRAMES;
            } else if (gate_hold > 0) {
                gate_hold -= 1;
            } else if (cfg.gate > 0) {
                continue;
            }
        }

        const echo_now = speakingNow();
        if (echo_was and !echo_now) c.SherpaOnnxOnlineStreamReset(rec, stream);
        echo_was = echo_now;

        const got = try feedSherpa(rec, stream, &buf);
        const text = got orelse continue;
        defer alloc.free(text);
        if (text.len == 0) continue;

        const trimmed = std.mem.trim(u8, text, " ");
        const wake_rest = commandAfterWake(trimmed);
        const body = wake_rest orelse trimmed;

        if (isStopPhrase(body)) {
            log("мгновенный стоп!", .{});
            stopStream();
            stopRing();
            speaker_abort.store(true, .release);
            dialog_frames = 0;
            dialog_open.store(false, .release);
            armed = 0;
            collect_frames = 0;
            acc.clearRetainingCapacity();
            c.SherpaOnnxOnlineStreamReset(rec, stream);
            continue;
        }

        // Эхо: пока динамик играет ответ, финалы распознавания — это ассистент, а не пользователь.
        // Исключение — «фокус»: тогда прерываем ответ и начинаем слушать.
        if (echo_now) {
            if (wake_rest == null) {
                c.SherpaOnnxOnlineStreamReset(rec, stream);
                continue;
            }
            speaker_abort.store(true, .release);
            stopSpeakingWindow();
        }

        var piece: []const u8 = undefined;
        var phrase_ai = false;
        if (wake_rest) |rest| {
            if (!wake_fired_last) playWakeSound();
            disp.showEmotion(.def, 3 * 1000);
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

        if (acc.items.len == 0) acc_force_ai = phrase_ai;
        if (acc.items.len > 0) try acc.append(alloc, ' ');
        try acc.appendSlice(alloc, piece);

        collect_frames = cfg.collect_sec * FPS;
    }
}

