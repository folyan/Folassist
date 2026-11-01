const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");

const alloc = std.heap.c_allocator;

pub const Kind = enum { alarm, reminder };

pub const Event = struct {
    kind: Kind,
    at: i64,
    pcm: ?[]u8 = null,
};

pub const Parsed = struct {
    kind: Kind,
    at: i64,
};

pub var store_path: []const u8 = "folassist_events.txt";
var list: std.ArrayList(Event) = .empty;

pub fn now() i64 {
    return @intCast(c.time(null));
}

const num_table = [_]struct { w: []const u8, v: u32 }{
    .{ .w = "ноль", .v = 0 },
    .{ .w = "один", .v = 1 },
    .{ .w = "одна", .v = 1 },
    .{ .w = "два", .v = 2 },
    .{ .w = "две", .v = 2 },
    .{ .w = "три", .v = 3 },
    .{ .w = "четыре", .v = 4 },
    .{ .w = "пять", .v = 5 },
    .{ .w = "шесть", .v = 6 },
    .{ .w = "семь", .v = 7 },
    .{ .w = "восемь", .v = 8 },
    .{ .w = "девять", .v = 9 },
    .{ .w = "десять", .v = 10 },
    .{ .w = "одиннадцать", .v = 11 },
    .{ .w = "двенадцать", .v = 12 },
    .{ .w = "тринадцать", .v = 13 },
    .{ .w = "четырнадцать", .v = 14 },
    .{ .w = "пятнадцать", .v = 15 },
    .{ .w = "шестнадцать", .v = 16 },
    .{ .w = "семнадцать", .v = 17 },
    .{ .w = "восемнадцать", .v = 18 },
    .{ .w = "девятнадцать", .v = 19 },
    .{ .w = "двадцать", .v = 20 },
    .{ .w = "тридцать", .v = 30 },
    .{ .w = "сорок", .v = 40 },
    .{ .w = "пятьдесят", .v = 50 },
};

const weekdays = [_]struct { w: []const u8, wd: c_int }{
    .{ .w = "воскресенье", .wd = 0 },
    .{ .w = "понедельник", .wd = 1 },
    .{ .w = "вторник", .wd = 2 },
    .{ .w = "среду", .wd = 3 },
    .{ .w = "среда", .wd = 3 },
    .{ .w = "четверг", .wd = 4 },
    .{ .w = "пятницу", .wd = 5 },
    .{ .w = "пятница", .wd = 5 },
    .{ .w = "субботу", .wd = 6 },
    .{ .w = "суббота", .wd = 6 },
};

fn numOf(t: []const u8) ?u32 {
    for (num_table) |e| {
        if (std.mem.eql(u8, t, e.w)) return e.v;
    }
    return std.fmt.parseInt(u32, t, 10) catch null;
}

const Groups = struct {
    vals: [4]u32 = .{ 0, 0, 0, 0 },
    n: usize = 0,

    fn add(self: *Groups, v: u32) void {
        if (self.n > 0) {
            const last = self.vals[self.n - 1];
            if (last >= 20 and last % 10 == 0 and v < 10) {
                self.vals[self.n - 1] = last + v;
                return;
            }
        }
        if (self.n < self.vals.len) {
            self.vals[self.n] = v;
            self.n += 1;
        }
    }
};

fn addToken(g: *Groups, t: []const u8) bool {
    if (std.mem.indexOfScalar(u8, t, ':') != null) {
        var any = false;
        var it = std.mem.splitScalar(u8, t, ':');
        while (it.next()) |part| {
            if (numOf(part)) |v| {
                g.add(v);
                any = true;
            }
        }
        return any;
    }
    if (numOf(t)) |v| {
        g.add(v);
        return true;
    }
    return false;
}

fn targetAt(h: c_int, m: c_int, day_add: c_int, weekday: c_int) i64 {
    var t: c.time_t = c.time(null);
    const t_now: i64 = @intCast(t);
    var tmv: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tmv);
    const cur_wd = tmv.tm_wday;

    tmv.tm_hour = h;
    tmv.tm_min = m;
    tmv.tm_sec = 0;
    tmv.tm_isdst = -1;
    tmv.tm_mday += day_add;
    if (weekday >= 0) tmv.tm_mday += @mod(weekday - cur_wd + 7, 7);

    var at: i64 = @intCast(c.mktime(&tmv));
    if (at <= t_now) {
        tmv.tm_mday += if (weekday >= 0) 7 else 1;
        at = @intCast(c.mktime(&tmv));
    }
    return at;
}

pub fn parseCommand(text: []const u8) ?Parsed {
    var words: [32][]const u8 = undefined;
    var nw: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |t| {
        if (nw == words.len) break;
        words[nw] = t;
        nw += 1;
    }
    if (nw == 0) return null;
    const kind: Kind = if (std.mem.eql(u8, words[0], "будильник"))
        .alarm
    else if (std.mem.eql(u8, words[0], "напомни"))
        .reminder
    else
        return null;

    const toks = words[1..nw];
    const t_now = now();

    for (toks, 0..) |t, i| {
        if (!std.mem.eql(u8, t, "через")) continue;
        if (i + 1 >= toks.len) return null;
        var amount: u32 = 1;
        var unit_idx = i + 1;
        if (numOf(toks[i + 1])) |v| {
            amount = v;
            unit_idx = i + 2;
        }
        if (unit_idx >= toks.len) return null;
        const unit = toks[unit_idx];
        if (std.mem.startsWith(u8, unit, "мин")) return .{ .kind = kind, .at = t_now + @as(i64, amount) * 60 };
        if (std.mem.startsWith(u8, unit, "час")) return .{ .kind = kind, .at = t_now + @as(i64, amount) * 3600 };
        return null;
    }

    var day_add: c_int = 0;
    var weekday: c_int = -1;
    var pm = false;
    var g: Groups = .{};
    for (toks) |t| {
        if (std.mem.eql(u8, t, "завтра")) day_add = 1;
        if (std.mem.eql(u8, t, "сегодня")) day_add = 0;
        if (std.mem.eql(u8, t, "вечера") or std.mem.eql(u8, t, "вечером") or std.mem.eql(u8, t, "дня")) pm = true;
        for (weekdays) |wd| {
            if (std.mem.eql(u8, t, wd.w)) weekday = wd.wd;
        }
        _ = addToken(&g, t);
    }
    if (g.n == 0) return null;

    var h = g.vals[0];
    const m: u32 = if (g.n > 1) g.vals[1] else 0;
    if (h > 23 or m > 59) return null;
    if (pm and h < 12) h += 12;
    return .{ .kind = kind, .at = targetAt(@intCast(h), @intCast(m), day_add, weekday) };
}

pub fn unlinkPath(path: []const u8) void {
    const pz = alloc.dupeSentinel(u8, path, 0) catch return;
    defer alloc.free(pz);
    _ = c.unlink(@ptrCast(pz.ptr));
}

fn writeAll(path: []const u8, data: []const u8) void {
    const pz = alloc.dupeSentinel(u8, path, 0) catch return;
    defer alloc.free(pz);
    const f = c.fopen(@ptrCast(pz.ptr), @ptrCast("wb")) orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(data.ptr, 1, data.len, f);
}

pub fn save() void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (list.items) |e| {
        const line = if (e.pcm) |p|
            alloc.print("r {d} {s}\n", .{ e.at, p }) catch continue
        else
            alloc.print("a {d}\n", .{e.at}) catch continue;
        defer alloc.free(line);
        out.appendSlice(alloc, line) catch return;
    }
    writeAll(store_path, out.items);
}

pub fn load() void {
    const data = zfmt.readFile(c, alloc, store_path) catch return;
    defer alloc.free(data);
    const t_now = now();

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len < 3) continue;
        const kind_c = line[0];
        const after_kind = std.mem.trim(u8, line[1..], " ");
        const sp = std.mem.indexOfScalar(u8, after_kind, ' ');
        const at_s = if (sp) |i| after_kind[0..i] else after_kind;
        const at = std.fmt.parseInt(i64, at_s, 10) catch continue;
        const rest = if (sp) |i| std.mem.trim(u8, after_kind[i + 1 ..], " ") else "";

        if (at <= t_now) {
            if (kind_c == 'r' and rest.len > 0) unlinkPath(rest);
            continue;
        }
        if (kind_c == 'a') {
            list.append(alloc, .{ .kind = .alarm, .at = at }) catch continue;
        } else if (kind_c == 'r' and rest.len > 0) {
            const p = alloc.dupe(u8, rest) catch continue;
            list.append(alloc, .{ .kind = .reminder, .at = at, .pcm = p }) catch {
                alloc.free(p);
                continue;
            };
        }
    }
    save();
}

pub fn addAlarm(at: i64) void {
    list.append(alloc, .{ .kind = .alarm, .at = at }) catch return;
    save();
}

pub fn addReminder(at: i64, pcm: []const u8) void {
    const path = alloc.print("{s}.{d}.pcm", .{ store_path, at }) catch return;
    writeAll(path, pcm);
    list.append(alloc, .{ .kind = .reminder, .at = at, .pcm = path }) catch {
        unlinkPath(path);
        alloc.free(path);
        return;
    };
    save();
}

pub fn popDue(t: i64) ?Event {
    for (list.items, 0..) |e, i| {
        if (e.at <= t) {
            const ev = list.orderedRemove(i);
            save();
            return ev;
        }
    }
    return null;
}
