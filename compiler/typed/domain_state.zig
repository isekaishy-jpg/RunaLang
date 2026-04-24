const std = @import("std");
const type_support = @import("type_support.zig");
const typed_text = @import("text.zig");
const typed = @import("root.zig");

const BoundaryTypeKind = type_support.BoundaryTypeKind;
const parseBoundaryType = type_support.parseBoundaryType;
const baseTypeName = typed_text.baseTypeName;

pub const AnchorAccess = enum {
    read,
    edit,
};

pub const Anchor = struct {
    field_name: []const u8,
    target_name: []const u8,
    access: AnchorAccess,
    lifetime_name: ?[]const u8,
};

pub const RootSignature = struct {
    parent_anchor: ?Anchor = null,
};

pub const ContextSignature = struct {
    root_anchor: Anchor,
};

pub const ItemSignature = union(enum) {
    none,
    root: RootSignature,
    context: ContextSignature,
};

pub fn signatureForItem(module: *const typed.Module, item: *const typed.Item) ItemSignature {
    if (item.kind != .struct_type) return .none;
    if (!item.is_domain_root and !item.is_domain_context) return .none;

    const struct_type = switch (item.payload) {
        .struct_type => |*struct_type| struct_type,
        else => return .none,
    };

    if (item.is_domain_context) {
        var anchors = findDomainAnchors(module, struct_type.fields, item.name, false, true, null) catch return .none;
        defer anchors.deinit();
        if (anchors.items.len == 1) {
            return .{ .context = .{ .root_anchor = anchors.items[0] } };
        }
        return .none;
    }

    var anchors = findDomainAnchors(module, struct_type.fields, item.name, true, false, item.name) catch return .{ .root = .{} };
    defer anchors.deinit();
    if (anchors.items.len == 1) {
        return .{ .root = .{ .parent_anchor = anchors.items[0] } };
    }

    return .{ .root = .{} };
}

fn isRetainedBoundary(kind: BoundaryTypeKind) bool {
    return kind == .retained_read or kind == .retained_edit;
}

fn findDomainAnchors(
    module: *const typed.Module,
    fields: []const typed.StructField,
    owner_name: []const u8,
    allow_zero: bool,
    require_one: bool,
    forbidden_target: ?[]const u8,
) !std.array_list.Managed(Anchor) {
    var anchors = std.array_list.Managed(Anchor).init(module.items.allocator);
    errdefer anchors.deinit();

    for (fields) |field| {
        const boundary = parseBoundaryType(field.type_name);
        const access = switch (boundary.kind) {
            .retained_read => AnchorAccess.read,
            .retained_edit => AnchorAccess.edit,
            else => continue,
        };

        const target_name = baseTypeName(boundary.inner_type_name);
        if (!isLocalDomainRoot(module, target_name)) continue;

        if (forbidden_target) |name| {
            if (std.mem.eql(u8, target_name, name)) continue;
        }

        try anchors.append(.{
            .field_name = field.name,
            .target_name = target_name,
            .access = access,
            .lifetime_name = boundary.lifetime_name,
        });
    }

    if (!allow_zero and require_one and anchors.items.len != 1) {
        return anchors;
    }

    _ = owner_name;
    return anchors;
}

fn isLocalDomainRoot(module: *const typed.Module, name: []const u8) bool {
    for (module.items.items) |item| {
        if (!item.is_domain_root) continue;
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}
