const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");
const tts_mod = @import("tts.zig");

const alloc = std.heap.c_allocator;

pub const Entry = struct {
    text: []u8,
    rate: u32,
    pcm: []u8,
};

const Audio = struct {
    rate: u32,
    pcm: []u8,
};

pub var dir: []const u8 = "cache";
pub var entries: std.ArrayList(Entry) = .empty;

fn fnv(text: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

pub fn find(text: []const u8) ?*const Entry {
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.text, text)) return e;
    }
    return null;
}

fn fromFile(path: []const u8) ?Audio {
    const data = zfmt.readFile(c, alloc, path) catch return null;
    defer alloc.free(data);
    if (data.len < 4) return null;
    const rate = std.mem.readInt(u32, data[0..4], .little);
    const pcm = alloc.dupe(u8, data[4..]) catch return null;
    return .{ .rate = rate, .pcm = pcm };
}

fn synth(tts: *tts_mod.Tts, text: []const u8) ?Audio {
    const a = tts.synthesizeToMemory(text) catch return null;
    defer alloc.free(a.samples);
    const pcm = alloc.dupe(u8, std.mem.sliceAsBytes(a.samples)) catch return null;
    return .{ .rate = a.sample_rate, .pcm = pcm };
}

fn writeCacheFile(path: []const u8, audio: Audio) void {
    const pz = alloc.dupeSentinel(u8, path, 0) catch return;
    defer alloc.free(pz);
    const f = c.fopen(@ptrCast(pz.ptr), @ptrCast("wb")) orelse return;
    defer _ = c.fclose(f);
    var rb: [4]u8 = undefined;
    std.mem.writeInt(u32, &rb, audio.rate, .little);
    _ = c.fwrite(&rb, 1, rb.len, f);
    _ = c.fwrite(audio.pcm.ptr, 1, audio.pcm.len, f);
}

fn ensureDir() void {
    const pz = alloc.dupeSentinel(u8, dir, 0) catch return;
    defer alloc.free(pz);
    _ = c.mkdir(@ptrCast(pz.ptr), 0o755);
}

pub fn load(tts: *tts_mod.Tts, phrases: []const []const u8) void {
    ensureDir();
    for (phrases) |text| {
        if (text.len == 0 or find(text) != null) continue;

        const path = alloc.print("{s}/{x:0>16}.pcm", .{ dir, fnv(text) }) catch continue;
        defer alloc.free(path);

        var audio: ?Audio = fromFile(path);
        if (audio == null) {
            audio = synth(tts, text);
            if (audio) |a| writeCacheFile(path, a);
        }
        const a = audio orelse continue;

        const owned = alloc.dupe(u8, text) catch {
            alloc.free(a.pcm);
            continue;
        };
        entries.append(alloc, .{ .text = owned, .rate = a.rate, .pcm = a.pcm }) catch {
            alloc.free(owned);
            alloc.free(a.pcm);
            continue;
        };
    }
}
