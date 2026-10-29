const std = @import("std");
const c = @import("c");

pub const Config = struct {
    city_in: []const u8 = "Омске",
    latitude: f64 = 54.99,
    longitude: f64 = 73.37,
};

pub const WeatherData = struct {
    description: []const u8,
    temperature_rounded: i32,
};

pub fn getWeatherDescription(code: i32) []const u8 {
    return switch (code) {
        0 => "ясно",
        1...3 => "переменная облачность",
        45, 48 => "туман",
        51, 53, 55, 61, 63, 65 => "дождь",
        71, 73, 75 => "снег",
        95, 96, 99 => "гроза",
        else => "облачно",
    };
}

pub fn getDegreeWord(deg: i32) []const u8 {
    const abs_d = @abs(deg);
    const rem100 = abs_d % 100;
    if (rem100 >= 11 and rem100 <= 14) return "градусов";
    const rem10 = abs_d % 10;
    return switch (rem10) {
        1 => "градус",
        2, 3, 4 => "градуса",
        else => "градусов",
    };
}

const ApiResponse = struct {
    current_weather: struct {
        temperature: f64,
        weathercode: i32,
    },
};

pub fn fetchCurrentWeather(allocator: std.mem.Allocator, cfg: Config) !WeatherData {
    var url_buf: [512]u8 = undefined;
    const len = (try std.fmt.bufPrint(url_buf[0 .. url_buf.len - 1], "curl -s \"https://api.open-meteo.com/v1/forecast?latitude={d:.2}&longitude={d:.2}&current_weather=true\"", .{ cfg.latitude, cfg.longitude })).len;
    url_buf[len] = 0;

    const pipe = c.popen(&url_buf, "r") orelse return error.NetworkError;
    defer _ = c.pclose(pipe);

    var json_list: std.ArrayListUnmanaged(u8) = .empty;
    defer json_list.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (true) {
        const bytes = c.fread(&buf, 1, buf.len, pipe);
        if (bytes == 0) break;
        try json_list.appendSlice(allocator, buf[0..bytes]);
    }

    if (json_list.items.len == 0) return error.EmptyResponse;

    const parsed = try std.json.parseFromSlice(
        ApiResponse,
        allocator,
        json_list.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const raw_temp = parsed.value.current_weather.temperature;
    return .{
        .description = getWeatherDescription(parsed.value.current_weather.weathercode),
        .temperature_rounded = @intFromFloat(@round(raw_temp)),
    };
}
