const std = @import("std");
const types = @import("../types/root.zig");

pub const summary = "Target-aware type layout facts owned by query.";

pub const ReprContext = union(enum) {
    default,
    declared: types.DeclaredRepr,

    pub fn eql(lhs: ReprContext, rhs: ReprContext) bool {
        return switch (lhs) {
            .default => rhs == .default,
            .declared => |left| switch (rhs) {
                .declared => |right| declaredReprEql(left, right),
                else => false,
            },
        };
    }
};

pub const LayoutKey = struct {
    type_id: types.CanonicalTypeId,
    target_name: []const u8,
    repr_context: ReprContext = .default,

    pub fn eql(lhs: LayoutKey, rhs: LayoutKey) bool {
        return lhs.type_id.eql(rhs.type_id) and
            std.mem.eql(u8, lhs.target_name, rhs.target_name) and
            lhs.repr_context.eql(rhs.repr_context);
    }
};

pub const LayoutStatus = enum {
    sized,
    unsized,
    unsupported,
};

pub const StorageShape = enum {
    scalar,
    pointer,
    @"opaque",
    array,
    tuple,
    @"struct",
    @"union",
    @"enum",
    zero_sized,
};

pub const Lowerability = enum {
    lowerable,
    not_lowerable,
};

pub const FieldLayout = struct {
    name: []const u8,
    type_id: types.CanonicalTypeId,
    offset: u64,
    size: u64,
    @"align": u32,
};

pub const VariantLayout = struct {
    name: []const u8,
    tag_value: i128,
    payload_layout: ?types.CanonicalTypeId = null,
};

pub const TagLayout = struct {
    repr_type_id: types.CanonicalTypeId,
    size: u64,
    @"align": u32,
};

pub const LayoutResult = struct {
    key: LayoutKey,
    status: LayoutStatus,
    size: ?u64 = null,
    @"align": ?u32 = null,
    storage: StorageShape = .@"opaque",
    lowerability: Lowerability = .not_lowerable,
    foreign_stable: bool = false,
    fields: []const FieldLayout = &.{},
    variants: []const VariantLayout = &.{},
    tag: ?TagLayout = null,
    unsupported_reason: ?[]const u8 = null,
};

pub fn unsupportedResult(allocator: std.mem.Allocator, key: LayoutKey, reason: []const u8) !LayoutResult {
    var owned_key = try cloneLayoutKey(allocator, key);
    errdefer deinitLayoutKey(allocator, &owned_key);
    return .{
        .key = owned_key,
        .status = .unsupported,
        .unsupported_reason = try allocator.dupe(u8, reason),
    };
}

pub fn cloneLayoutKey(allocator: std.mem.Allocator, key: LayoutKey) !LayoutKey {
    return .{
        .type_id = key.type_id,
        .target_name = try allocator.dupe(u8, key.target_name),
        .repr_context = key.repr_context,
    };
}

pub fn deinitLayoutKey(allocator: std.mem.Allocator, key: *LayoutKey) void {
    if (key.target_name.len != 0) allocator.free(key.target_name);
    key.* = .{
        .type_id = .{ .index = 0 },
        .target_name = "",
    };
}

pub fn cloneLayoutResult(allocator: std.mem.Allocator, result: LayoutResult) !LayoutResult {
    var cloned = LayoutResult{
        .key = try cloneLayoutKey(allocator, result.key),
        .status = result.status,
        .size = result.size,
        .@"align" = result.@"align",
        .storage = result.storage,
        .lowerability = result.lowerability,
        .foreign_stable = result.foreign_stable,
        .tag = result.tag,
    };
    errdefer deinitLayoutResult(allocator, &cloned);

    if (result.fields.len != 0) cloned.fields = try cloneFields(allocator, result.fields);
    if (result.variants.len != 0) cloned.variants = try cloneVariants(allocator, result.variants);
    if (result.unsupported_reason) |reason| cloned.unsupported_reason = try allocator.dupe(u8, reason);
    return cloned;
}

pub fn deinitLayoutResult(allocator: std.mem.Allocator, result: *LayoutResult) void {
    deinitLayoutKey(allocator, &result.key);
    for (result.fields) |field| {
        if (field.name.len != 0) allocator.free(field.name);
    }
    if (result.fields.len != 0) allocator.free(result.fields);
    for (result.variants) |variant| {
        if (variant.name.len != 0) allocator.free(variant.name);
    }
    if (result.variants.len != 0) allocator.free(result.variants);
    if (result.unsupported_reason) |reason| allocator.free(reason);
    result.* = .{
        .key = .{
            .type_id = .{ .index = 0 },
            .target_name = "",
        },
        .status = .unsupported,
    };
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const FieldLayout) ![]const FieldLayout {
    const cloned = try allocator.alloc(FieldLayout, fields.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |field| {
            if (field.name.len != 0) allocator.free(field.name);
        }
        allocator.free(cloned);
    }

    for (fields, 0..) |field, index| {
        cloned[index] = field;
        cloned[index].name = try allocator.dupe(u8, field.name);
        initialized += 1;
    }
    return cloned;
}

fn cloneVariants(allocator: std.mem.Allocator, variants: []const VariantLayout) ![]const VariantLayout {
    const cloned = try allocator.alloc(VariantLayout, variants.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |variant| {
            if (variant.name.len != 0) allocator.free(variant.name);
        }
        allocator.free(cloned);
    }

    for (variants, 0..) |variant, index| {
        cloned[index] = variant;
        cloned[index].name = try allocator.dupe(u8, variant.name);
        initialized += 1;
    }
    return cloned;
}

fn declaredReprEql(lhs: types.DeclaredRepr, rhs: types.DeclaredRepr) bool {
    return switch (lhs) {
        .default => rhs == .default,
        .c => rhs == .c,
        .c_enum => |left| switch (rhs) {
            .c_enum => |right| left.eql(right),
            else => false,
        },
    };
}
