//! This is an slightly modified version of the shell.zig version of
//! [tigerbeetle](github.com/tigerbeetle/tigerbeetle) shell.zig that is under
//! the Apache License Version 2.0, January 2004 http://www.apache.org/licenses/.
//!
//!
//! Collection of utilities for scripting: an in-process sh+coreutils combo.
//!
//! Keep this as a single file, independent from the rest of the codebase, to make it easier to
//! reuse across different processes (eg build.zig).
//!
//! If possible, avoid shelling out to `sh` or other systems utils --- the whole purpose here is to
//! avoid any extra dependencies.
//!
//! The `exec_` family of methods provides a convenience wrapper around `std.process.Child`:
//!   - It allows constructing the array of arguments using convenient interpolation syntax a-la
//!     `std.fmt` (but of course no actual string concatenation happens anywhere).
//!   - `ChildProcess` is versatile and has many knobs, but they might be hard to use correctly (eg,
//!     its easy to forget to check exit status). `Shell` instead is focused on providing a set of
//!     specific narrow use-cases (eg, parsing the output of a subprocess) and takes care of setting
//!     the right defaults.

const std = @import("std");
const log = std.log;
const builtin = @import("builtin");
const assert = std.debug.assert;

const Shell = @This();

const cwd_stack_max = 16;

var _golbal_gpa: ?std.mem.Allocator = null;
var _gpa_alloc_struct = std.heap.GeneralPurposeAllocator(.{}){};
fn golbal_gpa() std.mem.Allocator {
    return if (_golbal_gpa) |gpa| gpa else {
        _golbal_gpa = _gpa_alloc_struct.allocator();
        return _golbal_gpa.?;
    };
}

/// To improve ergonomics, any returned data is owned by the `Shell` and is stored in this arena.
/// This way, the user doesn't need to worry about deallocating each individual string, as long as
/// they don't forget to call `Shell.destroy`.
arena: std.heap.ArenaAllocator,

/// Root directory of this repository.
project_root: std.fs.Dir,

/// Shell's logical cwd which is used for all functions in this file. It might be different from
/// `std.fs.cwd()` and is set to `project_root` on init.
cwd: std.fs.Dir,

// Stack of working directories backing pushd/popd.
cwd_stack: [cwd_stack_max]std.fs.Dir,
cwd_stack_count: usize,

// Zig uses file-descriptor oriented APIs in the standard library, with the one exception being
// ChildProcess's cwd, which is required to be a path, rather than a file descriptor. This buffer
// is used to materialize the path to cwd when spawning a new process.
//   <https://github.com/ziglang/zig/issues/5190>
cwd_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

env: std.process.EnvMap,

/// Absolute path to the Zig binary.
zig_exe: []const u8,

pub fn create() !*Shell {
    const gpa = golbal_gpa();
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var project_root = try discover_project_root();
    errdefer project_root.close();

    var cwd = try project_root.openDir(".", .{});
    errdefer cwd.close();

    var env = try std.process.getEnvMap(gpa);
    errdefer env.deinit();

    const result = try gpa.create(Shell);
    errdefer gpa.destroy(result);

    result.* = Shell{
        .arena = arena,
        .project_root = project_root,
        .cwd = cwd,
        .cwd_stack = undefined,
        .cwd_stack_count = 0,
        .env = env,
        .zig_exe = env.get("ZIG_EXE") orelse "zig",
    };

    return result;
}

pub fn destroy(shell: *Shell) void {
    const gpa = golbal_gpa();

    assert(shell.cwd_stack_count == 0); // pushd not paired by popd

    shell.env.deinit();
    shell.cwd.close();
    shell.project_root.close();
    shell.arena.deinit();
    gpa.destroy(shell);
}

const ansi = .{
    .red = "\x1b[0;31m",
    .reset = "\x1b[0m",
};

/// Prints formatted input to stderr.
/// Newline symbol is appended automatically.
/// ANSI colors are supported via `"{ansi-red}my colored text{ansi-reset}"` syntax.
pub fn echo(shell: *Shell, comptime format: []const u8, format_args: anytype) void {
    _ = shell;

    comptime var format_ansi: []const u8 = "";
    comptime var pos: usize = 0;
    comptime var pos_start: usize = 0;

    comptime next_pos: while (pos < format.len) {
        if (format[pos] == '{') {
            for (std.meta.fieldNames(@TypeOf(ansi))) |field_name| {
                const tag = "{ansi-" ++ field_name ++ "}";
                if (std.mem.startsWith(u8, format[pos..], tag)) {
                    format_ansi = format_ansi ++ format[pos_start..pos] ++ @field(ansi, field_name);
                    pos += tag.len;
                    pos_start = pos;
                    continue :next_pos;
                }
            }
        }
        pos += 1;
    };
    comptime assert(pos == format.len);

    format_ansi = format_ansi ++ format[pos_start..pos] ++ "\n";

    std.debug.print(format_ansi, format_args);
}

/// Opens a logical, named section of the script.
/// When the section is subsequently closed, its name and timing are printed.
/// Additionally on CI output from a section gets into a named, foldable group.
pub fn open_section(shell: *Shell, name: []const u8) !Section {
    _ = shell;
    return Section.open(name);
}

const Section = struct {
    name: []const u8,
    start: std.time.Instant,

    fn open(name: []const u8) !Section {
        const start = try std.time.Instant.now();
        // See
        // https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#grouping-log-lines
        // https://github.com/actions/toolkit/issues/1001
        try std.io.getStdOut().writer().print("::group::{s}\n", .{name});

        return .{
            .name = name,
            .start = start,
        };
    }

    pub fn close(section: *Section) void {
        if (std.time.Instant.now()) |now| {
            const elapsed_nanos = now.since(section.start);
            std.debug.print("{s}: {}\n", .{ section.name, std.fmt.fmtDuration(elapsed_nanos) });
        } else |_| {}

        std.io.getStdOut().writer().print("::endgroup::\n", .{}) catch {};
        section.* = undefined;
    }
};

/// Convenience string formatting function which uses shell's arena and doesn't require
/// freeing the resulting string.
pub fn fmt(shell: *Shell, comptime format: []const u8, format_args: anytype) ![]const u8 {
    return std.fmt.allocPrint(shell.arena.allocator(), format, format_args);
}

pub fn env_get_option(shell: *Shell, var_name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(shell.arena.allocator(), var_name) catch null;
}

pub fn env_get(shell: *Shell, var_name: []const u8) ![]const u8 {
    errdefer {
        log.warn("environment variable '{s}' not defined", .{var_name});
    }

    return try std.process.getEnvVarOwned(shell.arena.allocator(), var_name);
}

/// Change `shell`'s working directory. It *must* be followed by
///
///     defer shell.popd();
///
/// to restore the previous directory back.
pub fn pushd(shell: *Shell, path: []const u8) !void {
    assert(shell.cwd_stack_count < cwd_stack_max);
    // allow only explicitly relative paths or absolute paths
    assert(path[0] == '.' or path[0] == '/');

    const cwd_new = try shell.cwd.openDir(path, .{});

    shell.cwd_stack[shell.cwd_stack_count] = shell.cwd;
    shell.cwd_stack_count += 1;
    shell.cwd = cwd_new;
}

pub fn pushd_dir(shell: *Shell, dir: std.fs.Dir) !void {
    assert(shell.cwd_stack_count < cwd_stack_max);

    // Re-open the directory such that `popd` can close it.
    const cwd_new = try dir.openDir(".", .{});

    shell.cwd_stack[shell.cwd_stack_count] = shell.cwd;
    shell.cwd_stack_count += 1;
    shell.cwd = cwd_new;
}

pub fn popd(shell: *Shell) void {
    shell.cwd.close();
    shell.cwd_stack_count -= 1;
    shell.cwd = shell.cwd_stack[shell.cwd_stack_count];
}

/// Checks if the path exists and is a directory.
///
/// Note: this api is prone to TOCTOU and exists primarily for assertions.
pub fn dir_exists(shell: *Shell, path: []const u8) !bool {
    return subdir_exists(shell.cwd, path);
}

/// Checks if the path exists and is a file.
///
/// Note: this api is prone to TOCTOU and exists primarily for assertions.
pub fn file_exists(shell: *Shell, path: []const u8) bool {
    const stat = shell.cwd.statFile(path) catch return false;
    return stat.kind == .file;
}

/// **WARNING**: This function set perm to 777
pub fn file_make_executable(shell: *Shell, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        const fd = try shell.cwd.openFile(path, .{ .mode = .read_write });
        defer fd.close();

        try fd.chmod(0o777);
    }
}

fn subdir_exists(dir: std.fs.Dir, path: []const u8) !bool {
    const stat = dir.statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.IsDir => return true,
        else => return err,
    };

    return stat.kind == .directory;
}

pub fn file_ensure_content(
    shell: *Shell,
    path: []const u8,
    content: []const u8,
    create_flags: std.fs.File.CreateFlags,
) !enum { unchanged, updated } {
    const gpa = golbal_gpa();
    const max_bytes = 1024 * 1024;
    const content_current = shell.cwd.readFileAlloc(gpa, path, max_bytes) catch null;
    defer if (content_current) |slice| gpa.free(slice);

    if (content_current) |content_current_|
        if (std.mem.eql(u8, content_current_, content))
            return .unchanged;

    try shell.cwd.writeFile(.{ .sub_path = path, .data = content, .flags = create_flags });
    return .updated;
}

/// Creates a new temporary directory (in the project-level .zig-cache) and returns the
/// absolute path.
///
/// It's the callers responsibility to delete the directory when done with it, e.g.
/// with `defer shell.cwd.deleteTree(dir) catch {};`.
pub fn create_tmp_dir(shell: *Shell) ![]const u8 {
    const root = try shell.project_root.realpathAlloc(shell.arena.allocator(), ".");
    const tmp_absolute = try shell.fmt("{s}/.zig-cache/tmp/{}", .{
        root,
        std.crypto.random.int(u64),
    });
    assert(!try shell.dir_exists(tmp_absolute));
    try shell.project_root.makePath(tmp_absolute);
    return tmp_absolute;
}

const FindOptions = struct {
    where: []const []const u8,
    extension: ?[]const u8 = null,
    extensions: ?[]const []const u8 = null,
};

/// Analogue of the `find` utility, returns a set of paths matching filtering criteria.
///
/// **WARNING:** Only files are included in the returned paths
///
/// Returned slice is stored in `Shell.arena`.
pub fn find(shell: *Shell, options: FindOptions) ![]const []const u8 {
    const gpa = golbal_gpa();
    if (options.extension != null and options.extensions != null) {
        @panic("conflicting extension filters");
    }
    if (options.extension) |extension| {
        assert(extension[0] == '.');
    }
    if (options.extensions) |extensions| {
        for (extensions) |extension| {
            assert(extension[0] == '.');
        }
    }

    var result = std.ArrayList([]const u8).init(shell.arena.allocator());

    for (options.where) |base_path| {
        var base_dir = try shell.cwd.openDir(base_path, .{ .iterate = true });
        defer base_dir.close();

        var walker = try base_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and find_filter_path(entry.path, options)) {
                const full_path =
                    try std.fs.path.join(shell.arena.allocator(), &.{ base_path, entry.path });
                try result.append(full_path);
            }
        }
    }

    return result.items;
}

fn find_filter_path(path: []const u8, options: FindOptions) bool {
    if (options.extension == null and options.extensions == null) return true;
    if (options.extension != null and options.extensions != null) @panic("conflicting filters");

    if (options.extension) |extension| {
        return std.mem.endsWith(u8, path, extension);
    }

    if (options.extensions) |extensions| {
        for (extensions) |extension| {
            if (std.mem.endsWith(u8, path, extension)) return true;
        }
        return false;
    }

    unreachable;
}

/// Copy file, creating the destination directory as necessary.
pub fn copy_path(
    src_dir: std.fs.Dir,
    src_path: []const u8,
    dst_dir: std.fs.Dir,
    dst_path: []const u8,
) !void {
    errdefer {
        log.warn("failed to copy {s} to {s}", .{ src_path, dst_path });
    }
    if (std.fs.path.dirname(dst_path)) |dir| {
        try dst_dir.makePath(dir);
    }
    try src_dir.copyFile(src_path, dst_dir, dst_path, .{});
}

/// Runs the given command for side effects.
/// Returns an error if exit status is non-zero.
///
/// Supports interpolation using the following syntax:
///
/// ```
/// shell.exec("git branch {op} {branches}", .{
///     .op = "-D",
///     .branches = &.{"main", "feature"},
/// })
/// ```
pub fn exec(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    var argv = try Argv.expand(golbal_gpa(), cmd, cmd_args);
    defer argv.deinit();

    return exec_inner(shell, argv.slice(), .{});
}

pub fn exec_options(
    shell: *Shell,
    options: struct {
        stdin_slice: ?[]const u8 = null,
        timeout_ns: u64 = 10 * std.time.ns_per_min,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !void {
    var argv = try Argv.expand(golbal_gpa(), cmd, cmd_args);
    defer argv.deinit();

    return exec_inner(shell, argv.slice(), .{
        .stdin_slice = options.stdin_slice,
        .timeout_ns = options.timeout_ns,
    });
}

/// Runs the given command and returns its output.
/// If the output is a single line, the final newline is stripped.
pub fn exec_stdout(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) ![]const u8 {
    var argv = try Argv.expand(golbal_gpa(), cmd, cmd_args);
    defer argv.deinit();

    var captured_stdout: []const u8 = &.{};
    try exec_inner(shell, argv.slice(), .{
        .capture_stdout = &captured_stdout,
    });
    return captured_stdout;
}

pub fn exec_stdout_options(
    shell: *Shell,
    options: struct {
        stdin_slice: ?[]const u8 = null,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) ![]const u8 {
    var argv = try Argv.expand(golbal_gpa(), cmd, cmd_args);
    defer argv.deinit();

    var captured_stdout: []const u8 = &.{};
    try exec_inner(shell, argv.slice(), .{
        .stdin_slice = options.stdin_slice,
        .capture_stdout = &captured_stdout,
    });
    return captured_stdout;
}

/// Runs the zig compiler.
pub fn exec_zig(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    var argv = Argv.init(golbal_gpa());
    defer argv.deinit();

    try argv.append_new_arg("{s}", .{shell.zig_exe.?});
    try expand_argv(&argv, cmd, cmd_args);

    return shell.exec_inner(argv.slice(), .{});
}

fn exec_inner(
    shell: *Shell,
    argv: []const []const u8,
    options: struct {
        stdin_slice: ?[]const u8 = null,
        capture_stdout: ?*[]const u8 = null, // Optional out parameter.
        output_limit_bytes: usize = 128 * 1024 * 1024,
        timeout_ns: u64 = 10 * std.time.ns_per_min,
    },
) !void {
    const gpa = golbal_gpa();
    const argv_formatted = try std.mem.join(gpa, " ", argv);
    defer gpa.free(argv_formatted);

    var stdin_writer: ?std.Thread = null;
    defer if (stdin_writer) |thread| thread.join();

    const Streams = enum { stdout, stderr };
    var poller: ?std.io.Poller(Streams) = null;
    defer if (poller) |*p| p.deinit();

    errdefer |err| {
        log.err("process failed with {s}: {s}", .{ @errorName(err), argv_formatted });
        if (poller) |*p| {
            inline for (comptime std.enums.values(Streams)) |stream| {
                if (p.fifo(stream).count > 0) {
                    log.err("{s}:\n++++\n{s}++++\n", .{
                        @tagName(stream),
                        p.fifo(stream).readableSlice(0),
                    });
                }
            }
        }
    }

    var child = std.process.Child.init(argv, gpa);
    child.cwd = try shell.cwd.realpath(".", &shell.cwd_path_buffer);
    child.env_map = &shell.env;
    child.stdin_behavior = if (options.stdin_slice != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    if (options.stdin_slice) |stdin_slice| {
        stdin_writer = try write_stdin(&child, stdin_slice);
    }

    poller = std.io.poll(gpa, Streams, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });

    {
        defer inline for (comptime std.enums.values(Streams)) |stream| {
            assert(poller.?.fifo(stream).head == 0);
        };

        const deadline: i128 = std.time.nanoTimestamp() + options.timeout_ns;
        for (0..1_000_000) |_| {
            const timeout: i128 = deadline - std.time.nanoTimestamp();
            if (timeout <= 0) return error.ExecTimeout;
            if (!try poller.?.pollTimeout(@intCast(timeout))) break;
            inline for (comptime std.enums.values(Streams)) |stream| {
                if (poller.?.fifo(stream).count > options.output_limit_bytes) {
                    return error.StdoutStreamTooLong;
                }
            }
        } else @panic("exec: safety counter exceeded");
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ExecNonZeroExitStatus,
        else => return error.ExecFailed,
    }

    if (options.capture_stdout) |destination| {
        const stdout = poller.?.fifo(.stdout).readableSlice(0);
        const trailing_newline = if (std.mem.indexOf(u8, stdout, "\n")) |first_newline|
            first_newline == stdout.len - 1
        else
            false;
        const len_without_newline = stdout.len - @intFromBool(trailing_newline);
        destination.* = try shell.arena.allocator().dupe(u8, stdout[0..len_without_newline]);
    }
}

fn write_stdin(child: *std.process.Child, stdin: []const u8) !std.Thread {
    assert(child.stdin != null);
    defer child.stdin = null;

    // Spawn a thread to avoid deadlock between us writing to stdin and reading from stdout.
    return try std.Thread.spawn(
        .{},
        struct {
            fn write_stdin(destination: std.fs.File, source: []const u8) void {
                defer destination.close();

                destination.writeAll(source) catch {};
            }
        }.write_stdin,
        .{ child.stdin.?, stdin },
    );
}

/// Run the command and return its status, stderr and stdout.
/// The caller is responsible for checking the status.
pub fn exec_raw(
    shell: *Shell,
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.Child.RunResult {
    var argv = try Argv.expand(golbal_gpa(), cmd, cmd_args);
    defer argv.deinit();

    return try std.process.Child.run(.{
        .allocator = shell.arena.allocator(),
        .argv = argv.slice(),
        .cwd = try shell.cwd.realpath(".", &shell.cwd_path_buffer),
        .env_map = &shell.env,
    });
}

pub fn spawn(
    shell: *Shell,
    options: struct {
        stdin_behavior: std.process.Child.StdIo = .Ignore,
        stdout_behavior: std.process.Child.StdIo = .Ignore,
        stderr_behavior: std.process.Child.StdIo = .Ignore,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.Child {
    const gpa = golbal_gpa();

    var argv = try Argv.expand(gpa, cmd, cmd_args);
    defer argv.deinit();

    var child = std.process.Child.init(argv.slice(), gpa);
    child.cwd = try shell.cwd.realpath(".", &shell.cwd_path_buffer);
    child.env_map = &shell.env;
    child.stdin_behavior = options.stdin_behavior;
    child.stdout_behavior = options.stdout_behavior;
    child.stderr_behavior = options.stderr_behavior;
    try child.spawn();

    return child;
}

/// On GitHub Actions runners, `git commit` fails with an "Author identity unknown" error.
///
/// This function sets up appropriate environmental variables to correct that error.
pub fn git_env_setup(shell: *Shell) !void {
    try shell.env.put("GIT_AUTHOR_NAME", "main repo ci");
    try shell.env.put("GIT_COMMITTER_NAME", "main repo ci");

    try shell.env.put("GIT_AUTHOR_EMAIL", "ci@repo.com");
    try shell.env.put("GIT_COMMITTER_EMAIL", "ci@repo.com");
}

const Argv = struct {
    args: std.ArrayList([]const u8),

    fn init(gpa: std.mem.Allocator) Argv {
        return Argv{ .args = std.ArrayList([]const u8).init(gpa) };
    }

    fn expand(gpa: std.mem.Allocator, comptime cmd: []const u8, cmd_args: anytype) !Argv {
        var result = Argv.init(gpa);
        errdefer result.deinit();
        try expand_argv(&result, cmd, cmd_args);
        return result;
    }

    fn deinit(argv: *Argv) void {
        for (argv.args.items) |arg| argv.args.allocator.free(arg);
        argv.args.deinit();
    }

    fn slice(argv: *Argv) []const []const u8 {
        return argv.args.items;
    }

    fn append_new_arg(argv: *Argv, comptime arg_fmt: []const u8, arg: anytype) !void {
        const arg_owned = try std.fmt.allocPrint(
            argv.args.allocator,
            arg_fmt,
            arg,
        );
        errdefer argv.args.allocator.free(arg_owned);

        try argv.args.append(arg_owned);
    }

    fn extend_last_arg(argv: *Argv, comptime arg_fmt: []const u8, arg: anytype) !void {
        assert(argv.args.items.len > 0);
        const arg_allocated = try std.fmt.allocPrint(
            argv.args.allocator,
            "{s}" ++ arg_fmt,
            .{argv.args.items[argv.args.items.len - 1]} ++ arg,
        );
        argv.args.allocator.free(argv.args.items[argv.args.items.len - 1]);
        argv.args.items[argv.args.items.len - 1] = arg_allocated;
    }
};

/// Expands `cmd` into an array of command arguments, substituting values from `cmd_args`.
///
/// This avoids shell injection by construction as it doesn't concatenate strings.
fn expand_argv(argv: *Argv, comptime cmd: []const u8, cmd_args: anytype) !void {
    @setEvalBranchQuota(5_000);
    // Mostly copy-paste from std.fmt.format

    comptime var pos: usize = 0;
    // std.fmt.format()

    // These two variables track the spaces around `{}` syntax.
    comptime var concat_left: bool = false;
    comptime var concat_right: bool = false;

    const arg_count = std.meta.fields(@TypeOf(cmd_args)).len;
    comptime var args_used = std.StaticBitSet(arg_count).initEmpty();
    comptime assert(std.mem.indexOf(u8, cmd, "'") == null); // Quoting isn't supported yet.
    comptime assert(std.mem.indexOf(u8, cmd, "\"") == null);
    inline while (pos < cmd.len) {
        inline while (pos < cmd.len and (cmd[pos] == ' ' or cmd[pos] == '\n')) {
            pos += 1;
        }

        const pos_start = pos;
        inline while (pos < cmd.len) : (pos += 1) {
            switch (cmd[pos]) {
                ' ', '\n', '{' => break,
                else => {},
            }
        }

        const pos_end = pos;
        if (pos_start != pos_end) {
            if (concat_right) {
                assert(pos_start > 0 and cmd[pos_start - 1] == '}');
                try argv.extend_last_arg("{s}", .{cmd[pos_start..pos_end]});
            } else {
                try argv.append_new_arg("{s}", .{cmd[pos_start..pos_end]});
            }
        }

        concat_left = false;
        concat_right = false;

        if (pos >= cmd.len) break;
        if (cmd[pos] == ' ' or cmd[pos] == '\n') continue;

        comptime assert(cmd[pos] == '{');
        concat_left = pos > 0 and cmd[pos - 1] != ' ' and cmd[pos - 1] != '\n';
        if (concat_left) assert(argv.slice().len > 0);
        pos += 1;

        const pos_arg_start = pos;
        inline while (pos < cmd.len and cmd[pos] != '}') : (pos += 1) {}
        const pos_arg_end = pos;

        if (pos >= cmd.len) @compileError("Missing closing }");

        comptime assert(cmd[pos] == '}');
        concat_right = pos + 1 < cmd.len and cmd[pos + 1] != ' ' and cmd[pos + 1] != '\n';
        pos += 1;

        const arg_name = comptime cmd[pos_arg_start..pos_arg_end];
        const arg_or_slice = @field(cmd_args, arg_name);
        comptime args_used.set(for (std.meta.fieldNames(@TypeOf(cmd_args)), 0..) |field, index| {
            if (std.mem.eql(u8, field, arg_name)) break index;
        } else unreachable);

        const T = @TypeOf(arg_or_slice);

        if (@typeInfo(T) == .Int or @typeInfo(T) == .ComptimeInt) {
            if (concat_left) {
                try argv.extend_last_arg("{d}", .{arg_or_slice});
            } else {
                try argv.append_new_arg("{d}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == u8) {
            if (concat_left) {
                try argv.extend_last_arg("{s}", .{arg_or_slice});
            } else {
                try argv.append_new_arg("{s}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == []const u8) {
            if (concat_left or concat_right) @compileError("Can't concatenate slices");
            for (arg_or_slice) |arg_part| {
                try argv.append_new_arg("{s}", .{arg_part});
            }
        } else {
            @compileError("Unsupported argument type");
        }
    }

    comptime if (args_used.count() != arg_count) @compileError("Unused argument");
}

/// Finds the root of the repo.
///
/// Caller is responsible for closing the dir.
fn discover_project_root() !std.fs.Dir {
    var current: ?std.fs.Dir = null;
    while (true) {
        current = if (current) |c| try c.openDir("..", .{}) else std.fs.cwd();

        if (current.?.statFile("bindings/shell.zig")) |_| {
            return current.?;
        } else |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        }
    }
}

test "ref_all" {
    std.testing.refAllDecls(@This());
}
