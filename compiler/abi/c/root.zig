const diag = @import("../../diag/root.zig");
const source = @import("../../source/root.zig");
const typed = @import("../../typed/root.zig");
const types = @import("../../types/root.zig");

pub const name = "c";
pub const required = true;
pub const supported_calling_conventions = [_][]const u8{
    "c",
    "system",
};

pub fn validateImportedFunction(
    span: source.Span,
    has_body: bool,
    is_unsafe: bool,
    function: *const typed.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    if (!isSupportedConvention(function.abi)) {
        try diagnostics.add(.@"error", "abi.c.convention", span, "stage0 supports only extern[\"c\"] and extern[\"system\"]", .{});
    }

    if (has_body) {
        try diagnostics.add(.@"error", "abi.c.export.stage0", span, "stage0 does not yet lower foreign declarations with bodies", .{});
    }

    if (!is_unsafe) {
        try diagnostics.add(.@"error", "abi.c.import.unsafe", span, "imported foreign declarations must be #unsafe", .{});
    }

    if (!isCAbiSafeTypeRef(function.return_type)) {
        try diagnostics.add(.@"error", "abi.c.return", span, "foreign return type must be C ABI-safe in stage0", .{});
    }

    for (function.parameters.items, 0..) |parameter, index| {
        if (!isCAbiSafeTypeRef(parameter.ty)) {
            try diagnostics.add(.@"error", "abi.c.param_type", span, "foreign parameter {d} must be C ABI-safe in stage0", .{index + 1});
        }
        switch (parameter.mode) {
            .owned, .take => {},
            .read, .edit => try diagnostics.add(.@"error", "abi.c.param_mode", span, "stage0 foreign declarations accept only owned/take parameters", .{}),
        }
    }
}

pub fn isSupportedConvention(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    for (supported_calling_conventions) |convention| {
        if (@import("std").mem.eql(u8, value, convention)) return true;
    }
    return false;
}

pub fn isCAbiSafe(ty: types.Builtin) bool {
    return switch (ty) {
        .i32, .u32, .index => true,
        .unit, .bool, .str, .unsupported => false,
    };
}

pub fn isCAbiSafeTypeRef(ty: types.TypeRef) bool {
    return switch (ty) {
        .builtin => |builtin| isCAbiSafe(builtin),
        else => false,
    };
}
