const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The manifest is the one place the version is written down, so a
    // release bump cannot leave the binary reporting the last one.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const markix_dep = b.dependency("markix", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.addModule("readmarks", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Debug info is most of a self-hosted build's size and nothing a
        // released binary needs; a debug build keeps it.
        .strip = if (optimize == .debug) null else true,
    });
    root_module.addImport("markix", markix_dep.module("markix"));
    root_module.addOptions("build_options", options);

    const data_module = b.addModule("data", .{
        .root_source_file = b.path("src/data.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("data", data_module);

    // The self-hosted backend builds the whole program in a couple of
    // seconds where LLVM takes minutes, which is the difference between a
    // release being something you wait for and something you run. Off by
    // default so an ordinary build keeps LLVM's code generation.
    const no_llvm = b.option(
        bool,
        "no-llvm",
        "Build with Zig's own backend instead of LLVM",
    ) orelse false;

    const executable = b.addExecutable(.{
        .name = "readmarks",
        .root_module = root_module,
        .use_llvm = if (no_llvm) false else null,
        .use_lld = if (no_llvm) false else null,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run readmarks");
    run_step.dependOn(&run_command.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("markix", markix_dep.module("markix"));
    test_module.addImport("data", data_module);
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
    check_step.dependOn(&executable.step);
    check_step.dependOn(&run_unit_tests.step);
    check_step.dependOn(&format_check.step);
}
