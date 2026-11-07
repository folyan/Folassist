const std = @import("std");
const zfmt = @import("zfmt");
const cache = @import("cache.zig");
const c = @import("c");
const protocol = @import("protocol");
const ai = @import("ai.zig");
const weather = @import("weather.zig");
const tts_mod = @import("tts.zig");
const sync = @import("sync.zig");
const update = @import("update.zig");
const stt = @import("stt.zig");

const net = protocol.Net(c);
const alloc = std.heap.c_allocator;

var tts: tts_mod.Tts = undefined;
var tts_lock: sync.Mutex = .{};
var model_archive: ?[:0]const u8 = null;
var phrases_path: ?[]const u8 = null;

const DEFAULT_PHRASES = [_][]const u8{
    "Напоминаю",
    "Включаю.",
    "Не понял, что включить.",
    "Не удалось узнать погоду.",
    "Не удалось получить ответ.",
};
var http_port: u16 = 9001;
var yt_rate: u32 = 44100;
var yt_channels: u8 = 1;

var verbose = false;

var id_lock: sync.Mutex = .{};
var id_used: [256]bool = @splat(false);

fn claimId(want: u8) ?u8 {
    id_lock.lock();
    defer id_lock.unlock();
    if (!id_used[want]) {
        id_used[want] = true;
        return want;
    }
    for (&id_used, 0..) |*u, i| {
        if (!u.*) {
            u.* = true;
            return @intCast(i);
        }
    }
    return null;
}

fn releaseId(id: u8) void {
    id_lock.lock();
    defer id_lock.unlock();
    id_used[id] = false;
}

const MAX_STREAMS: u32 = 4;
var streams = std.atomic.Value(u32).init(0);

var password: []const u8 = "";
var no_auth = false;
const PRE_AUTH_TIMEOUT: c_long = 10;
const IDLE_TIMEOUT: c_long = 600;
const HTTP_TIMEOUT: c_long = 10;

fn passOk(given: []const u8) bool {
    if (no_auth) return true;
    if (given.len != password.len) return false;
    var diff: u8 = 0;
    for (given, password) |a, b| diff |= a ^ b;
    return diff == 0;
}

fn setRecvTimeout(fd: c_int, sec: c_long) void {
    var tv = std.mem.zeroes(c.struct_timeval);
    tv.tv_sec = sec;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
}

fn safeAssetName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    }
    return true;
}

fn ytHostOk(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..end];
    if (host.len == 0 or std.mem.indexOfAny(u8, host, "@:\\ ") != null) return false;
    var lb: [64]u8 = undefined;
    if (host.len > lb.len) return false;
    const h = std.ascii.lowerString(&lb, host);
    return std.mem.eql(u8, h, "youtu.be") or std.mem.eql(u8, h, "youtube.com") or std.mem.endsWith(u8, h, ".youtube.com");
}

const USAGE =
    \\folserver [опции]
    \\  --port=N             TCP-порт клиентов, по умолчанию 9000
    \\  --http-port=N        порт HTTP-релея ютуба, по умолчанию 9001
    \\  --voice=ФАЙЛ         голос Piper (.onnx, рядом должен лежать .onnx.json)
    \\  --espeak=ПАПКА       espeak-ng-data, по умолчанию /usr/share/espeak-ng-data
    \\  --model-archive=ФАЙЛ архив модели Vosk для клиентов
    \\  --ai-model=ИМЯ       модель Groq
    \\  --proxy=URL          прокси для запросов к Groq
    \\  --prompt=ФАЙЛ        системный промпт ИИ
    \\  --cache=ПАПКА        папка кэша озвученных фраз, по умолчанию cache
    \\  --phrases=ФАЙЛ       дополнительные фразы для кэша, по одной на строку
    \\  --yt-rate=N          частота звука ютуба, по умолчанию 44100
    \\  --yt-ch=1|2          каналов в звуке ютуба, по умолчанию 2
    \\  --pass=ПАРОЛЬ        пароль клиентов (или переменная FOLSERVER_PASS), до 64 байт
    \\  --no-auth            работать без пароля (небезопасно)
    \\  --verbose            подробный лог
    \\  --help               эта справка
    \\Ключ Groq берётся из переменной GROQ_API_KEY.
;

fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    std.debug.print("folserver: " ++ fmt ++ "\n", args);
    return error.Fatal;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!verbose) return;
    std.debug.print("[folserver] " ++ fmt ++ "\n", args);
}

fn val(arg: []const u8, comptime key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, key ++ "=")) return arg[key.len + 1 ..];
    return null;
}

const Session = struct {
    id: u8 = 0,
    lat: f64 = 54.99,
    lon: f64 = 73.37,
    city_buf: [64]u8 = undefined,
    city_len: usize = 0,
    prompt: ?[]u8 = null,
    version: u8 = 0,
    asset: ?[]u8 = null,
    musl: bool = false,
    claimed: bool = false,

    fn city(self: *const Session) []const u8 {
        if (self.city_len == 0) return "Омске";
        return self.city_buf[0..self.city_len];
    }

    fn applyHello(self: *Session, payload: []const u8, version: u8, musl: bool) bool {
        self.musl = musl;
        self.version = version;
        if (payload.len < 1) return false;
        self.id = payload[0];
        var it = std.mem.splitScalar(u8, payload[1..], ';');
        if (it.next()) |s| self.lat = std.fmt.parseFloat(f64, s) catch self.lat;
        if (it.next()) |s| self.lon = std.fmt.parseFloat(f64, s) catch self.lon;
        if (it.next()) |s| {
            const n = @min(s.len, self.city_buf.len);
            @memcpy(self.city_buf[0..n], s[0..n]);
            self.city_len = n;
        }
        if (self.asset) |old| alloc.free(old);
        self.asset = null;
        if (it.next()) |s| {
            if (safeAssetName(s)) self.asset = alloc.dupe(u8, s) catch null;
        }
        return passOk(it.next() orelse "");
    }
};

fn sendReplyRaw(fd: c_int, rate: u32, pcm: []const u8, flags: u8) !void {
    var rate_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &rate_b, rate, .little);
    try net.sendFrameF(fd, .reply, flags, &.{ &rate_b, pcm });
}

fn speakF(fd: c_int, text: []const u8, flags: u8) !void {
    if (cache.find(text)) |e| return sendReplyRaw(fd, e.rate, e.pcm, flags);

    tts_lock.lock();
    const audio = tts.synthesizeToMemory(text) catch |e| {
        tts_lock.unlock();
        return e;
    };
    tts_lock.unlock();
    defer alloc.free(audio.samples);
    try sendReplyRaw(fd, audio.sample_rate, std.mem.sliceAsBytes(audio.samples), flags);
}

fn speak(fd: c_int, text: []const u8) !void {
    return speakF(fd, text, 0);
}

/// Сначала сразу шлём кадр с эмоцией (лицо меняется до озвучки), потом саму фразу.
fn speakEm(fd: c_int, text: []const u8, em: protocol.Emotion) !void {
    try net.sendFrameF(fd, .reply, protocol.setEmotion(protocol.REPLY_MORE, em), &.{});
    return speakF(fd, text, protocol.setEmotion(0, em));
}

fn youtubeQuery(text: []const u8, out: []u8) ?[]const u8 {
    var start: usize = 0;
    if (std.mem.indexOf(u8, text, "включи")) |i| {
        start = i + "включи".len;
    } else {
        const sp = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
        if (stt.similarity(text[0..sp], "включи") < 60) return null;
        start = sp;
    }
    var rest = std.mem.trim(u8, std.mem.trim(u8, text[start..], " "), " .,!?");
    for ([_][]const u8{ "в ютубе", "в ютуб", "ютубе", "ютуб", "youtube" }) |w| {
        if (std.mem.startsWith(u8, rest, w)) {
            rest = std.mem.trim(u8, rest[w.len..], " ");
            break;
        }
    }
    if (rest.len == 0 or rest.len > out.len) return null;
    @memcpy(out[0..rest.len], rest);
    return out[0..rest.len];
}

fn urlEncode(out: *std.ArrayList(u8), s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(alloc, ch);
        } else {
            try out.appendSlice(alloc, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
}

fn urlDecode(s: []const u8, out: []u8) ?[]u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (o += 1) {
        if (o >= out.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            out[o] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else if (s[i] == '+') {
            out[o] = ' ';
            i += 1;
        } else {
            out[o] = s[i];
            i += 1;
        }
    }
    return out[0..o];
}

const StreamCtx = struct {
    fd: c_int,
    sent: bool = false,
    emotion: protocol.Emotion = .def,
};

fn emitSentence(ctx: *anyopaque, sentence: []const u8) anyerror!void {
    const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
    log("[stream] «{s}»", .{sentence});
    // эмоция в каждом кадре: клиент не должен откатываться на def между предложениями
    try speakF(sc.fd, sentence, protocol.setEmotion(protocol.REPLY_MORE, sc.emotion));
    sc.sent = true;
}

fn emitEmotion(ctx: *anyopaque, em: protocol.Emotion) anyerror!void {
    const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
    log("[stream] эмоция {s}", .{@tagName(em)});
    try net.sendFrameF(sc.fd, .reply, protocol.setEmotion(protocol.REPLY_MORE, em), &.{});
}

fn handleCmd(fd: c_int, s: *const Session, op: protocol.Op, text: []const u8) !void {
    log("[{d}] код {d}: «{s}»", .{ s.id, @intFromEnum(op), text });
    if (std.mem.indexOf(u8, text, "Стоп") != null or std.mem.indexOf(u8, text, "Хватит") != null) {
        log("[{d}] перехвачен стоп, гасим звук", .{s.id});
        // Отправляем пустой ответ клиенту, чтобы он закрыл свой стрим
        try net.sendFrame(fd, .reply, &.{});
        return;
    }

    if (op == .music) {
        var qbuf: [256]u8 = undefined;
        const q = youtubeQuery(text, &qbuf) orelse {
            return speakEm(fd, "Не понял, что включить.", .what);
        };
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(alloc);
        try path.appendSlice(alloc, "/yt?k=");
        try urlEncode(&path, password);
        try path.appendSlice(alloc, "&q=");
        try urlEncode(&path, q);
        try net.sendFrame(fd, .play, &.{path.items});
        return speak(fd, "Включаю.");
    }

    if (op == .ai) {
        if (text.len == 0) return net.sendFrame(fd, .reply, &.{});
        var sc: StreamCtx = .{ .fd = fd };
        const sink = ai.Sink{ .ctx = &sc, .emit = emitSentence, .emotion = emitEmotion };
        const cp: ?[]const u8 = if (s.prompt) |p| p else null;
        const res: anyerror![]u8 = blk: {
            var kbuf: [stt.MAX_KEYS][]const u8 = undefined;
            const kn = stt.orderedKeys(&kbuf);
            var last: anyerror = error.NoApiKey;
            for (kbuf[0..kn]) |k| {
                if (ai.askStream(alloc, s.id, text, cp, sink, &sc.emotion, k)) |full| {
                    break :blk full;
                } else |e| {
                    last = e;
                    log("[{d}] ИИ, ключ не сработал: {s}", .{ s.id, @errorName(e) });
                    if (sc.sent) break;
                }
            }
            break :blk last;
        };
        if (res) |full| {
            alloc.free(full);
            var flags: u8 = 0;
            flags = protocol.setEmotion(flags, sc.emotion);
            try net.sendFrameF(fd, .reply, flags, &.{});
        } else |e| {
            log("ИИ: {s}", .{@errorName(e)});
            if (sc.sent) {
                try net.sendFrame(fd, .reply, &.{});
            } else {
                try speakEm(fd, "Не удалось получить ответ.", .sad);
            }
        }
        return;
    }

    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);
    const reply: []const u8 = blk: {
        if (weather.phrase(alloc, s.city(), s.lat, s.lon)) |r| {
            owned = r;
            break :blk r;
        } else |e| {
            log("погода: {s}", .{@errorName(e)});
            break :blk "Не удалось узнать погоду.";
        }
    };
    log("[{d}] отвечаю: «{s}»", .{ s.id, reply });
    try speak(fd, reply);
}

fn sendCache(fd: c_int, new_id: ?u8) !void {
    const items = cache.entries.items;
    const hdrs = try alloc.alloc([10]u8, items.len);
    defer alloc.free(hdrs);
    const parts = try alloc.alloc([]const u8, items.len * 3 + 1);
    defer alloc.free(parts);
    const id_b: [1]u8 = .{new_id orelse 0};
    var n: usize = 0;
    if (new_id != null) {
        parts[0] = &id_b;
        n = 1;
    }
    const base = n;
    for (items) |e| {
        if (e.text.len > std.math.maxInt(u16) or e.pcm.len > std.math.maxInt(u32)) continue;
        const k = (n - base) / 3;
        const hdr = &hdrs[k];
        std.mem.writeInt(u16, hdr[0..2], @intCast(e.text.len), .little);
        std.mem.writeInt(u32, hdr[2..6], e.rate, .little);
        std.mem.writeInt(u32, hdr[6..10], @intCast(e.pcm.len), .little);
        parts[n] = hdr;
        parts[n + 1] = e.text;
        parts[n + 2] = e.pcm;
        n += 3;
    }
    const flags: u8 = if (new_id != null) protocol.CACHE_ID else 0;
    try net.sendFrameF(fd, .cache, flags, parts[0..n]);
}

fn classify(text: []const u8) protocol.Op {
    if (std.mem.indexOf(u8, text, "погод") != null) return .weather;
    if (std.mem.indexOf(u8, text, "будильник") != null or std.mem.indexOf(u8, text, "напомни") != null or std.mem.indexOf(u8, text, "таймер") != null) return .ai;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |w| {
        for ([_][]const u8{ "включи", "вруби", "сыграй" }) |k| {
            if (stt.similarity(w, k) >= 60) return .music;
        }
    }
    return .ai;
}

fn handleAudio(fd: c_int, s: *const Session, flags: u8, pcm: []const u8) !void {
    const forced_ai = (flags & 0b11) == @intFromEnum(protocol.Op.ai);
    const raw = stt.transcribe(pcm) catch |e| {
        log("[{d}] распознавание: {s}", .{ s.id, @errorName(e) });
        return speakEm(fd, "Не получилось распознать.", .sad);
    };
    defer alloc.free(raw);
    const text = stt.stripWake(std.mem.trim(u8, raw, " .,!?"));
    log("[{d}] облако услышало: «{s}»", .{ s.id, text });
    if (text.len == 0) return speakEm(fd, "Не расслышал.", .what);
    const op: protocol.Op = if (forced_ai) .ai else classify(text);
    return handleCmd(fd, s, op, text);
}

fn handleConn(fd: c_int) !void {
    var s: Session = .{};
    defer if (s.claimed) releaseId(s.id);
    defer if (s.prompt) |p| alloc.free(p);
    defer if (s.asset) |p| alloc.free(p);
    var authed = false;
    setRecvTimeout(fd, PRE_AUTH_TIMEOUT);
    while (true) {
        const f = try net.recvFrame(alloc, fd);
        defer f.deinit(alloc);
        if (!authed and f.msg_type != .hello and f.msg_type != .cmd) return error.Unauthorized;
        switch (f.msg_type) {
            .cmd => {
                if ((f.flags & protocol.AUDIO_FLAG) != 0) {
                    if (!authed) return error.Unauthorized;
                    handleAudio(fd, &s, f.flags, f.payload) catch |e| {
                        log("[{d}] аудио: {s}", .{ s.id, @errorName(e) });
                        try net.sendFrame(fd, .reply, &.{});
                    };
                    continue;
                }
                const op: protocol.Op = @enumFromInt(@as(u2, @truncate(f.flags)));
                if (op == .model_req) {
                    // запрос модели идёт без hello, пароль лежит в payload
                    if (!passOk(f.payload)) return error.Unauthorized;
                    const p = model_archive orelse {
                        log("клиент просит модель, но --model-archive не задан", .{});
                        try net.sendFrame(fd, .model, &.{});
                        continue;
                    };
                    log("клиент просит модель (00), отдаю {s}", .{p});
                    net.sendFile(fd, p, .model) catch |e| {
                        log("модель не отправлена: {s}", .{@errorName(e)});
                        return e;
                    };
                    continue;
                }
                if (!authed) return error.Unauthorized;
                handleCmd(fd, &s, op, f.payload) catch |e| {
                    log("[{d}] ошибка обработки: {s}", .{ s.id, @errorName(e) });
                    try net.sendFrame(fd, .reply, &.{});
                };
            },
            .prompt => {
                if (!authed) return error.Unauthorized;
                if (s.prompt) |old| alloc.free(old);
                s.prompt = try alloc.dupe(u8, f.payload);
                log("клиент {d} прислал промпт ({d} байт)", .{ s.id, f.payload.len });
            },
            .hello => {
                if (s.claimed) {
                    releaseId(s.id);
                    s.claimed = false;
                }
                if (!s.applyHello(f.payload, f.version, f.musl)) return error.Unauthorized;
                const want = s.id;
                s.id = claimId(want) orelse return error.NoFreeId;
                s.claimed = true;
                const new_id: ?u8 = if (s.id != want) s.id else null;
                if (new_id != null) log("id {d} занят, выдаю {d}", .{ want, s.id });
                authed = true;
                setRecvTimeout(fd, IDLE_TIMEOUT);
                log("клиент {d} подключился (город: {s})", .{ s.id, s.city() });
                sendCache(fd, new_id) catch |e| {
                    log("кэш не отправлен: {s}", .{@errorName(e)});
                    // клиент ждёт кадр cache после hello, шлём пустой, чтобы он не завис
                    if (new_id) |nid| {
                        try net.sendFrameF(fd, .cache, protocol.CACHE_ID, &.{&.{nid}});
                    } else try net.sendFrame(fd, .cache, &.{});
                };
                if (update.offerPayload(s.version, s.asset, s.musl)) |p| {
                    defer alloc.free(p);
                    net.sendFrame(fd, .update, &.{p}) catch {};
                }
            },
            else => {},
        }
    }
}

fn connThread(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const fd: c_int = @intCast(@intFromPtr(arg));
    handleConn(fd) catch |e| log("соединение закрыто: {s}", .{@errorName(e)});
    _ = c.close(fd);
    return null;
}

fn httpFail(fd: c_int, status: []const u8) void {
    var b: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "HTTP/1.0 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    net.writeAll(fd, msg) catch {};
}

fn serveUpdate(fd: c_int, name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOf(u8, name, "..") != null) return httpFail(fd, "404 Not Found");
    const p = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ update.DIR, name }, 0);
    defer alloc.free(p);
    const data = zfmt.readFile(c, alloc, p) catch return httpFail(fd, "404 Not Found");
    defer alloc.free(data);
    var hb: [160]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "HTTP/1.0 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data.len});
    try net.writeAll(fd, head);
    try net.writeAll(fd, data);
}

fn serveHttp(fd: c_int) !void {
    setRecvTimeout(fd, HTTP_TIMEOUT);
    var req: [2048]u8 = undefined;
    const n = c.recv(fd, &req, req.len, 0);
    if (n <= 0) return error.NoRequest;
    const data = req[0..@intCast(n)];
    const eol = std.mem.indexOfAny(u8, data, "\r\n") orelse data.len;

    var it = std.mem.splitScalar(u8, data[0..eol], ' ');
    const method = it.next() orelse return httpFail(fd, "400 Bad Request");
    const target = it.next() orelse return httpFail(fd, "400 Bad Request");
    if (!std.mem.eql(u8, method, "GET")) return httpFail(fd, "405 Method Not Allowed");
    if (std.mem.startsWith(u8, target, "/update/")) return serveUpdate(fd, target["/update/".len..]);

    if (!std.mem.startsWith(u8, target, "/yt?k=")) return httpFail(fd, "404 Not Found");
    const after_k = target["/yt?k=".len..];
    const amp = std.mem.indexOfScalar(u8, after_k, '&') orelse return httpFail(fd, "400 Bad Request");
    var k_buf: [128]u8 = undefined;
    const k = urlDecode(after_k[0..amp], &k_buf) orelse return httpFail(fd, "400 Bad Request");
    if (!passOk(k)) return httpFail(fd, "403 Forbidden");
    const query = after_k[amp + 1 ..];

    var is_url = false;
    var raw: []const u8 = undefined;
    if (std.mem.startsWith(u8, query, "q=")) {
        raw = query["q=".len..];
    } else if (std.mem.startsWith(u8, query, "url=")) {
        raw = query["url=".len..];
        is_url = true;
    } else return httpFail(fd, "404 Not Found");

    var dec_buf: [512]u8 = undefined;
    const dec = urlDecode(raw, &dec_buf) orelse return httpFail(fd, "400 Bad Request");
    if (dec.len == 0) return httpFail(fd, "400 Bad Request");

    var tgt_buf: [600]u8 = undefined;
    const target_z = blk: {
        if (is_url) {
            if (!ytHostOk(dec)) return httpFail(fd, "400 Bad Request");
            break :blk zfmt.bufPrintZ(&tgt_buf, "{s}", .{dec}) catch return httpFail(fd, "400 Bad Request");
        }
        break :blk zfmt.bufPrintZ(&tgt_buf, "ytsearch1:{s}", .{dec}) catch return httpFail(fd, "400 Bad Request");
    };
    if (streams.fetchAdd(1, .acq_rel) >= MAX_STREAMS) {
        _ = streams.fetchSub(1, .acq_rel);
        return httpFail(fd, "503 Service Unavailable");
    }
    defer _ = streams.fetchSub(1, .acq_rel);
    log("ютуб-поток: {s}", .{target_z});

    try net.writeAll(fd, "HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");

    var pbuf: [256]u8 = undefined;
    var proxy_arg: [:0]const u8 = "";
    if (ai.getProxy()) |p| {
        proxy_arg = if (std.mem.indexOf(u8, p, "://") != null)
            try zfmt.bufPrintZ(&pbuf, "{s}", .{p})
        else
            try zfmt.bufPrintZ(&pbuf, "http://{s}", .{p});
    }

    var script_buf: [384]u8 = undefined;
    const script = try zfmt.bufPrintZ(&script_buf, "(yt-dlp -q --no-playlist ${{2:+--proxy \"$2\"}} -f bestaudio -o - -- \"$1\" | " ++
        "ffmpeg -loglevel error -i pipe:0 -vn -f wav -ac {d} -ar {d} pipe:1) 2>/dev/null", .{ yt_channels, yt_rate });
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", script.ptr, "sh", target_z.ptr, proxy_arg.ptr };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.dup2(fd, 1);
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    var st: c_int = 0;
    _ = c.waitpid(pid, &st, 0);
}

fn httpThread(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const fd: c_int = @intCast(@intFromPtr(arg));
    serveHttp(fd) catch |e| log("http: {s}", .{@errorName(e)});
    _ = c.close(fd);
    return null;
}

fn listenOn(port: u16) !c_int {
    const lfd = c.socket(@intCast(c.AF_INET), @intCast(c.SOCK_STREAM), 0);
    if (lfd < 0) return error.SocketFailed;
    var one: c_int = 1;
    _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
    _ = c.fcntl(lfd, c.F_SETFD, c.FD_CLOEXEC);

    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = @intCast(c.AF_INET);
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = 0;
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) return error.BindFailed;
    if (c.listen(lfd, 16) < 0) return error.ListenFailed;
    return lfd;
}

fn spawn(fd: c_int, f: *const fn (?*anyopaque) callconv(.c) ?*anyopaque) void {
    var one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_KEEPALIVE, &one, @sizeOf(c_int));
    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);

    var attr: c.pthread_attr_t = undefined;
    _ = c.pthread_attr_init(&attr);
    _ = c.pthread_attr_setstacksize(&attr, 1 << 20);
    _ = c.pthread_attr_setdetachstate(&attr, c.PTHREAD_CREATE_DETACHED);
    var tid: c.pthread_t = undefined;
    const arg: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(fd)));
    if (c.pthread_create(&tid, &attr, f, arg) != 0) _ = c.close(fd);
    _ = c.pthread_attr_destroy(&attr);
}

fn httpAcceptLoop(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lfd: c_int = @intCast(@intFromPtr(arg));
    while (true) {
        const cfd = c.accept(lfd, null, null);
        if (cfd < 0) {
            _ = c.usleep(10_000);
            continue;
        }
        spawn(cfd, httpThread);
    }
}

// signal() with usize handler: SIG_IGN (1) is not a valid aligned fn pointer on aarch64
extern "c" fn signal(sig: c_int, handler: usize) usize;

pub fn main(init: std.process.Init) !void {
    _ = c.umask(0o077);
    _ = signal(c.SIGPIPE, 1); // SIG_IGN
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var voice_path: []const u8 = "voice/ru_RU-ruslan-medium.onnx";
    var espeak_path: []const u8 = "/usr/share/espeak-ng-data";
    var port: u16 = 9000;
    for (args[1..]) |arg| {
        if (val(arg, "--model-archive")) |v| {
            model_archive = try alloc.dupeSentinel(u8, v, 0);
        } else if (val(arg, "--voice")) |v| {
            voice_path = v;
        } else if (val(arg, "--espeak")) |v| {
            espeak_path = v;
        } else if (val(arg, "--port")) |v| {
            port = std.fmt.parseInt(u16, v, 10) catch 9000;
        } else if (val(arg, "--http-port")) |v| {
            http_port = std.fmt.parseInt(u16, v, 10) catch 9001;
        } else if (val(arg, "--groq-key")) |v| {
            if (!stt.addKey(v)) log("--groq-key: пусто или больше 5 ключей", .{});
        } else if (val(arg, "--proxy")) |v| {
            ai.setProxy(v);
        } else if (val(arg, "--ai-model")) |v| {
            ai.ai_model = v;
        } else if (val(arg, "--prompt")) |v| {
            ai.system_prompt = try zfmt.readFile(c, alloc, v);
        } else if (val(arg, "--pass")) |v| {
            password = v;
        } else if (std.mem.eql(u8, arg, "--no-auth")) {
            no_auth = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (val(arg, "--cache")) |v| {
            cache.dir = v;
        } else if (val(arg, "--phrases")) |v| {
            phrases_path = v;
        } else if (val(arg, "--yt-rate")) |v| {
            yt_rate = std.fmt.parseInt(u32, v, 10) catch 44100;
        } else if (val(arg, "--yt-ch")) |v| {
            yt_channels = if (std.mem.eql(u8, v, "1")) 1 else 2;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return;
        } else {
            return fatal("неизвестная опция {s}, список: --help", .{arg});
        }
    }

    if (password.len == 0) {
        if (c.getenv(@ptrCast("FOLSERVER_PASS"))) |e| password = std.mem.span(@as([*:0]const u8, @ptrCast(e)));
    }
    if (!no_auth and (password.len == 0 or password.len > 64)) {
        return fatal("нужен пароль 1-64 байта: --pass=... или FOLSERVER_PASS (или --no-auth)", .{});
    }

    const cfg_path = try std.fmt.allocPrint(alloc, "{s}.json", .{voice_path});
    const cfg_data = zfmt.readFile(c, alloc, cfg_path) catch &[_]u8{};
    if (cfg_data.len == 0) return fatal("нет или пустой конфиг голоса: {s}", .{cfg_path});
    const onnx_z = try alloc.dupeSentinel(u8, voice_path, 0);
    const onnx_f = c.fopen(@ptrCast(onnx_z.ptr), @ptrCast("rb")) orelse
        return fatal("нет файла голоса: {s}", .{voice_path});
    _ = c.fclose(onnx_f);
    tts = try tts_mod.Tts.init(alloc, voice_path, espeak_path);

    var phrases: std.ArrayList([]const u8) = .empty;
    for (DEFAULT_PHRASES) |p| try phrases.append(alloc, p);
    if (phrases_path) |pp| {
        if (zfmt.readFile(c, alloc, pp)) |data| {
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \r");
                if (t.len > 0) try phrases.append(alloc, t);
            }
        } else |_| log("файл фраз не прочитан: {s}", .{pp});
    }
    cache.load(&tts, phrases.items);
    log("кэш фраз: {d}", .{cache.entries.items.len});

    var upd_tid: c.pthread_t = undefined;
    _ = c.pthread_create(&upd_tid, null, update.threadMain, null);

    const lfd = try listenOn(port);
    const hfd = try listenOn(http_port);
    spawn(hfd, httpAcceptLoop);
    log("TCP :{d}, HTTP-релей :{d}", .{ port, http_port });

    while (true) {
        const cfd = c.accept(lfd, null, null);
        if (cfd < 0) {
            _ = c.usleep(10_000);
            continue;
        }
        spawn(cfd, connThread);
    }
}

