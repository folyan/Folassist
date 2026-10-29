
const std = @import("std");
const c = @import("c");

pub const Event = union(enum) {
    wake: struct { conf: f32, heard: []const u8 },
    wake_rejected: struct { conf: f32, heard: []const u8 },
    listening,
    command: []const u8,
    not_understood,
    timeout,
};

pub const Handler = struct {
    ctx: *anyopaque,
    onEventFn: *const fn (ctx: *anyopaque, t_sec: f32, event: Event) void,
};

pub const Config = struct {
    wake: []const u8,
    commands: []const u8 = "пинг",
    min_conf: f32 = 0.0,
    listen_timeout_ms: u32 = 5000,
};

pub const Assistant = struct {
    const State = enum { idle, listening };
    const sample_rate: u64 = 16000;
    const utt_cap: usize = 16000 * 2 * 12;

    allocator: std.mem.Allocator,
    cfg: Config,
    handler: Handler,

    wake_rec: ?*c.VoskRecognizer = null,
    cmd_rec: ?*c.VoskRecognizer = null,
    grammar_wake: [:0]u8,
    grammar_cmd: [:0]u8,

    state: State = .idle,
    utt: []u8,
    utt_len: usize = 0,
    samples_fed: u64 = 0,
    listen_started: u64 = 0,

    muted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    was_muted: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, handler: Handler) !Assistant {
        const grammar_wake = try allocator.printSentinel(
            "[\"{s}\", \"тот\", \"вот\", \"долго\", \"дом\", \"кот\", \"год\", \"пот\", \"дело\", \"[unk]\"]",
            .{cfg.wake},
            0,
        );
        errdefer allocator.free(grammar_wake);

        var gbuf: [2048]u8 = undefined;
        var gw: std.Io.Writer = .fixed(&gbuf);
        try gw.print("[\"{s}\"", .{cfg.wake});
        var it = std.mem.splitScalar(u8, cfg.commands, ',');
        while (it.next()) |cmd| {
            if (cmd.len > 0) try gw.print(", \"{s}\"", .{cmd});
        }
        try gw.writeAll(", \"[unk]\"]");
        const grammar_cmd = try allocator.dupeSentinel(u8, gw.buffered(), 0);
        errdefer allocator.free(grammar_cmd);

        const utt = try allocator.alloc(u8, utt_cap);
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .handler = handler,
            .grammar_wake = grammar_wake,
            .grammar_cmd = grammar_cmd,
            .utt = utt,
        };
    }

    pub fn deinit(self: *Assistant) void {
        if (self.wake_rec) |r| c.vosk_recognizer_free(r);
        if (self.cmd_rec) |r| c.vosk_recognizer_free(r);
        self.allocator.free(self.grammar_wake);
        self.allocator.free(self.grammar_cmd);
        self.allocator.free(self.utt);
    }

    pub fn attach(self: *Assistant, model: *c.VoskModel) !void {
        self.wake_rec = c.vosk_recognizer_new_grm(model, 16000.0, self.grammar_wake.ptr) orelse return error.InitializationFailed;
        c.vosk_recognizer_set_words(self.wake_rec.?, 1);
        self.cmd_rec = c.vosk_recognizer_new(model, 16000.0) orelse return error.InitializationFailed;
    }

    pub fn sinkFeed(ctx: *anyopaque, samples: []const i16) void {
        const self: *Assistant = @ptrCast(@alignCast(ctx));
        self.feed(samples);
    }

    fn tSec(self: *const Assistant) f32 {
        return @as(f32, @floatFromInt(self.samples_fed)) / @as(f32, @floatFromInt(sample_rate));
    }

    fn emit(self: *Assistant, ev: Event) void {
        self.handler.onEventFn(self.handler.ctx, self.tSec(), ev);
    }

    fn resetAll(self: *Assistant) void {
        if (self.wake_rec) |r| c.vosk_recognizer_reset(r);
        if (self.cmd_rec) |r| c.vosk_recognizer_reset(r);
        self.state = .idle;
        self.utt_len = 0;
    }

    pub fn feed(self: *Assistant, samples: []const i16) void {
        const wake_rec = self.wake_rec orelse return;
        const cmd_rec = self.cmd_rec orelse return;

        if (self.muted.load(.acquire)) {
            self.was_muted = true;
            return;
        }
        if (self.was_muted) {
            self.was_muted = false;
            self.resetAll();
        }

        const bytes = std.mem.sliceAsBytes(samples);
        self.samples_fed += samples.len;

        switch (self.state) {
            .idle => {
                if (self.utt_len + bytes.len > utt_cap) self.utt_len = 0;
                @memcpy(self.utt[self.utt_len..][0..bytes.len], bytes);
                self.utt_len += bytes.len;
                if (c.vosk_recognizer_accept_waveform(wake_rec, bytes.ptr, @intCast(bytes.len)) != 0) {
                    self.onWakeUtterance(std.mem.span(c.vosk_recognizer_result(wake_rec)));
                }
            },
            .listening => {
                if (c.vosk_recognizer_accept_waveform(cmd_rec, bytes.ptr, @intCast(bytes.len)) != 0) {
                    const text = textOf(std.mem.span(c.vosk_recognizer_result(cmd_rec)));
                    if (text.len > 0) {
                        self.onCommandText(text);
                        self.resetAll();
                        return;
                    }
                }
                const waited_ms = (self.samples_fed - self.listen_started) * 1000 / sample_rate;
                if (waited_ms >= self.cfg.listen_timeout_ms) {
                    self.emit(.timeout);
                    self.resetAll();
                }
            },
        }
    }

    pub fn flush(self: *Assistant) void {
        const wake_rec = self.wake_rec orelse return;
        const cmd_rec = self.cmd_rec orelse return;
        if (self.state == .idle) {
            self.onWakeUtterance(std.mem.span(c.vosk_recognizer_final_result(wake_rec)));
        }
        if (self.state == .listening) {
            const text = textOf(std.mem.span(c.vosk_recognizer_final_result(cmd_rec)));
            if (text.len > 0) self.onCommandText(text) else self.emit(.timeout);
            self.resetAll();
        }
    }

    fn onCommandText(self: *Assistant, text: []const u8) void {
        if (onlyUnk(text)) self.emit(.not_understood) else self.emit(.{ .command = text });
    }

    fn onWakeUtterance(self: *Assistant, json: []const u8) void {
        const cmd_rec = self.cmd_rec.?;
        const text = textOf(json);
        if (containsToken(text, self.cfg.wake)) {
            const conf = wordConf(json, self.cfg.wake) orelse 0.0;
            if (conf < self.cfg.min_conf) {
                self.emit(.{ .wake_rejected = .{ .conf = conf, .heard = text } });
            } else {
                self.emit(.{ .wake = .{ .conf = conf, .heard = text } });

                c.vosk_recognizer_reset(cmd_rec);
                var p: usize = 0;
                const chunk: usize = 8000;
                while (p < self.utt_len) : (p += chunk) {
                    const q = self.utt[p..@min(p + chunk, self.utt_len)];
                    _ = c.vosk_recognizer_accept_waveform(cmd_rec, q.ptr, @intCast(q.len));
                }
                const full = textOf(std.mem.span(c.vosk_recognizer_final_result(cmd_rec)));
                const rest = textAfterWake(full, self.cfg.wake);
                if (rest.len > 0 and !onlyUnk(rest)) {
                    self.emit(.{ .command = rest });
                    self.resetAll();
                    return;
                }
                self.emit(.listening);
                c.vosk_recognizer_reset(cmd_rec);
                c.vosk_recognizer_reset(self.wake_rec.?);
                self.utt_len = 0;
                self.state = .listening;
                self.listen_started = self.samples_fed;
                return;
            }
        }
        self.utt_len = 0;
        c.vosk_recognizer_reset(self.wake_rec.?);
    }
};

pub fn textOf(json: []const u8) []const u8 {
    const key = std.mem.indexOf(u8, json, "\"text\"") orelse return "";
    const colon = std.mem.indexOfScalarPos(u8, json, key + 6, ':') orelse return "";
    const q1 = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return "";
    const q2 = std.mem.indexOfScalarPos(u8, json, q1 + 1, '"') orelse return "";
    return json[q1 + 1 .. q2];
}

fn textAfterWake(text: []const u8, wake: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, wake)) return std.mem.trim(u8, text[it.index..], " ");
    }
    var it2 = std.mem.tokenizeScalar(u8, text, ' ');
    _ = it2.next();
    return std.mem.trim(u8, text[it2.index..], " ");
}

fn wordConf(json: []const u8, word: []const u8) ?f32 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, "\"word\"")) |k| {
        from = k + 6;
        const colon = std.mem.indexOfScalarPos(u8, json, from, ':') orelse return null;
        const q1 = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
        const q2 = std.mem.indexOfScalarPos(u8, json, q1 + 1, '"') orelse return null;
        if (!std.mem.eql(u8, json[q1 + 1 .. q2], word)) continue;
        const ck = std.mem.lastIndexOf(u8, json[0..k], "\"conf\"") orelse return null;
        const cc = std.mem.indexOfScalarPos(u8, json, ck + 6, ':') orelse return null;
        var e = cc + 1;
        while (e < json.len and (std.ascii.isDigit(json[e]) or json[e] == '.' or json[e] == ' ' or json[e] == '-')) e += 1;
        return std.fmt.parseFloat(f32, std.mem.trim(u8, json[cc + 1 .. e], " ")) catch null;
    }
    return null;
}

fn onlyUnk(text: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| if (!std.mem.eql(u8, tok, "[unk]")) return false;
    return true;
}

fn containsToken(text: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| if (std.mem.eql(u8, tok, word)) return true;
    return false;
}

test "textOf" {
    try std.testing.expectEqualStrings("дот пинг", textOf("{\n  \"text\" : \"дот пинг\"\n}"));
    try std.testing.expectEqualStrings("", textOf("{}"));
}

test "textAfterWake" {
    try std.testing.expectEqualStrings("пинг", textAfterWake("дот пинг", "дот"));
    try std.testing.expectEqualStrings("пинг", textAfterWake("допинг пинг", "дот"));
    try std.testing.expectEqualStrings("", textAfterWake("дот", "дот"));
}

test "onlyUnk" {
    try std.testing.expect(onlyUnk("[unk] [unk]"));
    try std.testing.expect(!onlyUnk("[unk] пинг"));
}
