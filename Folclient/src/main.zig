const std = @import("std");
const zfmt = @import("zfmt");
const events = @import("events.zig");
const protocol = @import("protocol");
const c = @import("c");
const net = protocol.Net(c);

const alloc = std.heap.c_allocator;

const RATE = 16000;
const FRAME = 4000;
const FPS = 4;

const SHM_ARCHIVE = "/dev/shm/model.tar.gz";

const Config = struct {
    id: u8 = 1,
    server_ip: [:0]const u8 = "127.0.0.1",
    server_port: u16 = 9000,
    http_port: u16 = 9001,
    model: [:0]const u8 = "/dev/shm/vosk",
    wake_sound: ?[]const u8 = null,
    city: []const u8 = "Омске",
    lat: f64 = 54.99,
    lon: f64 = 73.37,
    wait_sec: u32 = 5,
    collect_sec: u32 = 3,
    dialog_sec: u32 = 10,
    prompt_path: ?[]const u8 = null,
    verbose: bool = false,
    ringtone: ?[]const u8 = null,
    remind_sound: ?[]const u8 = null,
    store: ?[]const u8 = null,
};

var cfg: Config = .{};
var client_prompt: ?[]u8 = null;

var acc: std.ArrayList(u8) = .empty;
var acc_force_ai = false;
var collect_frames: u32 = 0;

var utt: std.ArrayList(u8) = .empty;
const MAX_UTT_BYTES = 16000 * 2 * 30;
var pending_reminder: ?i64 = null;

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

fn val(arg: []const u8, comptime key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, key ++ "=")) return arg[key.len + 1 ..];
    return null;
}

fn openCapture() !*c.snd_pcm_t {
    var h: ?*c.snd_pcm_t = null;
    if (c.snd_pcm_open(&h, @ptrCast("default"), c.SND_PCM_STREAM_CAPTURE, 0) < 0) return error.AudioDeviceError;
    if (c.snd_pcm_set_params(h.?, c.SND_PCM_FORMAT_S16_LE, c.SND_PCM_ACCESS_RW_INTERLEAVED, 1, RATE, 1, 500_000) < 0) return error.AudioDeviceError;
    return h.?;
}

fn readFrame(pcm: *c.snd_pcm_t, buf: *[FRAME]i16) !void {
    var got: usize = 0;
    var failures: u32 = 0;
    while (got < FRAME) {
        const r = c.snd_pcm_readi(pcm, &buf[got], FRAME - got);
        if (r < 0) {
            failures += 1;
            if (failures > 50) return error.CaptureFailed;
            if (c.snd_pcm_recover(pcm, @intCast(r), 1) < 0) _ = c.usleep(100_000);
            continue;
        }
        got += @intCast(r);
    }
}

fn flushMic(pcm: *c.snd_pcm_t) void {
    _ = c.snd_pcm_drop(pcm);
    _ = c.snd_pcm_prepare(pcm);
}

const Speaker = struct {
    handle: ?*c.snd_pcm_t = null,
    rate: u32 = 0,

    fn open(self: *Speaker, rate: u32) !void {
        var h: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&h, @ptrCast("default"), c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.AudioDeviceError;
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

fn playOnce(rate: u32, pcm: []const u8) void {
    speaker.write(rate, pcm);
    speaker.close();
}

fn playWakeSound() void {
    const p = cfg.wake_sound orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    var b: [512]u8 = undefined;
    const redirect: []const u8 = if (cfg.verbose) "" else " 2>/dev/null";
    const cmd = zfmt.bufPrintZ(&b, "aplay -q '{s}'{s}", .{ p, redirect }) catch return;
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
    _ = c.kill(-pid.*, c.SIGTERM);
    _ = c.waitpid(pid.*, null, 0);
    pid.* = 0;
}

fn stopStream() void {
    killGroup(&stream_pid);
}

fn stopRing() void {
    killGroup(&ring_pid);
}

fn startRing() void {
    const p = cfg.ringtone orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    stopRing();
    var b: [512]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "while :; do aplay -q '{s}' >/dev/null 2>&1 || sleep 1; done", .{p}) catch return;
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
    const cmd = zfmt.bufPrintZ(&b, "wget -qO- 'http://{s}:{d}{s}' | aplay -q", .{ cfg.server_ip, cfg.http_port, path }) catch return;
    const pid = spawnShell(cmd.ptr);
    if (pid <= 0) return;
    stream_pid = pid;
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

fn connectServer() !c_int {
    const fd = try dial();
    errdefer _ = c.close(fd);
    var hb: [128]u8 = undefined;
    hb[0] = cfg.id;
    const info = try std.fmt.bufPrint(hb[1..], "{d:.4};{d:.4};{s}", .{ cfg.lat, cfg.lon, cfg.city });
    try net.sendFrame(alloc, fd, .hello, &.{hb[0 .. 1 + info.len]});
    if (client_prompt) |p| try net.sendFrame(alloc, fd, .prompt, &.{p});

    const f = try net.recvFrame(alloc, fd);
    defer f.deinit(alloc);
    if (f.msg_type == .cache) parseCache(f.payload);
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

    try net.sendFrameF(alloc, fd, .cmd, @intFromEnum(protocol.Op.model_req), &.{});
    const h = try net.recvHeader(fd);
    if (h.msg_type != .model or h.len == 0) return error.ModelUnavailable;

    errdefer _ = c.unlink(SHM_ARCHIVE);
    try net.recvToFile(fd, h.len, SHM_ARCHIVE);
    log("архив получен: {d} байт, распаковываю", .{h.len});

    const rc = c.system("tar -xzf " ++ SHM_ARCHIVE ++ " -C /dev/shm/");
    _ = c.unlink(SHM_ARCHIVE);
    if (rc != 0) return error.UntarFailed;
}

fn askServer(op: protocol.Op, text: []const u8, played: *bool) !void {
    if (sock < 0) sock = try connectServer();
    errdefer closeSock();
    defer speaker.close();
    try net.sendFrameF(alloc, sock, .cmd, @intFromEnum(op), &.{text});
    while (true) {
        const f = try net.recvFrame(alloc, sock);
        switch (f.msg_type) {
            .reply => {
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

fn checkPartialWake(rec: *c.VoskRecognizer) void {
    if (wake_fired) return;
    const res = c.vosk_recognizer_partial_result(rec);
    const json = std.mem.span(@as([*:0]const u8, @ptrCast(res)));
    const parsed = std.json.parseFromSlice(struct { partial: []const u8 = "" }, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const p = std.mem.trim(u8, parsed.value.partial, " ");
    if (commandAfterWake(p) != null) {
        wake_fired = true;
        playWakeSound();
    }
}

fn feedVosk(rec: *c.VoskRecognizer, buf: *const [FRAME]i16) !?[]u8 {
    if (c.vosk_recognizer_accept_waveform_s(rec, buf, FRAME) != 1) {
        checkPartialWake(rec);
        return null;
    }
    wake_fired_last = wake_fired;
    wake_fired = false;
    const res = c.vosk_recognizer_result(rec);
    const json = std.mem.span(@as([*:0]const u8, @ptrCast(res)));
    const parsed = try std.json.parseFromSlice(struct { text: []const u8 = "" }, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try alloc.dupe(u8, parsed.value.text);
}

fn commandAfterWake(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " ");
    for (wake_buf[0..wake_count]) |w| {
        if (!std.mem.startsWith(u8, t, w)) continue;
        const rest = t[w.len..];
        if (rest.len > 0 and rest[0] != ' ') continue;
        return std.mem.trim(u8, rest, " ");
    }
    return null;
}

fn opFor(cmd: []const u8) protocol.Op {
    if (std.mem.indexOf(u8, cmd, "погод") != null) return .weather;
    if (std.mem.indexOf(u8, cmd, "включи") != null) return .music;
    return .ai;
}

var dialog_frames: u32 = 0;

fn playFile(path: ?[]const u8) void {
    const p = path orelse return;
    if (std.mem.indexOfScalar(u8, p, '\'') != null) return;
    var b: [512]u8 = undefined;
    const cmd = zfmt.bufPrintZ(&b, "aplay -q '{s}' >/dev/null 2>&1", .{p}) catch return;
    _ = c.system(@ptrCast(cmd.ptr));
}

fn fire(ev: events.Event, mic: *c.snd_pcm_t) void {
    switch (ev.kind) {
        .alarm => {
            log("будильник", .{});
            startRing();
        },
        .reminder => {
            log("напоминание", .{});
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
            log("напоминание на {d}, жду сообщение", .{p.at});
        },
    }
    playWakeSound();
    return true;
}

fn dispatchBatch(rec: *c.VoskRecognizer, mic: *c.snd_pcm_t) void {
    handleCommand(acc.items, acc_force_ai);
    acc.clearRetainingCapacity();
    flushMic(mic);
    c.vosk_recognizer_reset(rec);
}

fn handleCommand(cmd: []const u8, force_ai: bool) void {
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
    for (args[1..]) |arg| {
        if (val(arg, "--id")) |v| {
            cfg.id = std.fmt.parseInt(u8, v, 10) catch 1;
        } else if (val(arg, "--server")) |v| {
            const i = std.mem.lastIndexOfScalar(u8, v, ':');
            cfg.server_ip = try alloc.dupeSentinel(u8, if (i) |p| v[0..p] else v, 0);
            if (i) |p| cfg.server_port = std.fmt.parseInt(u16, v[p + 1 ..], 10) catch 9000;
        } else if (val(arg, "--http-port")) |v| {
            cfg.http_port = std.fmt.parseInt(u16, v, 10) catch 9001;
        } else if (val(arg, "--model")) |v| {
            cfg.model = try alloc.dupeSentinel(u8, v, 0);
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

    if (cfg.prompt_path) |p| client_prompt = try zfmt.readFile(c, alloc, p);
    if (cfg.store) |s| events.store_path = s;
    events.load();
    sock = connectServer() catch -1;

    if (stop_count == 0) {
        addStop("стоп");
        addStop("хватит");
    }
    if (wake_count == 0) {
        addWake("дот");
        addWake("тот");
    }

    if (c.access(cfg.model.ptr, c.F_OK) != 0) try fetchModel();

    c.vosk_set_log_level(-1);
    const model = c.vosk_model_new(cfg.model.ptr) orelse return error.VoskModelLoadError;
    const rec = c.vosk_recognizer_new(model, @floatFromInt(RATE)) orelse return error.VoskFailed;
    const mic = try openCapture();

    log("слушаю, слова активации: {d} шт., сервер {s}:{d}", .{ wake_count, cfg.server_ip, cfg.server_port });

    var buf: [FRAME]i16 = undefined;
    var armed: u32 = 0;

    while (true) {
        reapStream();
        try readFrame(mic, &buf);
        if (armed > 0) armed -= 1;
        if (dialog_frames > 0) dialog_frames -= 1;
        try utt.appendSlice(alloc, std.mem.sliceAsBytes(buf[0..]));
        if (utt.items.len > MAX_UTT_BYTES) utt.clearRetainingCapacity();

        if (events.popDue(events.now())) |ev| fire(ev, mic);

        if (collect_frames > 0) {
            collect_frames -= 1;
            if (collect_frames == 0 and acc.items.len > 0) dispatchBatch(rec, mic);
        }

        const got = try feedVosk(rec, &buf);
        const text = got orelse continue;
        defer alloc.free(text);

        if (pending_reminder) |at| {
            if (text.len == 0) continue;
            pending_reminder = null;
            events.addReminder(at, utt.items);
            utt.clearRetainingCapacity();
            log("сообщение для напоминания сохранено", .{});
            playWakeSound();
            continue;
        }
        utt.clearRetainingCapacity();
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
            c.vosk_recognizer_reset(rec);
            continue;
        }

        var piece: []const u8 = undefined;
        var phrase_ai = false;
        if (wake_rest) |rest| {
            if (!wake_fired_last) playWakeSound();
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
        if (collect_frames == 0) dispatchBatch(rec, mic);
    }
}
