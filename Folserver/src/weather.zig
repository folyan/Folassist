const std = @import("std");
const zfmt = @import("zfmt");
const c = @import("c");

pub const Current = struct {
    temp: f64,
    code: i32,
    wind: f64,
};

pub fn fetch(allocator: std.mem.Allocator, lat: f64, lon: f64) !Current {
    var cmd_buf: [384]u8 = undefined;
    const cmd = try zfmt.bufPrintZ(
        &cmd_buf,
        "curl -s --max-time 8 \"https://api.open-meteo.com/v1/forecast?latitude={d:.4}&longitude={d:.4}&current_weather=true\"",
        .{ lat, lon },
    );
    const pipe = c.popen(@ptrCast(cmd.ptr), @ptrCast("r")) orelse return error.WeatherFailed;
    defer _ = c.pclose(pipe);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = c.fread(&tmp, 1, tmp.len, pipe);
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }

    const Resp = struct {
        current_weather: struct {
            temperature: f64 = 0,
            windspeed: f64 = 0,
            weathercode: i32 = 0,
        },
    };
    const parsed = std.json.parseFromSlice(Resp, allocator, out.items, .{ .ignore_unknown_fields = true }) catch return error.WeatherFailed;
    defer parsed.deinit();
    const w = parsed.value.current_weather;
    return .{ .temp = w.temperature, .code = w.weathercode, .wind = w.windspeed };
}

fn describe(code: i32) []const u8 {
    return switch (code) {
        0 => "ясно",
        1...3 => "переменная облачность",
        45, 48 => "туман",
        51...57 => "морось",
        61...67 => "дождь",
        71...77 => "снег",
        80...82 => "ливень",
        85, 86 => "снегопад",
        95...99 => "гроза",
        else => "без осадков",
    };
}

fn degreesWord(n: u32) []const u8 {
    const m100 = n % 100;
    const m10 = n % 10;
    if (m100 >= 11 and m100 <= 19) return "градусов";
    if (m10 == 1) return "градус";
    if (m10 >= 2 and m10 <= 4) return "градуса";
    return "градусов";
}

pub fn phrase(allocator: std.mem.Allocator, city: []const u8, lat: f64, lon: f64) ![]u8 {
    const w = try fetch(allocator, lat, lon);
    const rounded: i32 = @intFromFloat(@round(w.temp));
    const abs: u32 = @intCast(@abs(rounded));
    return std.fmt.allocPrint(allocator, "В {s} сейчас {s}{d} {s}, {s}.", .{
        city,
        if (rounded < 0) "минус " else "",
        abs,
        degreesWord(abs),
        describe(w.code),
    });
}
