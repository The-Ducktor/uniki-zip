const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main module
    const mod = b.addModule("zip_test", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Create an executable
    const exe = b.addExecutable(.{
        .name = "zip_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zip_test", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Add memory_example executable
    const memory_exe = b.addExecutable(.{
        .name = "memory_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/memory_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zip_test", .module = mod },
            },
        }),
    });
    b.installArtifact(memory_exe);

    // WASM build
    const wasm_lib = b.addExecutable(.{
        .name = "uniki-zip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    wasm_lib.rdynamic = true;
    wasm_lib.entry = .disabled;
    b.installArtifact(wasm_lib);

    // Install files directory
    const install_files = b.addInstallDirectory(.{
        .source_dir = b.path("files"),
        .install_dir = .bin,
        .install_subdir = "files",
    });

    // Run step for main executable
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Run step for memory_example with files
    const memory_run_step = b.step("run-memory", "Run the memory example");
    const memory_run_cmd = b.addRunArtifact(memory_exe);
    memory_run_step.dependOn(&memory_run_cmd.step);
    memory_run_cmd.step.dependOn(b.getInstallStep());
    memory_run_cmd.step.dependOn(&install_files.step);
    if (b.args) |args| {
        memory_run_cmd.addArgs(args);
    }

    // Test executable for module
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.step.dependOn(b.getInstallStep());
    run_mod_tests.step.dependOn(&install_files.step);

    // Test executable for main executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());
    run_exe_tests.step.dependOn(&install_files.step);

    // Test step aggregates both test executables
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
