const std = @import("std");
const types = @import("../types/root.zig");

pub const summary = "Explicit raw-pointer surface helpers.";

pub const Access = enum {
    read,
    edit,
};

pub const Parts = struct {
    access: Access,
    pointee: []const u8,
};

pub const address_read_callee = "__runa_raw_address_read";
pub const address_edit_callee = "__runa_raw_address_edit";
pub const is_null_callee = "__runa_raw_is_null";
pub const cast_callee = "__runa_raw_cast";
pub const offset_callee = "__runa_raw_offset";
pub const load_callee = "__runa_raw_load";
pub const store_callee = "__runa_raw_store";

pub fn parse(raw: []const u8) ?Parts {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "*read ")) return .{
        .access = .read,
        .pointee = std.mem.trim(u8, trimmed["*read ".len..], " \t\r\n"),
    };
    if (std.mem.startsWith(u8, trimmed, "*edit ")) return .{
        .access = .edit,
        .pointee = std.mem.trim(u8, trimmed["*edit ".len..], " \t\r\n"),
    };
    return null;
}

pub fn makeTypeName(allocator: std.mem.Allocator, access: Access, pointee: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{
        switch (access) {
            .read => "*read",
            .edit => "*edit",
        },
        std.mem.trim(u8, pointee, " \t\r\n"),
    });
}

pub fn isLeafCallee(raw: []const u8) bool {
    return std.mem.eql(u8, raw, address_read_callee) or
        std.mem.eql(u8, raw, address_edit_callee) or
        std.mem.eql(u8, raw, is_null_callee) or
        std.mem.eql(u8, raw, cast_callee) or
        std.mem.eql(u8, raw, offset_callee) or
        std.mem.eql(u8, raw, load_callee) or
        std.mem.eql(u8, raw, store_callee);
}

pub fn isMemorySafePointeeName(raw: []const u8) bool {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    const builtin = types.Builtin.fromName(name);
    if (builtin != .unsupported) return switch (builtin) {
        .i32, .u32, .index, .isize => true,
        .unit, .bool, .str, .unsupported => false,
    };
    if (types.CAbiAlias.fromName(name)) |alias| return alias != .c_void;
    return parse(name) != null;
}
