const std = @import("std");
const session = @import("../session/root.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");

const option_source_path = "libraries/std/option/mod.rna";
const result_source_path = "libraries/std/result/mod.rna";

pub const Family = enum {
    option,
    result,

    pub fn name(self: Family) []const u8 {
        return switch (self) {
            .option => "Option",
            .result => "Result",
        };
    }
};

pub const VariantInfo = struct {
    family: Family,
    concrete_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
    tag: i32,
    payload_type: ?types.TypeRef = null,
    payload_field_name: ?[]const u8 = null,
};

pub const HelperSurface = struct {
    family: Family,
    method_name: []const u8,
    true_variant_name: []const u8,
    source_path: []const u8,
};

pub const helper_surfaces = [_]HelperSurface{
    .{
        .family = .option,
        .method_name = "is_some",
        .true_variant_name = "Some",
        .source_path = "libraries/std/option/mod.rna",
    },
    .{
        .family = .option,
        .method_name = "is_none",
        .true_variant_name = "None",
        .source_path = "libraries/std/option/mod.rna",
    },
    .{
        .family = .result,
        .method_name = "is_ok",
        .true_variant_name = "Ok",
        .source_path = "libraries/std/result/mod.rna",
    },
    .{
        .family = .result,
        .method_name = "is_err",
        .true_variant_name = "Err",
        .source_path = "libraries/std/result/mod.rna",
    },
};

pub fn familyFromName(name: []const u8) ?Family {
    if (std.mem.eql(u8, name, "Option")) return .option;
    if (std.mem.eql(u8, name, "Result")) return .result;
    return null;
}

pub fn familyForCanonicalType(active: *const session.Session, type_id: types.CanonicalTypeId) ?Family {
    if (type_id.index >= active.caches.canonical_types.items.len) return null;
    return switch (active.caches.canonical_types.items[type_id.index].key) {
        .option => .option,
        .result => .result,
        .nominal => |nominal| familyForItemId(active, .{ .index = nominal.item_index }),
        else => null,
    };
}

pub fn familyForResolvedBase(
    active: *const session.Session,
    resolved_base: ?types.CanonicalTypeId,
    base_name: []const u8,
) ?Family {
    if (resolved_base) |base| {
        if (base.index < active.caches.canonical_types.items.len and active.caches.canonical_types.items[base.index].key != .unsupported) {
            return familyForCanonicalType(active, base);
        }
    }
    return familyFromName(base_name);
}

pub fn familyForItemId(active: *const session.Session, item_id: session.ItemId) ?Family {
    if (item_id.index >= active.semantic_index.items.items.len) return null;
    const item = active.item(item_id);
    if (item.category != .type_decl or item.kind != .enum_type) return null;
    const module = active.module(active.semantic_index.itemEntry(item_id).module_id);
    const file_path = active.pipeline.sources.get(module.file_id).path;
    if (std.mem.eql(u8, item.name, "Option") and pathEndsWithNormalized(file_path, option_source_path)) return .option;
    if (std.mem.eql(u8, item.name, "Result") and pathEndsWithNormalized(file_path, result_source_path)) return .result;
    return null;
}

pub fn itemIdForName(active: *const session.Session, name: []const u8) ?session.ItemId {
    const family = familyFromName(name) orelse return null;
    return itemIdForFamily(active, family);
}

pub fn variantForExpected(
    allocator: std.mem.Allocator,
    expected_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    return variantForTypeRef(allocator, expected_type, family_name, variant_name);
}

pub fn variantForSubject(
    allocator: std.mem.Allocator,
    subject_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    return variantForTypeRef(allocator, subject_type, family_name, variant_name);
}

pub fn helperVariantForTypeRef(
    allocator: std.mem.Allocator,
    concrete_type: types.TypeRef,
    method_name: []const u8,
) !?[]const u8 {
    const family = familyForTypeRef(allocator, concrete_type) orelse return null;
    for (helper_surfaces) |surface| {
        if (surface.family == family and std.mem.eql(u8, surface.method_name, method_name)) {
            return surface.true_variant_name;
        }
    }
    return null;
}

pub fn typeRefIsApplicationOf(
    allocator: std.mem.Allocator,
    ty: types.TypeRef,
    family: Family,
) !bool {
    const args = try applicationArgRefsForTypeRef(allocator, ty, family) orelse return false;
    defer allocator.free(args);
    return switch (family) {
        .option => args.len == 1,
        .result => args.len == 2,
    };
}

pub fn resultTypeArgsMatch(
    allocator: std.mem.Allocator,
    ty: types.TypeRef,
    ok: types.TypeRef,
    err: types.TypeRef,
) !bool {
    const args = try applicationArgRefsForTypeRef(allocator, ty, .result) orelse return false;
    defer allocator.free(args);
    if (args.len != 2) return false;
    return args[0].eql(ok) and args[1].eql(err);
}

pub fn exhaustiveVariantNamesForTypeRef(
    allocator: std.mem.Allocator,
    ty: types.TypeRef,
) !?[]const []const u8 {
    const family = familyForTypeRef(allocator, ty) orelse return null;
    const args = (try applicationArgRefsForTypeRef(allocator, ty, family)) orelse return null;
    defer allocator.free(args);
    return switch (family) {
        .option => if (args.len == 1) &[_][]const u8{ "None", "Some" } else null,
        .result => if (args.len == 2) &[_][]const u8{ "Ok", "Err" } else null,
    };
}

pub fn applicationArgRefsForFamily(
    allocator: std.mem.Allocator,
    ty: types.TypeRef,
    family: Family,
) !?[]types.TypeRef {
    return try applicationArgRefsForTypeRef(allocator, ty, family);
}

fn variantForTypeRef(
    allocator: std.mem.Allocator,
    concrete_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    const family = familyFromName(family_name) orelse return null;
    const args = (try applicationArgRefsForTypeRef(allocator, concrete_type, family)) orelse return null;
    defer allocator.free(args);

    switch (family) {
        .option => {
            if (args.len != 1) return null;
            if (std.mem.eql(u8, variant_name, "None")) return .{
                .family = .option,
                .concrete_type = concrete_type,
                .family_name = family.name(),
                .variant_name = "None",
                .tag = 0,
            };
            if (std.mem.eql(u8, variant_name, "Some")) return .{
                .family = .option,
                .concrete_type = concrete_type,
                .family_name = family.name(),
                .variant_name = "Some",
                .tag = 1,
                .payload_type = args[0],
                .payload_field_name = "value",
            };
        },
        .result => {
            if (args.len != 2) return null;
            if (std.mem.eql(u8, variant_name, "Ok")) return .{
                .family = .result,
                .concrete_type = concrete_type,
                .family_name = family.name(),
                .variant_name = "Ok",
                .tag = 0,
                .payload_type = args[0],
                .payload_field_name = "value",
            };
            if (std.mem.eql(u8, variant_name, "Err")) return .{
                .family = .result,
                .concrete_type = concrete_type,
                .family_name = family.name(),
                .variant_name = "Err",
                .tag = 1,
                .payload_type = args[1],
                .payload_field_name = "error",
            };
        },
    }
    return null;
}

fn familyForTypeRef(allocator: std.mem.Allocator, ty: types.TypeRef) ?Family {
    const base = type_support.baseTypeNameFromTypeRef(allocator, ty) catch return null;
    return familyFromName(base orelse return null);
}

fn applicationArgRefsForTypeRef(
    allocator: std.mem.Allocator,
    ty: types.TypeRef,
    family: Family,
) !?[]types.TypeRef {
    return try type_support.applicationArgsFromTypeRef(allocator, ty, family.name());
}

fn itemIdForFamily(active: *const session.Session, family: Family) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item_id: session.ItemId = .{ .index = index };
        if (familyForItemId(active, item_id) == family) return item_id;
    }
    return null;
}

fn pathEndsWithNormalized(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    const tail = path[path.len - suffix.len ..];
    for (tail, suffix) |lhs, rhs| {
        const lhs_normalized: u8 = if (lhs == '\\') '/' else lhs;
        const rhs_normalized: u8 = if (rhs == '\\') '/' else rhs;
        if (lhs_normalized != rhs_normalized) return false;
    }
    return true;
}
