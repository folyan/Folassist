const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");

const alloc = std.heap.c_allocator;
pub const ROOT = "update";
const REPO = "folyan/Folassist";

const Asset = struct { name: []const u8, browser_download_url: []const u8 };
const Release = struct { tag_name: []const u8, assets: []Asset = &.{} };

/// Релиз, который отдаём клиентам. Всё лежит в update/<tag>/, а версия (APP) берётся из
/// app.txt того же релиза. Так клиенту никогда не уходит бинарник от другого релиза,
/// чем тот, номер которого в offer.
var latest_tag: ?[]u8 = null;
var latest_dir: ?[]u8 = null;
var latest_app: u8 = 0;

fn sh(cmd: []const u8) bool {
    const z = alloc.dupeSentinel(u8, cmd, 0) catch return false;
    defer alloc.free(z);
    return c.system(z.ptr) == 0;
}

fn wanted(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "folclient-") or
        std.mem.eql(u8, name, "app.txt") or
        std.mem.eql(u8, name, "sha256sums.txt") or
        std.mem.eql(u8, name, "sha256sums.txt.sig");
}

fn joinZ(dir: []const u8, name: []const u8) ?[:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0) catch null;
}

fn fileExists(dir: []const u8, name: []const u8) bool {
    const p = joinZ(dir, name) orelse return false;
    defer alloc.free(p);
    return c.access(p.ptr, c.F_OK) == 0;
}

/// Проверяет sha256 скачанного файла по строке из sha256sums.txt того же релиза.
fn hashOk(dir: []const u8, name: []const u8) bool {
    const cmd = std.fmt.allocPrint(alloc, "cd '{s}' && grep -E ' {s}$' sha256sums.txt | sha256sum -c - >/dev/null 2>&1", .{ dir, name }) catch return false;
    defer alloc.free(cmd);
    return sh(cmd);
}

fn readApp(dir: []const u8) ?u8 {
    const p = joinZ(dir, "app.txt") orelse return null;
    defer alloc.free(p);
    const data = zfmt.readFile(c, alloc, std.mem.span(p.ptr)) catch return null;
    defer alloc.free(data);
    return std.fmt.parseInt(u8, std.mem.trim(u8, data, " \r\n"), 10) catch null;
}

pub fn refresh() void {
    _ = c.mkdir(ROOT, 0o755);
    std.debug.print("update: проверяю релизы {s}\n", .{REPO});
    if (!sh("curl -sfL -H 'Accept: application/vnd.github+json' -o update/latest.json https://api.github.com/repos/" ++ REPO ++ "/releases/latest")) {
        std.debug.print("update: GitHub не отдал latest (нет сети, неверный REPO или нет опубликованного релиза)\n", .{});
        return;
    }
    const data = zfmt.readFile(c, alloc, "update/latest.json") catch {
        std.debug.print("update: не прочитан update/latest.json\n", .{});
        return;
    };
    defer alloc.free(data);
    const parsed = std.json.parseFromSlice(Release, alloc, data, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("update: не разобран JSON релиза\n", .{});
        return;
    };
    defer parsed.deinit();
    const ver = std.mem.trimStart(u8, parsed.value.tag_name, "v");
    if (latest_tag) |old| {
        if (std.mem.eql(u8, old, ver)) return;
    }

    const dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ ROOT, ver }) catch return;
    defer alloc.free(dir);
    if (joinZ(ROOT, ver)) |d| {
        _ = c.mkdir(d.ptr, 0o755);
        alloc.free(d);
    }

    var ok = true;
    for (parsed.value.assets) |a| {
        if (!wanted(a.name)) continue;
        const cmd = std.fmt.allocPrint(alloc, "curl -sfL -o '{s}/{s}.part' '{s}' && mv -f '{s}/{s}.part' '{s}/{s}'", .{ dir, a.name, a.browser_download_url, dir, a.name, dir, a.name }) catch return;
        defer alloc.free(cmd);
        if (!sh(cmd)) ok = false;
    }
    if (!ok) {
        std.debug.print("update: не все файлы релиза {s} скачались\n", .{ver});
        return;
    }

    // проверяем каждый бинарник и app.txt по хешам из того же релиза
    for (parsed.value.assets) |a| {
        if (!wanted(a.name)) continue;
        if (std.mem.eql(u8, a.name, "sha256sums.txt") or std.mem.eql(u8, a.name, "sha256sums.txt.sig")) continue;
        if (!hashOk(dir, a.name)) {
            std.debug.print("update: хеш не сошёлся для {s} ({s}), релиз не принят\n", .{ a.name, ver });
            return;
        }
    }

    const app = readApp(dir) orelse {
        std.debug.print("update: в релизе {s} нет корректного app.txt\n", .{ver});
        return;
    };
    std.debug.print("update: принят релиз {s}, APP {d}\n", .{ ver, app });

    if (latest_tag) |old| alloc.free(old);
    if (latest_dir) |old| alloc.free(old);
    latest_tag = alloc.dupe(u8, ver) catch null;
    latest_dir = alloc.dupe(u8, dir) catch null;
    latest_app = app;
}

/// Путь к файлу текущего релиза (для HTTP /update/<name>). null — файла нет в релизе.
pub fn assetPath(name: []const u8) ?[:0]u8 {
    const dir = latest_dir orelse return null;
    if (!fileExists(dir, name)) return null;
    return joinZ(dir, name);
}

pub fn offerPayload(client_ver: u8, client_asset: ?[]const u8, musl: bool) ?[]u8 {
    if (latest_tag == null) return null;
    const ca = client_asset orelse return null;
    if (client_ver >= latest_app) return null;
    const dir = latest_dir orelse return null;
    const special = std.fmt.allocPrint(alloc, "{s}-{s}", .{ ca, if (musl) "musl" else "glibc" }) catch return null;
    defer alloc.free(special);
    const asset = if (fileExists(dir, special)) special else ca;
    if (!fileExists(dir, asset)) return null;
    return std.fmt.allocPrint(alloc, "{d}\n{s}", .{ latest_app, asset }) catch null;
}

pub fn threadMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        refresh();
        _ = c.sleep(6 * 3600);
    }
}
