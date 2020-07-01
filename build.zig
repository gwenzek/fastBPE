const std = @import("std");
const Builder = std.build.Builder;
const BuildMode = std.builtin.Mode;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("fastBPE", "fastBPE/main.zig");
    exe.linkSystemLibrary("c");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const lib = b.addSharedLibrary("fastBPE_apply", "fastBPE/applyBPE.zig", b.version(0, 1, 0));
    lib.linkSystemLibrary("c");
    lib.setBuildMode(mode);
    lib.setOutputDir(".");
    lib.install();

    const run_step = b.step("run", "Run the app");
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // const sort_crash = b.addExecutable("fastBPE", "fastBPE/sort_crash.zig");
    // sort_crash.setTarget(target);
    // sort_crash.setBuildMode(mode);
    // sort_crash.install();

    // const sort_test = sort_crash.run();
    // sort_test.step.dependOn(b.getInstallStep());
    // run_step.dependOn(&sort_test.step);
}
