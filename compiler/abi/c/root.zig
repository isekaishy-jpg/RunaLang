pub const name = "c";
pub const required = true;
pub const va_list = @import("va_list.zig");
pub const supported_calling_conventions = [_][]const u8{
    "c",
    "system",
};
