const std = @import("std");
pub const storage = @import("win32/storage.zig");
pub const zig = @import("win32/zig.zig");
test {
    @import("std").testing.refAllDecls(@This());
}

test "get_temp" {
    var ss: [500:0]u8 = undefined;
    const s = storage.file_system.GetTempPath2(500, &ss);
    std.debug.print("temp {s}\n", .{ss[0..s]});
}
