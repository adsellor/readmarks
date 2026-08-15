const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const web_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const web_markix_dep = b.dependency("markix", .{
        .target = web_target,
        .optimize = .ReleaseSmall,
    });
    const web_module = b.createModule(.{
        .root_source_file = b.path("src/web_main.zig"),
        .target = web_target,
        .optimize = .ReleaseSmall,
        .pic = true,
    });
    web_module.addImport("markix", web_markix_dep.module("markix"));
    const web_data_module = b.createModule(.{
        .root_source_file = b.path("src/data.zig"),
        .target = web_target,
        .optimize = .ReleaseSmall,
    });
    web_module.addImport("data", web_data_module);
    const web_lib = b.addLibrary(.{
        .name = "readmarks-web",
        .root_module = web_module,
        .linkage = .dynamic,
    });
    const install_wasm = b.addInstallArtifact(web_lib, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "readmarks.wasm",
    });
    const install_html = b.addInstallFileWithDir(
        b.path("web/index.html"),
        .{ .custom = "web" },
        "index.html",
    );
    const install_glue = b.addInstallFileWithDir(
        b.path("web/glue.js"),
        .{ .custom = "web" },
        "glue.js",
    );
    const install_serve = b.addInstallFileWithDir(
        b.path("web/serve.js"),
        .{ .custom = "web" },
        "serve.js",
    );
    const web_step = b.step("web", "Build the wasm demo and web assets");
    web_step.dependOn(&install_wasm.step);
    web_step.dependOn(&install_html.step);
    web_step.dependOn(&install_glue.step);
    web_step.dependOn(&install_serve.step);
}
