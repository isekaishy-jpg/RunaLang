const std = @import("std");
const ast = @import("../ast/root.zig");
const attribute_support = @import("../attribute_support.zig");
const const_ir = @import("const_ir.zig");
const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const type_support = @import("type_support.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const typed = @import("../typed/root.zig");
const typed_text = @import("text.zig");
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
pub const AssociatedResolver = *const fn (active: *session.Session, module_id: session.ModuleId, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value;

pub fn validateSignature(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
) !Summary {
    var summary = Summary{};

    switch (checked.facts) {
        .function => |function| {
            for (function.parameters) |parameter| {
                const parameter_type_name = try ownedTypeNameForSyntaxOrRef(diagnostics.allocator, parameter.type_syntax, parameter.ty);
                defer diagnostics.allocator.free(parameter_type_name);
                try validateTypeName(active, checked.module_id, parameter_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
            }
            const return_type_name = try ownedTypeNameForSyntaxOrRef(diagnostics.allocator, function.return_type_syntax, function.return_type);
            defer diagnostics.allocator.free(return_type_name);
            try validateTypeName(active, checked.module_id, return_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .const_item => |const_item| {
            const type_name = try type_syntax_support.render(diagnostics.allocator, const_item.type_syntax);
            defer diagnostics.allocator.free(type_name);
            try validateTypeName(active, checked.module_id, type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .type_alias => |type_alias| {
            const target_type_name = try type_syntax_support.render(diagnostics.allocator, type_alias.target_type_syntax);
            defer diagnostics.allocator.free(target_type_name);
            try validateTypeName(active, checked.module_id, target_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .struct_type => |struct_type| for (struct_type.fields) |field| {
            const field_type_name = try type_syntax_support.render(diagnostics.allocator, field.type_syntax);
            defer diagnostics.allocator.free(field_type_name);
            try validateTypeName(active, checked.module_id, field_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .union_type => |union_type| for (union_type.fields) |field| {
            const field_type_name = try type_syntax_support.render(diagnostics.allocator, field.type_syntax);
            defer diagnostics.allocator.free(field_type_name);
            try validateTypeName(active, checked.module_id, field_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .enum_type => |enum_type| {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| for (fields) |field| {
                        const field_type_name = try type_syntax_support.render(diagnostics.allocator, field.type_syntax);
                        defer diagnostics.allocator.free(field_type_name);
                        try validateTypeName(active, checked.module_id, field_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
                    },
                    .named_fields => |fields| for (fields) |field| {
                        const field_type_name = try type_syntax_support.render(diagnostics.allocator, field.type_syntax);
                        defer diagnostics.allocator.free(field_type_name);
                        try validateTypeName(active, checked.module_id, field_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
                    },
                }
            }
            try validateEnumDiscriminants(active, checked, enum_type.variants, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .impl_block => |impl_block| {
            const target_type_name = try type_syntax_support.render(diagnostics.allocator, impl_block.target_type_syntax);
            defer diagnostics.allocator.free(target_type_name);
            try validateTypeName(active, checked.module_id, target_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
            for (impl_block.associated_types) |binding| {
                const binding_type_name = try type_syntax_support.render(diagnostics.allocator, binding.value_type_syntax);
                defer diagnostics.allocator.free(binding_type_name);
                try validateTypeName(active, checked.module_id, binding_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
            }
            for (impl_block.associated_consts) |binding| {
                const const_type_name = try type_syntax_support.render(diagnostics.allocator, binding.const_item.type_syntax);
                defer diagnostics.allocator.free(const_type_name);
                try validateTypeName(active, checked.module_id, const_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
            }
        },
        .trait_type => |trait_type| for (trait_type.associated_consts) |associated_const| {
            const associated_type_name = try type_syntax_support.render(diagnostics.allocator, associated_const.type_syntax);
            defer diagnostics.allocator.free(associated_type_name);
            try validateTypeName(active, checked.module_id, associated_type_name, checked.item.span, diagnostics, resolve_identifier, resolve_associated_const, &summary);
        },
        .opaque_type, .none => {},
    }

    try validateArrayLengthSites(active, checked, diagnostics, resolve_identifier, resolve_associated_const, &summary);

    return summary;
}

const ReprInteger = union(enum) {
    builtin: types.Builtin,
    c_alias: types.CAbiAlias,

    fn isInteger(self: ReprInteger) bool {
        return switch (self) {
            .builtin => |builtin| builtin.isInteger(),
            .c_alias => |alias| switch (alias) {
                .c_void, .c_bool => false,
                else => true,
            },
        };
    }

    fn stage0Builtin(self: ReprInteger) types.Builtin {
        return switch (self) {
            .builtin => |builtin| builtin,
            .c_alias => |alias| switch (alias) {
                .c_uint,
                .c_ulong,
                .c_ulong_long,
                .c_ushort,
                .c_unsigned_char,
                => .u32,
                .c_size => .index,
                .c_void, .c_bool => .unsupported,
                else => .i32,
            },
        };
    }
};

const ReprEnum = struct {
    has_repr: bool = false,
    int_type: ?ReprInteger = null,
};

fn validateEnumDiscriminants(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    variants: []const @import("../typed/root.zig").EnumVariant,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
    summary: *Summary,
) !void {
    const repr = try reprEnumInfo(active, checked.item.attributes);
    if (!repr.has_repr) {
        for (variants) |variant| {
            if (variant.discriminant_source != null) {
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

    const repr_type = repr.int_type orelse {
        summary.rejected_enum_discriminants += variants.len;
        try diagnostics.add(
            .@"error",
            "type.enum.repr_int",
            checked.item.span,
            "C-layout enum '{s}' requires #repr[c, IntType] with an integer representation",
            .{checked.item.name},
        );
        return;
    };
    if (!repr_type.isInteger()) {
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

        const discriminant = variant.discriminant_source orelse {
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
        const site = findConstRequiredExpr(checked.const_required_expr_sites, .enum_discriminant, variant.name, discriminant.text) orelse {
            summary.rejected_enum_discriminants += 1;
            try reportEnumDiscriminantError(diagnostics, checked.item.span, variant.name, discriminant.text, error.UnsupportedConstExpr);
            continue;
        };
        const value = evalEnumDiscriminant(active, checked.module_id, site, repr_type.stage0Builtin(), resolve_identifier, resolve_associated_const) catch |err| {
            summary.rejected_enum_discriminants += 1;
            try reportEnumDiscriminantError(diagnostics, checked.item.span, variant.name, discriminant.text, err);
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
                    .{ variant.name, discriminant.text },
                );
                break;
            }
        } else {
            try seen.append(value);
        }
    }
}

fn reprEnumInfo(active: *session.Session, attributes: []const ast.Attribute) !ReprEnum {
    _ = active;
    const repr = attribute_support.reprInfoForTarget(attributes, .enum_type);
    if (!repr.has_c and repr.integer_type_name == null) return .{};

    var result = ReprEnum{ .has_repr = true };
    if (!repr.has_c) return result;
    if (repr.integer_type_name) |name| {
        const builtin = types.Builtin.fromName(name);
        if (builtin.isInteger()) {
            result.int_type = .{ .builtin = builtin };
            return result;
        }
        if (types.CAbiAlias.fromName(name)) |alias| {
            result.int_type = .{ .c_alias = alias };
        }
    }
    return result;
}

fn ownedTypeNameForSyntaxOrRef(
    allocator: std.mem.Allocator,
    type_syntax: ?ast.TypeSyntax,
    ty: types.TypeRef,
) ![]const u8 {
    if (type_syntax) |syntax_value| return type_syntax_support.render(allocator, syntax_value);
    return type_support.renderTypeRef(allocator, ty);
}

fn evalEnumDiscriminant(
    active: *session.Session,
    module_id: session.ModuleId,
    site: query_types.ConstRequiredExprSite,
    result_type: types.Builtin,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
) !const_ir.Value {
    var value = try evalConstRequiredExpr(active, module_id, site, resolve_identifier, resolve_associated_const);
    defer const_ir.deinitValue(active.allocator, &value);
    return coerceIntegerValue(value, result_type);
}

fn findConstRequiredExpr(
    sites: []const query_types.ConstRequiredExprSite,
    kind: query_types.ConstRequiredExprKind,
    owner_name: []const u8,
    source_text: []const u8,
) ?query_types.ConstRequiredExprSite {
    for (sites) |site| {
        if (site.kind != kind) continue;
        if (!std.mem.eql(u8, site.owner_name, owner_name)) continue;
        if (!std.mem.eql(u8, site.source, source_text)) continue;
        return site;
    }
    return null;
}

fn validateTypeName(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
    summary: *Summary,
) anyerror!void {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t");
    if (trimmed.len == 0) return;

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse return;
        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return validateTypeName(active, module_id, rest["read ".len..], span, diagnostics, resolve_identifier, resolve_associated_const, summary);
        if (std.mem.startsWith(u8, rest, "edit ")) return validateTypeName(active, module_id, rest["edit ".len..], span, diagnostics, resolve_identifier, resolve_associated_const, summary);
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return validateTypeName(active, module_id, trimmed["read ".len..], span, diagnostics, resolve_identifier, resolve_associated_const, summary);
    if (std.mem.startsWith(u8, trimmed, "edit ")) return validateTypeName(active, module_id, trimmed["edit ".len..], span, diagnostics, resolve_identifier, resolve_associated_const, summary);

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse return;
        const element_type = std.mem.trim(u8, inner[0..separator], " \t");
        if (element_type.len != 0) {
            try validateTypeName(active, module_id, element_type, span, diagnostics, resolve_identifier, resolve_associated_const, summary);
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const args = try splitTopLevelCommaParts(active.allocator, trimmed[open_index + 1 .. close_index]);
        defer active.allocator.free(args);
        for (args) |arg| try validateTypeName(active, module_id, arg, span, diagnostics, resolve_identifier, resolve_associated_const, summary);
    }
}

fn validateArrayLengthSites(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
    summary: *Summary,
) !void {
    for (checked.const_required_expr_sites) |site| {
        if (site.kind != .array_length) continue;
        summary.checked_array_lengths += 1;
        _ = evalArrayLength(active, checked.module_id, site, resolve_identifier, resolve_associated_const) catch |err| {
            summary.rejected_array_lengths += 1;
            try reportArrayLengthError(diagnostics, checked.item.span, site.source, err);
        };
    }
}

fn evalArrayLength(
    active: *session.Session,
    module_id: session.ModuleId,
    site: query_types.ConstRequiredExprSite,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
) !usize {
    var value = try evalConstRequiredExpr(active, module_id, site, resolve_identifier, resolve_associated_const);
    defer const_ir.deinitValue(active.allocator, &value);
    return lengthValue(value);
}

fn evalConstRequiredExpr(
    active: *session.Session,
    module_id: session.ModuleId,
    site: query_types.ConstRequiredExprSite,
    resolve_identifier: Resolver,
    resolve_associated_const: AssociatedResolver,
) !const_ir.Value {
    const lowered = site.expr orelse return site.lower_error orelse error.UnsupportedConstExpr;

    return const_ir.evalExpr(active.allocator, EvalContext{
        .active = active,
        .module_id = module_id,
        .resolve_identifier = resolve_identifier,
        .resolve_associated_const = resolve_associated_const,
    }, lowered, resolveIdentifier);
}

const EvalContext = struct {
    active: *session.Session,
    module_id: session.ModuleId,
    resolve_identifier: Resolver,

    resolve_associated_const: AssociatedResolver,

    pub fn resolveAssociatedConst(self: EvalContext, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value {
        return self.resolve_associated_const(self.active, self.module_id, owner_name, const_name);
    }
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
        .array, .aggregate, .enum_value => false,
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
        error.AmbiguousAssociatedConst => try diagnostics.add(
            .@"error",
            "type.const.associated_ambiguous",
            span,
            "array length const expression '{s}' references an ambiguous associated const",
            .{length_expr},
        ),
        error.InvalidConversion => try diagnostics.add(
            .@"error",
            "type.const.conversion",
            span,
            "array length const expression '{s}' uses an invalid compile-time conversion",
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
        error.AmbiguousAssociatedConst => try diagnostics.add(
            .@"error",
            "type.const.associated_ambiguous",
            span,
            "enum variant '{s}' discriminant '{s}' references an ambiguous associated const",
            .{ variant_name, discriminant_expr },
        ),
        error.InvalidConversion => try diagnostics.add(
            .@"error",
            "type.const.conversion",
            span,
            "enum variant '{s}' discriminant '{s}' uses an invalid compile-time conversion",
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
