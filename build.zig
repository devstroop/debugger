const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "debugger",
        .root_module = exe_module,
    });
    // Required on macOS for system symbols (fork, exit, getcwd, etc.)
    if (target.result.os.tag == .macos) {
        exe.linkLibC();
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run debugger");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ────────────────────────────────────────────────────

    const test_step = b.step("test", "Run debugger unit tests");

    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .macos) {
        t.linkLibC();
    }
    const run_t = b.addRunArtifact(t);
    test_step.dependOn(&run_t.step);
}
