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

pub const CachedAudio = struct {
    samples: []i16,
    sample_rate: u32,
};

pub const Tts = struct {
    synth: SynthPtr,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, model_path: []const u8, espeak_data_path: []const u8) !Tts {
        const model_z = try allocator.dupeSentinel(u8, model_path, 0);
        defer allocator.free(model_z);
        const espeak_z = try allocator.dupeSentinel(u8, espeak_data_path, 0);
        defer allocator.free(espeak_z);

        const synth = c.piper_create(@ptrCast(model_z.ptr), null, @ptrCast(espeak_z.ptr)) orelse return error.TtsModelLoadError;
        return .{ .synth = synth, .allocator = allocator };
    }

    pub fn deinit(self: *Tts) void {
        c.piper_free(self.synth);
    }

    pub fn synthesizeToMemory(self: *Tts, text: []const u8) !CachedAudio {
        const text_z = try self.allocator.dupeSentinel(u8, text, 0);
        defer self.allocator.free(text_z);

        var opts = c.piper_default_synthesize_options(self.synth);
        if (c.piper_synthesize_start(self.synth, @ptrCast(text_z.ptr), &opts) != c.PIPER_OK) return error.TtsFailed;

        var samples: std.ArrayList(i16) = .empty;
        errdefer samples.deinit(self.allocator);
        var rate: u32 = 22050;

        while (true) {
            var chunk: Chunk = std.mem.zeroes(Chunk);
            const rc = c.piper_synthesize_next(self.synth, &chunk);
            if (rc < 0) return error.TtsFailed;

            const n: usize = @intCast(chunk.num_samples);
            if (n > 0) {
                rate = @intCast(chunk.sample_rate);
                const prev = samples.items.len;
                try samples.resize(self.allocator, prev + n);
                for (0..n) |i| {
                    const s = std.math.clamp(chunk.samples[i], -1.0, 1.0);
                    samples.items[prev + i] = @intFromFloat(s * 32767.0);
                }
            }
            if (rc == c.PIPER_DONE) break;
        }

        return .{ .samples = try samples.toOwnedSlice(self.allocator), .sample_rate = rate };
    }
};
