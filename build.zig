const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const art = b.dependency("art", .{
        .target = target,
        .optimize = optimize,
    });
    const jdz_allocator = b.dependency("jdz_allocator", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "rdb",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("art", art.module("art"));
    lib.root_module.addImport("jdz_allocator", jdz_allocator.module("jdz_allocator"));
    b.installArtifact(lib);
    // _ = lib.getEmittedH();

    const shared_lib = b.addStaticLibrary(.{
        .name = "rdb",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_lib.root_module.addImport("art", art.module("art"));
    shared_lib.root_module.addImport("jdz_allocator", jdz_allocator.module("jdz_allocator"));

    b.installArtifact(shared_lib);
    _ = shared_lib.getEmittedH();

    // const cache_root = b.cache_root.path orelse b.cache_root.join(b.allocator, &.{"."}) catch unreachable;
    // std.fs.path.dirname(cache_root);
    const install_file = b.addInstallFile(b.path(".zig-cache/rdb.h"), "lib/rdb.h");
    install_file.step.dependOn(&shared_lib.step);
    b.getInstallStep().dependOn(&install_file.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    lib_unit_tests.root_module.addImport("art", art.module("art"));
    lib_unit_tests.root_module.addImport("jdz_allocator", jdz_allocator.module("jdz_allocator"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
