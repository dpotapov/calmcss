const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("calmcss", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // ReleaseFast keeps the CGO host binary fast (CalmCSS is CPU-heavy text
    // scanning + CSS rendering; ReleaseSmall is roughly 2-3x slower). The
    // size cost over ReleaseSmall is small (~hundreds of KB) and well worth
    // it on a host-side library. The wasm build below stays on ReleaseSmall
    // so the embeddable .wasm artifact stays compact.
    const static_lib_mod = b.addModule("calmcss_static", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .strip = true,
    });

    const static_lib = b.addLibrary(.{
        .name = "calmcss",
        .linkage = .static,
        .root_module = static_lib_mod,
    });
    static_lib.installHeader(b.path("include/calmcss.h"), "calmcss.h");
    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    b.getInstallStep().dependOn(&install_static_lib.step);

    const static_lib_install_name = if (target.result.os.tag == .windows) "calmcss.lib" else "libcalmcss.a";
    const cgo_archive = b.addSystemCommand(&.{
        "bash",
        "scripts/make-cgo-archive.sh",
        b.getInstallPath(.lib, static_lib_install_name),
        b.getInstallPath(.lib, "libcalmcss_cgo.a"),
        @tagName(target.result.os.tag),
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

    const release_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const release_tests = b.addTest(.{ .root_module = release_test_mod });
    const run_release_tests = b.addRunArtifact(release_tests);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_release_tests.step);
}
