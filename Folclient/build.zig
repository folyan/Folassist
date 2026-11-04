const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});
    const libs = b.option([]const u8, "libs", "папка с libsherpa_fat.a, libasound.a и c-api.h") orelse "vendor/lib";
    const include = b.option([]const u8, "include", "папка с alsa/asoundlib.h") orelse "/usr/include";
    const extra_libs = b.option([]const u8, "extra-libs", "через запятую полные пути к libstdc++.a, libgcc.a (и libgcc_eh.a)");

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.graph.cwdRelativePath(libs));
    translate_c.addIncludePath(b.graph.cwdRelativePath(include));

    const exe = b.addExecutable(.{
        .name = "folclient",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const root = exe.root_module;
    root.addImport("protocol", b.createModule(.{ .root_source_file = b.path("../common/protocol.zig") }));
    root.addImport("zfmt", b.createModule(.{ .root_source_file = b.path("../common/zfmt.zig") }));
    root.addImport("pubkey", b.createModule(.{ .root_source_file = b.path("../common/pubkey.zig") }));
    root.addImport("c", translate_c.createModule());

    root.addObjectFile(b.graph.cwdRelativePath(b.fmt("{s}/libsherpa_fat.a", .{libs})));
    root.addObjectFile(b.graph.cwdRelativePath(b.fmt("{s}/libasound.a", .{libs})));

    if (extra_libs) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            root.addObjectFile(b.graph.cwdRelativePath(path));
        }
    }

    b.installArtifact(exe);

    const watchdog = b.addExecutable(.{
        .name = "folwatchdog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/watchdog.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(watchdog);
}
