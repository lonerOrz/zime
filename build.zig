const std = @import("std");

/// Build script for Zime IME Indicator
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root application module
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link required Windows system libraries
    root_mod.linkSystemLibrary("user32", .{});
    root_mod.linkSystemLibrary("gdi32", .{});
    root_mod.linkSystemLibrary("gdiplus", .{});
    root_mod.linkSystemLibrary("imm32", .{});
    root_mod.linkSystemLibrary("ole32", .{});
    root_mod.linkSystemLibrary("oleaut32", .{});
    root_mod.linkSystemLibrary("oleacc", .{});
    root_mod.linkSystemLibrary("advapi32", .{});
    root_mod.linkSystemLibrary("shell32", .{});

    // Embed application resource file
    root_mod.addWin32ResourceFile(.{
        .file = b.path("res/zime.rc"),
    });

    // Main executable definition
    const exe = b.addExecutable(.{
        .name = "zime",
        .root_module = root_mod,
    });

    // Windows GUI subsystem
    exe.subsystem = .Windows;

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Unit tests configuration
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
