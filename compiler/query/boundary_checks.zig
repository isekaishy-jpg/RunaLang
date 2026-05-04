const std = @import("std");
const attribute_support = @import("../attribute_support.zig");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const typed = @import("../typed/root.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");

pub const BoundaryKind = enum {
    none,
    api,
    value,
    capability,
};

pub fn kindForItem(item: *const typed.Item) BoundaryKind {
    const kind = attribute_support.boundaryKind(item.attributes) orelse return .none;
    return switch (kind) {
        .api => .api,
        .value => .value,
        .capability => .capability,
    };
}

pub fn validateItem(item: *const typed.Item, diagnostics: *diag.Bag) !void {
    var boundary_count: usize = 0;
    var first_kind: ?BoundaryKind = null;

    for (item.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "boundary")) continue;
        boundary_count += 1;
        if (boundaryKindForAttribute(attribute)) |kind| {
            if (first_kind == null) first_kind = kind;
        } else {
            try diagnostics.add(.@"error", "type.boundary.kind", attribute.span, "unsupported boundary attribute form on '#boundary[...]'", .{});
        }
    }

    if (boundary_count == 0) return;
    if (boundary_count > 1) {
        try diagnostics.add(.@"error", "type.boundary.duplicate", item.span, "a declaration may not carry multiple #boundary[...] attributes", .{});
    }

    if (item.visibility != .pub_item) {
        try diagnostics.add(.@"error", "type.boundary.visibility", item.span, "#boundary[...] is valid only on pub declarations", .{});
    }

    const kind = first_kind orelse return;
    switch (kind) {
        .none => unreachable,
        .api => switch (item.kind) {
            .function, .suspend_function => {},
            else => try diagnostics.add(.@"error", "type.boundary.api_target", item.span, "#boundary[api] is valid only on pub fn and pub suspend fn", .{}),
        },
        .value => switch (item.kind) {
            .struct_type, .enum_type => {},
            else => try diagnostics.add(.@"error", "type.boundary.value_target", item.span, "#boundary[value] is valid only on pub struct and pub enum", .{}),
        },
        .capability => switch (item.kind) {
            .opaque_type => {},
            else => try diagnostics.add(.@"error", "type.boundary.capability_target", item.span, "#boundary[capability] is valid only on pub opaque type", .{}),
        },
    }
}

pub fn validateSignature(active: *session.Session, checked: anytype, diagnostics: *diag.Bag, signature_resolver: anytype) anyerror!void {
    switch (checked.boundary_kind) {
        .none => return,
        .api => try validateApiSignature(active, checked, diagnostics, signature_resolver),
        .value => try validateValueFamily(active, checked, diagnostics, signature_resolver),
        .capability => {},
    }
}

fn boundaryKindForAttribute(attribute: @import("../ast/root.zig").Attribute) ?BoundaryKind {
    const attributes = [_]@import("../ast/root.zig").Attribute{attribute};
    const kind = attribute_support.boundaryKind(attributes[0..]) orelse return null;
    return switch (kind) {
        .api => .api,
        .value => .value,
        .capability => .capability,
    };
}

const BoundaryCategory = enum {
    transfer_safe,
    capability_safe,
    local_only,
};

fn validateApiSignature(active: *session.Session, checked: anytype, diagnostics: *diag.Bag, signature_resolver: anytype) anyerror!void {
    const function = switch (checked.facts) {
        .function => |function| function,
        else => return,
    };

    for (function.parameters) |parameter| {
        const boundary = type_support.boundaryFromParameter(parameter);
        if (parameter.mode == .read or parameter.mode == .edit or boundary.isBoundary()) {
            try diagnostics.add(
                .@"error",
                "type.boundary.api_param_mode",
                checked.item.span,
                "boundary API '{s}' parameter '{s}' must be an owned value",
                .{ checked.item.name, parameter.name },
            );
            continue;
        }

        const category = try classifyType(active, checked.module_id, parameter.ty, signature_resolver);
        if (category == .local_only) {
            const parameter_type_name = try type_support.renderTypeRef(diagnostics.allocator, parameter.ty);
            defer diagnostics.allocator.free(parameter_type_name);
            try diagnostics.add(
                .@"error",
                "type.boundary.api_param_type",
                checked.item.span,
                "boundary API '{s}' parameter '{s}' uses local-only type '{s}'",
                .{ checked.item.name, parameter.name, parameter_type_name },
            );
        }
    }

    if (try classifyType(active, checked.module_id, function.return_type, signature_resolver) == .local_only) {
        const return_type_name = try type_support.renderTypeRef(diagnostics.allocator, function.return_type);
        defer diagnostics.allocator.free(return_type_name);
        try diagnostics.add(
            .@"error",
            "type.boundary.api_return_type",
            checked.item.span,
            "boundary API '{s}' returns local-only type '{s}'",
            .{ checked.item.name, return_type_name },
        );
    }
}

fn validateValueFamily(active: *session.Session, checked: anytype, diagnostics: *diag.Bag, signature_resolver: anytype) anyerror!void {
    switch (checked.facts) {
        .struct_type => |struct_type| {
            for (struct_type.fields) |field| {
                if (try classifyType(active, checked.module_id, field.ty, signature_resolver) == .transfer_safe) continue;
                const field_type_name = try type_syntax_support.render(diagnostics.allocator, field.type_syntax);
                defer diagnostics.allocator.free(field_type_name);
                try diagnostics.add(
                    .@"error",
                    "type.boundary.value_member",
                    checked.item.span,
                    "boundary value family '{s}' contains non-transfer-safe member '{s}' of type '{s}'",
                    .{ checked.item.name, field.name, field_type_name },
                );
            }
        },
        .enum_type => |enum_type| {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| {
                        for (fields, 0..) |field, index| {
                            if (try classifyType(active, checked.module_id, field.ty, signature_resolver) == .transfer_safe) continue;
                            try diagnostics.add(
                                .@"error",
                                "type.boundary.value_member",
                                checked.item.span,
                                "boundary value family '{s}' contains non-transfer-safe payload {d} on variant '{s}'",
                                .{ checked.item.name, index, variant.name },
                            );
                        }
                    },
                    .named_fields => |fields| {
                        for (fields) |field| {
                            if (try classifyType(active, checked.module_id, field.ty, signature_resolver) == .transfer_safe) continue;
                            try diagnostics.add(
                                .@"error",
                                "type.boundary.value_member",
                                checked.item.span,
                                "boundary value family '{s}' contains non-transfer-safe payload '{s}' on variant '{s}'",
                                .{ checked.item.name, field.name, variant.name },
                            );
                        }
                    },
                }
            }
        },
        else => {},
    }
}

fn classifyType(
    active: *session.Session,
    module_id: session.ModuleId,
    ty: types.TypeRef,
    signature_resolver: anytype,
) anyerror!BoundaryCategory {
    const boundary = type_support.boundaryFromTypeRef(ty);
    if (boundary.isBoundary()) return .local_only;

    switch (ty) {
        .builtin => |builtin| return classifyBuiltin(builtin),
        .unsupported => return .local_only,
        .named => {},
    }

    const name = (try type_support.baseTypeNameFromTypeRef(active.allocator, ty)) orelse return .local_only;
    if (name.len == 0) return .local_only;
    if (std.mem.eql(u8, name, "Task")) return .local_only;

    const item_id = resolveTypeItemId(active, module_id, name) orelse return .local_only;
    const signature = try signature_resolver(active, item_id);
    if (signature.domain_signature != .none) return .local_only;
    return switch (signature.boundary_kind) {
        .value => .transfer_safe,
        .capability => .capability_safe,
        .api, .none => .local_only,
    };
}

fn classifyBuiltin(builtin: types.Builtin) BoundaryCategory {
    return switch (builtin) {
        .unit,
        .bool,
        .i32,
        .u32,
        .index,
        .isize,
        .str,
        => .transfer_safe,
        .unsupported => .local_only,
    };
}

fn resolveTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    if (findLocalTypeItemId(active, module_id, name)) |item_id| return item_id;

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        return findItemIdBySymbol(active, binding.target_symbol);
    }

    return null;
}

fn findLocalTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }
    return null;
}

fn findItemIdBySymbol(active: *const session.Session, symbol_name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.symbol_name, symbol_name)) return .{ .index = index };
    }
    return null;
}
