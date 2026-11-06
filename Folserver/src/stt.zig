const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");
const ai = @import("ai.zig");

const alloc = std.heap.c_allocator;
const URL = "https://api.groq.com/openai/v1/audio/transcriptions";
const MODEL = "whisper-large-v3-turbo";
const RATE: u32 = 16000;
pub const MAX_KEYS = 5;

var keys: [MAX_KEYS][]const u8 = undefined;
var key_count: usize = 0;
var key_idx: usize = 0;
var seq: u32 = 0;

pub fn addKey(k: []const u8) bool {
    if (k.len == 0 or key_count >= MAX_KEYS) return false;
    keys[key_count] = k;
    key_count += 1;
    return true;
}

pub fn similarity(a: []const u8, b: []const u8) u32 {
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
    const dist: usize = buf[alen * max_size + blen];
    const max_len = @max(alen, blen);
    if (max_len == 0) return 100;
    return @intCast(((max_len - dist) * 100) / max_len);
}

pub fn stripWake(text: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, text, ' ') orelse return text;
    if (similarity(text[0..sp], "фокус") >= 60) return std.mem.trim(u8, text[sp..], " ");
    return text;
}

fn buildWav(pcm: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, 44 + pcm.len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(36 + pcm.len), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], 1, .little);
    std.mem.writeInt(u32, out[24..28], RATE, .little);
    std.mem.writeInt(u32, out[28..32], RATE * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(pcm.len), .little);
    @memcpy(out[44..], pcm);
    return out;
}

fn writeFile(path: [:0]const u8, data: []const u8) !void {
    const f = c.fopen(@ptrCast(path.ptr), @ptrCast("wb")) orelse return error.WriteFailed;
    defer _ = c.fclose(f);
    if (c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}

fn parseText(path: []const u8) ![]u8 {
    const data = try zfmt.readFile(c, alloc, path);
    defer alloc.free(data);
    const Resp = struct { text: []const u8 = "" };
    const parsed = try std.json.parseFromSlice(Resp, alloc, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return alloc.dupe(u8, parsed.value.text);
}

fn runOnce(key: []const u8, wav_path: [:0]const u8, out_path: [:0]const u8) !bool {
    const auth = try std.fmt.allocPrintSentinel(alloc, "Authorization: Bearer {s}", .{key}, 0);
    defer alloc.free(auth);
    const file_arg = try std.fmt.allocPrintSentinel(alloc, "file=@{s}", .{wav_path}, 0);
    defer alloc.free(file_arg);
    const proxy_z: ?[:0]u8 = if (ai.getProxy()) |p| try alloc.dupeSentinel(u8, p, 0) else null;
    defer if (proxy_z) |pz| alloc.free(pz);

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(alloc);
    const fixed = [_][*:0]const u8{
        "curl", "-sS", "-m", "60", "-o", out_path.ptr, "-w", "%{http_code}",
        "-H", auth.ptr, "-F", "model=" ++ MODEL, "-F", "language=ru",
        "-F", "response_format=json", "-F", file_arg.ptr, URL,
    };
    for (fixed) |a| try argv.append(alloc, a);
    if (proxy_z) |pz| {
        try argv.append(alloc, "--proxy");
        try argv.append(alloc, pz.ptr);
    }
    try argv.append(alloc, null);

    var p: [2]c_int = undefined;
    if (c.pipe(&p) != 0) return error.CurlFailed;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(p[0]);
        _ = c.close(p[1]);
        return error.CurlFailed;
    }
    if (pid == 0) {
        _ = c.dup2(p[1], 1);
        _ = c.close(p[0]);
        _ = c.close(p[1]);
        _ = c.execvp("curl", @ptrCast(argv.items.ptr));
        c._exit(127);
    }
    _ = c.close(p[1]);
    var code_buf: [8]u8 = undefined;
    var n: usize = 0;
    while (n < code_buf.len) {
        const r = c.read(p[0], code_buf[n..].ptr, code_buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    _ = c.close(p[0]);
    _ = c.waitpid(pid, null, 0);
    const code = code_buf[0..n];
    if (std.mem.eql(u8, code, "200")) return true;
    std.debug.print("[stt] ключ не сработал, код {s}\n", .{code});
    return false;
}

fn ensureKeys() void {
    if (key_count == 0) {
        if (c.getenv(@ptrCast("GROQ_API_KEY"))) |e| {
            _ = addKey(std.mem.span(@as([*:0]const u8, @ptrCast(e))));
        }
    }
}

pub fn orderedKeys(out: *[MAX_KEYS][]const u8) usize {
    ensureKeys();
    var i: usize = 0;
    while (i < key_count) : (i += 1) out[i] = keys[(key_idx + i) % key_count];
    return key_count;
}

pub fn transcribe(pcm: []const u8) ![]u8 {
    ensureKeys();
    if (key_count == 0) return error.NoKey;
    if (pcm.len < RATE / 2 * 2) return alloc.dupe(u8, "");

    seq +%= 1;
    const wav = try buildWav(pcm);
    defer alloc.free(wav);
    const wav_path = try std.fmt.allocPrintSentinel(alloc, "/dev/shm/folstt_{d}.wav", .{seq}, 0);
    defer alloc.free(wav_path);
    const out_path = try std.fmt.allocPrintSentinel(alloc, "/dev/shm/folstt_{d}.json", .{seq}, 0);
    defer alloc.free(out_path);
    try writeFile(wav_path, wav);
    defer _ = c.remove(wav_path.ptr);
    defer _ = c.remove(out_path.ptr);

    var attempt: usize = 0;
    while (attempt < key_count) : (attempt += 1) {
        const idx = (key_idx + attempt) % key_count;
        if (try runOnce(keys[idx], wav_path, out_path)) {
            key_idx = idx;
            return parseText(out_path);
        }
    }
    return error.AllKeysFailed;
}
