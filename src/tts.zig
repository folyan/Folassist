const std = @import("std");
const c = @import("c");

const SynthPtr = blk: {
    const Ret = @typeInfo(@TypeOf(c.piper_create)).@"fn".return_type.?;
    break :blk switch (@typeInfo(Ret)) {
        .optional => |o| o.child,
        else => Ret,
    };
};
const ChunkPtr = @typeInfo(@TypeOf(c.piper_synthesize_next)).@"fn".param_types[1].?;
const Chunk = @typeInfo(ChunkPtr).pointer.child;

pub const CACHE_DIR = "cache/tts";

pub const Tts = struct {
    synth: SynthPtr,
    allocator: std.mem.Allocator,
    device: [:0]u8,
    busy: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        model_path: []const u8,
        espeak_data_path: []const u8,
        device: []const u8,
    ) !Tts {
        const model_z = try allocator.dupeSentinel(u8, model_path, 0);
        defer allocator.free(model_z);

        const espeak_z = try allocator.dupeSentinel(u8, espeak_data_path, 0);
        defer allocator.free(espeak_z);
        const synth = c.piper_create(model_z.ptr, null, espeak_z.ptr) orelse return error.TtsModelLoadError;
        const dev = try allocator.dupeSentinel(u8, device, 0);   
        return .{
            .synth = synth,
            .allocator = allocator,
            .device = dev,
        };
    }

    pub fn deinit(self: *Tts) void {
        c.piper_free(self.synth);
        self.allocator.free(self.device);
    }

    fn streamFileToAlsa(self: *Tts, file_path: [*:0]const u8) !void {
        const f = c.fopen(file_path, "rb") orelse return error.FileNotFound;
        defer _ = c.fclose(f);

        var sample_rate: u32 = 22050;
        if (c.fread(&sample_rate, 1, @sizeOf(u32), f) != @sizeOf(u32)) return error.ReadError;

        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, self.device.ptr, c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.AudioDeviceError;
        defer {
            _ = c.snd_pcm_drain(pcm.?);
            _ = c.snd_pcm_close(pcm.?);
        }

        if (c.snd_pcm_set_params(pcm.?, c.SND_PCM_FORMAT_S16_LE, c.SND_PCM_ACCESS_RW_INTERLEAVED, 1, @intCast(sample_rate), 1, 500_000) < 0)
            return error.AudioDeviceError;

        var buf: [2048]i16 = undefined;
        while (true) {
            const n = c.fread(&buf, @sizeOf(i16), buf.len, f);
            if (n == 0) break;
            var done: usize = 0;
            while (done < n) {
                const r = c.snd_pcm_writei(pcm.?, &buf[done], @intCast(n - done));
                if (r < 0) {
                    if (c.snd_pcm_recover(pcm.?, @intCast(r), 1) < 0) return error.AudioDeviceError;
                    continue;
                }
                done += @intCast(r);
            }
        }
    }

    fn synthesizeToFile(self: *Tts, text: []const u8, file_path: [*:0]const u8) !void {
        const text_z = try self.allocator.dupeSentinel(u8, text, 0);
        defer self.allocator.free(text_z);

        var opts = c.piper_default_synthesize_options(self.synth);
        if (c.piper_synthesize_start(self.synth, text_z.ptr, &opts) != c.PIPER_OK) return error.TtsSynthesisFailed;

        _ = c.mkdir("cache", 0o755);
        _ = c.mkdir(CACHE_DIR, 0o755);

        const f = c.fopen(file_path, "wb") orelse return error.FileCreateError;
        defer _ = c.fclose(f);

        var sample_rate: u32 = 22050;
        var rate_written = false;

        while (true) {
            var chunk: Chunk = std.mem.zeroes(Chunk);
            const rc = c.piper_synthesize_next(self.synth, &chunk);
            if (rc < 0) return error.TtsSynthesisFailed;

            const n: usize = @intCast(chunk.num_samples);
            if (n > 0) {
                if (!rate_written) {
                    sample_rate = @intCast(chunk.sample_rate);
                    _ = c.fwrite(&sample_rate, 1, @sizeOf(u32), f);
                    rate_written = true;
                }
                for (0..n) |i| {
                    const s = std.math.clamp(chunk.samples[i], -1.0, 1.0);
                    const sample_val: i16 = @intFromFloat(s * 32767.0);
                    _ = c.fwrite(&sample_val, @sizeOf(i16), 1, f);
                }
            }
            if (rc == c.PIPER_DONE) break;
        }
    }

    pub fn precompilePhrase(self: *Tts, phrase: []const u8) !void {
        const hash = std.hash.Wyhash.hash(0, phrase);
        var path_buf: [256]u8 = undefined;
        const path_slice = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], CACHE_DIR ++ "/{x}.raw", .{hash}) catch return;
        path_buf[path_slice.len] = 0;
        const path_z: [:0]const u8 = path_buf[0..path_slice.len :0];

        if (c.fopen(path_z.ptr, "rb")) |f| {
            _ = c.fclose(f);
            return;
        }

        try self.synthesizeToFile(phrase, path_z.ptr);
    }

    pub fn speakCached(self: *Tts, phrase: []const u8) !void {
        while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
        defer self.busy.store(false, .release);

        const hash = std.hash.Wyhash.hash(0, phrase);
        var path_buf: [256]u8 = undefined;
        const path_slice = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], CACHE_DIR ++ "/{x}.raw", .{hash}) catch return;
        path_buf[path_slice.len] = 0;
        const path_z: [:0]const u8 = path_buf[0..path_slice.len :0];

        if (c.fopen(path_z.ptr, "rb")) |f| {
            _ = c.fclose(f);
        } else {
            try self.synthesizeToFile(phrase, path_z.ptr);
        }

        try self.streamFileToAlsa(path_z.ptr);
    }

    pub fn speak(self: *Tts, text: []const u8) !void {
        while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
        defer self.busy.store(false, .release);

        const tmp_path: [*:0]const u8 = CACHE_DIR ++ "/_dyn_speak.raw";
        try self.synthesizeToFile(text, tmp_path);
        try self.streamFileToAlsa(tmp_path);
        _ = c.unlink(tmp_path);
    }
};
