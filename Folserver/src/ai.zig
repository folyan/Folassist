const std = @import("std");
const c = @import("c");
const sync = @import("sync.zig");
const protocol = @import("protocol");

const Message = struct {
    role: []const u8,
    content: []u8,
};

const MAX_HISTORY = 16;
const SYSTEM_PROMPT = "Ты голосовой ассистент. " ++
    "Каждый ответ обязательно начинай с метки эмоции: [00] если тон нейтральный, [01] если радостный или весёлый, [10] если грустный или сочувственный, [11] только если даже по смыслу непонятно, чего хочет человек. " ++
    "Понимай речь как живой разговор: разговорные, короткие и слегка искажённые распознаванием фразы считай тем, что имел в виду собеседник, и отвечай на смысл. " ++
    "Отвечай максимально коротко, одним-двумя предложениями, если пользователь прямо не просит ответить подробно. Не используй markdown, списки, эмодзи и скобки. Числа пиши словами.";

var histories: [256]std.ArrayList(Message) = @splat(.empty);
var hist_lock: sync.Mutex = .{};
var proxy: ?[]const u8 = null;

pub fn setProxy(p: []const u8) void {
    proxy = p;
}

pub fn getProxy() ?[]const u8 {
    return proxy;
}

fn jsonEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n', '\r', '\t' => try out.append(allocator, ' '),
        0...8, 11, 12, 14...31 => {},
        else => try out.append(allocator, ch),
    };
}

fn isEmotionTag(s: []const u8) bool {
    return s.len >= 4 and s[0] == '[' and s[3] == ']' and
        (s[1] == '0' or s[1] == '1') and (s[2] == '0' or s[2] == '1');
}

fn cleanForTts(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src = std.mem.trimStart(u8, s, " \r\n\t");
    if (isEmotionTag(src)) src = src[4..];

    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '[' and isEmotionTag(src[i..])) {
            i += 4;
        } else if (ch == '*' or ch == '#' or ch == '`' or ch == '_' or ch == '(' or ch == ')' or ch == '[' or ch == ']') {
            i += 1;
        } else if (ch == '-' or ch == '\n' or ch == '\r' or ch == '\t') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (ch == ':' or ch == ';') {
            try out.append(allocator, ',');
            i += 1;
        } else if (std.mem.startsWith(u8, src[i..], "—") or std.mem.startsWith(u8, src[i..], "–")) {
            try out.append(allocator, ' ');
            i += 3;
        } else {
            try out.append(allocator, ch);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn cfgEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), str: []const u8) !void {
    for (str) |ch| switch (ch) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        else => try out.append(allocator, ch),
    };
}

fn closeFd(fd: c_int) void {
    _ = c.close(fd);
}

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, sentence: []const u8) anyerror!void,
    /// Зовётся один раз, как только из потока стало известно настроение ответа
    /// (метка [xx] идёт первой), то есть ДО озвучки первого предложения.
    emotion: ?*const fn (ctx: *anyopaque, em: protocol.Emotion) anyerror!void = null,
};

fn emotionFromTag(tag: []const u8) protocol.Emotion {
    if (std.mem.eql(u8, tag, "01")) return .happy;
    if (std.mem.eql(u8, tag, "10")) return .sad;
    if (std.mem.eql(u8, tag, "11")) return .what;
    return .def;
}

/// Пытается определить эмоцию по началу ответа. true, если решение принято
/// (метка найдена, либо уже ясно, что её нет). final = поток закончился.
fn detectEmotion(full: []const u8, final: bool, out: *protocol.Emotion) bool {
    const t = std.mem.trimStart(u8, full, " \r\n\t");
    if (t.len < 4 and !final) return false;
    out.* = if (isEmotionTag(t)) emotionFromTag(t[1..3]) else .def;
    return true;
}

const StreamChunk = struct {
    choices: []const struct {
        delta: struct { content: ?[]const u8 = null } = .{},
    } = &.{},
};

fn emitPart(allocator: std.mem.Allocator, raw: []const u8, sink: Sink) !void {
    const cleaned = try cleanForTts(allocator, raw);
    defer allocator.free(cleaned);
    const t = std.mem.trim(u8, cleaned, " ,");
    if (t.len == 0) return;
    try sink.emit(sink.ctx, t);
}

pub var ai_model: []const u8 = "openai/gpt-oss-20b";
pub var system_prompt: []const u8 = SYSTEM_PROMPT;

const MIN_CHUNK_CHARS = 4;

fn utf8Chars(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

fn isPunct(ch: u8) bool {
    return switch (ch) {
        '.', '!', '?', ',', ';', ':' => true,
        else => false,
    };
}

fn flushChunks(allocator: std.mem.Allocator, pending: *std.ArrayList(u8), sink: Sink) !void {
    var start: usize = 0;
    for (pending.items, 0..) |ch, i| {
        if (ch != ' ' or i == 0 or !isPunct(pending.items[i - 1])) continue;
        const piece = pending.items[start..i];
        if (utf8Chars(piece) < MIN_CHUNK_CHARS) continue;
        try emitPart(allocator, piece, sink);
        start = i + 1;
    }
    if (start == 0) return;
    const rest = try allocator.dupe(u8, pending.items[start..]);
    defer allocator.free(rest);
    pending.clearRetainingCapacity();
    try pending.appendSlice(allocator, rest);
}

pub fn askStream(allocator: std.mem.Allocator, client_id: u8, query: []const u8, client_prompt: ?[]const u8, sink: Sink, emotion_out: *protocol.Emotion, key: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, key, "\"\\\r\n") != null) return error.BadApiKey;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(allocator);
    try sys.appendSlice(allocator, system_prompt);
    if (client_prompt) |cp| {
        try sys.appendSlice(allocator, "\n\n");
        try sys.appendSlice(allocator, cp);
    }

    try body.appendSlice(allocator, "{\"model\":\"");
    try jsonEscape(allocator, &body, ai_model);
    try body.appendSlice(allocator, "\",\"include_reasoning\":false,\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"");
    try jsonEscape(allocator, &body, sys.items);
    try body.appendSlice(allocator, "\"}");
    {
        hist_lock.lock();
        defer hist_lock.unlock();
        for (histories[client_id].items) |m| {
            try body.appendSlice(allocator, ",{\"role\":\"");
            try body.appendSlice(allocator, m.role);
            try body.appendSlice(allocator, "\",\"content\":\"");
            try jsonEscape(allocator, &body, m.content);
            try body.appendSlice(allocator, "\"}");
        }
    }
    try body.appendSlice(allocator, ",{\"role\":\"user\",\"content\":\"");
    try jsonEscape(allocator, &body, query);
    try body.appendSlice(allocator, "\"}]}");

    var cfg: std.ArrayList(u8) = .empty;
    defer {
        @memset(cfg.items, 0);
        cfg.deinit(allocator);
    }
    try cfg.appendSlice(allocator, "silent\nno-buffer\nmax-time = 60\n" ++
        "url = \"https://api.groq.com/openai/v1/chat/completions\"\n" ++
        "header = \"Content-Type: application/json\"\nheader = \"Authorization: Bearer ");
    try cfg.appendSlice(allocator, key);
    try cfg.appendSlice(allocator, "\"\ndata-binary = \"");
    try cfgEscape(allocator, &cfg, body.items);
    try cfg.appendSlice(allocator, "\"\n");
    if (proxy) |p| {
        if (std.mem.indexOfAny(u8, p, "\"\\\r\n") == null) {
            try cfg.appendSlice(allocator, "proxy = \"");
            try cfg.appendSlice(allocator, p);
            try cfg.appendSlice(allocator, "\"\n");
        }
    }

    var in_p: [2]c_int = undefined;
    var out_p: [2]c_int = undefined;
    if (c.pipe(&in_p) != 0) return error.CurlFailed;
    if (c.pipe(&out_p) != 0) {
        closeFd(in_p[0]);
        closeFd(in_p[1]);
        return error.CurlFailed;
    }
    for ([_]c_int{ in_p[0], in_p[1], out_p[0], out_p[1] }) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);

    const pid = c.fork();
    if (pid < 0) {
        closeFd(in_p[0]);
        closeFd(in_p[1]);
        closeFd(out_p[0]);
        closeFd(out_p[1]);
        return error.CurlFailed;
    }
    if (pid == 0) {
        _ = c.dup2(in_p[0], 0);
        _ = c.dup2(out_p[1], 1);
        const argv = [_:null]?[*:0]const u8{ "curl", "-K", "-" };
        _ = c.execvp("curl", @ptrCast(&argv));
        c._exit(127);
    }
    closeFd(in_p[0]);
    closeFd(out_p[1]);

    var off: usize = 0;
    var write_ok = true;
    while (off < cfg.items.len) {
        const n = c.write(in_p[1], cfg.items.ptr + off, cfg.items.len - off);
        if (n <= 0) {
            write_ok = false;
            break;
        }
        off += @intCast(n);
    }
    closeFd(in_p[1]);

    const pipe = c.fdopen(out_p[0], @ptrCast("r")) orelse {
        closeFd(out_p[0]);
        var st0: c_int = 0;
        _ = c.waitpid(pid, &st0, 0);
        return error.CurlFailed;
    };
    defer {
        _ = c.fclose(pipe);
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
    }
    if (!write_ok) return error.CurlFailed;

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var emotion_known = false;

    var line_buf: [8192]u8 = undefined;
    while (c.fgets(&line_buf, @intCast(line_buf.len), pipe) != null) {
        const line = std.mem.trim(u8, std.mem.sliceTo(&line_buf, 0), " \r\n");
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const data = line["data: ".len..];
        if (std.mem.eql(u8, data, "[DONE]")) break;

        const parsed = std.json.parseFromSlice(StreamChunk, allocator, data, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (parsed.value.choices.len == 0) continue;
        const piece = parsed.value.choices[0].delta.content orelse continue;

        try full.appendSlice(allocator, piece);
        try pending.appendSlice(allocator, piece);
        if (!emotion_known and detectEmotion(full.items, false, emotion_out)) {
            emotion_known = true;
            if (sink.emotion) |cb| try cb(sink.ctx, emotion_out.*);
        }
        try flushChunks(allocator, &pending, sink);
    }

    if (full.items.len == 0) return error.EmptyReply;
    if (!emotion_known) {
        // очень короткий ответ: метку ещё не успели разобрать
        _ = detectEmotion(full.items, true, emotion_out);
        if (sink.emotion) |cb| try cb(sink.ctx, emotion_out.*);
    }
    if (pending.items.len > 0) try emitPart(allocator, pending.items, sink);

    const cleaned = try cleanForTts(allocator, full.items);
    errdefer allocator.free(cleaned);
    if (std.mem.trim(u8, cleaned, " ,").len == 0) return error.EmptyReply;

    {
        const q = try allocator.dupe(u8, query);
        errdefer allocator.free(q);
        const a = try allocator.dupe(u8, cleaned);
        errdefer allocator.free(a);
        hist_lock.lock();
        defer hist_lock.unlock();
        const h = &histories[client_id];
        try h.append(allocator, .{ .role = "user", .content = q });
        try h.append(allocator, .{ .role = "assistant", .content = a });
        while (h.items.len > MAX_HISTORY) {
            allocator.free(h.items[0].content);
            _ = h.orderedRemove(0);
        }
    }
    return cleaned;
}

