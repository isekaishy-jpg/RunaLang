const std = @import("std");
const boundary_checks = @import("boundary_checks.zig");
const session = @import("../session/root.zig");
const standard_families = @import("standard_families.zig");
const typed_text = @import("text.zig");
const tuple_types = @import("tuple_types.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");

pub fn itemIsHandleFamily(active: *const session.Session, item_id: session.ItemId) bool {
    return boundary_checks.kindForItem(active.item(item_id)) == .capability;
}

pub fn typeRefContainsHandleFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    ty: types.TypeRef,
    signature_resolver: anytype,
) !bool {
    var visited = std.AutoHashMap(usize, void).init(active.allocator);
    defer visited.deinit();
    return typeRefContainsHandleFamilyInner(active, module_id, ty, signature_resolver, &visited);
}

fn typeRefContainsHandleFamilyInner(
    active: *session.Session,
    module_id: session.ModuleId,
    ty: types.TypeRef,
    signature_resolver: anytype,
    visited: *std.AutoHashMap(usize, void),
) anyerror!bool {
    return switch (ty) {
        .builtin, .unsupported => false,
        .named => |name| typeNameContainsHandleFamily(active, module_id, name, signature_resolver, visited),
    };
}

fn typeNameContainsHandleFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_name: []const u8,
    signature_resolver: anytype,
    visited: *std.AutoHashMap(usize, void),
) anyerror!bool {
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (name.len == 0) return false;

    const boundary = type_support.parseBoundaryType(name);
    if (boundary.isBoundary()) return false;

    if (std.mem.startsWith(u8, name, "[")) {
        const close_index = typed_text.findMatchingDelimiter(name, 0, '[', ']') orelse return false;
        if (std.mem.trim(u8, name[close_index + 1 ..], " \t\r\n").len != 0) return false;
        const inner = name[1..close_index];
        const separator = typed_text.findTopLevelHeaderScalar(inner, ';') orelse return false;
        const element_name = std.mem.trim(u8, inner[0..separator], " \t\r\n");
        return typeNameContainsHandleFamily(active, module_id, element_name, signature_resolver, visited);
    }

    if (std.mem.startsWith(u8, name, "(")) {
        const parts = (try tuple_types.splitTypeParts(active.allocator, name)) orelse return false;
        defer active.allocator.free(parts);
        if (!tuple_types.validTupleParts(parts)) return false;
        for (parts) |part| {
            if (try typeNameContainsHandleFamily(active, module_id, part, signature_resolver, visited)) return true;
        }
        return false;
    }

    if (std.mem.startsWith(u8, name, "*read ") or std.mem.startsWith(u8, name, "*edit ")) return false;

    if (try standard_families.applicationArgs(active.allocator, name, .option)) |args| {
        defer active.allocator.free(args);
        for (args) |arg| {
            if (try typeNameContainsHandleFamily(active, module_id, arg, signature_resolver, visited)) return true;
        }
        return false;
    }

    if (try standard_families.applicationArgs(active.allocator, name, .result)) |args| {
        defer active.allocator.free(args);
        for (args) |arg| {
            if (try typeNameContainsHandleFamily(active, module_id, arg, signature_resolver, visited)) return true;
        }
        return false;
    }

    const item_id = resolveTypeItemId(active, module_id, typed_text.baseTypeName(name)) orelse return false;
    if (itemIsHandleFamily(active, item_id)) return true;

    if (visited.contains(item_id.index)) return false;
    try visited.put(item_id.index, {});

    const signature = try signature_resolver(active, item_id);
    return switch (signature.facts) {
        .struct_type => |struct_type| fieldsContainHandleFamily(active, module_id, struct_type.fields, signature_resolver, visited),
        .union_type => |union_type| fieldsContainHandleFamily(active, module_id, union_type.fields, signature_resolver, visited),
        .enum_type => |enum_type| enumContainsHandleFamily(active, module_id, enum_type.variants, signature_resolver, visited),
        else => false,
    };
}

fn fieldsContainHandleFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    fields: anytype,
    signature_resolver: anytype,
    visited: *std.AutoHashMap(usize, void),
) !bool {
    for (fields) |field| {
        if (try typeRefContainsHandleFamilyInner(active, module_id, field.ty, signature_resolver, visited)) return true;
    }
    return false;
}

fn enumContainsHandleFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    variants: anytype,
    signature_resolver: anytype,
    visited: *std.AutoHashMap(usize, void),
) !bool {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |fields| {
                if (try fieldsContainHandleFamily(active, module_id, fields, signature_resolver, visited)) return true;
            },
            .named_fields => |fields| {
                if (try fieldsContainHandleFamily(active, module_id, fields, signature_resolver, visited)) return true;
            },
        }
    }
    return false;
}

fn resolveTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (item.kind == .type_alias) continue;
        if (std.mem.eql(u8, item.name, name) or std.mem.eql(u8, item.symbol_name, name)) return .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (binding.category != .type_decl) continue;
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        const item_id = findItemIdBySymbol(active, binding.target_symbol) orelse return null;
        if (active.item(item_id).kind == .type_alias) return null;
        return item_id;
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
