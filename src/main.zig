const std = @import("std");
const builtin = @import("builtin");
const stt = @import("stt.zig");
const c = @import("c");
const assistant = @import("assistant.zig");
const tts_mod = @import("tts.zig");
const weather = @import("weather.zig");
const ai = @import("ai.zig");

const Io = std.Io;

var should_exit = std.atomic.Value(bool).init(false);

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

var music_child: ?*std.process.Child = null;
var alarm_child: ?*std.process.Child = null;
var proc_mutex: Mutex = .{};

var ringtone_path: ?[]const u8 = null;
var proxy_arg: ?[]const u8 = null;

const TimerKind = enum { alarm, reminder };
const TimerItem = struct {
    kind: TimerKind,
    trigger_time: i64,
    message: []const u8,
};

var timers: std.ArrayListUnmanaged(TimerItem) = .empty;
var timers_mutex: Mutex = .{};

const current_city = weather.Config{
    .city_in = "Омске",
    .latitude = 54.99,
    .longitude = 73.37,
};

var handler: SpeechHandler = undefined;
var tts: ?tts_mod.Tts = null;

fn sleepMs(io: Io, ms: i64) void {
    io.sleep(Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

fn writeAll(io: Io, file: Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

fn printOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

const SpeechHandler = struct {
    allocator: std.mem.Allocator,
    io: ?Io = null,
    speech_count: u32 = 0,
    error_count: u32 = 0,
    mute: ?*std.atomic.Value(bool) = null,

    fn onSpeech(ctx: *anyopaque, event: stt.SpeechEvent) void {
        _ = ctx;
        _ = event;
    }

    fn onError(ctx: *anyopaque, error_code: stt.Error, message: []const u8) void {
        _ = ctx;
        std.log.err("STT Error ({}): {s}", .{ error_code, message });
    }

    fn onDetailedError(ctx: *anyopaque, error_info: stt.ErrorInfo) void {
        _ = ctx;
        if (!error_info.recoverable) {
            std.log.err("STT Fatal: {s}", .{error_info.message});
        }
    }
};

fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    if (sig == .INT) should_exit.store(true, .release);
}

fn stopMusic(io: Io) void {
    proc_mutex.lock();
    defer proc_mutex.unlock();
    if (music_child) |child| {
        child.kill(io);
        music_child = null;
    }
}

fn stopAlarm(io: Io) void {
    proc_mutex.lock();
    defer proc_mutex.unlock();
    if (alarm_child) |child| {
        child.kill(io);
        alarm_child = null;
    }
}

fn playMusic(self: *SpeechHandler, query: []const u8) !void {
    const io = self.io orelse return;
    stopMusic(io);
    stopAlarm(io);

    printOut(io, "Ищу на YouTube: {s}\n", .{query});
    if (tts) |*t| t.speakCached("Включаю музыку") catch {};

    var ytdl_buf: [512]u8 = undefined;
    const ytdl_arg = try std.fmt.bufPrint(&ytdl_buf, "ytdl://ytsearch1:{s}", .{query});

    const child = try self.allocator.create(std.process.Child);
    errdefer self.allocator.destroy(child);

    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "mpv"; argc += 1;
    argv_buf[argc] = "--no-video"; argc += 1;
    argv_buf[argc] = "--ao=pulse"; argc += 1;
    argv_buf[argc] = "--script-opts=ytdl_hook-ytdl_path=/usr/bin/yt-dlp"; argc += 1;
    argv_buf[argc] = "--ytdl-format=bestaudio/best"; argc += 1;

    var proxy_mpv_buf: [256]u8 = undefined;
    if (proxy_arg) |p| {
        argv_buf[argc] = std.fmt.bufPrint(&proxy_mpv_buf, "--http-proxy={s}", .{p}) catch "";
        argc += 1;
    }
    argv_buf[argc] = ytdl_arg; argc += 1;

    child.* = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
    });

    proc_mutex.lock();
    music_child = child;
    proc_mutex.unlock();
}

fn parseDurationSeconds(text: []const u8) i64 {
    var it = std.mem.tokenizeAny(u8, text, " ,.-");
    var total_sec: i64 = 0;
    var current_num: i64 = 1;

    while (it.next()) |word| {
        if (std.fmt.parseInt(i64, word, 10)) |num| {
            current_num = num;
            continue;
        } else |_| {}

        if (std.mem.eql(u8, word, "один") or std.mem.eql(u8, word, "одну")) {
            current_num = 1;
        } else if (std.mem.eql(u8, word, "два") or std.mem.eql(u8, word, "две")) {
            current_num = 2;
        } else if (std.mem.eql(u8, word, "три")) {
            current_num = 3;
        } else if (std.mem.eql(u8, word, "четыре")) {
            current_num = 4;
        } else if (std.mem.eql(u8, word, "пять")) {
            current_num = 5;
        } else if (std.mem.eql(u8, word, "десять")) {
            current_num = 10;
        } else if (std.mem.eql(u8, word, "пятнадцать")) {
            current_num = 15;
        } else if (std.mem.eql(u8, word, "двадцать")) {
            current_num = 20;
        } else if (std.mem.eql(u8, word, "тридцать") or std.mem.eql(u8, word, "полчаса")) {
            current_num = 30;
        } else if (std.mem.startsWith(u8, word, "сек")) {
            total_sec += current_num;
            current_num = 1;
        } else if (std.mem.startsWith(u8, word, "мин")) {
            total_sec += current_num * 60;
            current_num = 1;
        } else if (std.mem.startsWith(u8, word, "час")) {
            total_sec += current_num * 3600;
            current_num = 1;
        }
    }
    return total_sec;
}

fn parseAlarmTargetTime(text: []const u8, now: i64) ?i64 {
    var it = std.mem.tokenizeAny(u8, text, " ,.-");
    var nums: [4]i64 = undefined;
    var count: usize = 0;
    var is_evening = false;
    var is_morning = false;

    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "вечера") or std.mem.eql(u8, word, "ночи")) is_evening = true;
        if (std.mem.eql(u8, word, "утра") or std.mem.eql(u8, word, "дня")) is_morning = true;

        if (std.fmt.parseInt(i64, word, 10)) |num| {
            if (count < 4) {
                nums[count] = num;
                count += 1;
            }
            continue;
        } else |_| {}

        const mapped: ?i64 = blk: {
            if (std.mem.eql(u8, word, "один") or std.mem.eql(u8, word, "одну")) break :blk 1;
            if (std.mem.eql(u8, word, "два") or std.mem.eql(u8, word, "две")) break :blk 2;
            if (std.mem.eql(u8, word, "три")) break :blk 3;
            if (std.mem.eql(u8, word, "четыре")) break :blk 4;
            if (std.mem.eql(u8, word, "пять")) break :blk 5;
            if (std.mem.eql(u8, word, "шесть")) break :blk 6;
            if (std.mem.eql(u8, word, "семь")) break :blk 7;
            if (std.mem.eql(u8, word, "восемь")) break :blk 8;
            if (std.mem.eql(u8, word, "девять")) break :blk 9;
            if (std.mem.eql(u8, word, "десять")) break :blk 10;
            if (std.mem.eql(u8, word, "одиннадцать")) break :blk 11;
            if (std.mem.eql(u8, word, "двенадцать")) break :blk 12;
            if (std.mem.eql(u8, word, "двадцать")) break :blk 20;
            if (std.mem.eql(u8, word, "тридцать")) break :blk 30;
            break :blk null;
        };

        if (mapped) |val| {
            if (count < 4) {
                nums[count] = val;
                count += 1;
            }
        }
    }

    if (count == 0) return null;

    var target_hours: i64 = nums[0];
    var target_mins: i64 = if (count > 1) nums[1] else 0;

    if (count >= 3 and nums[1] >= 20 and nums[2] < 10) {
        target_mins = nums[1] + nums[2];
    }

    if (is_evening and target_hours < 12) target_hours += 12;
    if (is_morning and target_hours == 12) target_hours = 0;

    const tm_now = c.localtime(&now);
    const cur_hour: i64 = tm_now.*.tm_hour;
    const cur_min: i64 = tm_now.*.tm_min;
    const cur_sec: i64 = tm_now.*.tm_sec;

    var diff_seconds = ((target_hours - cur_hour) * 3600) + ((target_mins - cur_min) * 60) - cur_sec;

    if (diff_seconds <= 0) {
        diff_seconds += 24 * 3600;
    }

    return now + diff_seconds;
}

fn handleAlarm(self: *SpeechHandler, text: []const u8) void {
    const now = c.time(null);
    var trigger_time: i64 = 0;

    if (std.mem.indexOf(u8, text, "через") != null) {
        const sec = parseDurationSeconds(text);
        if (sec > 0) trigger_time = now + sec;
    } else {
        if (parseAlarmTargetTime(text, now)) |t| {
            trigger_time = t;
        }
    }

    if (trigger_time <= 0) {
        if (tts) |*t| t.speak("На какое время поставить будильник?") catch {};
        return;
    }

    timers_mutex.lock();
    timers.append(self.allocator, .{
        .kind = .alarm,
        .trigger_time = trigger_time,
        .message = "",
    }) catch {};
    timers_mutex.unlock();

    if (tts) |*t| t.speakCached("Будильник установлен") catch {};
}

fn handleReminder(self: *SpeechHandler, text: []const u8) void {
    const sec = parseDurationSeconds(text);
    if (sec <= 0) {
        if (tts) |*t| t.speak("Через какое время напомнить?") catch {};
        return;
    }

    var clean_msg: []const u8 = text;
    if (std.mem.indexOf(u8, text, "напомни")) |p| {
        clean_msg = std.mem.trim(u8, text[p + "напомни".len ..], " ");
    } else if (std.mem.indexOf(u8, text, "напоминание")) |p| {
        clean_msg = std.mem.trim(u8, text[p + "напоминание".len ..], " ");
    }

    const owned_msg = self.allocator.dupe(u8, clean_msg) catch return;

    const now = c.time(null);
    timers_mutex.lock();
    timers.append(self.allocator, .{
        .kind = .reminder,
        .trigger_time = now + sec,
        .message = owned_msg,
    }) catch {};
    timers_mutex.unlock();

    if (tts) |*t| t.speakCached("Хорошо, я напомню") catch {};
}

fn checkTimers(io: Io, allocator: std.mem.Allocator, now: i64) void {
    timers_mutex.lock();
    defer timers_mutex.unlock();

    var i: usize = 0;
    while (i < timers.items.len) {
        const item = timers.items[i];
        if (now >= item.trigger_time) {
            _ = timers.swapRemove(i);

            switch (item.kind) {
                .alarm => {
                    printOut(io, "Будильник\n", .{});
                    stopMusic(io); // Глушим музыку при срабатывании будильника
                    if (ringtone_path) |rt| {
                        const child = allocator.create(std.process.Child) catch return;
                        child.* = std.process.spawn(io, .{
                            .argv = &.{ "mpv", "--no-video", "--ao=pulse", "--loop", rt },
                        }) catch return;

                        proc_mutex.lock();
                        alarm_child = child;
                        proc_mutex.unlock();
                    } else {
                        if (tts) |*t| t.speak("Будильник звенит, пора вставать") catch {};
                    }
                },
                .reminder => {
                    printOut(io, "напоминание: {s}\n", .{item.message});
                    if (tts) |*t| {
                        var rem_buf: [512]u8 = undefined;
                        if (std.fmt.bufPrint(&rem_buf, "напоминаю {s}", .{item.message})) |msg| {
                            t.speak(msg) catch {};
                        } else |_| {}
                    }
                    allocator.free(item.message);
                },
            }
        } else {
            i += 1;
        }
    }
}

fn handleWeather(self: *SpeechHandler) void {
    const t = &(tts orelse return);
    const data = weather.fetchCurrentWeather(self.allocator, current_city) catch {
        t.speakCached("Не удалось получить погоду") catch {};
        return;
    };

    var city_buf: [128]u8 = undefined;
    const city_str = std.fmt.bufPrint(&city_buf, "Погода в {s}", .{current_city.city_in}) catch return;
    t.speakCached(city_str) catch {};
    t.speakCached(data.description) catch {};

    var temp_buf: [128]u8 = undefined;
    const deg_word = weather.getDegreeWord(data.temperature_rounded);
    const temp_str = if (data.temperature_rounded > 0)
        std.fmt.bufPrint(&temp_buf, "плюс {d} {s}", .{ data.temperature_rounded, deg_word }) catch return
    else if (data.temperature_rounded < 0)
        std.fmt.bufPrint(&temp_buf, "минус {d} {s}", .{ @abs(data.temperature_rounded), deg_word }) catch return
    else
        std.fmt.bufPrint(&temp_buf, "ноль градусов", .{}) catch return;

    t.speak(temp_str) catch {};
}

fn preheatTtsCache(t: *tts_mod.Tts) void {
    const static_phrases = [_][]const u8{
        "ясно",
        "переменная облачность",
        "туман",
        "дождь",
        "снег",
        "гроза",
        "облачно",
        "Включаю музыку",
        "Останавливаю",
        "Какую музыку включить",
        "Секунду",
        "Будильник установлен",
        "Хорошо, я напомню",
        "Не удалось получить погоду",
    };

    var city_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&city_buf, "Погода в {s}", .{current_city.city_in})) |city_phrase| {
        t.precompilePhrase(city_phrase) catch {};
    } else |_| {}

    for (static_phrases) |phrase| {
        t.precompilePhrase(phrase) catch {};
    }
}

fn onAssistantEvent(ctx: *anyopaque, t_sec: f32, ev: assistant.Event) void {
    const self: *SpeechHandler = @ptrCast(@alignCast(ctx));
    const io = self.io.?;
    switch (ev) {
        .wake => |w| {
            printOut(io, "[{d:.2}s] услышано: {s}\n", .{ t_sec, w.heard });
            // Автоматически останавливаем музыку при активации, чтобы колонка услышала команду
            stopMusic(io);
        },
        .wake_rejected => {},
        .listening => printOut(io, "[{d:.2}s] слушаю команду\n", .{t_sec}),
        .not_understood => {},
        .timeout => {},
        .command => |raw_text| {
            printOut(io, "[{d:.2}s] команда: {s}\n", .{ t_sec, raw_text });
            self.speech_count += 1;
            const text = std.mem.trim(u8, raw_text, " ");

            if (std.mem.indexOf(u8, text, "погода") != null) {
                handleWeather(self);
                return;
            }

            if (std.mem.eql(u8, text, "стоп") or std.mem.eql(u8, text, "выключи") or std.mem.indexOf(u8, text, "выключи музыку") != null or std.mem.indexOf(u8, text, "выключи будильник") != null) {
                stopMusic(io);
                stopAlarm(io);
                if (tts) |*t| t.speakCached("Останавливаю") catch {};
                return;
            }

            if (std.mem.indexOf(u8, text, "будильник") != null) {
                handleAlarm(self, text);
                return;
            }

            if (std.mem.indexOf(u8, text, "напомни") != null or std.mem.indexOf(u8, text, "напоминание") != null) {
                handleReminder(self, text);
                return;
            }

            if (std.mem.indexOf(u8, text, "включи")) |pos| {
                var query = text[pos + "включи".len ..];
                query = std.mem.trim(u8, query, " ");

                if (std.mem.startsWith(u8, query, "музыку")) {
                    query = std.mem.trim(u8, query["музыку".len..], " ");
                } else if (std.mem.startsWith(u8, query, "песню")) {
                    query = std.mem.trim(u8, query["песню".len..], " ");
                } else if (std.mem.startsWith(u8, query, "трек")) {
                    query = std.mem.trim(u8, query["трек".len..], " ");
                }

                if (query.len > 0) {
                    playMusic(self, query) catch |err| std.log.err("Music error: {}", .{err});
                } else {
                    if (tts) |*t| t.speakCached("Какую музыку включить") catch {};
                }
                return;
            }

            printOut(io, "запрос к ИИ: {s}\n", .{text});
            if (tts) |*t| t.speakCached("Секунду") catch {};

            const ai_reply = ai.ask(self.allocator, text) catch |err| {
                std.log.err("AI error: {}", .{err});
                if (tts) |*t| t.speak("не удалось связаться с ИИ") catch {};
                return;
            };
            defer self.allocator.free(ai_reply);

            printOut(io, "ИИ ответил: {s}\n", .{ai_reply});
            if (tts) |*t| t.speak(ai_reply) catch |err| std.log.err("TTS speak failed: {}", .{err});
        },
    }
}

fn printHelp(io: Io) !void {
    const stdout = Io.File.stdout();
    try writeAll(io, stdout,
        \\Voice Assistant
        \\
        \\OPTIONS:
        \\    --model=<path>          Path to Vosk model directory
        \\    --voice=<path.onnx>     Path to Piper voice model
        \\    --wake=<word>           Wake word (default: дот)
        \\    --ringtone=<file>       Alarm ringtone file
        \\    --proxy=<url>           HTTP or SOCKS5 proxy
        \\    --prompt-file=<file>    Custom system prompt .txt file
        \\    --help, -h              Show this help message
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const sigintact = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sigintact, null);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    const bin_dir = if (exe_len > 0) (std.fs.path.dirname(exe_buf[0..exe_len]) orelse ".") else ".";
    const proj_root = if (std.mem.endsWith(u8, bin_dir, "zig-out/bin"))
        (std.fs.path.dirname(std.fs.path.dirname(bin_dir) orelse bin_dir) orelse ".")
    else
        bin_dir;

    var def_model_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_model = try std.fmt.bufPrint(&def_model_buf, "{s}/vosk-model-small-ru-0.22", .{proj_root});

    var def_voice_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_voice = try std.fmt.bufPrint(&def_voice_buf, "{s}/voice/ru_RU-ruslan-medium.onnx", .{proj_root});

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var model_path: ?[]const u8 = default_model;
    var wake_word: []const u8 = "дот";
    var voice_path: ?[]const u8 = default_voice;
    var custom_prompt_path: ?[]const u8 = null;
    const espeak_data: []const u8 = "/usr/share/espeak-ng-data";
    const out_device: []const u8 = "default";

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(io);
            return;
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model_path = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--voice=")) {
            voice_path = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--wake=")) {
            wake_word = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--ringtone=")) {
            ringtone_path = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--proxy=")) {
            proxy_arg = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--prompt-file=")) {
            custom_prompt_path = arg[14..];
        }
    }

    if (proxy_arg) |p| {
        var p_buf: [256]u8 = undefined;
        const normalized_proxy = if (std.mem.startsWith(u8, p, "http://") or std.mem.startsWith(u8, p, "socks5://"))
            p
        else
            std.fmt.bufPrint(&p_buf, "http://{s}", .{p}) catch p;

        proxy_arg = normalized_proxy;

        const p_z = allocator.dupeSentinel(u8, normalized_proxy, 0) catch null;
        if (p_z) |pz| {
            _ = c.setenv("http_proxy", pz.ptr, 1);
            _ = c.setenv("https_proxy", pz.ptr, 1);
            _ = c.setenv("all_proxy", pz.ptr, 1);
            _ = c.setenv("HTTP_PROXY", pz.ptr, 1);
            _ = c.setenv("HTTPS_PROXY", pz.ptr, 1);
        }

        ai.setProxy(normalized_proxy);
    }

    try ai.initPrompt(allocator, wake_word, custom_prompt_path);
    defer ai.deinit(allocator);

    handler = SpeechHandler{
        .allocator = allocator,
        .io = io,
    };

    tts = tts_mod.Tts.init(allocator, voice_path.?, espeak_data, out_device) catch |err| {
        std.log.err("TTS init error: {}", .{err});
        return err;
    };
    defer if (tts) |*t| t.deinit();
    preheatTtsCache(&tts.?);

    var live_assistant = try assistant.Assistant.init(allocator, .{
        .wake = wake_word,
        .commands = "",
        .min_conf = 0.0,
    }, .{ .ctx = &handler, .onEventFn = onAssistantEvent });
    defer live_assistant.deinit();
    handler.mute = &live_assistant.muted;

    const speech_handler = stt.SpeechEventHandler{
        .onSpeechFn = SpeechHandler.onSpeech,
        .onErrorFn = SpeechHandler.onError,
        .onDetailedErrorFn = SpeechHandler.onDetailedError,
        .ctx = &handler,
    };

    var session = try stt.Session.init(allocator, .{
        .model_path = model_path.?,
        .audio_device = "default",
        .event_handler = speech_handler,
        .sample_rate = 16000,
        .buffer_size = 256,
        .silence_threshold = 300,
        .audio_sink = .{ .ctx = &live_assistant, .feedFn = assistant.Assistant.sinkFeed },
    });
    defer session.deinit();
    try live_assistant.attach(session.vosk_model.?);

    try session.start();
    defer session.stop();

    printOut(io, "start, wake: \"{s}\"\n", .{wake_word});

    while (!should_exit.load(.acquire)) {
        sleepMs(io, 100);
        const now = c.time(null);
        checkTimers(io, allocator, now);
    }

    stopMusic(io);
    stopAlarm(io);
}
