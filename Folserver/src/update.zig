const std = @import("std");
const c = @import("c");
const zfmt = @import("zfmt");
const app = @import("protocol").VERSION;

const alloc = std.heap.c_allocator;
pub const DIR = "update";
const REPO = "folyan/Folassist";

pub var latest: ?[]u8 = null;

const Asset = struct { name: []const u8, browser_download_url: []const u8 };
const Release = struct { tag_name: []const u8, assets: []Asset = &.{} };

fn sh(cmd: []const u8) bool {
    const z = alloc.dupeSentinel(u8, cmd, 0) catch return false;
    defer alloc.free(z);
    return c.system(z.ptr) == 0;
}

fn wanted(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "folclient-") or std.mem.eql(u8, name, "sha256sums.txt") or std.mem.eql(u8, name, "sha256sums.txt.sig");
}

fn fileExists(name: []const u8) bool {
    const p = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ DIR, name }, 0) catch return false;
    defer alloc.free(p);
    return c.access(p.ptr, c.F_OK) == 0;
}

pub fn refresh() void {
    _ = c.mkdir(DIR, 0o755);
    if (!sh("curl -sfL -H 'Accept: application/vnd.github+json' -o update/latest.json https://api.github.com/repos/" ++ REPO ++ "/releases/latest")) return;
    const data = zfmt.readFile(c, alloc, "update/latest.json") catch return;
    defer alloc.free(data);
    const parsed = std.json.parseFromSlice(Release, alloc, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const ver = std.mem.trimStart(u8, parsed.value.tag_name, "v");
    if (latest) |old| {
        if (std.mem.eql(u8, old, ver)) return;
    }

    var ok = true;
    for (parsed.value.assets) |a| {
        if (!wanted(a.name)) continue;
        const cmd = std.fmt.allocPrint(alloc, "curl -sfL -o '{s}/{s}.part' '{s}' && mv -f '{s}/{s}.part' '{s}/{s}'", .{ DIR, a.name, a.browser_download_url, DIR, a.name, DIR, a.name }) catch return;
        defer alloc.free(cmd);
        if (!sh(cmd)) ok = false;
    }
    if (!ok) return;
    if (latest) |old| alloc.free(old);
    latest = alloc.dupe(u8, ver) catch null;
}

pub fn offerPayload(client_ver: u8, client_asset: ?[]const u8, musl: bool) ?[]u8 {
    if (latest == null) return null;
    const ca = client_asset orelse return null;
    if (client_ver >= app) return null;
    const special = std.fmt.allocPrint(alloc, "{s}-{s}", .{ ca, if (musl) "musl" else "glibc" }) catch return null;
    defer alloc.free(special);
    const asset = if (fileExists(special)) special else ca;
    return std.fmt.allocPrint(alloc, "{d}\n{s}", .{ app, asset }) catch null;
}

pub fn threadMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        refresh();
        _ = c.sleep(6 * 3600);
    }
}
