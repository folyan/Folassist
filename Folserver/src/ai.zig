const std = @import("std");
const zfmt = @import("zfmt");
const c = @import("c");
const sync = @import("sync.zig");

const Message = struct {
    role: []const u8,
    content: []u8,
};

const MAX_HISTORY = 16;
const SYSTEM_PROMPT = "Ты голосовой ассистент по имени Дот. Отвечай по-русски, коротко: одно-три предложения. " ++
    "Не используй markdown, списки, эмодзи и скобки. Числа пиши словами.";

var histories: [256]std.ArrayList(Message) = @splat(.empty);
var hist_lock: sync.Mutex = .{};
var proxy: ?[]const u8 = null;

pub fn setProxy(p: []const u8) void {
    proxy = p;
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

fn cleanForTts(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '*' or ch == '#' or ch == '`' or ch == '_' or ch == '(' or ch == ')' or ch == '[' or ch == ']') {
            i += 1;
        } else if (ch == '-' or ch == '\n' or ch == '\r' or ch == '\t') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (ch == ':' or ch == ';') {
            try out.append(allocator, ',');
            i += 1;
        } else if (std.mem.startsWith(u8, s[i..], "—") or std.mem.startsWith(u8, s[i..], "–")) {
            try out.append(allocator, ' ');
            i += 3;
        } else {
            try out.append(allocator, ch);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var pb: [128]u8 = undefined;
    const pz = try zfmt.bufPrintZ(&pb, "{s}", .{path});
    const f = c.fopen(@ptrCast(pz.ptr), @ptrCast("wb")) orelse return error.FileWriteFailed;
    defer _ = c.fclose(f);
    if (c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.FileWriteFailed;
}

fn unlinkPath(path: []const u8) void {
    var pb: [128]u8 = undefined;
    const pz = zfmt.bufPrintZ(&pb, "{s}", .{path}) catch return;
    _ = c.unlink(@ptrCast(pz.ptr));
}

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, sentence: []const u8) anyerror!void,
};

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

pub fn askStream(allocator: std.mem.Allocator, client_id: u8, query: []const u8, client_prompt: ?[]const u8, sink: Sink) ![]u8 {
    const key_c = c.getenv(@ptrCast("GROQ_API_KEY")) orelse return error.NoApiKey;
    const key = std.mem.span(@as([*:0]const u8, @ptrCast(key_c)));
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

    var req_path_b: [64]u8 = undefined;
    var cfg_path_b: [64]u8 = undefined;
    const req_path = try std.fmt.bufPrint(&req_path_b, "/tmp/folserver_{d}.json", .{client_id});
    const cfg_path = try std.fmt.bufPrint(&cfg_path_b, "/tmp/folserver_{d}.cfg", .{client_id});
    defer unlinkPath(req_path);
    defer unlinkPath(cfg_path);

    try writeFile(req_path, body.items);

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(allocator);
    const head = try std.fmt.allocPrint(allocator,
        "silent\nno-buffer\nmax-time = 60\nurl = \"https://api.groq.com/openai/v1/chat/completions\"\n" ++
            "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\n" ++
            "data-binary = \"@{s}\"\n",
        .{ key, req_path },
    );
    defer allocator.free(head);
    try cfg.appendSlice(allocator, head);
    if (proxy) |p| {
        if (std.mem.indexOfAny(u8, p, "\"\\\r\n") == null) {
            const line = try std.fmt.allocPrint(allocator, "proxy = \"{s}\"\n", .{p});
            defer allocator.free(line);
            try cfg.appendSlice(allocator, line);
        }
    }
    try writeFile(cfg_path, cfg.items);

    var cmd_b: [160]u8 = undefined;
    const cmd = try zfmt.bufPrintZ(&cmd_b, "curl -K {s}", .{cfg_path});
    const pipe = c.popen(@ptrCast(cmd.ptr), @ptrCast("r")) orelse return error.CurlFailed;

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

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
        try flushChunks(allocator, &pending, sink);
    }
    _ = c.pclose(pipe);

    if (pending.items.len > 0) try emitPart(allocator, pending.items, sink);
    if (full.items.len == 0) return error.EmptyReply;

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
