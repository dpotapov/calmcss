const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const compat_snapshots = b.option(bool, "compat-snapshots", "Include generated Tailwind compatibility snapshots in CLI/test builds") orelse true;
    const production_snapshots = b.option(bool, "production-snapshots", "Include generated Tailwind compatibility snapshots in installed static library and WASM artifacts") orelse false;

    const lib_mod = b.addModule("calmcss", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    addCalmOptions(b, lib_mod, compat_snapshots);

    const exe = b.addExecutable(.{
        .name = "calmcss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "calmcss", .module = lib_mod }},
        }),
    });
    b.installArtifact(exe);

    const static_lib_mod = b.addModule("calmcss_static", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    addCalmOptions(b, static_lib_mod, production_snapshots);

    const static_lib = b.addLibrary(.{
        .name = "calmcss",
        .linkage = .static,
        .root_module = static_lib_mod,
    });
    static_lib.installHeader(b.path("include/calmcss.h"), "calmcss.h");
    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    b.getInstallStep().dependOn(&install_static_lib.step);

    const cgo_archive = b.addSystemCommand(&.{
        "sh",
        "scripts/make-cgo-archive.sh",
        b.getInstallPath(.lib, "libcalmcss.a"),
        b.getInstallPath(.lib, "libcalmcss_cgo.a"),
    });
    cgo_archive.step.dependOn(&install_static_lib.step);
    b.getInstallStep().dependOn(&cgo_archive.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    addCalmOptions(b, wasm_mod, production_snapshots);
    const wasm = b.addExecutable(.{
        .name = "calmcss",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    wasm.initial_memory = 4 * 1024 * 1024;
    wasm.max_memory = 64 * 1024 * 1024;
    b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
        .dest_sub_path = "calmcss.wasm",
    }).step);

    const run_step = b.step("run", "Run the CalmCSS CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const production_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    addCalmOptions(b, production_test_mod, false);
    const production_tests = b.addTest(.{ .root_module = production_test_mod });
    const run_production_tests = b.addRunArtifact(production_tests);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_production_tests.step);
}

fn addCalmOptions(b: *std.Build, module: *std.Build.Module, compat_snapshots: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "compat_snapshots", compat_snapshots);
    module.addOptions("calmcss_options", options);
}
