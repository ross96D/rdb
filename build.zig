const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------- Obtain all dependencies of this project --------------------------
    const deps = dependencies(b, target, optimize);

    // -------------------------- Creates a step for static library build --------------------------
    const lib = b.addStaticLibrary(.{
        .name = "rdb",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    Dep.apply_deps(deps, &lib.root_module);
    b.installArtifact(lib);

    // -------------------------- Creates a step for shared library build --------------------------
    const shared_lib = b.addStaticLibrary(.{
        .name = "rdb",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    Dep.apply_deps(deps, &shared_lib.root_module);

    b.installArtifact(shared_lib);

    // -------------------------- Fast check if compiles --------------------------
    check(b, b.step("check", "check if compiles"), .{ .deps = deps, .target = target, .optimize = optimize });

    // -------------------------- test run or build --------------------------
    run_tests(b, b.step("test", "run tests"), b.step("test:build", "build test"), .{
        .deps = deps,
        .target = target,
        .optimize = optimize,
    });
}

/// fast compile check for easy development
fn check(
    b: *std.Build,
    step_check: *std.Build.Step,
    opts: struct {
        deps: []const ?Dep,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    const lib = b.addStaticLibrary(.{
        .name = "rdb",
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    Dep.apply_deps(opts.deps, &lib.root_module);
    step_check.dependOn(&lib.step);
}

fn run_tests(
    b: *std.Build,
    run_test_step: *std.Build.Step,
    build_test_step: *std.Build.Step,
    opts: struct {
        deps: []const ?Dep,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
) void {
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const sanitize_thread = b.option(bool, "sanitize_thread", "Enable Thread Sanitizer");
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .test_runner = b.path("test_runner.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .filters = test_filters,
        .sanitize_thread = if (sanitize_thread) |sanitize| sanitize else false,
    });
    Dep.apply_deps(opts.deps, &lib_unit_tests.root_module);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.has_side_effects = true;

    run_test_step.dependOn(&run_lib_unit_tests.step);
    build_test_step.dependOn(&b.addInstallArtifact(lib_unit_tests, .{}).step);
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
    Dep.apply_deps(deps, &exe.root_module);
    exe.root_module.addImport(rdb.name, &rdb.root_module);
    b.installArtifact(exe);
}

const Dep = struct {
    dep: *std.Build.Dependency,
    import_name: []const u8,
    module_name: []const u8,

    pub fn init(dep: *std.Build.Dependency, name: []const u8) Dep {
        return Dep{ .dep = dep, .import_name = name, .module_name = name };
    }

    pub fn init_with_mod_name(dep: *std.Build.Dependency, import_name: []const u8, mod_name: []const u8) Dep {
        return Dep{ .dep = dep, .import_name = import_name, .module_name = mod_name };
    }

    pub fn apply(self: Dep, mod: *std.Build.Module) void {
        mod.addImport(self.import_name, self.dep.module(self.module_name));
    }

    pub fn apply_deps(deps: []const ?Dep, mod: *std.Build.Module) void {
        for (deps) |ndep| {
            if (ndep) |dep| {
                dep.apply(mod);
            }
        }
    }
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
        Dep.init(jdz_allocator, "jdz_allocator"),
        Dep.init(zart, "zart"),
        if (target.result.os.tag == .windows) Dep.init(win32.?, "win32") else null,
    };
}
