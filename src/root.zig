const _root = @This();

const std = @import("std");
const db = @import("db.zig");
const builtin = @import("builtin");
const mode = builtin.mode;
const jdz = @import("jdz_allocator");

const global_allocator: std.mem.Allocator = allocator_instance.allocator();
var allocator_instance = switch (mode) {
    .Debug => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseFast => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseSmall => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseSafe => std.heap.GeneralPurposeAllocator(.{}){},
};

pub const DB = db.DB;

pub const Result = extern struct {
    database: ?*db.DB = null,
    err: ?[*:0]const u8 = null,
};

pub const Bytes = extern struct {
    ptr: [*]const u8,
    len: u64,
};

pub const OptionalBytes = extern struct {
    bytes: Bytes = undefined,
    valid: bool = false,
};

inline fn toSlice(ptr: [*]const u8, len: u64) []const u8 {
    var resp: []const u8 = &[_]u8{};
    resp.len = len;
    resp.ptr = ptr;
    return resp;
}

pub export fn rdb_open(path: Bytes) Result {
    const database = global_allocator.create(db.DB) catch unreachable;

    database.* = db.DB.init(global_allocator, toSlice(path.ptr, path.len)) catch |err| {
        const error_str = std.fmt.allocPrintZ(global_allocator, "{}", .{err}) catch unreachable;
        return Result{ .err = error_str.ptr };
    };
    return Result{ .database = database };
}

pub export fn rdb_close(database: *db.DB) void {
    database.deinit();
    global_allocator.destroy(database);
}

pub export fn rdb_get(database: *db.DB, key: Bytes) OptionalBytes {
    const val = database.search(toSlice(key.ptr, key.len)) catch {
        return OptionalBytes{};
    };
    if (val) |v| {
        return OptionalBytes{
            .bytes = .{
                .ptr = v.value.ptr,
                .len = v.value.len,
            },
            .valid = true,
        };
    } else {
        return OptionalBytes{};
    }
}

pub export fn rdb_set(database: *db.DB, key: Bytes, value: Bytes) bool {
    database.set(toSlice(key.ptr, key.len), toSlice(value.ptr, value.len), .{ .own = true }) catch {
        // TODO handle error
        return false;
    };
    return true;
}

pub export fn rdb_remove(database: *db.DB, key: Bytes) bool {
    database.delete(toSlice(key.ptr, key.len)) catch {
        // TODO handle error
        return false;
    };
    return true;
}

pub export fn rdb_foreach(database: *db.DB, caller_ctx_: *anyopaque, cfun: *const fn (*anyopaque, Bytes, Bytes) callconv(.C) bool) bool {
    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();
    const T = struct {
        fun: *const fn (*anyopaque, Bytes, Bytes) callconv(.C) bool,
        caller_ctx: *anyopaque,
    };
    const fun = struct {
        fn f(context: T, key: []const u8, value: []const u8) !bool {
            return context.fun(
                context.caller_ctx,
                .{ .ptr = key.ptr, .len = key.len },
                .{ .ptr = value.ptr, .len = value.len },
            );
        }
    }.f;
    const ctx = T{ .fun = cfun, .caller_ctx = caller_ctx_ };
    database.for_each(arena.allocator(), T, ctx, fun) catch {
        return false;
    };
    return true;
}

test "call" {
    std.testing.refAllDecls(_root);
    std.testing.refAllDecls(db);
    std.testing.refAllDecls(db.DB);
}
