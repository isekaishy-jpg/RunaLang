const std = @import("std");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const typed = @import("../typed/root.zig");
const callee_helpers = @import("callee_helpers.zig");
const boundary_checks = @import("boundary_checks.zig");
const query_types = @import("types.zig");
const typed_domain_state = @import("../typed/domain_state.zig");
const type_support = @import("../typed/type_support.zig");
const typed_text = @import("../typed/text.zig");
const types = @import("../types/root.zig");

const parseBoundaryType = type_support.parseBoundaryType;
const baseTypeName = typed_text.baseTypeName;

pub const DomainTypeRef = struct {
    item_id: session.ItemId,
    kind: Kind,

    pub const Kind = enum {
        root,
        context,
    };
};

const Anchor = typed_domain_state.Anchor;
const AnchorAccess = typed_domain_state.AnchorAccess;

pub fn signatureForItem(
    active: *const session.Session,
    module_id: session.ModuleId,
    item: *const typed.Item,
    facts: query_types.SignatureFacts,
) typed_domain_state.ItemSignature {
    if (item.kind != .struct_type) return .none;
    if (!item.is_domain_root and !item.is_domain_context) return .none;

    const struct_type = switch (facts) {
        .struct_type => |struct_type| struct_type,
        else => return .none,
    };

    if (item.is_domain_context) {
        const anchor = singleValidAnchor(active, module_id, item.name, struct_type.fields, false, true);
        if (anchor) |root_anchor| return .{ .context = .{ .root_anchor = root_anchor } };
        return .none;
    }

    const parent_anchor = singleValidAnchor(active, module_id, item.name, struct_type.fields, true, false);
    return .{ .root = .{ .parent_anchor = parent_anchor } };
}

pub fn validateSignature(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    diagnostics: *diag.Bag,
) !void {
    const item = checked.item;
    try validateDomainDeclaration(active, checked, diagnostics);

    if (checked.domain_signature != .none and checked.boundary_kind == .value) {
        try diagnostics.add(
            .@"error",
            "type.domain_state.boundary_attr",
            item.span,
            "#{s} declaration '{s}' may not also carry a boundary attribute",
            .{
                if (item.is_domain_root) "domain_root" else "domain_context",
                item.name,
            },
        );
    }

    if (checked.boundary_kind != .api) return;

    const function = switch (checked.facts) {
        .function => |function| function,
        else => return,
    };

    for (function.parameters) |parameter| {
        if (classifyTypeName(active, checked.module_id, parameter.type_name)) |domain_ref| {
            try diagnostics.add(
                .@"error",
                "type.domain_state.boundary_param",
                item.span,
                "boundary API '{s}' may not accept {s} '{s}' in its signature",
                .{
                    item.name,
                    kindLabel(domain_ref.kind),
                    baseTypeName(parseBoundaryType(parameter.type_name).inner_type_name),
                },
            );
        }
    }

    if (classifyTypeName(active, checked.module_id, function.return_type_name)) |domain_ref| {
        try diagnostics.add(
            .@"error",
            "type.domain_state.boundary_return",
            item.span,
            "boundary API '{s}' may not return {s} '{s}'",
            .{
                item.name,
                kindLabel(domain_ref.kind),
                baseTypeName(parseBoundaryType(function.return_type_name).inner_type_name),
            },
        );
    }
}

fn validateDomainDeclaration(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    diagnostics: *diag.Bag,
) !void {
    const item = checked.item;
    if (item.kind != .struct_type) return;
    if (!item.is_domain_root and !item.is_domain_context) return;

    const struct_type = switch (checked.facts) {
        .struct_type => |struct_type| struct_type,
        else => return,
    };

    if (item.is_domain_root) {
        try validateRootDeclaration(active, checked, struct_type.generic_params, struct_type.fields, diagnostics);
    }
    if (item.is_domain_context) {
        try validateContextDeclaration(active, checked, struct_type.fields, diagnostics);
    }
}

fn validateRootDeclaration(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    generic_params: []const typed.GenericParam,
    fields: []const typed.StructField,
    diagnostics: *diag.Bag,
) !void {
    var valid_anchor_count: usize = 0;
    var invalid_anchor_count: usize = 0;

    for (fields) |field| {
        const boundary = parseBoundaryType(field.type_name);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = baseTypeName(boundary.inner_type_name);
        if (target_name.len == 0) {
            invalid_anchor_count += 1;
            try diagnostics.add(.@"error", "type.domain_root.parent_anchor_target", checked.item.span, "#domain_root '{s}' retained parent-anchor field '{s}' must target a different #domain_root type", .{ checked.item.name, field.name });
            continue;
        }

        const domain_ref = resolveDomainTypeByName(active, checked.module_id, target_name) orelse {
            invalid_anchor_count += 1;
            try diagnostics.add(.@"error", "type.domain_root.parent_anchor_target", checked.item.span, "#domain_root '{s}' retained parent-anchor field '{s}' must target a different #domain_root type", .{ checked.item.name, field.name });
            continue;
        };

        if (domain_ref.kind != .root or domain_ref.item_id.index == checked.item_id.index) {
            invalid_anchor_count += 1;
            try diagnostics.add(.@"error", "type.domain_root.parent_anchor_target", checked.item.span, "#domain_root '{s}' retained parent-anchor field '{s}' must target a different #domain_root type", .{ checked.item.name, field.name });
            continue;
        }

        valid_anchor_count += 1;
    }

    if (invalid_anchor_count != 0) return;

    if (valid_anchor_count == 0 and hasLifetimeParam(generic_params)) {
        try diagnostics.add(.@"error", "type.domain_root.parent_anchor_missing", checked.item.span, "#domain_root child '{s}' requires exactly one retained parent-anchor field", .{checked.item.name});
        return;
    }
    if (valid_anchor_count > 1) {
        try diagnostics.add(.@"error", "type.domain_root.parent_anchor", checked.item.span, "#domain_root '{s}' may declare at most one retained parent-anchor field", .{checked.item.name});
    }
}

fn hasLifetimeParam(generic_params: []const typed.GenericParam) bool {
    for (generic_params) |param| {
        if (param.kind == .lifetime_param) return true;
    }
    return false;
}

fn validateContextDeclaration(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    fields: []const typed.StructField,
    diagnostics: *diag.Bag,
) !void {
    var valid_anchor_count: usize = 0;
    var invalid_anchor_count: usize = 0;

    for (fields) |field| {
        const boundary = parseBoundaryType(field.type_name);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = baseTypeName(boundary.inner_type_name);
        const domain_ref = if (target_name.len == 0)
            null
        else
            resolveDomainTypeByName(active, checked.module_id, target_name);

        if (domain_ref == null or domain_ref.?.kind != .root) {
            invalid_anchor_count += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_context.anchor_target",
                checked.item.span,
                "#domain_context '{s}' retained root-anchor field '{s}' must target a #domain_root type",
                .{ checked.item.name, field.name },
            );
            continue;
        }

        valid_anchor_count += 1;
    }

    if (invalid_anchor_count != 0) return;

    if (valid_anchor_count == 0) {
        try diagnostics.add(.@"error", "type.domain_context.anchor_missing", checked.item.span, "#domain_context '{s}' requires exactly one retained root-anchor field", .{checked.item.name});
        return;
    }
    if (valid_anchor_count > 1) {
        try diagnostics.add(.@"error", "type.domain_context.anchor_multiple", checked.item.span, "#domain_context '{s}' may not anchor multiple domain roots", .{checked.item.name});
    }
}

pub fn classifyTypeName(
    active: *const session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
) ?DomainTypeRef {
    const boundary = parseBoundaryType(raw_type_name);
    const target_name = baseTypeName(boundary.inner_type_name);
    if (target_name.len == 0) return null;

    return resolveDomainTypeByName(active, module_id, target_name);
}

pub fn classifyExpr(
    active: *const session.Session,
    module_id: session.ModuleId,
    expr: *const typed.Expr,
) ?DomainTypeRef {
    return classifyTypeName(active, module_id, type_support.typeRefRawName(expr.ty));
}

pub fn classifyTypeRef(
    active: *const session.Session,
    module_id: session.ModuleId,
    ty: types.TypeRef,
) ?DomainTypeRef {
    return switch (ty) {
        .named => |name| classifyTypeName(active, module_id, name),
        else => null,
    };
}

pub fn resolveBoundaryApiFunction(
    active: *const session.Session,
    module_id: session.ModuleId,
    callee_name: []const u8,
) ?session.ItemId {
    if (findLocalItemByName(active, module_id, callee_name)) |item_id| {
        const item = active.item(item_id);
        if (boundary_checks.kindForItem(item) == .api) return item_id;
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, callee_name)) continue;
        if (findItemBySymbol(active, binding.target_symbol)) |item_id| {
            const item = active.item(item_id);
            if (boundary_checks.kindForItem(item) == .api) return item_id;
        }
    }

    return null;
}

pub fn isSpawnHelper(callee_name: []const u8) bool {
    return callee_helpers.isSpawnHelper(callee_name);
}

fn resolveDomainTypeByName(
    active: *const session.Session,
    module_id: session.ModuleId,
    type_name: []const u8,
) ?DomainTypeRef {
    if (findLocalItemByName(active, module_id, type_name)) |item_id| {
        if (itemDomainTypeRef(active, item_id)) |domain_ref| return domain_ref;
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, type_name)) continue;
        if (findItemBySymbol(active, binding.target_symbol)) |item_id| {
            if (itemDomainTypeRef(active, item_id)) |domain_ref| return domain_ref;
        }
    }

    return null;
}

fn singleValidAnchor(
    active: *const session.Session,
    module_id: session.ModuleId,
    owner_name: []const u8,
    fields: []const typed.StructField,
    reject_self_target: bool,
    require_root_target: bool,
) ?Anchor {
    var found: ?Anchor = null;
    for (fields) |field| {
        const boundary = parseBoundaryType(field.type_name);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = baseTypeName(boundary.inner_type_name);
        if (target_name.len == 0) continue;
        if (reject_self_target and std.mem.eql(u8, target_name, owner_name)) continue;

        const domain_ref = resolveDomainTypeByName(active, module_id, target_name) orelse continue;
        if (require_root_target and domain_ref.kind != .root) continue;
        if (domain_ref.kind != .root) continue;
        if (found != null) return null;

        found = .{
            .field_name = field.name,
            .target_name = target_name,
            .access = anchorAccess(boundary.kind),
            .lifetime_name = boundary.lifetime_name,
        };
    }
    return found;
}

fn isRetainedBoundary(kind: type_support.BoundaryTypeKind) bool {
    return kind == .retained_read or kind == .retained_edit;
}

fn anchorAccess(kind: type_support.BoundaryTypeKind) AnchorAccess {
    return switch (kind) {
        .retained_edit => .edit,
        else => .read,
    };
}

fn itemDomainTypeRef(active: *const session.Session, item_id: session.ItemId) ?DomainTypeRef {
    const item = active.item(item_id);
    if (item.is_domain_root) {
        return .{
            .item_id = item_id,
            .kind = .root,
        };
    }
    if (item.is_domain_context) {
        return .{
            .item_id = item_id,
            .kind = .context,
        };
    }
    return null;
}

fn findLocalItemByName(
    active: *const session.Session,
    module_id: session.ModuleId,
    name: []const u8,
) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }
    return null;
}

fn findItemBySymbol(active: *const session.Session, symbol_name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.symbol_name, symbol_name)) return .{ .index = index };
    }
    return null;
}

fn kindLabel(kind: DomainTypeRef.Kind) []const u8 {
    return switch (kind) {
        .root => "#domain_root",
        .context => "#domain_context",
    };
}
