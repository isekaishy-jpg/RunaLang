const const_ir = @import("const_ir.zig");
const session = @import("../session/root.zig");
const std = @import("std");
const typed = @import("../typed/root.zig");

pub const summary = "Query-owned const IR lowering and evaluation.";

pub const Resolver = *const fn (active: *session.Session, module_id: session.ModuleId, name: []const u8) anyerror!const_ir.Value;
pub const AssociatedResolver = *const fn (active: *session.Session, module_id: session.ModuleId, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value;

pub fn evalExpr(
    active: *session.Session,
    module_id: session.ModuleId,
    expr: *const const_ir.Expr,
    resolve_identifier: Resolver,
) anyerror!const_ir.Value {
    return evalExprWithAssociated(active, module_id, expr, resolve_identifier, null);
}

pub fn evalExprWithAssociated(
    active: *session.Session,
    module_id: session.ModuleId,
    expr: *const const_ir.Expr,
    resolve_identifier: Resolver,
    resolve_associated_const: ?AssociatedResolver,
) anyerror!const_ir.Value {
    return const_ir.evalExpr(active.allocator, EvalContext{
        .active = active,
        .module_id = module_id,
        .resolve_identifier = resolve_identifier,
        .resolve_associated_const = resolve_associated_const,
    }, expr, resolveIdentifier);
}

const EvalContext = struct {
    active: *session.Session,
    module_id: session.ModuleId,
    resolve_identifier: Resolver,
    resolve_associated_const: ?AssociatedResolver,

    pub fn structFieldName(self: EvalContext, type_name: []const u8, index: usize) ?[]const u8 {
        return structFieldNameFor(self, type_name, index);
    }

    pub fn enumPayloadFieldName(self: EvalContext, enum_name: []const u8, variant_name: []const u8, index: usize) ?[]const u8 {
        return enumPayloadFieldNameFor(self, enum_name, variant_name, index);
    }

    pub fn enumVariantTag(self: EvalContext, enum_name: []const u8, variant_name: []const u8) ?i32 {
        return enumVariantTagFor(self, enum_name, variant_name);
    }

    pub fn resolveAssociatedConst(self: EvalContext, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value {
        const resolver = self.resolve_associated_const orelse return error.UnknownConst;
        return resolver(self.active, self.module_id, owner_name, const_name);
    }
};

fn resolveIdentifier(context: EvalContext, name: []const u8) anyerror!const_ir.Value {
    return context.resolve_identifier(context.active, context.module_id, name);
}

fn structFieldNameFor(context: EvalContext, type_name: []const u8, index: usize) ?[]const u8 {
    const item = typeItem(context.active, context.module_id, type_name) orelse return null;
    return switch (item.payload) {
        .struct_type => |struct_type| if (index < struct_type.fields.len) struct_type.fields[index].name else null,
        else => null,
    };
}

fn enumPayloadFieldNameFor(context: EvalContext, enum_name: []const u8, variant_name: []const u8, index: usize) ?[]const u8 {
    const item = typeItem(context.active, context.module_id, enum_name) orelse return null;
    const enum_type = switch (item.payload) {
        .enum_type => |enum_type| enum_type,
        else => return null,
    };
    const variant = findEnumVariant(enum_type.variants, variant_name) orelse return null;
    return switch (variant.payload) {
        .none => null,
        .tuple_fields => |fields| if (index < fields.len) tuplePayloadFieldName(index) else null,
        .named_fields => |fields| if (index < fields.len) fields[index].name else null,
    };
}

fn enumVariantTagFor(context: EvalContext, enum_name: []const u8, variant_name: []const u8) ?i32 {
    const item = typeItem(context.active, context.module_id, enum_name) orelse return null;
    const enum_type = switch (item.payload) {
        .enum_type => |enum_type| enum_type,
        else => return null,
    };
    for (enum_type.variants, 0..) |variant, index| {
        if (std.mem.eql(u8, variant.name, variant_name)) return @intCast(index);
    }
    return null;
}

fn typeItem(active: *session.Session, module_id: session.ModuleId, type_name: []const u8) ?*const typed.Item {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (std.mem.eql(u8, item.name, type_name)) return item;
    }
    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, type_name)) continue;
        for (active.semantic_index.items.items, 0..) |_, index| {
            const item = active.item(.{ .index = index });
            if (item.category != .type_decl) continue;
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return item;
        }
    }
    return null;
}

fn findEnumVariant(variants: []const typed.EnumVariant, name: []const u8) ?typed.EnumVariant {
    for (variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

fn tuplePayloadFieldName(index: usize) []const u8 {
    return switch (index) {
        0 => "_0",
        1 => "_1",
        2 => "_2",
        3 => "_3",
        4 => "_4",
        5 => "_5",
        6 => "_6",
        7 => "_7",
        8 => "_8",
        9 => "_9",
        else => "_overflow",
    };
}
