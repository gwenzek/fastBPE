const std = @import("std");
const Builder = std.build.Builder;
const BuildMode = std.builtin.Mode;

const TRACY_PATH = "./tracy/";

fn tryAddTracy(enabled: bool, target: anytype) void {
    target.addBuildOption(bool, "enable_tracy", enabled);

    if (!enabled) return;
    target.addIncludeDir(TRACY_PATH);
    target.addCSourceFile(
        TRACY_PATH ++ "TracyClient.cpp",
        &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" },
    );
    target.linkSystemLibraryName("c++");
    target.linkLibC();
}

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

    // Tracy integration
    // TODO: figure how to ready this option from Zig code.
    const enable_tracy = b.option(bool, "enable_tracy", "Enable Tracy profiling") orelse false;
    if (enable_tracy) {
        const tracy_dir = std.fs.cwd().openDir(TRACY_PATH, .{}) catch @panic("Tracy dir " ++ TRACY_PATH ++ "' not found.");
    }
    tryAddTracy(enable_tracy, exe);

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const lib = b.addSharedLibrary("fastBPE_apply", "fastBPE/applyBPE.zig", b.version(0, 2, 0));
    lib.linkSystemLibrary("c");
    lib.setBuildMode(mode);
    lib.setOutputDir(".");
    lib.install();
    tryAddTracy(enable_tracy, lib);

    const run_step = b.step("run", "Run the app");
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
}
