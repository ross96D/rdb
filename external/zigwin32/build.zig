const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("win32", .{
        .root_source_file = b.path("win32.zig"),
    });
    _ = mod;
}
