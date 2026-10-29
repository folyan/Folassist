const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .musl,
        },
    });

    const optimize = b.standardOptimizeOption(.{});
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(.{ .cwd_relative = "/usr/include" });

    const c_mod = translate_c.createModule();

    const exe = b.addExecutable(.{
        .name = "stt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("c", c_mod);

    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/lib" });

    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;

    exe.root_module.linkSystemLibrary("asound", .{});
    exe.root_module.linkSystemLibrary("vosk", .{});
    exe.root_module.linkSystemLibrary("piper", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the speech assistant");
    run_step.dependOn(&run_cmd.step);
}
