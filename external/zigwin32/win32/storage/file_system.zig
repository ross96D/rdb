// TODO: this type is limited to platform 'windows5.1.2600'
pub extern "kernel32" fn GetTempPathW(
    nBufferLength: u32,
    lpBuffer: ?[*:0]u16,
) callconv(@import("std").os.windows.WINAPI) u32;

// TODO: this type is limited to platform 'windows5.1.2600'
pub extern "kernel32" fn GetTempPathA(
    nBufferLength: u32,
    lpBuffer: ?[*:0]u8,
) callconv(@import("std").os.windows.WINAPI) u32;

pub extern "kernel32" fn GetTempPath2W(
    BufferLength: u32,
    Buffer: ?[*:0]u16,
) callconv(@import("std").os.windows.WINAPI) u32;

pub extern "kernel32" fn GetTempPath2A(
    BufferLength: u32,
    Buffer: ?[*:0]u8,
) callconv(@import("std").os.windows.WINAPI) u32;

//--------------------------------------------------------------------------------
// Section: Unicode Aliases (93)
//--------------------------------------------------------------------------------
const thismodule = @This();
pub usingnamespace switch (@import("../zig.zig").unicode_mode) {
    .ansi => struct {
        pub const GetTempPath = thismodule.GetTempPathA;
        pub const GetTempPath2 = thismodule.GetTempPath2A;
    },
    .wide => struct {
        pub const GetTempPath = thismodule.GetTempPathW;
        pub const GetTempPath2 = thismodule.GetTempPath2W;
    },
    .unspecified => if (@import("builtin").is_test) struct {
        pub const GetTempPath = *opaque {};
        pub const GetTempPath2 = *opaque {};
    } else struct {
        pub const GetTempPath = @compileError("'GetTempPath' requires that UNICODE be set to true or false in the root module");
        pub const GetTempPath2 = @compileError("'GetTempPath2' requires that UNICODE be set to true or false in the root module");
    },
};
