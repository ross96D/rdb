const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = dependencies(b, target, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "rdb",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (deps) |ndep| {
        if (ndep) |dep| {
            lib.root_module.addImport(dep.name, dep.dep.module(dep.name));
        }
    }
    b.installArtifact(lib);

    const shared_lib = b.addStaticLibrary(.{
        .name = "rdb",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (deps) |ndep| {
        if (ndep) |dep| {
            shared_lib.root_module.addImport(dep.name, dep.dep.module(dep.name));
        }
    }

    b.installArtifact(shared_lib);
    _ = shared_lib.getEmittedH();

    const install_file = b.addInstallFile(b.path(".zig-cache/rdb.h"), "lib/rdb.h");
    install_file.step.dependOn(&shared_lib.step);
    b.getInstallStep().dependOn(&install_file.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const sanitize_thread = b.option(bool, "sanitize_thread", "Enable Thread Sanitizer");
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
        .sanitize_thread = if (sanitize_thread) |sanitize| sanitize else false,
    });
    for (deps) |ndep| {
        if (ndep) |dep| {
            lib_unit_tests.root_module.addImport(dep.name, dep.dep.module(dep.name));
        }
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    bench(b, lib, deps, target, optimize);
}

fn bench(
    b: *std.Build,
    rdb: *std.Build.Step.Compile,
    deps: []const ?Dep,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("test/bench.zig"),
        .optimize = optimize,
        .target = target,
    });
    for (deps) |ndep| {
        if (ndep) |dep| {
            // // not add already added deps
            // if (rdb.root_module.import_table.contains(dep.name)) {
            //     continue;
            // }
            exe.root_module.addImport(dep.name, dep.dep.module(dep.name));
        }
    }
    exe.root_module.addImport(rdb.name, &rdb.root_module);
    b.installArtifact(exe);
}

const Dep = struct {
    dep: *std.Build.Dependency,
    name: []const u8,
};

inline fn dependencies(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) []const ?Dep {
    const jdz_allocator = b.dependency("jdz_allocator", .{
        .target = target,
        .optimize = optimize,
    });
    const zart = b.dependency("zart", .{
        .target = target,
        .optimize = optimize,
    });
    const win32: ?*std.Build.Dependency = if (target.result.os.tag == .windows)
        b.dependency("win32", .{})
    else
        null;

    return &[_]?Dep{
        .{ .dep = jdz_allocator, .name = "jdz_allocator" },
        .{ .dep = zart, .name = "zart" },
        if (target.result.os.tag == .windows) .{ .dep = win32.?, .name = "win32" } else null,
    };
}
