const std = @import("std");

const db = @import("db.zig");

test "call" {
    std.testing.refAllDecls(db);
    std.testing.refAllDecls(db.DB);
}
