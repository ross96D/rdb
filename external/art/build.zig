const std = @import("std");
const Builder = std.Build;

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("art", .{
        .root_source_file = b.path("src/art.zig"),
        .target = target,
        .optimize = optimize,
    });

    // const exe = b.addExecutable(.{
    //     .name = "art",
    //     .root_source_file = b.path("src/main.zig"),
    //     .optimize = optimize,
    //     .target = target,
    // });
    // exe.linkLibC();
    // exe.root_module.addImport("art", mod);

    // const install = b.addInstallArtifact(exe, .{});
    // b.getInstallStep().dependOn(&install.step);

    var tests = b.addTest(.{
        .root_source_file = b.path("src/test_art.zig"),
        .optimize = optimize,
        .target = target,
        .filters = if (b.option([]const u8, "test-filter", "test filter")) |opt| &.{opt} else &.{},
    });
    tests.root_module.addImport("art", mod);

    const test_step = b.step("test", "Run library tests");
    const main_tests_run = b.addRunArtifact(tests);
    main_tests_run.has_side_effects = true;
    test_step.dependOn(&main_tests_run.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench2.zig"),
        .optimize = .ReleaseFast,
        .target = target,
    });
    bench.root_module.addImport("art", mod);
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Bench against std.StringHashMap()");
    bench_step.dependOn(&bench_run.step);
}
