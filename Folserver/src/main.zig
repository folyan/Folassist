const std = @import("std");
const zfmt = @import("zfmt");
const cache = @import("cache.zig");
const c = @import("c");
const protocol = @import("protocol");
const ai = @import("ai.zig");
const weather = @import("weather.zig");
const tts_mod = @import("tts.zig");
const sync = @import("sync.zig");

const net = protocol.Net(c);
const alloc = std.heap.c_allocator;

var tts: tts_mod.Tts = undefined;
var tts_lock: sync.Mutex = .{};
var model_archive: ?[:0]const u8 = null;
var phrases_path: ?[]const u8 = null;

const DEFAULT_PHRASES = [_][]const u8{
    "Напоминаю",
    "Включаю.",
    "Не поняла, что включить.",
    "Не удалось узнать погоду.",
    "Не удалось получить ответ.",
};
var http_port: u16 = 9001;

var verbose = false;

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

    fn city(self: *const Session) []const u8 {
        if (self.city_len == 0) return "Омске";
        return self.city_buf[0..self.city_len];
    }

    fn applyHello(self: *Session, payload: []const u8) void {
        if (payload.len < 1) return;
        self.id = payload[0];
        var it = std.mem.splitScalar(u8, payload[1..], ';');
        if (it.next()) |s| self.lat = std.fmt.parseFloat(f64, s) catch self.lat;
        if (it.next()) |s| self.lon = std.fmt.parseFloat(f64, s) catch self.lon;
        if (it.next()) |s| {
            const n = @min(s.len, self.city_buf.len);
            @memcpy(self.city_buf[0..n], s[0..n]);
            self.city_len = n;
        }
    }
};

fn sendReplyRaw(fd: c_int, rate: u32, pcm: []const u8, flags: u8) !void {
    var rate_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &rate_b, rate, .little);
    try net.sendFrameF(alloc, fd, .reply, flags, &.{ &rate_b, pcm });
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

fn youtubeQuery(text: []const u8, out: []u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, text, "включи") orelse return null;
    var rest = std.mem.trim(u8, text[i + "включи".len ..], " ");
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
};

fn emitSentence(ctx: *anyopaque, sentence: []const u8) anyerror!void {
    const sc: *StreamCtx = @ptrCast(@alignCast(ctx));
    log("[stream] «{s}»", .{sentence});
    try speakF(sc.fd, sentence, protocol.REPLY_MORE);
    sc.sent = true;
}

fn handleCmd(fd: c_int, s: *const Session, op: protocol.Op, text: []const u8) !void {
    log("[{d}] код {d}: «{s}»", .{ s.id, @intFromEnum(op), text });

    if (op == .music) {
        var qbuf: [256]u8 = undefined;
        const q = youtubeQuery(text, &qbuf) orelse {
            return speak(fd, "Не поняла, что включить.");
        };
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(alloc);
        try path.appendSlice(alloc, "/yt?q=");
        try urlEncode(&path, q);
        try net.sendFrame(alloc, fd, .play, &.{path.items});
        return speak(fd, "Включаю.");
    }

    if (op == .ai) {
        if (text.len == 0) return net.sendFrame(alloc, fd, .reply, &.{});
        var sc: StreamCtx = .{ .fd = fd };
        const sink = ai.Sink{ .ctx = &sc, .emit = emitSentence };
        const cp: ?[]const u8 = if (s.prompt) |p| p else null;
        if (ai.askStream(alloc, s.id, text, cp, sink)) |full| {
            alloc.free(full);
            try net.sendFrame(alloc, fd, .reply, &.{});
        } else |e| {
            log("ИИ: {s}", .{@errorName(e)});
            if (sc.sent) {
                try net.sendFrame(alloc, fd, .reply, &.{});
            } else {
                try speak(fd, "Не удалось получить ответ.");
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

fn sendCache(fd: c_int) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (cache.entries.items) |e| {
        var hdr: [10]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], @intCast(e.text.len), .little);
        std.mem.writeInt(u32, hdr[2..6], e.rate, .little);
        std.mem.writeInt(u32, hdr[6..10], @intCast(e.pcm.len), .little);
        try out.appendSlice(alloc, &hdr);
        try out.appendSlice(alloc, e.text);
        try out.appendSlice(alloc, e.pcm);
    }
    try net.sendFrame(alloc, fd, .cache, &.{out.items});
}

fn handleConn(fd: c_int) !void {
    var s: Session = .{};
    defer if (s.prompt) |p| alloc.free(p);
    while (true) {
        const f = try net.recvFrame(alloc, fd);
        defer f.deinit(alloc);
        switch (f.msg_type) {
            .cmd => {
                const op: protocol.Op = @enumFromInt(@as(u2, @truncate(f.flags)));
                if (op == .model_req) {
                    const p = model_archive orelse {
                        log("клиент просит модель, но --model-archive не задан", .{});
                        try net.sendFrame(alloc, fd, .model, &.{});
                        continue;
                    };
                    log("клиент просит модель (00), отдаю {s}", .{p});
                    net.sendFile(fd, p, .model) catch |e| {
                        log("модель не отправлена: {s}", .{@errorName(e)});
                        return e;
                    };
                    continue;
                }
                handleCmd(fd, &s, op, f.payload) catch |e| {
                    log("[{d}] ошибка обработки: {s}", .{ s.id, @errorName(e) });
                    try net.sendFrame(alloc, fd, .reply, &.{});
                };
            },
            .prompt => {
                if (s.prompt) |old| alloc.free(old);
                s.prompt = try alloc.dupe(u8, f.payload);
                log("клиент {d} прислал промпт ({d} байт)", .{ s.id, f.payload.len });
            },
            .hello => {
                s.applyHello(f.payload);
                log("клиент {d} подключился (город: {s})", .{ s.id, s.city() });
                sendCache(fd) catch |e| log("кэш не отправлен: {s}", .{@errorName(e)});
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

fn serveHttp(fd: c_int) !void {
    var req: [2048]u8 = undefined;
    const n = c.recv(fd, &req, req.len, 0);
    if (n <= 0) return error.NoRequest;
    const data = req[0..@intCast(n)];
    const eol = std.mem.indexOfAny(u8, data, "\r\n") orelse data.len;

    var it = std.mem.splitScalar(u8, data[0..eol], ' ');
    const method = it.next() orelse return httpFail(fd, "400 Bad Request");
    const target = it.next() orelse return httpFail(fd, "400 Bad Request");
    if (!std.mem.eql(u8, method, "GET")) return httpFail(fd, "405 Method Not Allowed");

    var is_url = false;
    var raw: []const u8 = undefined;
    if (std.mem.startsWith(u8, target, "/yt?q=")) {
        raw = target["/yt?q=".len..];
    } else if (std.mem.startsWith(u8, target, "/yt?url=")) {
        raw = target["/yt?url=".len..];
        is_url = true;
    } else return httpFail(fd, "404 Not Found");

    var dec_buf: [512]u8 = undefined;
    const dec = urlDecode(raw, &dec_buf) orelse return httpFail(fd, "400 Bad Request");
    if (dec.len == 0) return httpFail(fd, "400 Bad Request");

    var tgt_buf: [600]u8 = undefined;
    const target_z = blk: {
        if (is_url) {
            if (!std.mem.startsWith(u8, dec, "http://") and !std.mem.startsWith(u8, dec, "https://")) {
                return httpFail(fd, "400 Bad Request");
            }
            break :blk zfmt.bufPrintZ(&tgt_buf, "{s}", .{dec}) catch return httpFail(fd, "400 Bad Request");
        }
        break :blk zfmt.bufPrintZ(&tgt_buf, "ytsearch1:{s}", .{dec}) catch return httpFail(fd, "400 Bad Request");
    };
    log("ютуб-поток: {s}", .{target_z});

    try net.writeAll(fd, "HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");

    const script = "yt-dlp -q --no-playlist -f bestaudio -o - -- \"$1\" | " ++
        "ffmpeg -loglevel error -i pipe:0 -vn -f wav -ac 2 -ar 44100 pipe:1";
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", script, "sh", target_z.ptr };

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
        if (cfd < 0) continue;
        spawn(cfd, httpThread);
    }
}

pub fn main(init: std.process.Init) !void {
    _ = c.umask(0o077);
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
        } else if (val(arg, "--proxy")) |v| {
            ai.setProxy(v);
        } else if (val(arg, "--ai-model")) |v| {
            ai.ai_model = v;
        } else if (val(arg, "--prompt")) |v| {
            ai.system_prompt = try zfmt.readFile(c, alloc, v);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (val(arg, "--cache")) |v| {
            cache.dir = v;
        } else if (val(arg, "--phrases")) |v| {
            phrases_path = v;
        }
    }

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

    const lfd = try listenOn(port);
    const hfd = try listenOn(http_port);
    spawn(hfd, httpAcceptLoop);
    log("TCP :{d}, HTTP-релей :{d}", .{ port, http_port });

    while (true) {
        const cfd = c.accept(lfd, null, null);
        if (cfd < 0) continue;
        spawn(cfd, connThread);
    }
}
