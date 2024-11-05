const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Owned(T: type) type {
    const tinfo = @typeInfo(T);
    const isSlice: bool = switch (tinfo) {
        .Pointer => |info| switch (info.size) {
            .One => false,
            .Slice => true,
            else => @compileError("type can only be a pointer or an slice"),
        },
        else => @compileError("type can only be a pointer or an slice"),
    };

    return struct {
        const Self = @This();

        allocator: Allocator,
        value: T,

        pub fn init(allocator: Allocator, value: T) Self {
            return .{ .allocator = allocator, .value = value };
        }

        pub fn deinit(self: Self) void {
            if (isSlice) {
                self.allocator.free(self.value);
            } else {
                self.allocator.destroy(self.value);
            }
        }
    };
}

test Owned {
    const a = std.testing.allocator;

    const val = try a.create(u32);
    var ownu32 = Owned(*u32).init(a, val);
    ownu32.deinit();

    const slice = try a.alloc(u64, 549);
    var ownslice = Owned([]u64).init(a, slice);
    ownslice.deinit();
}

pub inline fn tempDir() !std.fs.Dir {
    const path: []const u8 = switch (builtin.os.tag) {
        .windows => @compileError("TODO support temp dir on windows"),
        else => if (std.posix.getenv("TMPDIR")) |path| path else "/tmp",
    };
    return std.fs.openDirAbsolute(path, .{});
}

test tempDir {
    var tempdir = try tempDir();
    defer tempdir.close();
    var buff: [256]u8 = undefined;
    const path = try tempdir.realpath(".", &buff);
    std.debug.print("tmp: {s}\n", .{path});
}

const chars_size = 'z' - 'a';
const chars = r: {
    var c: [chars_size]u8 = undefined;
    for ('a'..'z', 0..) |value, i| {
        c[i] = value;
    }
    break :r c;
};

pub inline fn randomWord(comptime size: usize, word: *[size]u8) []const u8 {
    var DefaultPrng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
        break :blk seed;
    });
    return createRandomWord(size, word, DefaultPrng.random());
}

pub inline fn randomWordZ(comptime size: usize, word: *[size:0]u8) [:0]const u8 {
    var DefaultPrng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
        break :blk seed;
    });
    return createRandomWordZ(size, word, DefaultPrng.random());
}

pub inline fn createRandomWord(comptime size: usize, word: *[size]u8, rand: std.Random) []const u8 {
    for (0..size) |i| {
        const char_index = rand.intRangeLessThan(usize, 0, chars_size);
        word[i] = chars[char_index];
    }
    return word[0..];
}

pub inline fn createRandomWordZ(comptime size: usize, word: *[size:0]u8, rand: std.Random) [:0]const u8 {
    word[size] = 0;

    for (0..size) |i| {
        const char_index = rand.intRangeLessThan(usize, 0, chars_size);
        word[i] = chars[char_index];
    }

    return word[0..];
}
