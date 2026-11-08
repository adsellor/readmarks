const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("markix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "markix",
        .root_module = root_module,
    });
    b.installArtifact(lib);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const format_check = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("src"),
        },
        .check = true,
    });
    const check_step = b.step("check", "Compile, test, and check formatting");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&run_unit_tests.step);
    check_step.dependOn(&format_check.step);
}
