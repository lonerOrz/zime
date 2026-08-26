const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;

    // Main executable definition
    const exe = b.addExecutable(.{
        .name = "zime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // Required for MinGW C headers in @cImport
            .strip = strip,
        }),
    });

    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("res/zime.rc"),
    });

    exe.subsystem = .Windows;

    // Link required Windows system libraries
    const system_libs = [_][]const u8{
        "user32",
        "gdi32",
        "gdiplus",
        "imm32",
        "shell32",
        "ole32",
        "oleaut32",
        "advapi32",
    };
    for (system_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    b.installArtifact(exe);

    // Target-agnostic unit tests for pure calculations
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/geometry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run pure calculation unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // i18n tests
    const i18n_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/i18n.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    test_step.dependOn(&run_i18n_tests.step);
}
