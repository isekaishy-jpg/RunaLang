const std = @import("std");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const typed = @import("../typed/root.zig");
const callee_helpers = @import("callee_helpers.zig");
const boundary_checks = @import("boundary_checks.zig");
const query_types = @import("types.zig");
const domain_state_types = @import("domain_state_types.zig");
const type_text_syntax = @import("../parse/type_text_syntax.zig");
const type_forms = @import("type_forms.zig");
const type_lowering = @import("type_lowering.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");

pub const DomainTypeRef = struct {
    item_id: session.ItemId,
    kind: Kind,

    pub const Kind = enum {
        root,
        context,
    };
};

const Anchor = domain_state_types.Anchor;
const AnchorAccess = domain_state_types.AnchorAccess;

pub fn signatureForItem(
    active: *const session.Session,
    module_id: session.ModuleId,
    item: *const typed.Item,
    facts: query_types.SignatureFacts,
) domain_state_types.ItemSignature {
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
        if (classifyTypeRef(active, checked.module_id, parameter.ty)) |domain_ref| {
            const target_name = targetTypeNameFromSyntaxOrType(active, parameter.type_syntax, parameter.ty);
            try diagnostics.add(
                .@"error",
                "type.domain_state.boundary_param",
                item.span,
                "boundary API '{s}' may not accept {s} '{s}' in its signature",
                .{
                    item.name,
                    kindLabel(domain_ref.kind),
                    target_name,
                },
            );
        }
    }

    if (classifyTypeRef(active, checked.module_id, function.return_type)) |domain_ref| {
        const target_name = targetTypeNameFromSyntaxOrType(active, function.return_type_syntax, function.return_type);
        try diagnostics.add(
            .@"error",
            "type.domain_state.boundary_return",
            item.span,
            "boundary API '{s}' may not return {s} '{s}'",
            .{
                item.name,
                kindLabel(domain_ref.kind),
                target_name,
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
        try validateContextDeclaration(active, checked, struct_type.generic_params, struct_type.fields, diagnostics);
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
        const boundary = boundaryFromSyntaxOrType(field.type_syntax, field.ty);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = targetTypeNameFromSyntaxOrType(active, field.type_syntax, field.ty);
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
        if (!lifetimeIsVisible(generic_params, boundary.lifetime_name)) {
            invalid_anchor_count += 1;
            try diagnostics.add(.@"error", "type.domain_root.parent_anchor_lifetime", checked.item.span, "#domain_root '{s}' retained parent-anchor field '{s}' must use a declared lifetime parameter", .{ checked.item.name, field.name });
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

fn lifetimeIsVisible(generic_params: []const typed.GenericParam, maybe_lifetime_name: ?[]const u8) bool {
    const lifetime_name = maybe_lifetime_name orelse return false;
    if (std.mem.eql(u8, lifetime_name, "'static")) return true;
    for (generic_params) |param| {
        if (param.kind == .lifetime_param and std.mem.eql(u8, param.name, lifetime_name)) return true;
    }
    return false;
}

fn validateContextDeclaration(
    active: *session.Session,
    checked: query_types.CheckedSignature,
    generic_params: []const typed.GenericParam,
    fields: []const typed.StructField,
    diagnostics: *diag.Bag,
) !void {
    var valid_anchor_count: usize = 0;
    var invalid_anchor_count: usize = 0;

    for (fields) |field| {
        const boundary = boundaryFromSyntaxOrType(field.type_syntax, field.ty);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = targetTypeNameFromSyntaxOrType(active, field.type_syntax, field.ty);
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
        if (!lifetimeIsVisible(generic_params, boundary.lifetime_name)) {
            invalid_anchor_count += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_context.anchor_lifetime",
                checked.item.span,
                "#domain_context '{s}' retained root-anchor field '{s}' must use a declared lifetime parameter",
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

pub fn classifyExpr(
    active: *const session.Session,
    module_id: session.ModuleId,
    expr: *const typed.Expr,
) ?DomainTypeRef {
    return classifyTypeRef(active, module_id, expr.ty);
}

pub fn classifyTypeName(
    active: *const session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
) ?DomainTypeRef {
    const ty = typeRefFromStandaloneTypeText(std.heap.page_allocator, raw_type_name) catch return null;
    return classifyTypeRef(active, module_id, ty);
}

pub fn classifyTypeRef(
    active: *const session.Session,
    module_id: session.ModuleId,
    ty: types.TypeRef,
) ?DomainTypeRef {
    const boundary = type_support.boundaryFromTypeRef(ty);
    const target_name = targetTypeNameForTypeRef(active, boundary.inner_type);
    if (target_name.len == 0) return null;
    return resolveDomainTypeByName(active, module_id, target_name);
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
        const boundary = boundaryFromSyntaxOrType(field.type_syntax, field.ty);
        if (!isRetainedBoundary(boundary.kind)) continue;

        const target_name = targetTypeNameFromSyntaxOrType(active, field.type_syntax, field.ty);
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

fn targetTypeName(active: *const session.Session, raw: []const u8) []const u8 {
    return targetTypeNameConst(active, raw);
}

fn targetTypeNameConst(active: *const session.Session, raw: []const u8) []const u8 {
    _ = active;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const ty = typeRefFromStandaloneTypeText(std.heap.page_allocator, trimmed) catch return trimmed;
    return type_support.baseTypeNameFromTypeRef(std.heap.page_allocator, ty) catch trimmed orelse trimmed;
}

fn targetTypeNameForTypeRef(active: *const session.Session, ty: types.TypeRef) []const u8 {
    _ = active;
    return type_support.baseTypeNameFromTypeRef(std.heap.page_allocator, ty) catch "" orelse "";
}

fn boundaryFromSyntaxOrType(type_syntax: ?@import("../ast/root.zig").TypeSyntax, ty: types.TypeRef) type_support.BoundaryType {
    if (type_syntax) |syntax_value| {
        if (!type_syntax_support.containsInvalid(syntax_value)) {
            return type_support.boundaryFromSyntax(std.heap.page_allocator, syntax_value) catch type_support.boundaryFromTypeRef(ty);
        }
    }
    return type_support.boundaryFromTypeRef(ty);
}

fn targetTypeNameFromSyntaxOrType(
    active: *const session.Session,
    type_syntax: ?@import("../ast/root.zig").TypeSyntax,
    ty: types.TypeRef,
) []const u8 {
    if (type_syntax) |syntax_value| {
        if (targetTypeNameFromSyntax(syntax_value)) |name| return name;
    }
    const boundary = type_support.boundaryFromTypeRef(ty);
    return targetTypeNameForTypeRef(active, boundary.inner_type);
}

fn targetTypeNameFromSyntax(syntax_value: @import("../ast/root.zig").TypeSyntax) ?[]const u8 {
    if (type_syntax_support.containsInvalid(syntax_value)) return null;
    var view = type_forms.View.fromSyntax(std.heap.page_allocator, syntax_value) catch return null;
    defer view.deinit();
    const root = view.rootNode();
    return switch (root.payload) {
        .borrow => blk: {
            const children = view.rootChildren();
            if (children.len == 0) break :blk null;
            break :blk baseNameAtNode(view.syntax, children[children.len - 1]);
        },
        else => type_forms.baseName(view),
    };
}

fn baseNameAtNode(syntax_value: @import("../ast/root.zig").TypeSyntax, node_index: usize) ?[]const u8 {
    const node = syntax_value.nodes[node_index];
    return switch (node.payload) {
        .name_ref => std.mem.trim(u8, node.source.text, " \t\r\n"),
        .apply => blk: {
            const children = syntax_value.childNodeIndices(node_index);
            if (children.len == 0) break :blk null;
            const base = syntax_value.nodes[children[0]];
            if (base.payload != .name_ref) break :blk null;
            break :blk std.mem.trim(u8, base.source.text, " \t\r\n");
        },
        else => null,
    };
}

fn typeRefFromStandaloneTypeText(allocator: std.mem.Allocator, raw: []const u8) !types.TypeRef {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .unsupported;
    var syntax_value = (try type_text_syntax.lowerStandalone(allocator, trimmed)) orelse return .unsupported;
    defer syntax_value.deinit(allocator);
    return type_lowering.typeRefFromSyntax(allocator, syntax_value);
}
