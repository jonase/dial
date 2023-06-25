const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dial",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    exe.linkLibC();
    exe.linkSystemLibrary("curl");
    exe.addIncludePath("./include");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const zig_example_plugin = b.addSharedLibrary(.{
        .name = "zig-example-plugin",
        .root_source_file = .{ .path = "./example/zig-example-plugin.zig" },
        .target = target,
        .optimize = optimize,
    });

    zig_example_plugin.addIncludePath("./include");
    b.installArtifact(zig_example_plugin);

    const c_example_plugin = b.addSharedLibrary(.{
        .name = "c-example-plugin",
        .root_source_file = .{ .path = "./example/c-example-plugin.c" },
        .target = target,
        .optimize = optimize,
    });

    c_example_plugin.addIncludePath("./include");
    b.installArtifact(c_example_plugin);
}
