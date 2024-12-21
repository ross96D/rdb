const std = @import("std");
const zli = @import("zli");
const rdb = @import("rdb").DB;
const hex = @import("hex.zig");

const Args = struct {
    limit: usize,
    path: []const u8,

    pub fn format(self: Args, num: usize, buff: []u8) []u8 {
        const digits = std.math.log10_int(num) + 1;
        const total_digits = std.math.log10_int(self.limit) + 1;
        const diff = total_digits - digits;
        std.debug.assert(diff >= 0);
        for (0..diff) |i| {
            buff[i] = '0';
        }
        const numstr = std.fmt.bufPrint(buff[diff..], "{d}", .{num}) catch unreachable;
        return buff[0 .. diff + numstr.len];
    }
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var arena = std.heap.ArenaAllocator.init(gpa.allocator());
const allocator = arena.allocator();
var gbuffer: [100]u8 = undefined;

pub fn main() !void {
    defer arena.deinit();

    var iter = try std.process.ArgIterator.initWithAllocator(arena.allocator());
    const args = zli.parse(&iter, Args);

    try check_path(args.path);

    const ctx_t = struct {
        count: *usize,
        args: Args,
    };
    var count: usize = 0;
    const ctx_v: ctx_t = .{ .count = &count, .args = args };

    const fun = struct {
        fn f(ctx: ctx_t, key: []const u8, value: []const u8) !bool {
            const index = ctx.args.format(ctx.count.* + 1, &gbuffer);
            var _key: []const u8 = undefined;
            var _value: []const u8 = undefined;
            if (std.unicode.utf8ValidateSlice(key)) {
                _key = key;
            } else {
                const buffer = try allocator.alloc(u8, key.len * 2);
                hex.SimdHexEncode.encode(key, buffer);
                _value = buffer;
            }
            if (std.unicode.utf8ValidateSlice(value)) {
                _value = value;
            } else {
                const buffer = try allocator.alloc(u8, value.len * 2);
                hex.SimdHexEncode.encode(value, buffer);
                _value = value;
            }
            std.debug.print("{s} - key: {s} value: {s}\n", .{ index, _key, _value });
            ctx.count.* += 1;
            return ctx.count.* < ctx.args.limit;
        }
    }.f;

    var db = try rdb.init(allocator, args.path);
    try db.for_each(arena.allocator(), ctx_t, ctx_v, fun);

    return;
}

fn check_path(path: []const u8) !void {
    const stats = try std.fs.cwd().statFile(path);
    if (stats.kind != .file) {
        return error.NotAFile;
    }
}
