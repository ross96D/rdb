const std = @import("std");

pub const SimdHexEncode = struct {
    const SimdHexTable: @Vector(16, u8) = .{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };
    const va: @Vector(16, u3) = @splat(@as(u8, 4));
    const vf: @Vector(16, u8) = @splat(@as(u8, 15));

    pub fn encode(bytes: []const u8, hexed: []u8) void {
        std.debug.assert(hexed.len == bytes.len * 2);

        var i: usize = 0;
        while (bytes.len - i >= 16) {
            const vec: @Vector(16, u8) = .{
                bytes[i + 0],  bytes[i + 1],  bytes[i + 2],  bytes[i + 3],
                bytes[i + 4],  bytes[i + 5],  bytes[i + 6],  bytes[i + 7],
                bytes[i + 8],  bytes[i + 9],  bytes[i + 10], bytes[i + 11],
                bytes[i + 12], bytes[i + 13], bytes[i + 14], bytes[i + 15],
            };
            const a = vec >> va;
            const b = vec & vf;
            const final = std.simd.interlace(.{ a, b });
            for (@as([32]u8, final), 0..) |tindex, hindex| {
                hexed[i * 2 + hindex] = SimdHexTable[tindex];
            }
            i += 16;
        }
        while (i < bytes.len) {
            const byte = bytes[i];
            const a = SimdHexTable[byte >> 4];
            const b = SimdHexTable[byte & 0x0f];
            hexed[i * 2] = a;
            hexed[i * 2 + 1] = b;
            i += 1;
        }
    }
};

pub const HexEncode = struct {
    const HexTable = "0123456789ABCDEF";

    pub fn encode(bytes: []const u8, hexed: []u8) void {
        std.debug.assert(hexed.len == bytes.len * 2);
        for (bytes, 0..) |byte, i| {
            const a = HexTable[byte >> 4];
            const b = HexTable[byte & 0x0f];
            hexed[i * 2] = a;
            hexed[i * 2 + 1] = b;
        }
    }
};

test "bench_hex" {
    const data: []const u8 = try std.testing.allocator.alloc(u8, 1000000);
    const buff: []u8 = try std.testing.allocator.alloc(u8, 2000000);
    defer {
        std.testing.allocator.free(data);
        std.testing.allocator.free(buff);
    }
    var timer = try std.time.Timer.start();
    HexEncode.encode(data, buff);
    const normal = timer.read();
    std.debug.print("normal hex took {d} nanoseconds\n", .{normal});
    timer.reset();
    SimdHexEncode.encode(data, buff);
    const simd = timer.read();
    std.debug.print("simd hex took {d} nanoseconds\n", .{simd});
}

test "encode" {
    const bytes = "asdasdjadkhadhgkasfdgusyfgasfdhsadfasdasdjadkhadhgkasfdgusyfgasfdhsadf";
    var hex: [bytes.len * 2]u8 = undefined;
    SimdHexEncode.encode(bytes, &hex);
    // HexEncode.encode("zig", &hex);
    std.testing.expectEqualDeep(
        &hex,
        @as(
            []const u8,
            @ptrCast("6173646173646A61646B68616468676B617366646775737966676173666468736164666173646173646A61646B68616468676B61736664677573796667617366646873616466"),
        ),
    ) catch |err| {
        std.debug.print(
            "expected {s}\ngot      {s}\n",
            .{
                "6173646173646A61646B68616468676B617366646775737966676173666468736164666173646173646A61646B68616468676B61736664677573796667617366646873616466",
                &hex,
            },
        );
        return err;
    };
}
