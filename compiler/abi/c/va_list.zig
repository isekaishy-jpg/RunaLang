const std = @import("std");
const types = @import("../../types/root.zig");

pub const type_name = "CVaList";
pub const copy_callee = "__runa_c_va_copy";
pub const next_callee = "__runa_c_va_next";
pub const finish_callee = "__runa_c_va_finish";

pub fn isTypeName(raw: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), type_name);
}

pub fn localName(raw_parameter_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_parameter_name, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "...")) {
        return std.mem.trim(u8, trimmed["...".len..], " \t\r\n");
    }
    return trimmed;
}

pub fn variadicValueTypeNameSupported(raw_name: []const u8) bool {
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (name.len == 0) return false;
    const builtin = types.Builtin.fromName(name);
    if (builtin != .unsupported) {
        return switch (builtin) {
            .i32, .u32, .index, .isize => true,
            .unit, .bool, .str, .unsupported => false,
        };
    }
    if (types.CAbiAlias.fromName(name)) |alias| return alias != .c_void;
    if (std.mem.startsWith(u8, name, "*read ")) {
        return std.mem.trim(u8, name["*read ".len..], " \t\r\n").len != 0;
    }
    if (std.mem.startsWith(u8, name, "*edit ")) {
        return std.mem.trim(u8, name["*edit ".len..], " \t\r\n").len != 0;
    }
    return false;
}

pub fn isOperationCallee(callee: []const u8) bool {
    return std.mem.eql(u8, callee, copy_callee) or
        std.mem.eql(u8, callee, next_callee) or
        std.mem.eql(u8, callee, finish_callee);
}
