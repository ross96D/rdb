//! TODO build libs for the go bindings `zig build bindings:go`
//! TODO test go binding with go test
//! TODO update go binding repository

const std = @import("std");
const Shell = @import("shell.zig");
const log = std.log;
const assert = std.debug.assert;
const zli = @import("zli/src/zli.zig");

const VersionInfo = struct {
    // tag is the symbolic name of the release used as a git tag and a version for client libraries.
    // Normally, the tag and the release_triple match, but it is possible to have different tags
    // with matching release_triples, for hot-fixes.
    tag: []const u8,

    sha: []const u8,
};

const dist_path = "./zig-out/dist/";
const dist_path_go = dist_path ++ "go";

const CLIArgs = union(enum) {
    publish: struct {
        tag: []const u8,
        sha: []const u8,
        pub const help =
            \\ Command: publish
            \\ 
            \\ publish the selected binding
            \\
            \\ Usage: publish
            \\
            \\ publish --tag=v0.1.0 --sha=<value>
            \\
            \\ Options:
            \\
            \\ -h, --help               Displays this help message then exits
        ;
    },
    none: struct {},
};

pub fn main() !void {
    log.info("executing ci script", .{});

    // TODO make shure all the requirements are installed

    const shell = try Shell.create();

    var argiter = try std.process.ArgIterator.initWithAllocator(std.heap.page_allocator);
    defer argiter.deinit();

    const parsed_cli = zli.parse(&argiter, CLIArgs);
    switch (parsed_cli) {
        .publish => |command| {
            assert(!std.mem.eql(u8, command.sha, ""));
            assert(!std.mem.eql(u8, command.tag, ""));
            const info = VersionInfo{ .sha = command.sha, .tag = command.tag };
            try build_go(shell, &info);
            try test_go(shell);
            try publish_go(shell, &info);
        },
        .none => assert(false),
    }
}

fn test_go(shell: *Shell) !void {
    var section = try shell.open_section("go test");
    defer section.close();

    try shell.pushd(dist_path_go);
    defer shell.popd();

    const out = try shell.exec_stdout("go test ./...", .{});
    shell.echo("{s}", .{out});
}

fn build_go(shell: *Shell, info: *const VersionInfo) !void {
    var dist_dir = try shell.project_root.makeOpenPath(dist_path_go, .{});
    defer dist_dir.close();

    var section = try shell.open_section("build go");
    defer section.close();

    try shell.exec_zig("build bindings:go -Doptimize=ReleaseFast", .{});

    try shell.pushd("./bindings/go");
    defer shell.popd();

    const files = try shell.exec_stdout("git ls-files", .{});
    var files_lines = std.mem.tokenize(u8, files, "\n");
    while (files_lines.next()) |file| {
        assert(file.len > 3);
        try Shell.copy_path(shell.cwd, file, dist_dir, file);
        log.debug("copy git file {s} to {s}", .{
            try shell.realpath(shell.cwd, file),
            try shell.realpath(dist_dir, file),
        });
        assert(shell.file_exists(try shell.realpath(dist_dir, file)));
    }

    const native_files = try shell.find(.{ .where = &.{"."}, .extensions = &.{ ".a", ".lib", ".h" } });
    for (native_files) |native_file| {
        try Shell.copy_path(shell.cwd, native_file, dist_dir, native_file);
        log.debug("copy native file {s} to {s}", .{
            try shell.realpath(shell.cwd, native_file),
            try shell.realpath(dist_dir, native_file),
        });
        assert(shell.file_exists(try shell.realpath(dist_dir, native_file)));
    }

    const readme = try shell.fmt(
        \\# rdb-go
        \\This repo has been automatically generated from
        \\[ross96D/rdb@{[sha]s}](https://github.com/ross96D/rdb/commit/{[sha]s})
        \\to keep binary blobs out of the main repo.
        \\
        \\See <https://github.com/ross96D/rdb/tree/master/bindings/go>
    , .{ .sha = info.sha });
    try dist_dir.writeFile(.{ .sub_path = "README.md", .data = readme });
}

fn publish_go(shell: *Shell, info: *const VersionInfo) !void {
    var section = try shell.open_section("publish go");
    defer section.close();

    assert(try shell.dir_exists(dist_path_go));

    const token = try shell.env_get("GO_PAT");
    try shell.exec(
        \\git clone --no-checkout --depth 1
        \\  https://oauth2:{token}@github.com/ross96D/rdb-go.git rdb-go
    , .{ .token = token });
    defer {
        shell.project_root.deleteTree("rdb-go") catch {};
    }

    const dist_files = try shell.find(.{ .where = &.{"zig-out/dist/go"} });
    assert(dist_files.len > 10);
    for (dist_files) |file| {
        try Shell.copy_path(
            shell.project_root,
            file,
            shell.project_root,
            try std.mem.replaceOwned(
                u8,
                shell.arena.allocator(),
                file,
                dist_path_go,
                "rdb-go",
            ),
        );
    }

    try shell.pushd("./rdb-go");
    defer shell.popd();

    try shell.exec("git add .", .{});
    // Native libraries are ignored in this repository, but we want to push them to the
    // rdb-go one!
    try shell.exec("git add --force pkg/native", .{});

    try shell.git_env_setup();
    try shell.exec("git commit --message {message}", .{
        .message = try shell.fmt("Autogenerated commit from ci {s}", .{info.sha}),
    });

    try shell.exec("git tag v{tag}", .{ .tag = info.tag });

    try shell.exec("git push origin main", .{});
    try shell.exec("git push origin v{tag}", .{ .tag = info.tag });
}
