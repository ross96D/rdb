const std = @import("std");
const rdb = @import("rdb");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.posix.exit(1);
}

const help =
    \\I created this for profiling reasons mainly, not actually benchmark
    \\
    \\Usage:
    \\  bench [commad]
    \\
    \\Available Commands:
    \\  prepare  create the necessary artifacts for the run command 
    \\  run      run some workload to get usefull profiling metrics
    \\  clear    remove the artifacts created on the prepare command
;

var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = allocator_instance.allocator();
pub fn main() void {
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();

    // skip command argument
    _ = args.skip();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "prepare")) {
            return prepare() catch unreachable;
        } else if (std.mem.eql(u8, arg, "run")) {
            return run() catch unreachable;
        } else if (std.mem.eql(u8, arg, "clear")) {
            std.debug.print("clearing benchmark\n", .{});
        } else if (std.mem.eql(u8, arg, "help")) {
            std.debug.print(help ++ "\n", .{});
            std.posix.exit(1);
        } else if (std.mem.eql(u8, arg, "-h")) {
            std.debug.print(help ++ "\n", .{});
            std.posix.exit(1);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(help ++ "\n", .{});
            std.posix.exit(1);
        } else {
            fail("unknown argument {s}", .{arg});
        }
    }
    fail(help, .{});
}

const db_name = "db_bench_test";
const dir = "test";

fn prepare() !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, db_name });
    defer allocator.free(path);
    const dbr = rdb.open(rdb.Bytes{ .ptr = path.ptr, .len = path.len });
    if (dbr.database == null) {
        const ss: []const u8 = std.mem.span(dbr.err.?);
        @panic(ss);
    }
    const db = dbr.database.?;
    defer rdb.close(db);

    for (0..1_000_000) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(allocator, "val{d}", .{i});
        defer allocator.free(key);
        defer allocator.free(value);

        const v = rdb.set(
            db,
            .{ .len = key.len, .ptr = key.ptr },
            .{ .len = value.len, .ptr = value.ptr },
        );
        std.debug.assert(v);
    }
}

fn run() !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, db_name });

    const now = std.time.milliTimestamp();
    const dbr = rdb.open(.{ .ptr = path.ptr, .len = path.len });
    _ = dbr;
    std.debug.print("delay {d} ms\n", .{std.time.milliTimestamp() - now});
}
