const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_mod = b.createModule(.{
        .root_source_file = b.path("../common/protocol.zig"),
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(.{ .cwd_relative = "/usr/include" });
    const c_mod = translate_c.createModule();

    const zfmt_mod = b.createModule(.{
        .root_source_file = b.path("../common/zfmt.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "folserver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("protocol", proto_mod);
    exe.root_module.addImport("zfmt", zfmt_mod);
    exe.root_module.addImport("c", c_mod);
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    exe.root_module.linkSystemLibrary("piper", .{});

    b.installArtifact(exe);
}
