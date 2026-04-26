const std = @import("std");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const typed = @import("../typed/root.zig");
const type_support = @import("type_support.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");

const baseTypeName = typed_text.baseTypeName;
const parseBoundaryType = type_support.parseBoundaryType;

pub const BoundaryKind = enum {
    none,
    api,
    value,
    capability,
};

pub fn kindForItem(item: *const typed.Item) BoundaryKind {
    for (item.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "boundary")) continue;
        return parseRawBoundaryKind(attribute.raw) orelse .none;
    }
    return .none;
}

pub fn validateItem(item: *const typed.Item, diagnostics: *diag.Bag) !void {
    var boundary_count: usize = 0;
    var first_kind: ?BoundaryKind = null;

    for (item.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "boundary")) continue;
        boundary_count += 1;
        if (parseRawBoundaryKind(attribute.raw)) |kind| {
            if (first_kind == null) first_kind = kind;
        } else {
            try diagnostics.add(.@"error", "type.boundary.kind", item.span, "unsupported boundary attribute form '{s}'", .{attribute.raw});
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

fn parseRawBoundaryKind(raw: []const u8) ?BoundaryKind {
    var trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len != 0 and trimmed[0] == '#') trimmed = trimmed[1..];
    if (std.mem.eql(u8, trimmed, "boundary[api]")) return .api;
    if (std.mem.eql(u8, trimmed, "boundary[value]")) return .value;
    if (std.mem.eql(u8, trimmed, "boundary[capability]")) return .capability;
    return null;
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
        const boundary = parseBoundaryType(parameter.type_name);
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

        const category = try classifyTypeName(active, checked.module_id, parameter.type_name, parameter.ty, signature_resolver);
        if (category == .local_only) {
            try diagnostics.add(
                .@"error",
                "type.boundary.api_param_type",
                checked.item.span,
                "boundary API '{s}' parameter '{s}' uses local-only type '{s}'",
                .{ checked.item.name, parameter.name, parameter.type_name },
            );
        }
    }

    if (try classifyTypeName(active, checked.module_id, function.return_type_name, function.return_type, signature_resolver) == .local_only) {
        try diagnostics.add(
            .@"error",
            "type.boundary.api_return_type",
            checked.item.span,
            "boundary API '{s}' returns local-only type '{s}'",
            .{ checked.item.name, function.return_type_name },
        );
    }
}

fn validateValueFamily(active: *session.Session, checked: anytype, diagnostics: *diag.Bag, signature_resolver: anytype) anyerror!void {
    switch (checked.facts) {
        .struct_type => |struct_type| {
            for (struct_type.fields) |field| {
                if (try classifyTypeName(active, checked.module_id, field.type_name, field.ty, signature_resolver) == .transfer_safe) continue;
                try diagnostics.add(
                    .@"error",
                    "type.boundary.value_member",
                    checked.item.span,
                    "boundary value family '{s}' contains non-transfer-safe member '{s}' of type '{s}'",
                    .{ checked.item.name, field.name, field.type_name },
                );
            }
        },
        .enum_type => |enum_type| {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| {
                        for (fields, 0..) |field, index| {
                            if (try classifyTypeName(active, checked.module_id, field.type_name, field.ty, signature_resolver) == .transfer_safe) continue;
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
                            if (try classifyTypeName(active, checked.module_id, field.type_name, field.ty, signature_resolver) == .transfer_safe) continue;
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

fn classifyTypeName(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    ty: types.TypeRef,
    signature_resolver: anytype,
) anyerror!BoundaryCategory {
    const boundary = parseBoundaryType(raw_type_name);
    if (boundary.isBoundary()) return .local_only;

    switch (ty) {
        .builtin => |builtin| return classifyBuiltin(builtin),
        .unsupported => return .local_only,
        .named => {},
    }

    const name = baseTypeName(boundary.inner_type_name);
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
