const std = @import("std");
const const_ir = @import("const_ir.zig");
const const_parse = @import("const_parse.zig");
const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const typed_text = @import("../typed/text.zig");
const types = @import("../types/root.zig");

const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub const Summary = struct {
    checked_array_lengths: usize = 0,
    rejected_array_lengths: usize = 0,
    checked_enum_discriminants: usize = 0,
    rejected_enum_discriminants: usize = 0,
};

pub const Resolver = *const fn (active: *session.Session, module_id: session.ModuleId, name: []const u8) anyerror!const_ir.Value;

pub fn validateSignature(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
) !Summary {
    var summary = Summary{};

    switch (checked.facts) {
        .function => |function| {
            for (function.parameters) |parameter| {
                try validateTypeName(active, checked.module_id, parameter.type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
            }
            try validateTypeName(active, checked.module_id, function.return_type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
        },
        .const_item => |const_item| try validateTypeName(active, checked.module_id, const_item.type_name, checked.item.span, diagnostics, resolve_identifier, &summary),
        .struct_type => |struct_type| for (struct_type.fields) |field| {
            try validateTypeName(active, checked.module_id, field.type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
        },
        .union_type => |union_type| for (union_type.fields) |field| {
            try validateTypeName(active, checked.module_id, field.type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
        },
        .enum_type => |enum_type| {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| for (fields) |field| {
                        try validateTypeName(active, checked.module_id, field.type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
                    },
                    .named_fields => |fields| for (fields) |field| {
                        try validateTypeName(active, checked.module_id, field.type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
                    },
                }
            }
            try validateEnumDiscriminants(active, checked, enum_type.variants, diagnostics, resolve_identifier, &summary);
        },
        .impl_block => |impl_block| {
            try validateTypeName(active, checked.module_id, impl_block.target_type, checked.item.span, diagnostics, resolve_identifier, &summary);
            for (impl_block.associated_types) |binding| {
                try validateTypeName(active, checked.module_id, binding.value_type_name, checked.item.span, diagnostics, resolve_identifier, &summary);
            }
        },
        .opaque_type, .trait_type, .none => {},
    }

    return summary;
}

const ReprEnum = struct {
    has_repr: bool = false,
    int_type: types.Builtin = .unsupported,
};

fn validateEnumDiscriminants(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    variants: []const @import("../typed/root.zig").EnumVariant,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    summary: *Summary,
) !void {
    const repr = try reprEnumInfo(active, checked.item.attributes);
    if (!repr.has_repr) {
        for (variants) |variant| {
            if (variant.discriminant != null) {
                summary.rejected_enum_discriminants += 1;
                try diagnostics.add(
                    .@"error",
                    "type.enum.discriminant_repr",
                    checked.item.span,
                    "enum variant '{s}' uses an explicit discriminant without #repr[c, IntType]",
                    .{variant.name},
                );
            }
        }
        return;
    }

    if (!repr.int_type.isInteger()) {
        summary.rejected_enum_discriminants += variants.len;
        try diagnostics.add(
            .@"error",
            "type.enum.repr_int",
            checked.item.span,
            "C-layout enum '{s}' requires #repr[c, IntType] with an integer representation",
            .{checked.item.name},
        );
        return;
    }

    var seen = std.array_list.Managed(const_ir.Value).init(active.allocator);
    defer seen.deinit();

    for (variants) |variant| {
        if (variant.payload != .none) {
            summary.rejected_enum_discriminants += 1;
            try diagnostics.add(
                .@"error",
                "type.enum.repr_payload",
                checked.item.span,
                "C-layout enum variant '{s}' must be a unit variant",
                .{variant.name},
            );
        }

        const discriminant = variant.discriminant orelse {
            summary.rejected_enum_discriminants += 1;
            try diagnostics.add(
                .@"error",
                "type.enum.discriminant_missing",
                checked.item.span,
                "C-layout enum variant '{s}' requires an explicit discriminant",
                .{variant.name},
            );
            continue;
        };

        summary.checked_enum_discriminants += 1;
        const value = evalEnumDiscriminant(active, checked.module_id, discriminant, repr.int_type, checked.item.span, diagnostics, resolve_identifier) catch |err| {
            summary.rejected_enum_discriminants += 1;
            try reportEnumDiscriminantError(diagnostics, checked.item.span, variant.name, discriminant, err);
            continue;
        };

        for (seen.items) |existing| {
            if (constValueEql(existing, value)) {
                summary.rejected_enum_discriminants += 1;
                try diagnostics.add(
                    .@"error",
                    "type.enum.discriminant_duplicate",
                    checked.item.span,
                    "C-layout enum variant '{s}' reuses discriminant '{s}'",
                    .{ variant.name, discriminant },
                );
                break;
            }
        } else {
            try seen.append(value);
        }
    }
}

fn reprEnumInfo(active: *session.Session, attributes: []const @import("../ast/root.zig").Attribute) !ReprEnum {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "repr")) continue;
        var result = ReprEnum{ .has_repr = true };
        const open_index = std.mem.indexOfScalar(u8, attribute.raw, '[') orelse return result;
        const close_index = std.mem.lastIndexOfScalar(u8, attribute.raw, ']') orelse return result;
        if (close_index <= open_index) return result;

        const parts = try splitTopLevelCommaParts(active.allocator, attribute.raw[open_index + 1 .. close_index]);
        defer active.allocator.free(parts);
        var saw_c = false;
        for (parts) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "c")) {
                saw_c = true;
                continue;
            }
            const builtin = types.Builtin.fromName(trimmed);
            if (builtin.isInteger()) {
                result.int_type = builtin;
                continue;
            }
        }
        if (!saw_c) result.int_type = .unsupported;
        return result;
    }
    return .{};
}

fn evalEnumDiscriminant(
    active: *session.Session,
    module_id: session.ModuleId,
    discriminant_expr: []const u8,
    result_type: types.Builtin,
    span: source.Span,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
) !const_ir.Value {
    _ = diagnostics;
    _ = span;
    const lowered = try const_parse.parseExpr(active.allocator, discriminant_expr, result_type);
    defer const_ir.destroyExpr(active.allocator, lowered);

    const value = try const_ir.evalExpr(EvalContext{
        .active = active,
        .module_id = module_id,
        .resolve_identifier = resolve_identifier,
    }, lowered, resolveIdentifier);
    return coerceIntegerValue(value, result_type);
}

fn validateTypeName(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    summary: *Summary,
) anyerror!void {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t");
    if (trimmed.len == 0) return;

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse return;
        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return validateTypeName(active, module_id, rest["read ".len..], span, diagnostics, resolve_identifier, summary);
        if (std.mem.startsWith(u8, rest, "edit ")) return validateTypeName(active, module_id, rest["edit ".len..], span, diagnostics, resolve_identifier, summary);
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return validateTypeName(active, module_id, trimmed["read ".len..], span, diagnostics, resolve_identifier, summary);
    if (std.mem.startsWith(u8, trimmed, "edit ")) return validateTypeName(active, module_id, trimmed["edit ".len..], span, diagnostics, resolve_identifier, summary);

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse return;
        const element_type = std.mem.trim(u8, inner[0..separator], " \t");
        const length_expr = std.mem.trim(u8, inner[separator + 1 ..], " \t");
        if (element_type.len != 0) {
            try validateTypeName(active, module_id, element_type, span, diagnostics, resolve_identifier, summary);
        }
        if (length_expr.len != 0) {
            summary.checked_array_lengths += 1;
            _ = evalArrayLength(active, module_id, length_expr, span, diagnostics, resolve_identifier) catch |err| {
                summary.rejected_array_lengths += 1;
                try reportArrayLengthError(diagnostics, span, length_expr, err);
            };
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const args = try splitTopLevelCommaParts(active.allocator, trimmed[open_index + 1 .. close_index]);
        defer active.allocator.free(args);
        for (args) |arg| try validateTypeName(active, module_id, arg, span, diagnostics, resolve_identifier, summary);
    }
}

fn evalArrayLength(
    active: *session.Session,
    module_id: session.ModuleId,
    length_expr: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
) !usize {
    _ = diagnostics;
    _ = span;
    const lowered = try const_parse.parseExpr(active.allocator, length_expr, .index);
    defer const_ir.destroyExpr(active.allocator, lowered);

    const value = try const_ir.evalExpr(EvalContext{
        .active = active,
        .module_id = module_id,
        .resolve_identifier = resolve_identifier,
    }, lowered, resolveIdentifier);
    return lengthValue(value);
}

const EvalContext = struct {
    active: *session.Session,
    module_id: session.ModuleId,
    resolve_identifier: Resolver,
};

fn resolveIdentifier(context: EvalContext, name: []const u8) anyerror!const_ir.Value {
    return context.resolve_identifier(context.active, context.module_id, name);
}

fn lengthValue(value: const_ir.Value) !usize {
    return switch (value) {
        .index => |length| length,
        .u32 => |length| @intCast(length),
        .i32 => |length| blk: {
            if (length < 0) return error.NegativeArrayLength;
            break :blk @intCast(length);
        },
        else => error.UnsupportedConstExpr,
    };
}

fn coerceIntegerValue(value: const_ir.Value, result_type: types.Builtin) !const_ir.Value {
    return switch (result_type) {
        .i32 => .{ .i32 = switch (value) {
            .i32 => |integer| integer,
            .u32 => |integer| blk: {
                if (integer > @as(u32, @intCast(std.math.maxInt(i32)))) return error.EnumDiscriminantOutOfRange;
                break :blk @intCast(integer);
            },
            .index => |integer| blk: {
                if (integer > @as(usize, @intCast(std.math.maxInt(i32)))) return error.EnumDiscriminantOutOfRange;
                break :blk @intCast(integer);
            },
            else => return error.UnsupportedConstExpr,
        } },
        .u32 => .{ .u32 = switch (value) {
            .i32 => |integer| blk: {
                if (integer < 0) return error.EnumDiscriminantOutOfRange;
                break :blk @intCast(integer);
            },
            .u32 => |integer| integer,
            .index => |integer| blk: {
                if (integer > @as(usize, @intCast(std.math.maxInt(u32)))) return error.EnumDiscriminantOutOfRange;
                break :blk @intCast(integer);
            },
            else => return error.UnsupportedConstExpr,
        } },
        .index => .{ .index = switch (value) {
            .i32 => |integer| blk: {
                if (integer < 0) return error.EnumDiscriminantOutOfRange;
                break :blk @intCast(integer);
            },
            .u32 => |integer| @intCast(integer),
            .index => |integer| integer,
            else => return error.UnsupportedConstExpr,
        } },
        else => error.UnsupportedConstExpr,
    };
}

fn constValueEql(lhs: const_ir.Value, rhs: const_ir.Value) bool {
    return switch (lhs) {
        .i32 => |value| switch (rhs) {
            .i32 => |other| other == value,
            else => false,
        },
        .u32 => |value| switch (rhs) {
            .u32 => |other| other == value,
            else => false,
        },
        .index => |value| switch (rhs) {
            .index => |other| other == value,
            else => false,
        },
        .bool => |value| switch (rhs) {
            .bool => |other| other == value,
            else => false,
        },
        .str => |value| switch (rhs) {
            .str => |other| std.mem.eql(u8, other, value),
            else => false,
        },
        .unit => switch (rhs) {
            .unit => true,
            else => false,
        },
        .unsupported => switch (rhs) {
            .unsupported => true,
            else => false,
        },
    };
}

fn reportArrayLengthError(diagnostics: *diag.Bag, span: source.Span, length_expr: []const u8, err: anyerror) !void {
    switch (err) {
        error.NegativeArrayLength => try diagnostics.add(
            .@"error",
            "type.const.array_length_negative",
            span,
            "array length const expression '{s}' evaluates to a negative value",
            .{length_expr},
        ),
        error.DivideByZero => try diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            span,
            "array length const expression '{s}' divides by zero during compile-time evaluation",
            .{length_expr},
        ),
        error.InvalidRemainder => try diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            span,
            "array length const expression '{s}' uses an invalid remainder operation",
            .{length_expr},
        ),
        error.InvalidShiftCount => try diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            span,
            "array length const expression '{s}' uses an invalid shift count",
            .{length_expr},
        ),
        error.ConstOverflow => try diagnostics.add(
            .@"error",
            "type.const.overflow",
            span,
            "array length const expression '{s}' overflows during compile-time evaluation",
            .{length_expr},
        ),
        error.QueryCycle => try diagnostics.add(
            .@"error",
            "type.const.cycle",
            span,
            "array length const expression '{s}' participates in cyclic const evaluation",
            .{length_expr},
        ),
        else => try diagnostics.add(
            .@"error",
            "type.const.array_length",
            span,
            "array length '{s}' is not a valid const Index expression",
            .{length_expr},
        ),
    }
}

fn reportEnumDiscriminantError(
    diagnostics: *diag.Bag,
    span: source.Span,
    variant_name: []const u8,
    discriminant_expr: []const u8,
    err: anyerror,
) !void {
    switch (err) {
        error.EnumDiscriminantOutOfRange, error.ConstOverflow => try diagnostics.add(
            .@"error",
            "type.const.enum_discriminant_range",
            span,
            "enum variant '{s}' discriminant '{s}' is out of range for its representation type",
            .{ variant_name, discriminant_expr },
        ),
        error.DivideByZero => try diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            span,
            "enum variant '{s}' discriminant '{s}' divides by zero during compile-time evaluation",
            .{ variant_name, discriminant_expr },
        ),
        error.InvalidRemainder => try diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            span,
            "enum variant '{s}' discriminant '{s}' uses an invalid remainder operation",
            .{ variant_name, discriminant_expr },
        ),
        error.InvalidShiftCount => try diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            span,
            "enum variant '{s}' discriminant '{s}' uses an invalid shift count",
            .{ variant_name, discriminant_expr },
        ),
        error.QueryCycle => try diagnostics.add(
            .@"error",
            "type.const.cycle",
            span,
            "enum variant '{s}' discriminant '{s}' participates in cyclic const evaluation",
            .{ variant_name, discriminant_expr },
        ),
        else => try diagnostics.add(
            .@"error",
            "type.const.enum_discriminant",
            span,
            "enum variant '{s}' discriminant '{s}' is not a valid const expression",
            .{ variant_name, discriminant_expr },
        ),
    }
}
