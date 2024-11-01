const _root = @This();

const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");

const global_allocator: std.mem.Allocator = allocator_instance.allocator();
var allocator_instance = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};

pub const Result = extern struct {
    database: ?*db.DB = null,
    err: ?[*:0]const u8 = null,
};

fn copyCStr(allocator: std.mem.Allocator, ptr: [*:0]const u8) ![]const u8 {
    const slice = std.mem.span(ptr);
    const copy_slice: []u8 = try allocator.alloc(u8, slice.len);
    @memcpy(copy_slice, slice);
    return copy_slice;
}
fn copyCStrZ(allocator: std.mem.Allocator, ptr: [*:0]const u8) ![:0]const u8 {
    const slice = std.mem.span(ptr);
    const copy_slice: [:0]u8 = try allocator.allocSentinel(u8, slice.len, 0);
    @memcpy(copy_slice, slice);
    return copy_slice;
}

pub export fn create(path: [*:0]const u8) Result {
    const database = global_allocator.create(db.DB) catch unreachable;

    const slice_path = copyCStr(global_allocator, path) catch unreachable;
    database.* = db.DB.init(global_allocator, slice_path) catch |err| {
        const error_str = std.fmt.allocPrintZ(global_allocator, "{}", .{err}) catch unreachable;
        return Result{ .err = error_str.ptr };
    };
    return Result{ .database = database };
}

pub export fn insert(database: *db.DB, key: [*:0]const u8, value: [*:0]const u8) bool {
    const key_copy = copyCStrZ(global_allocator, key) catch unreachable;
    // ! TODO fix: I am never freeing the key_copy
    database.insert(key_copy, std.mem.span(value)) catch {
        // TODO handle error
        return false;
    };
    return true;
}

pub export fn update(database: *db.DB, key: [*:0]const u8, value: [*:0]const u8) bool {
    const key_copy = copyCStrZ(global_allocator, key) catch unreachable;
    defer global_allocator.free(key_copy);
    database.update(key_copy, std.mem.span(value)) catch {
        // TODO handle error
        return false;
    };
    return true;
}

pub export fn delete(database: *db.DB, key: [*:0]const u8) bool {
    const key_copy = copyCStrZ(global_allocator, key) catch unreachable;
    defer global_allocator.free(key_copy);
    database.delete(key_copy) catch {
        // TODO handle error
        return false;
    };
    return true;
}

test "call" {
    std.testing.refAllDecls(_root);
    std.testing.refAllDecls(db);
    std.testing.refAllDecls(db.DB);
}
