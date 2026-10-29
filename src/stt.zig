




const std = @import("std");
const c = @import("c");




fn sleepMs(ms: anytype) void {
    const v: u64 = @intCast(ms);
    _ = c.usleep(@intCast(v * 1000));
}


fn nowSeconds() i64 {
    return @intCast(c.time(null));
}


const Mutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *Mutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Mutex) void {
        self.locked.store(false, .release);
    }
};


pub const Error = error{

    InitializationFailed,

    AudioDeviceError,

    ModelLoadError,

    CallbackError,

    OutOfMemory,

    InvalidParameter,

    InvalidState,

    ThreadingError,

    AudioDeviceBusy,

    AudioDeviceNotFound,

    AudioDeviceUnsupported,

    ModelCorrupted,

    ModelNotFound,

    PermissionDenied,

    SystemResourcesExhausted,

    Timeout,

    InternalError,

    SetAccessError,
    SetFormatError,
    SetChannelError,
    SetSampleRateError,
    SetBufferSizeError,
    SetPeriodSizeError,
    ApplyParametersError,
    PcmPrepareError,
};


pub const ErrorInfo = struct {

    error_code: Error,

    message: []const u8,

    system_error: ?i32 = null,

    context: ?[]const u8 = null,

    timestamp: i64,

    recoverable: bool = false,

    recovery_suggestion: ?[]const u8 = null,


    pub fn init(error_code: Error, message: []const u8) ErrorInfo {
        return ErrorInfo{
            .error_code = error_code,
            .message = message,
            .timestamp = nowSeconds(),
        };
    }


    pub fn initWithContext(error_code: Error, message: []const u8, context: []const u8) ErrorInfo {
        return ErrorInfo{
            .error_code = error_code,
            .message = message,
            .context = context,
            .timestamp = nowSeconds(),
        };
    }


    pub fn initRecoverable(error_code: Error, message: []const u8, suggestion: []const u8) ErrorInfo {
        return ErrorInfo{
            .error_code = error_code,
            .message = message,
            .timestamp = nowSeconds(),
            .recoverable = true,
            .recovery_suggestion = suggestion,
        };
    }
};


pub const SpeechEvent = struct {

    text: []const u8,

    max_amplitude: u16 = std.math.maxInt(u16),

    min_amplitude: u16 = 0,

    audio_data: []const i16 = &[_]i16{},
};






pub const SpeechCallback = *const fn (event: SpeechEvent, user_data: ?*anyopaque) void;







pub const ErrorCallback = *const fn (error_code: Error, message: [*:0]const u8, user_data: ?*anyopaque) void;






pub const DetailedErrorCallback = *const fn (error_info: ErrorInfo, user_data: ?*anyopaque) void;





pub const SpeechEventHandler = struct {

    onSpeechFn: *const fn (ctx: *anyopaque, event: SpeechEvent) void,

    onErrorFn: *const fn (ctx: *anyopaque, error_code: Error, message: []const u8) void,

    onDetailedErrorFn: ?*const fn (ctx: *anyopaque, error_info: ErrorInfo) void = null,

    ctx: *anyopaque,


    pub fn onSpeech(self: SpeechEventHandler, event: SpeechEvent) void {



        self.onSpeechFn(self.ctx, event);
    }


    pub fn onError(self: SpeechEventHandler, error_code: Error, message: []const u8) void {
        self.onErrorFn(self.ctx, error_code, message);
    }


    pub fn onDetailedError(self: SpeechEventHandler, error_info: ErrorInfo) void {
        if (self.onDetailedErrorFn) |detailed_fn| {
            detailed_fn(self.ctx, error_info);
        } else {

            self.onError(error_info.error_code, error_info.message);
        }
    }


    fn reportError(self: SpeechEventHandler, error_code: Error, error_info: ErrorInfo) void {
        if (self.onDetailedErrorFn) |detailed_fn| {
            detailed_fn(self.ctx, error_info);
        } else {
            self.onError(error_code, error_info.message);
        }
    }
};


fn resample(input_samples: []const i16, output_samples: []i16, input_rate: u32, output_rate: u32) usize {
    if (input_rate == output_rate) {
        const copy_len = @min(input_samples.len, output_samples.len);
        @memcpy(output_samples[0..copy_len], input_samples[0..copy_len]);
        return copy_len;
    }

    const ratio = @as(f64, @floatFromInt(input_rate)) / @as(f64, @floatFromInt(output_rate));
    const output_len = @min(output_samples.len, @as(usize, @intFromFloat(@as(f64, @floatFromInt(input_samples.len)) / ratio)));

    for (0..output_len) |i| {
        const src_pos = @as(f64, @floatFromInt(i)) * ratio;
        const src_idx: usize = @intFromFloat(src_pos);

        if (src_idx >= input_samples.len) break;

        if (src_idx + 1 < input_samples.len) {
            const frac = src_pos - @as(f64, @floatFromInt(src_idx));
            const sample1: f64 = @floatFromInt(input_samples[src_idx]);
            const sample2: f64 = @floatFromInt(input_samples[src_idx + 1]);
            const interpolated = sample1 + (sample2 - sample1) * frac;
            output_samples[i] = @intFromFloat(@max(@min(interpolated, std.math.maxInt(i16)), std.math.minInt(i16)));
        } else {
            output_samples[i] = input_samples[src_idx];
        }
    }

    return output_len;
}


fn getCpuPerformance() !u32 {
    const file = c.fopen("/proc/cpuinfo", "r") orelse return error.PerformanceNotFound;
    defer _ = c.fclose(file);

    var buf: [4096]u8 = undefined;
    const bytes_read: usize = c.fread(&buf, 1, buf.len, file);

    var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "BogoMIPS")) {
            var parts = std.mem.splitScalar(u8, line, ':');
            _ = parts.next();
            if (parts.next()) |value| {
                const trimmed = std.mem.trim(u8, value, " \t");
                return @intFromFloat(try std.fmt.parseFloat(f32, trimmed));
            }
        }
        if (std.mem.startsWith(u8, line, "cpu MHz")) {
            var parts = std.mem.splitScalar(u8, line, ':');
            _ = parts.next();
            if (parts.next()) |value| {
                const trimmed = std.mem.trim(u8, value, " \t");

                const mhz = try std.fmt.parseFloat(f32, trimmed);
                return @intFromFloat(mhz / 20.0);
            }
        }
    }
    return error.PerformanceNotFound;
}


pub const AudioBuffer = struct {
    const Self = @This();


    buffer: []i16,

    read_pos: usize = 0,

    write_pos: usize = 0,

    count: usize = 0,

    mutex: Mutex = .{},

    allocator: std.mem.Allocator,


    pub fn init(allocator: std.mem.Allocator, buffer_capacity: usize) !Self {
        const buffer = try allocator.alloc(i16, buffer_capacity);
        return Self{
            .buffer = buffer,
            .allocator = allocator,
        };
    }


    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }


    pub fn write(self: *Self, samples: []const i16) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const available_space = self.buffer.len - self.count;
        const to_write = @min(samples.len, available_space);

        for (0..to_write) |i| {
            self.buffer[self.write_pos] = samples[i];
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
        }

        self.count += to_write;
        return to_write;
    }


    pub fn read(self: *Self, samples: []i16) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const to_read = @min(samples.len, self.count);

        for (0..to_read) |i| {
            samples[i] = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buffer.len;
        }

        self.count -= to_read;
        return to_read;
    }


    pub fn available(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }


    pub fn capacity(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.len - self.count;
    }


    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_pos = 0;
        self.write_pos = 0;
        self.count = 0;
    }
};


pub const AudioConverter = struct {

    pub fn stereoToMono(stereo_samples: []const i16, mono_samples: []i16) usize {
        const frames = @min(stereo_samples.len / 2, mono_samples.len);

        for (0..frames) |i| {
            const left = stereo_samples[i * 2];
            const right = stereo_samples[i * 2 + 1];

            const avg: i32 = @divTrunc(@as(i32, left) + @as(i32, right), 2);
            mono_samples[i] = @intCast(@max(@min(avg, std.math.maxInt(i16)), std.math.minInt(i16)));
        }

        return frames;
    }
};


pub const AlsaCapture = struct {
    const Self = @This();


    pcm_handle: ?*c.snd_pcm_t = null,

    device_name: []const u8,

    sample_rate: u32,

    channels: u32,

    buffer_size: u32,

    period_size: u32,

    audio_buffer: AudioBuffer,

    allocator: std.mem.Allocator,


    pub fn init(allocator: std.mem.Allocator, device_name: []const u8, sample_rate: u32, buffer_size: u32) !Self {

        const period_size = buffer_size / 4;


        const audio_buffer = try AudioBuffer.init(allocator, buffer_size * 4);

        return Self{
            .device_name = device_name,
            .sample_rate = sample_rate,
            .buffer_size = buffer_size,
            .period_size = period_size,
            .audio_buffer = audio_buffer,

            .channels = undefined,
            .allocator = allocator,
        };
    }


    pub fn deinit(self: *Self) void {
        self.close();
        self.audio_buffer.deinit();
    }


    pub fn open(self: *Self) !void {

        const device_cstr = self.allocator.dupeSentinel(u8, self.device_name, 0) catch {
            return Error.OutOfMemory;
        };
        defer self.allocator.free(device_cstr);


        var err = c.snd_pcm_open(&self.pcm_handle, device_cstr.ptr, c.SND_PCM_STREAM_CAPTURE, 0);
        if (err < 0) {
            return switch (err) {
                -c.ENOENT => Error.AudioDeviceNotFound,
                -c.EBUSY => Error.AudioDeviceBusy,
                -c.EACCES => Error.PermissionDenied,
                -c.ENOMEM => Error.OutOfMemory,
                -c.EMFILE, -c.ENFILE => Error.SystemResourcesExhausted,
                else => Error.AudioDeviceError,
            };
        }


        var hw_params: ?*c.snd_pcm_hw_params_t = null;
        err = c.snd_pcm_hw_params_malloc(@ptrCast(&hw_params));
        errdefer self.close();
        if (err < 0) return Error.AudioDeviceError;
        defer c.snd_pcm_hw_params_free(hw_params);


        err = c.snd_pcm_hw_params_any(self.pcm_handle, hw_params);
        if (err < 0) return Error.AudioDeviceError;


        err = c.snd_pcm_hw_params_set_access(self.pcm_handle, hw_params, c.SND_PCM_ACCESS_RW_INTERLEAVED);
        if (err < 0) return Error.SetAccessError;


        err = c.snd_pcm_hw_params_set_format(self.pcm_handle, hw_params, c.SND_PCM_FORMAT_S16_LE);
        if (err < 0) return Error.SetFormatError;


        var min: c_uint = undefined;
        err = c.snd_pcm_hw_params_get_channels_min(hw_params, &min);
        if (err < 0) return Error.SetChannelError;

        self.channels = min;


        err = c.snd_pcm_hw_params_set_channels(self.pcm_handle, hw_params, self.channels);
        if (err < 0) {
            std.log.err("error setting number of channels. Must be at least {d}", .{min});
            return Error.SetChannelError;
        }


        var actual_rate = self.sample_rate;
        err = c.snd_pcm_hw_params_set_rate_near(self.pcm_handle, hw_params, &actual_rate, null);
        if (err < 0) return Error.SetSampleRateError;


        if (actual_rate != self.sample_rate) {
            std.log.info("Hardware doesn't support {}Hz, using {}Hz", .{ self.sample_rate, actual_rate });
            self.sample_rate = actual_rate;
        }



        var min_buffer: c.snd_pcm_uframes_t = undefined;

        var max_buffer: c.snd_pcm_uframes_t = undefined;
        _ = c.snd_pcm_hw_params_get_buffer_size_min(hw_params, &min_buffer);
        _ = c.snd_pcm_hw_params_get_buffer_size_max(hw_params, &max_buffer);


        const calculated_min: u32 = @intCast((self.sample_rate * 40) / 1000);
        const target_buffer = @max(self.buffer_size, calculated_min);
        if (target_buffer < min_buffer) {
            std.log.info("Buffer size {} too small, using minimum {}", .{ target_buffer, min_buffer });
            self.buffer_size = @intCast(min_buffer);
        } else if (target_buffer > max_buffer) {
            std.log.info("Buffer size {} too large, using maximum {}", .{ target_buffer, max_buffer });
            self.buffer_size = @intCast(max_buffer);
        } else {
            self.buffer_size = @intCast(target_buffer);
        }


        var actual_buffer_size: c.snd_pcm_uframes_t = self.buffer_size;
        err = c.snd_pcm_hw_params_set_buffer_size_near(self.pcm_handle, hw_params, &actual_buffer_size);
        if (err < 0) return Error.SetBufferSizeError;
        self.buffer_size = @intCast(actual_buffer_size);



        var period_time: c_uint = std.time.us_per_ms * 10;
        var dir: c_int = 0;
        err = c.snd_pcm_hw_params_set_period_time_near(self.pcm_handle, hw_params, &period_time, &dir);
        if (err < 0) return Error.SetPeriodSizeError;



        var actual_period_size: c.snd_pcm_uframes_t = undefined;
        err = c.snd_pcm_hw_params_get_period_size(hw_params, &actual_period_size, null);
        if (err >= 0) {
            self.period_size = @intCast(actual_period_size);
        }

        std.log.debug("ALSA params: rate={}, channels={}, buffer={}, period={}", .{ self.sample_rate, self.channels, actual_buffer_size, self.period_size });


        err = c.snd_pcm_hw_params(self.pcm_handle, hw_params);
        if (err < 0) {
            std.log.err("snd_pcm_hw_params failed with error code: {}", .{err});
            return Error.ApplyParametersError;
        }


        err = c.snd_pcm_prepare(self.pcm_handle);
        if (err < 0) return Error.PcmPrepareError;
    }


    pub fn close(self: *Self) void {
        if (self.pcm_handle) |handle| {
            _ = c.snd_pcm_close(handle);
            self.pcm_handle = null;
        }
    }


    pub fn readAudio(self: *Self) !usize {
        if (self.pcm_handle == null)
            return Error.AudioDeviceError;


        const temp_buffer = try self.allocator.alloc(i16, self.period_size * self.channels);
        defer self.allocator.free(temp_buffer);


        const frames_read = c.snd_pcm_readi(self.pcm_handle, temp_buffer.ptr, self.period_size);

        if (frames_read < 0) {

            if (frames_read == -c.EPIPE) {

                const err = c.snd_pcm_prepare(self.pcm_handle);
                if (err < 0) return Error.AudioDeviceError;
                return 0;
            } else return Error.AudioDeviceError;
        }

        const samples_read = @as(usize, @intCast(frames_read)) * self.channels;


        if (self.channels == 1) {

            _ = self.audio_buffer.write(temp_buffer[0..samples_read]);
        } else if (self.channels == 2) {

            const mono_buffer = try self.allocator.alloc(i16, @as(usize, @intCast(frames_read)));
            defer self.allocator.free(mono_buffer);

            const mono_samples = AudioConverter.stereoToMono(temp_buffer[0..samples_read], mono_buffer);
            _ = self.audio_buffer.write(mono_buffer[0..mono_samples]);
        } else {

            const mono_buffer = try self.allocator.alloc(i16, @as(usize, @intCast(frames_read)));
            defer self.allocator.free(mono_buffer);

            for (0..@as(usize, @intCast(frames_read))) |i| {
                mono_buffer[i] = temp_buffer[i * self.channels];
            }
            _ = self.audio_buffer.write(mono_buffer);
        }

        return @intCast(frames_read);
    }


    pub fn getAudioSamples(self: *Self, output_buffer: []i16) usize {
        return self.audio_buffer.read(output_buffer);
    }


    pub fn availableSamples(self: *Self) usize {
        return self.audio_buffer.available();
    }
};





pub const AudioSink = struct {
    ctx: *anyopaque,
    feedFn: *const fn (ctx: *anyopaque, samples: []const i16) void,
};

pub const Options = struct {
    pipe_path: ?[]const u8 = null,

    model_path: []const u8,

    audio_device: []const u8,

    event_handler: SpeechEventHandler,

    sample_rate: u32 = 16000,





    buffer_size: u32 = 256,

    silence_threshold: i16 = 300,

    audio_sink: ?AudioSink = null,
};





pub const Session = struct {
    const Self = @This();


    allocator: std.mem.Allocator,

    options: Options,

    initialized: bool = false,

    listening: bool = false,

    alsa_capture: ?AlsaCapture = null,

    audio_thread: ?std.Thread = null,

    processing_thread: ?std.Thread = null,

    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    processing_buffer: []i16,

    resample_buffer: ?[]i16,

    vosk_model: ?*c.VoskModel = null,

    vosk_recognizer: ?*c.VoskRecognizer = null,

    vosk_audio_buffer: AudioBuffer,










    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Session {

        validateOptions(options) catch |err| {
            const error_info = switch (err) {
                Error.InvalidParameter => ErrorInfo.initWithContext(err, "Invalid initialization parameters provided", "Check model path, audio device, sample rate, and other parameters"),
                else => ErrorInfo.init(err, "Parameter validation failed"),
            };
            options.event_handler.onDetailedError(error_info);
            return err;
        };


        const processing_buffer = allocator.alloc(i16, options.sample_rate) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate processing buffer during initialization");
            options.event_handler.onDetailedError(error_info);
            return Error.OutOfMemory;
        };
        errdefer allocator.free(processing_buffer);


        const alsa_capture = AlsaCapture.init(
            allocator,
            options.audio_device,
            options.sample_rate,
            options.buffer_size,
        ) catch |err| {
            const error_info = switch (err) {
                error.OutOfMemory => ErrorInfo.init(Error.OutOfMemory, "Out of memory while initializing audio capture"),
            };
            options.event_handler.onDetailedError(error_info);
            return Error.OutOfMemory;
        };
        errdefer {
            var alsa_capture_mut = alsa_capture;
            alsa_capture_mut.deinit();
        }

        const cpu_perf = getCpuPerformance() catch 100;
        const buffer_multiplier: u32 = if (cpu_perf < 50) 8 else if (cpu_perf < 100) 4 else 2;
        const new_buffer_size = 16000 * 10;

        std.log.debug(
            "Buffer multiplier {d} based on implied BogoMIPS of {d} (100 default in case of error)",
            .{ buffer_multiplier, cpu_perf },
        );


        const vosk_buf = AudioBuffer.init(
            allocator,
            new_buffer_size,
        ) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to initialize Vosk buffer after ALSA open");
            options.event_handler.onDetailedError(error_info);
            return error.InitializationFailed;
        };
        var session = Session{
            .allocator = allocator,
            .options = options,
            .alsa_capture = alsa_capture,
            .processing_buffer = processing_buffer,
            .resample_buffer = null,
            .vosk_audio_buffer = vosk_buf,
        };


        session.initVosk() catch |err| {
            const error_info = switch (err) {
                Error.ModelLoadError => ErrorInfo.initWithContext(err, "Failed to load Vosk speech recognition model", options.model_path),
                Error.OutOfMemory => ErrorInfo.init(err, "Out of memory while loading Vosk model"),
                else => ErrorInfo.initWithContext(Error.InitializationFailed, "Unexpected error during Vosk initialization", options.model_path),
            };
            options.event_handler.onDetailedError(error_info);
            session.deinitPartial();
            return err;
        };

        session.initialized = true;


        const success_info = ErrorInfo.initRecoverable(Error.InternalError, "STT library initialized successfully", "Ready to start speech recognition");
        options.event_handler.onDetailedError(success_info);

        return session;
    }


    fn initVosk(self: *Session) !void {

        const model_path_cstr = try self.allocator.dupeSentinel(u8, self.options.model_path, 0);
        defer self.allocator.free(model_path_cstr);


        if (@import("builtin").mode != .debug) {
            c.vosk_set_log_level(-1);
        }


        self.vosk_model = c.vosk_model_new(model_path_cstr.ptr);
        if (self.vosk_model == null) {
            return Error.ModelLoadError;
        }


        self.vosk_recognizer = c.vosk_recognizer_new(self.vosk_model, 16000.0);
        if (self.vosk_recognizer == null) {
            if (self.vosk_model) |model| {
                c.vosk_model_free(model);
                self.vosk_model = null;
            }
            return Error.ModelLoadError;
        }
    }


    fn deinitPartial(self: *Session) void {

        if (self.vosk_recognizer) |recognizer| {
            c.vosk_recognizer_free(recognizer);
            self.vosk_recognizer = null;
        }
        if (self.vosk_model) |model| {
            c.vosk_model_free(model);
            self.vosk_model = null;
        }


        self.vosk_audio_buffer.deinit();


        if (self.alsa_capture) |*capture| {
            capture.deinit();
            self.alsa_capture = null;
        }


        self.allocator.free(self.processing_buffer);
    }





    fn audioThreadFn(self: *Session) void {
        if (self.options.pipe_path) |pipe_path| {
            const path_z = self.allocator.dupeSentinel(u8, pipe_path, 0) catch return;
            defer self.allocator.free(path_z);


            const fd = c.open(path_z.ptr, c.O_RDONLY | c.O_NONBLOCK);
            if (fd < 0) {
                std.log.err("Cannot open audio pipe '{s}'", .{pipe_path});
                return;
            }
            defer _ = c.close(fd);

            std.log.info("Audio capture thread: reading raw stream from {s}", .{pipe_path});

            var raw_buf: [1024]u8 = undefined;
            while (!self.should_stop.load(.acquire)) {
                const bytes_read = c.read(fd, &raw_buf, raw_buf.len);
                if (bytes_read <= 0) {
                    sleepMs(20);
                    continue;
                }


                const samples_count = @divTrunc(bytes_read, 2);
                if (samples_count > 0) {
                    const samples: [*]const i16 = @ptrCast(@alignCast(&raw_buf));
                    _ = self.vosk_audio_buffer.write(samples[0..@intCast(samples_count)]);
                }
            }
            return;
        }

        var retry_count: u32 = 0;
        const max_retries = 5;
        const retry_delay_ms = 100;
        var consecutive_errors: u32 = 0;
        const max_consecutive_errors = 20;


        if (self.alsa_capture) |*capture| {
            while (retry_count < max_retries and !self.should_stop.load(.acquire)) {
                capture.open() catch |err| {
                    retry_count += 1;


                    const error_info = switch (err) {
                        Error.AudioDeviceNotFound => ErrorInfo.initWithContext(err, "Audio device not found", self.options.audio_device),
                        Error.AudioDeviceBusy => ErrorInfo.initRecoverable(err, "Audio device is busy", "Close other applications using the audio device"),
                        Error.PermissionDenied => ErrorInfo.initWithContext(err, "Permission denied accessing audio device", self.options.audio_device),
                        Error.OutOfMemory => ErrorInfo.init(err, "Out of memory while opening audio device"),
                        Error.SystemResourcesExhausted => ErrorInfo.initRecoverable(err, "System resources exhausted", "Close other applications to free system resources"),
                        else => ErrorInfo.initWithContext(err, "Failed to open audio device", self.options.audio_device),
                    };

                    if (retry_count >= max_retries) {
                        var final_error = error_info;
                        final_error.message = "Failed to open audio device after maximum retries";
                        final_error.recoverable = false;
                        self.options.event_handler.onDetailedError(final_error);
                        return;
                    }


                    if (retry_count == 1) {
                        self.options.event_handler.onDetailedError(error_info);
                    }

                    sleepMs(retry_delay_ms * retry_count);
                    continue;
                };
                break;
            }

            if (retry_count >= max_retries) {
                return;
            }


            if (capture.sample_rate != 16000) {
                std.log.info("Hardware rate {d}Hz != 16kHz, enabling resampling", .{capture.sample_rate});
                self.resample_buffer = self.allocator.alloc(i16, 16000) catch {
                    const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate resample buffer");
                    self.options.event_handler.onDetailedError(error_info);
                    return;
                };
            }


            retry_count = 0;


            var loop_count: u32 = 0;
            while (!self.should_stop.load(.acquire)) {
                loop_count += 1;

                _ = capture.readAudio() catch |err| {
                    consecutive_errors += 1;


                    const error_info = switch (err) {
                        Error.AudioDeviceError => blk: {

                            if (consecutive_errors > 5) {
                                break :blk ErrorInfo.initRecoverable(Error.AudioDeviceError, "Audio device may have been disconnected", "Check audio device connection and restart application");
                            } else {
                                break :blk ErrorInfo.initRecoverable(err, "Audio capture error, attempting recovery", "Audio device will be automatically reopened");
                            }
                        },
                        Error.OutOfMemory => ErrorInfo.init(err, "Out of memory during audio processing"),
                        else => ErrorInfo.initWithContext(err, "Unexpected audio capture error", self.options.audio_device),
                    };


                    self.options.event_handler.onDetailedError(error_info);


                    if (err == Error.AudioDeviceError) {
                        retry_count += 1;
                        if (retry_count >= max_retries or consecutive_errors >= max_consecutive_errors) {
                            const final_error = ErrorInfo.init(Error.AudioDeviceError, "Audio capture failed permanently, stopping audio thread");
                            self.options.event_handler.onDetailedError(final_error);
                            break;
                        }


                        self.recoverAudioDevice() catch |recovery_err| {

                            const recovery_error_info = switch (recovery_err) {
                                Error.AudioDeviceError => ErrorInfo.init(Error.AudioDeviceError, "Audio device recovery failed"),
                                else => ErrorInfo.init(Error.AudioDeviceError, "Audio device recovery failed with unknown error"),
                            };
                            self.options.event_handler.onDetailedError(recovery_error_info);
                        };

                        sleepMs(retry_delay_ms * retry_count);
                        continue;
                    } else if (err == Error.OutOfMemory) {

                        break;
                    } else {

                        sleepMs(50);
                        continue;
                    }
                };


                retry_count = 0;
                consecutive_errors = 0;


                const available = capture.availableSamples();


                if (available >= 512) {
                    const chunk_size = @min(available, self.processing_buffer.len);
                    const samples_read = capture.getAudioSamples(self.processing_buffer[0..chunk_size]);
                    if (samples_read > 0) {
                        var max_before_resample: u16 = 0;
                        for (self.processing_buffer[0..samples_read]) |s| {
                            const abs_s = @abs(s);
                            if (abs_s > max_before_resample) max_before_resample = abs_s;
                        }


                        const samples_to_write = if (self.resample_buffer) |resample_buf| blk: {
                            const resampled_count = resample(
                                self.processing_buffer[0..samples_read],
                                resample_buf,
                                capture.sample_rate,
                                16000,
                            );
                            break :blk resample_buf[0..resampled_count];
                        } else self.processing_buffer[0..samples_read];


                        const written = self.vosk_audio_buffer.write(samples_to_write);
                        if (written < samples_to_write.len) {
                            _ = self.vosk_audio_buffer.write(samples_to_write);
                        }
                    }
                }


                sleepMs(1);
            }


            capture.close();
        }
    }




    fn sinkLoop(self: *Session, sink: AudioSink) void {
        const buf = self.allocator.alloc(i16, 4096) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate audio sink buffer");
            self.options.event_handler.onDetailedError(error_info);
            return;
        };
        defer self.allocator.free(buf);
        while (!self.should_stop.load(.acquire)) {
            const available = self.vosk_audio_buffer.available();
            if (available < 256) {
                sleepMs(10);
                continue;
            }
            const n = self.vosk_audio_buffer.read(buf[0..@min(available, buf.len)]);
            if (n == 0) continue;
            sink.feedFn(sink.ctx, buf[0..n]);
        }
    }

    fn processingThreadFn(self: *Session) void {
        if (self.options.audio_sink) |sink| {
            self.sinkLoop(sink);
            return;
        }
        if (self.vosk_recognizer == null) @panic("Session not initialized");
        const rec = self.vosk_recognizer.?;
        const vosk_chunk_size = 4096;
        var vosk_buffer = self.allocator.alloc(i16, vosk_chunk_size) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate Vosk processing buffer");
            self.options.event_handler.onDetailedError(error_info);
            return;
        };
        defer self.allocator.free(vosk_buffer);


        const silence_threshold: i16 = self.options.silence_threshold;
        const silence_duration_ms: u64 = 300;
        const min_speech_duration_ms: u64 = 300;
        const samples_per_ms = 16;
        const preroll_ms: u64 = 250;
        const preroll_samples = preroll_ms * samples_per_ms;

        std.log.info(
            "Listening with silence threshold {}. If wrong, use --measure-levels to find approriate val",
            .{silence_threshold},
        );
        var speech_buffer = self.allocator.alloc(i16, 16000 * 10) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate speech buffer");
            self.options.event_handler.onDetailedError(error_info);
            return;
        };
        defer self.allocator.free(speech_buffer);


        var preroll_buffer = self.allocator.alloc(i16, preroll_samples) catch {
            const error_info = ErrorInfo.init(Error.OutOfMemory, "Failed to allocate pre-roll buffer");
            self.options.event_handler.onDetailedError(error_info);
            return;
        };
        defer self.allocator.free(preroll_buffer);
        var preroll_pos: usize = 0;
        var preroll_filled: bool = false;

        var in_speech = false;
        var silence_samples: usize = 0;
        var speech_samples: usize = 0;
        var speech_pos: usize = 0;
        var speech_max_amplitude: u16 = 0;
        var speech_min_amplitude: u16 = std.math.maxInt(u16);

        while (!self.should_stop.load(.acquire)) {
            const available = self.vosk_audio_buffer.available();
            if (available < 256) {
                sleepMs(10);
                continue;
            }

            const read_size = @min(available, vosk_chunk_size);
            const samples_read = self.vosk_audio_buffer.read(vosk_buffer[0..read_size]);
            if (samples_read == 0) continue;

            var is_silent = true;
            var max_amplitude: u16 = 0;
            for (vosk_buffer[0..samples_read]) |sample| {
                const abs_sample = @abs(sample);
                if (abs_sample > max_amplitude) max_amplitude = abs_sample;
                if (abs_sample > silence_threshold) {
                    is_silent = false;
                }
            }

            if (!is_silent) {
                if (!in_speech) {
                    in_speech = true;
                    speech_samples = 0;
                    silence_samples = 0;
                    speech_pos = 0;
                    speech_max_amplitude = 0;
                    speech_min_amplitude = std.math.maxInt(u16);


                    if (preroll_filled) {

                        const first_part_len = preroll_samples - preroll_pos;
                        @memcpy(speech_buffer[0..first_part_len], preroll_buffer[preroll_pos..]);

                        @memcpy(speech_buffer[first_part_len..preroll_samples], preroll_buffer[0..preroll_pos]);
                        speech_pos = preroll_samples;


                        const preroll_bytes = std.mem.sliceAsBytes(speech_buffer[0..preroll_samples]);
                        _ = c.vosk_recognizer_accept_waveform(rec, preroll_bytes.ptr, @intCast(preroll_bytes.len));
                    } else if (preroll_pos > 0) {

                        @memcpy(speech_buffer[0..preroll_pos], preroll_buffer[0..preroll_pos]);
                        speech_pos = preroll_pos;


                        const preroll_bytes = std.mem.sliceAsBytes(speech_buffer[0..preroll_pos]);
                        _ = c.vosk_recognizer_accept_waveform(rec, preroll_bytes.ptr, @intCast(preroll_bytes.len));
                    }
                }
                if (max_amplitude > speech_max_amplitude) speech_max_amplitude = max_amplitude;
                if (max_amplitude < speech_min_amplitude) speech_min_amplitude = max_amplitude;
                const copy_len = @min(samples_read, speech_buffer.len - speech_pos);
                @memcpy(speech_buffer[speech_pos .. speech_pos + copy_len], vosk_buffer[0..copy_len]);
                speech_pos += copy_len;
                speech_samples += samples_read;
                silence_samples = 0;


                const audio_bytes = std.mem.sliceAsBytes(vosk_buffer[0..samples_read]);
                _ = c.vosk_recognizer_accept_waveform(rec, audio_bytes.ptr, @intCast(audio_bytes.len));
            } else if (in_speech) {
                silence_samples += samples_read;
                const copy_len = @min(samples_read, speech_buffer.len - speech_pos);
                @memcpy(speech_buffer[speech_pos .. speech_pos + copy_len], vosk_buffer[0..copy_len]);
                speech_pos += copy_len;


                const audio_bytes = std.mem.sliceAsBytes(vosk_buffer[0..samples_read]);
                _ = c.vosk_recognizer_accept_waveform(rec, audio_bytes.ptr, @intCast(audio_bytes.len));

                if (silence_samples >= silence_duration_ms * samples_per_ms) {
                    if (speech_samples >= min_speech_duration_ms * samples_per_ms) {
                        const event = SpeechEvent{

                            .text = undefined,
                            .max_amplitude = speech_max_amplitude,
                            .min_amplitude = speech_min_amplitude,
                            .audio_data = speech_buffer[0..speech_pos],
                        };
                        self.finalizeVoskAudio(event) catch |err| {
                            std.log.err("Error processing speech: {}", .{err});
                        };
                    }

                    in_speech = false;
                    speech_pos = 0;
                    speech_samples = 0;
                    silence_samples = 0;
                    speech_max_amplitude = 0;
                    speech_min_amplitude = std.math.maxInt(u16);

                    c.vosk_recognizer_reset(rec);
                }
            } else {

                for (vosk_buffer[0..samples_read]) |sample| {
                    preroll_buffer[preroll_pos] = sample;
                    preroll_pos = (preroll_pos + 1) % preroll_samples;
                    if (preroll_pos == 0) preroll_filled = true;
                }
            }


            sleepMs(1);
        }
    }


    fn finalizeVoskAudio(self: *Session, event: SpeechEvent) !void {
        if (self.vosk_recognizer == null) return Error.InvalidState;


        const result_cstr = c.vosk_recognizer_final_result(self.vosk_recognizer);
        if (result_cstr != null) {
            const result_str = std.mem.span(result_cstr);
            self.parseVoskResult(result_str, event) catch |err| {
                self.options.event_handler.onError(err, "Failed to parse Vosk result");
            };
        }
    }


    fn parseVoskResult(self: *Session, json_str: []const u8, event: SpeechEvent) !void {
        if (json_str.len == 0) return;

        const text_key = "\"text\"";
        if (std.mem.indexOf(u8, json_str, text_key)) |text_start| {
            const value_start = text_start + text_key.len;
            if (std.mem.indexOf(u8, json_str[value_start..], ":")) |colon_pos| {
                const after_colon = value_start + colon_pos + 1;
                var quote_start: ?usize = null;
                for (json_str[after_colon..], 0..) |char, i| {
                    if (char == '"') {
                        quote_start = after_colon + i + 1;
                        break;
                    }
                }
                if (quote_start) |s| {
                    if (std.mem.indexOf(u8, json_str[s..], "\"")) |quote_end| {
                        const text = json_str[s .. s + quote_end];
                        if (text.len > 0 and !std.mem.eql(u8, text, " ")) {
                            var result_event = event;
                            result_event.text = text;
                            self.options.event_handler.onSpeech(result_event);
                        }
                    }
                }
            }
        }
    }


    fn recoverAudioDevice(self: *Session) Error!void {
        if (self.alsa_capture) |*capture| {

            capture.close();


            sleepMs(100);


            capture.open() catch |err| {
                const recovery_error = switch (err) {
                    Error.AudioDeviceNotFound => ErrorInfo.initWithContext(err, "Audio device not found during recovery", self.options.audio_device),
                    Error.AudioDeviceBusy => ErrorInfo.initRecoverable(err, "Audio device busy during recovery", "Wait for other applications to release the device"),
                    Error.PermissionDenied => ErrorInfo.initWithContext(err, "Permission denied during audio device recovery", self.options.audio_device),
                    else => ErrorInfo.initWithContext(err, "Failed to recover audio device", self.options.audio_device),
                };

                self.options.event_handler.onDetailedError(recovery_error);
                return err;
            };


            capture.audio_buffer.clear();

            const recovery_success = ErrorInfo.initRecoverable(Error.InternalError, "Audio device recovered successfully", "Audio capture will resume normally");
            self.options.event_handler.onDetailedError(recovery_success);
        }
    }


    fn reinitializeVosk(self: *Session) Error!void {

        if (self.vosk_recognizer) |recognizer| {
            c.vosk_recognizer_free(recognizer);
            self.vosk_recognizer = null;
        }


        if (self.vosk_model) |model| {
            self.vosk_recognizer = c.vosk_recognizer_new(model, 16000.0);
            if (self.vosk_recognizer == null) {
                const error_info = ErrorInfo.init(Error.ModelLoadError, "Failed to reinitialize Vosk recognizer");
                self.options.event_handler.onDetailedError(error_info);
                return Error.ModelLoadError;
            }


            self.vosk_audio_buffer.clear();

            const success_info = ErrorInfo.initRecoverable(Error.InternalError, "Vosk recognizer reinitialized successfully", "Speech processing will resume normally");
            self.options.event_handler.onDetailedError(success_info);
        } else {
            return Error.InvalidState;
        }
    }


    pub fn getStatus(self: *Session) struct {
        initialized: bool,
        listening: bool,
        audio_samples_available: usize,
        processing_samples_available: usize,
    } {
        return .{
            .initialized = self.initialized,
            .listening = self.listening,
            .audio_samples_available = if (self.alsa_capture) |*capture| capture.availableSamples() else 0,
            .processing_samples_available = self.vosk_audio_buffer.available(),
        };
    }


    fn validateOptions(options: Options) Error!void {
        if (options.model_path.len == 0) {
            return Error.InvalidParameter;
        }
        if (options.audio_device.len == 0) {
            return Error.InvalidParameter;
        }
        if (options.sample_rate == 0 or options.sample_rate > 48000) {
            return Error.InvalidParameter;
        }
        if (options.buffer_size == 0 or options.buffer_size > 8192) {
            return Error.InvalidParameter;
        }
    }


    pub fn reinitialize(self: *Session) Error!void {
        if (self.listening) {
            self.stop_listening();
        }


        if (self.vosk_recognizer) |recognizer| {
            c.vosk_recognizer_free(recognizer);
            self.vosk_recognizer = null;
        }
        if (self.vosk_model) |model| {
            c.vosk_model_free(model);
            self.vosk_model = null;
        }


        try self.initVosk();


        if (self.alsa_capture) |*capture| {
            capture.audio_buffer.clear();
        }
        self.vosk_audio_buffer.clear();

        self.initialized = true;
    }










    pub fn start(self: *Session) Error!void {
        if (!self.initialized) {
            return Error.InvalidState;
        }
        if (self.listening) {
            return Error.InvalidState;
        }


        if (self.alsa_capture) |*capture| {
            capture.audio_buffer.clear();
        }
        self.vosk_audio_buffer.clear();


        self.should_stop.store(false, .release);


        self.audio_thread = std.Thread.spawn(.{}, audioThreadFn, .{self}) catch |err| {
            self.should_stop.store(true, .release);
            return switch (err) {
                error.SystemResources, error.ThreadQuotaExceeded => Error.ThreadingError,
                else => Error.ThreadingError,
            };
        };


        self.processing_thread = std.Thread.spawn(.{}, processingThreadFn, .{self}) catch |err| {

            self.should_stop.store(true, .release);
            if (self.audio_thread) |thread| {
                thread.detach();
                self.audio_thread = null;
            }
            return switch (err) {
                error.SystemResources, error.ThreadQuotaExceeded => Error.ThreadingError,
                else => Error.ThreadingError,
            };
        };


        sleepMs(10);

        self.listening = true;
    }





    pub fn stop(self: *Session) void {
        if (!self.listening) {
            return;
        }


        self.should_stop.store(true, .release);


        sleepMs(10);


        if (self.audio_thread) |thread| {
            thread.detach();
            self.audio_thread = null;
        }

        if (self.processing_thread) |thread| {
            thread.detach();
            self.processing_thread = null;
        }


        if (self.alsa_capture) |*capture| {
            capture.audio_buffer.clear();
        }
        self.vosk_audio_buffer.clear();

        self.listening = false;
    }





    pub fn deinit(self: *Session) void {

        if (self.listening) {
            self.stop();
        }


        if (self.audio_thread) |thread| {
            thread.detach();
            self.audio_thread = null;
        }
        if (self.processing_thread) |thread| {
            thread.detach();
            self.processing_thread = null;
        }


        if (self.vosk_recognizer) |recognizer| {
            c.vosk_recognizer_free(recognizer);
            self.vosk_recognizer = null;
        }
        if (self.vosk_model) |model| {
            c.vosk_model_free(model);
            self.vosk_model = null;
        }


        self.vosk_audio_buffer.deinit();


        if (self.alsa_capture) |*capture| {
            capture.deinit();
            self.alsa_capture = null;
        }


        self.allocator.free(self.processing_buffer);


        if (self.resample_buffer) |buf| {
            self.allocator.free(buf);
        }


        _ = c.snd_config_update_free_global();


        self.initialized = false;
    }
};













pub fn init(allocator: std.mem.Allocator, options: Options) Error!Session {
    return Session.init(allocator, options);
}


test "Error enum" {
    const testing = std.testing;


    const err1 = Error.InitializationFailed;
    const err2 = Error.AudioDeviceError;

    try testing.expect(err1 != err2);
    try testing.expect(err1 == Error.InitializationFailed);
}

test "Options validation" {
    const testing = std.testing;


    const DummyHandler = struct {
        fn onSpeech(ctx: *anyopaque, event: SpeechEvent) void {
            _ = ctx;
            _ = event;
        }
        fn onError(ctx: *anyopaque, error_code: Error, message: []const u8) void {
            _ = ctx;
            _ = message;

            switch (error_code) {
                else => {},
            }
        }
    };

    var dummy_ctx: u8 = 0;
    const valid_options = Options{
        .model_path = "/path/to/model",
        .audio_device = "hw:0,0",
        .event_handler = SpeechEventHandler{
            .onSpeechFn = DummyHandler.onSpeech,
            .onErrorFn = DummyHandler.onError,
            .ctx = &dummy_ctx,
        },
    };


    try testing.expectEqualStrings("/path/to/model", valid_options.model_path);
    try testing.expectEqualStrings("hw:0,0", valid_options.audio_device);
    try testing.expect(valid_options.sample_rate == 16000);
    try testing.expect(valid_options.buffer_size == 256);
}

test "Session state management" {
    const testing = std.testing;

    const DummyHandler = struct {
        fn onSpeech(ctx: *anyopaque, event: SpeechEvent) void {
            _ = ctx;
            _ = event;
        }
        fn onError(ctx: *anyopaque, error_code: Error, message: []const u8) void {
            _ = ctx;
            _ = message;

            switch (error_code) {
                else => {},
            }
        }
    };

    var dummy_ctx: u8 = 0;
    const options = Options{
        .model_path = "/path/to/model",
        .audio_device = "hw:0,0",
        .event_handler = SpeechEventHandler{
            .onSpeechFn = DummyHandler.onSpeech,
            .onErrorFn = DummyHandler.onError,
            .ctx = &dummy_ctx,
        },
    };


    try testing.expectEqualStrings("/path/to/model", options.model_path);
    try testing.expectEqualStrings("hw:0,0", options.audio_device);
    try testing.expect(options.sample_rate == 16000);
    try testing.expect(options.buffer_size == 256);
}

test "SpeechEventHandler interface" {
    const testing = std.testing;

    const TestHandler = struct {
        speech_called: bool = false,
        error_called: bool = false,
        last_text: []const u8 = "",
        last_amplitude: u16 = 0,
        last_error: Error = Error.InitializationFailed,

        fn onSpeech(ctx: *anyopaque, event: SpeechEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.speech_called = true;
            self.last_text = event.text;
            self.last_amplitude = event.max_amplitude;
        }

        fn onError(ctx: *anyopaque, error_code: Error, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.error_called = true;
            self.last_error = error_code;
            _ = message;
        }
    };

    var handler = TestHandler{};
    const event_handler = SpeechEventHandler{
        .onSpeechFn = TestHandler.onSpeech,
        .onErrorFn = TestHandler.onError,
        .ctx = &handler,
    };


    event_handler.onSpeech(.{ .text = "hello world" });
    try testing.expect(handler.speech_called);
    try testing.expectEqualStrings("hello world", handler.last_text);
    try testing.expect(handler.last_amplitude == std.math.maxInt(u16));


    event_handler.onError(Error.AudioDeviceError, "test error");
    try testing.expect(handler.error_called);
    try testing.expect(handler.last_error == Error.AudioDeviceError);
}

test "Vosk integration with valid model" {



    return error.SkipZigTest;
}

test "AudioBuffer basic operations" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = try AudioBuffer.init(allocator, 10);
    defer buffer.deinit();


    try testing.expect(buffer.available() == 0);
    try testing.expect(buffer.capacity() == 10);


    const samples = [_]i16{ 1, 2, 3, 4, 5 };
    const written = buffer.write(&samples);
    try testing.expect(written == 5);
    try testing.expect(buffer.available() == 5);
    try testing.expect(buffer.capacity() == 5);


    var read_samples: [3]i16 = undefined;
    const read_count = buffer.read(&read_samples);
    try testing.expect(read_count == 3);
    try testing.expect(read_samples[0] == 1);
    try testing.expect(read_samples[1] == 2);
    try testing.expect(read_samples[2] == 3);
    try testing.expect(buffer.available() == 2);


    const more_samples = [_]i16{ 6, 7, 8, 9, 10, 11, 12, 13 };
    const written2 = buffer.write(&more_samples);
    try testing.expect(written2 == 8);
    try testing.expect(buffer.available() == 10);


    buffer.clear();
    try testing.expect(buffer.available() == 0);
    try testing.expect(buffer.capacity() == 10);
}

test "AudioConverter stereo to mono conversion" {
    const testing = std.testing;


    const stereo_samples = [_]i16{ 100, 200, 300, 400, 500, 600 };
    var mono_samples: [3]i16 = undefined;

    const frames_converted = AudioConverter.stereoToMono(&stereo_samples, &mono_samples);
    try testing.expect(frames_converted == 3);


    try testing.expect(mono_samples[0] == 150);
    try testing.expect(mono_samples[1] == 350);
    try testing.expect(mono_samples[2] == 550);
}

test "AlsaCapture initialization" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    var capture = AlsaCapture.init(allocator, "hw:0,0", 16000, 1024) catch |err| {

        if (err == error.OutOfMemory) {
            return err;
        }
        return;
    };
    defer capture.deinit();


    try testing.expect(capture.sample_rate == 16000);
    try testing.expect(capture.buffer_size == 1024);
    try testing.expect(capture.period_size == 256);
    try testing.expect(capture.pcm_handle == null);
}

test "AudioBuffer thread safety" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = try AudioBuffer.init(allocator, 1000);
    defer buffer.deinit();


    const samples1 = [_]i16{ 1, 2, 3, 4, 5 };
    const samples2 = [_]i16{ 6, 7, 8, 9, 10 };


    const written1 = buffer.write(&samples1);
    const written2 = buffer.write(&samples2);

    try testing.expect(written1 == 5);
    try testing.expect(written2 == 5);
    try testing.expect(buffer.available() == 10);


    var read_buffer: [10]i16 = undefined;
    const read_count = buffer.read(&read_buffer);
    try testing.expect(read_count == 10);


    try testing.expect(read_buffer[0] == 1);
    try testing.expect(read_buffer[4] == 5);
    try testing.expect(read_buffer[5] == 6);
    try testing.expect(read_buffer[9] == 10);
}

test "Session session management API" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const TestHandler = struct {
        speech_count: u32 = 0,
        error_count: u32 = 0,

        fn onSpeech(ctx: *anyopaque, event: SpeechEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.speech_count += 1;
            _ = event;
        }

        fn onError(ctx: *anyopaque, error_code: Error, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.error_count += 1;
            switch (error_code) {
                else => {},
            }
            _ = message;
        }
    };

    var handler = TestHandler{};
    const options = Options{
        .model_path = "/invalid/path",
        .audio_device = "hw:0,0",
        .event_handler = SpeechEventHandler{
            .onSpeechFn = TestHandler.onSpeech,
            .onErrorFn = TestHandler.onError,
            .ctx = &handler,
        },
    };


    try testing.expectEqualStrings("/invalid/path", options.model_path);
    try testing.expectEqualStrings("hw:0,0", options.audio_device);
    try testing.expect(options.sample_rate == 16000);
    try testing.expect(options.buffer_size == 256);


    const invalid_options = Options{
        .model_path = "",
        .audio_device = "hw:0,0",
        .event_handler = options.event_handler,
    };

    const invalid_result = init(allocator, invalid_options);
    try testing.expectError(Error.InvalidParameter, invalid_result);
}

test "Session status and recovery" {



    return error.SkipZigTest;
}

test "resample function" {

    const input = [_]i16{ 100, 200, 300, 400 };
    var output: [4]i16 = undefined;
    const count = resample(&input, &output, 16000, 16000);
    try std.testing.expect(count == 4);
    try std.testing.expectEqualSlices(i16, &input, output[0..count]);


    const input_48k = [_]i16{ 100, 150, 200, 250, 300, 350 };
    var output_16k: [2]i16 = undefined;
    const down_count = resample(&input_48k, &output_16k, 48000, 16000);
    try std.testing.expect(down_count == 2);


    const input_16k = [_]i16{ 100, 200 };
    var output_48k: [6]i16 = undefined;
    const up_count = resample(&input_16k, &output_48k, 16000, 48000);
    try std.testing.expect(up_count == 6);
}
