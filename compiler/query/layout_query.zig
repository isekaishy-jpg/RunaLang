const std = @import("std");
const layout = @import("../layout/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const target = @import("../target/root.zig");
const types = @import("../types/root.zig");

const array_list = std.array_list;

pub const Resolvers = struct {
    canonical_key: *const fn (*session.Session, types.TypeKey) anyerror!types.CanonicalTypeId,
    canonical_type_expression: *const fn (*session.Session, session.ModuleId, []const u8) anyerror!types.CanonicalTypeId,
    checked_signature: *const fn (*session.Session, session.ItemId) anyerror!query_types.CheckedSignature,
    layout_for_key: *const fn (*session.Session, layout.LayoutKey) anyerror!layout.LayoutResult,
};

const TargetLayoutModel = struct {
    pointer_size: u64,
    pointer_alignment: u32,
    c_long_size: u64,
    c_long_alignment: u32,
    c_wchar_size: u64,
    c_wchar_alignment: u32,
};

pub fn build(active: *session.Session, key: layout.LayoutKey, resolvers: Resolvers) !layout.LayoutResult {
    const model = targetLayoutModel(key.target_name) orelse
        return layout.unsupportedResult(active.allocator, key, "unsupported layout target");
    if (key.type_id.index >= active.caches.canonical_types.items.len) {
        return layout.unsupportedResult(active.allocator, key, "unknown canonical type id");
    }

    const canonical = active.caches.canonical_types.items[key.type_id.index];
    return switch (canonical.key) {
        .builtin_scalar => |scalar| layoutBuiltinScalar(active, key, model, scalar),
        .c_abi_alias => |alias| layoutCAbiAlias(active, key, model, alias),
        .raw_pointer => layoutPointer(active, key, model, true),
        .fixed_array => |array_type| layoutFixedArray(active, key, model, array_type, resolvers),
        .tuple => |tuple_type| layoutTuple(active, key, model, tuple_type, resolvers),
        .nominal => |nominal| layoutNominal(active, key, model, nominal, resolvers),
        .generic_param => layout.unsupportedResult(active.allocator, key, "generic parameter layout requires instantiation"),
        .generic_application => layout.unsupportedResult(active.allocator, key, "generic application layout is not implemented"),
        .callable => layoutPointer(active, key, model, true),
        .c_va_list => layout.unsupportedResult(active.allocator, key, "CVaList layout is backend target-owned"),
        .handle => layout.unsupportedResult(active.allocator, key, "handle layout is not implemented"),
        .option => |option_type| layoutOption(active, key, model, option_type, resolvers),
        .result => |result_type| layoutResult(active, key, model, result_type, resolvers),
        .unsupported => layout.unsupportedResult(active.allocator, key, "unsupported canonical type key"),
    };
}

fn layoutBuiltinScalar(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    scalar: types.BuiltinScalar,
) !layout.LayoutResult {
    return switch (scalar) {
        .unit => sizedLayout(active, key, 0, 1, .zero_sized, false),
        .bool => sizedLayout(active, key, 1, 1, .scalar, false),
        .i32, .u32 => sizedLayout(active, key, 4, 4, .scalar, true),
        .index, .isize => sizedLayout(active, key, model.pointer_size, model.pointer_alignment, .scalar, true),
        .str => sizedLayout(active, key, model.pointer_size, model.pointer_alignment, .pointer, false),
    };
}

fn layoutCAbiAlias(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    alias: types.CAbiAlias,
) !layout.LayoutResult {
    return switch (alias) {
        .c_void => unsizedLayout(active, key, .zero_sized, "CVoid has no object layout"),
        .c_bool, .c_char, .c_signed_char, .c_unsigned_char => sizedLayout(active, key, 1, 1, .scalar, true),
        .c_short, .c_ushort => sizedLayout(active, key, 2, 2, .scalar, true),
        .c_int, .c_uint => sizedLayout(active, key, 4, 4, .scalar, true),
        .c_long, .c_ulong => sizedLayout(active, key, model.c_long_size, model.c_long_alignment, .scalar, true),
        .c_long_long, .c_ulong_long => sizedLayout(active, key, 8, 8, .scalar, true),
        .c_size, .c_ptr_diff => sizedLayout(active, key, model.pointer_size, model.pointer_alignment, .scalar, true),
        .c_wchar => sizedLayout(active, key, model.c_wchar_size, model.c_wchar_alignment, .scalar, true),
    };
}

fn layoutPointer(active: *session.Session, key: layout.LayoutKey, model: TargetLayoutModel, foreign_stable: bool) !layout.LayoutResult {
    return sizedLayout(active, key, model.pointer_size, model.pointer_alignment, .pointer, foreign_stable);
}

fn layoutFixedArray(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    array_type: types.FixedArray,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = model;
    const element_layout = try layoutForType(active, key, array_type.element, resolvers);
    if (element_layout.status != .sized) {
        return layout.unsupportedResult(active.allocator, key, "fixed array element has no sized layout");
    }
    const element_size = element_layout.size orelse return layout.unsupportedResult(active.allocator, key, "fixed array element size is unavailable");
    const element_alignment = element_layout.@"align" orelse return layout.unsupportedResult(active.allocator, key, "fixed array element alignment is unavailable");
    const size = try std.math.mul(u64, element_size, array_type.length);
    return sizedLayout(active, key, size, element_alignment, .array, element_layout.foreign_stable);
}

fn layoutTuple(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    tuple_type: types.Tuple,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = model;
    var fields = array_list.Managed(layout.FieldLayout).init(active.allocator);
    defer fields.deinit();
    defer deinitFieldItems(active.allocator, fields.items);

    var offset: u64 = 0;
    var max_alignment: u32 = 1;
    for (tuple_type.elements, 0..) |element, index| {
        const element_layout = try layoutForType(active, key, element, resolvers);
        if (element_layout.status != .sized) {
            return layout.unsupportedResult(active.allocator, key, "tuple element has no sized layout");
        }
        const element_size = element_layout.size orelse return layout.unsupportedResult(active.allocator, key, "tuple element size is unavailable");
        const element_alignment = element_layout.@"align" orelse return layout.unsupportedResult(active.allocator, key, "tuple element alignment is unavailable");
        offset = try alignForward(offset, element_alignment);
        const name = try tupleFieldName(active.allocator, index);
        defer active.allocator.free(name);
        try appendField(active.allocator, &fields, name, element, offset, element_size, element_alignment);
        offset = try std.math.add(u64, offset, element_size);
        max_alignment = @max(max_alignment, element_alignment);
    }

    return aggregateResult(active, key, try alignForward(offset, max_alignment), max_alignment, .tuple, false, &fields, null, null);
}

fn layoutNominal(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    nominal: types.NominalType,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = model;
    if (nominal.item_index >= active.semantic_index.items.items.len) {
        return layout.unsupportedResult(active.allocator, key, "nominal layout item id is unknown");
    }
    const item_id = session.ItemId{ .index = nominal.item_index };
    const checked = try resolvers.checked_signature(active, item_id);
    const declared_repr = switch (key.repr_context) {
        .default => .default,
        .declared => |repr| repr,
    };
    return switch (checked.facts) {
        .struct_type => |struct_type| layoutStruct(active, key, checked.module_id, struct_type, declared_repr, resolvers),
        .union_type => |union_type| layoutUnion(active, key, checked.module_id, union_type, declared_repr, resolvers),
        .enum_type => |enum_type| layoutEnum(active, key, checked.module_id, enum_type, declared_repr, resolvers),
        .opaque_type => unsizedLayout(active, key, .@"opaque", "opaque type has no transparent layout"),
        else => layout.unsupportedResult(active.allocator, key, "nominal item is not a layout-bearing type"),
    };
}

fn layoutStruct(
    active: *session.Session,
    key: layout.LayoutKey,
    module_id: session.ModuleId,
    struct_type: query_types.StructSignature,
    declared_repr: types.DeclaredRepr,
    resolvers: Resolvers,
) !layout.LayoutResult {
    if (struct_type.generic_params.len != 0) {
        return layout.unsupportedResult(active.allocator, key, "generic struct layout requires instantiation");
    }

    var fields = array_list.Managed(layout.FieldLayout).init(active.allocator);
    defer fields.deinit();
    defer deinitFieldItems(active.allocator, fields.items);

    var offset: u64 = 0;
    var max_alignment: u32 = 1;
    for (struct_type.fields) |field| {
        const field_type = try resolvers.canonical_type_expression(active, module_id, field.type_name);
        const field_layout = try layoutForType(active, key, field_type, resolvers);
        if (field_layout.status != .sized) {
            return layout.unsupportedResult(active.allocator, key, "struct field has no sized layout");
        }
        const field_size = field_layout.size orelse return layout.unsupportedResult(active.allocator, key, "struct field size is unavailable");
        const field_alignment = field_layout.@"align" orelse return layout.unsupportedResult(active.allocator, key, "struct field alignment is unavailable");
        offset = try alignForward(offset, field_alignment);
        try appendField(active.allocator, &fields, field.name, field_type, offset, field_size, field_alignment);
        offset = try std.math.add(u64, offset, field_size);
        max_alignment = @max(max_alignment, field_alignment);
    }

    return aggregateResult(active, key, try alignForward(offset, max_alignment), max_alignment, .@"struct", declaredReprIsC(declared_repr), &fields, null, null);
}

fn layoutUnion(
    active: *session.Session,
    key: layout.LayoutKey,
    module_id: session.ModuleId,
    union_type: query_types.UnionSignature,
    declared_repr: types.DeclaredRepr,
    resolvers: Resolvers,
) !layout.LayoutResult {
    var fields = array_list.Managed(layout.FieldLayout).init(active.allocator);
    defer fields.deinit();
    errdefer deinitFieldItems(active.allocator, fields.items);

    var max_size: u64 = 0;
    var max_alignment: u32 = 1;
    for (union_type.fields) |field| {
        const field_type = try resolvers.canonical_type_expression(active, module_id, field.type_name);
        const field_layout = try layoutForType(active, key, field_type, resolvers);
        if (field_layout.status != .sized) {
            return layout.unsupportedResult(active.allocator, key, "union field has no sized layout");
        }
        const field_size = field_layout.size orelse return layout.unsupportedResult(active.allocator, key, "union field size is unavailable");
        const field_alignment = field_layout.@"align" orelse return layout.unsupportedResult(active.allocator, key, "union field alignment is unavailable");
        try appendField(active.allocator, &fields, field.name, field_type, 0, field_size, field_alignment);
        max_size = @max(max_size, field_size);
        max_alignment = @max(max_alignment, field_alignment);
    }

    return aggregateResult(active, key, try alignForward(max_size, max_alignment), max_alignment, .@"union", declaredReprIsC(declared_repr), &fields, null, null);
}

fn layoutEnum(
    active: *session.Session,
    key: layout.LayoutKey,
    module_id: session.ModuleId,
    enum_type: query_types.EnumSignature,
    declared_repr: types.DeclaredRepr,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = module_id;
    if (enum_type.generic_params.len != 0) {
        return layout.unsupportedResult(active.allocator, key, "generic enum layout requires instantiation");
    }
    if (declared_repr == .c) {
        return layout.unsupportedResult(active.allocator, key, "#repr[c] enum requires an explicit integer representation");
    }

    const tag_type = switch (declared_repr) {
        .c_enum => |repr_type| repr_type,
        .default => try resolvers.canonical_key(active, .{ .builtin_scalar = .i32 }),
        .c => unreachable,
    };
    const tag_layout = try layoutForType(active, key, tag_type, resolvers);
    if (tag_layout.status != .sized) {
        return layout.unsupportedResult(active.allocator, key, "enum tag type has no sized layout");
    }
    const tag_size = tag_layout.size orelse return layout.unsupportedResult(active.allocator, key, "enum tag size is unavailable");
    const tag_alignment = tag_layout.@"align" orelse return layout.unsupportedResult(active.allocator, key, "enum tag alignment is unavailable");

    var variants = array_list.Managed(layout.VariantLayout).init(active.allocator);
    defer variants.deinit();
    defer deinitVariantItems(active.allocator, variants.items);

    for (enum_type.variants, 0..) |variant, index| {
        switch (variant.payload) {
            .none => {},
            else => return layout.unsupportedResult(active.allocator, key, "enum payload layout is not implemented"),
        }
        const tag_value = if (variant.discriminant) |discriminant|
            std.fmt.parseInt(i128, std.mem.trim(u8, discriminant, " \t\r\n"), 10) catch return layout.unsupportedResult(active.allocator, key, "enum discriminant layout requires an integer literal")
        else
            @as(i128, @intCast(index));
        try appendVariant(active.allocator, &variants, variant.name, tag_value);
    }

    return aggregateResult(active, key, tag_size, tag_alignment, .@"enum", declared_repr != .default, null, &variants, .{
        .repr_type_id = tag_type,
        .size = tag_size,
        .@"align" = tag_alignment,
    });
}

fn layoutOption(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    option_type: types.OptionType,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = model;
    const tag = try standardEnumTagLayout(active, key, resolvers);
    var variants = array_list.Managed(layout.VariantLayout).init(active.allocator);
    defer variants.deinit();
    defer deinitVariantItems(active.allocator, variants.items);

    try appendVariantWithPayload(active.allocator, &variants, "None", 0, null);
    try appendVariantWithPayload(active.allocator, &variants, "Some", 1, option_type.payload);

    const payload_storage = standardEnumPayloadStorage(active, key, &.{option_type.payload}, resolvers) catch |err| switch (err) {
        error.UnsupportedStandardEnumPayloadLayout => return layout.unsupportedResult(active.allocator, key, "standard enum payload has no sized layout"),
        else => return err,
    };
    const size = try standardEnumSize(tag.size, tag.@"align", payload_storage.size, payload_storage.@"align", payload_storage.has_payload);
    const alignment = if (payload_storage.has_payload) @max(tag.@"align", payload_storage.@"align") else tag.@"align";

    var fields = array_list.Managed(layout.FieldLayout).init(active.allocator);
    defer fields.deinit();
    defer deinitFieldItems(active.allocator, fields.items);
    try appendField(active.allocator, &fields, "tag", tag.repr_type_id, 0, tag.size, tag.@"align");

    return aggregateResult(active, key, size, alignment, .@"enum", false, &fields, &variants, tag);
}

fn layoutResult(
    active: *session.Session,
    key: layout.LayoutKey,
    model: TargetLayoutModel,
    result_type: types.ResultType,
    resolvers: Resolvers,
) !layout.LayoutResult {
    _ = model;
    const tag = try standardEnumTagLayout(active, key, resolvers);
    var variants = array_list.Managed(layout.VariantLayout).init(active.allocator);
    defer variants.deinit();
    defer deinitVariantItems(active.allocator, variants.items);

    try appendVariantWithPayload(active.allocator, &variants, "Ok", 0, result_type.ok);
    try appendVariantWithPayload(active.allocator, &variants, "Err", 1, result_type.err);

    const payload_storage = standardEnumPayloadStorage(active, key, &.{ result_type.ok, result_type.err }, resolvers) catch |err| switch (err) {
        error.UnsupportedStandardEnumPayloadLayout => return layout.unsupportedResult(active.allocator, key, "standard enum payload has no sized layout"),
        else => return err,
    };
    const size = try standardEnumSize(tag.size, tag.@"align", payload_storage.size, payload_storage.@"align", payload_storage.has_payload);
    const alignment = if (payload_storage.has_payload) @max(tag.@"align", payload_storage.@"align") else tag.@"align";

    var fields = array_list.Managed(layout.FieldLayout).init(active.allocator);
    defer fields.deinit();
    defer deinitFieldItems(active.allocator, fields.items);
    try appendField(active.allocator, &fields, "tag", tag.repr_type_id, 0, tag.size, tag.@"align");

    return aggregateResult(active, key, size, alignment, .@"enum", false, &fields, &variants, tag);
}

const StandardEnumPayloadStorage = struct {
    has_payload: bool = false,
    size: u64 = 0,
    @"align": u32 = 1,
};

fn standardEnumTagLayout(
    active: *session.Session,
    key: layout.LayoutKey,
    resolvers: Resolvers,
) !layout.TagLayout {
    const tag_type = try resolvers.canonical_key(active, .{ .builtin_scalar = .i32 });
    const tag_layout = try layoutForType(active, key, tag_type, resolvers);
    if (tag_layout.status != .sized) {
        return error.InvalidLayoutTag;
    }
    return .{
        .repr_type_id = tag_type,
        .size = tag_layout.size orelse return error.InvalidLayoutTag,
        .@"align" = tag_layout.@"align" orelse return error.InvalidLayoutTag,
    };
}

fn standardEnumPayloadStorage(
    active: *session.Session,
    key: layout.LayoutKey,
    payloads: []const types.CanonicalTypeId,
    resolvers: Resolvers,
) !StandardEnumPayloadStorage {
    var result = StandardEnumPayloadStorage{};
    for (payloads) |payload| {
        if (isUnitCanonical(active, payload)) continue;
        const payload_layout = try layoutForType(active, key, payload, resolvers);
        if (payload_layout.status != .sized) {
            return error.UnsupportedStandardEnumPayloadLayout;
        }
        const payload_size = payload_layout.size orelse return error.UnsupportedStandardEnumPayloadLayout;
        const payload_alignment = payload_layout.@"align" orelse return error.UnsupportedStandardEnumPayloadLayout;
        result.has_payload = true;
        result.size = @max(result.size, payload_size);
        result.@"align" = @max(result.@"align", payload_alignment);
    }
    return result;
}

fn standardEnumSize(
    tag_size: u64,
    tag_alignment: u32,
    payload_size: u64,
    payload_alignment: u32,
    has_payload: bool,
) !u64 {
    if (!has_payload) return alignForward(tag_size, tag_alignment);
    const payload_offset = try alignForward(tag_size, payload_alignment);
    const unaligned_size = try std.math.add(u64, payload_offset, payload_size);
    return alignForward(unaligned_size, @max(tag_alignment, payload_alignment));
}

fn isUnitCanonical(active: *session.Session, type_id: types.CanonicalTypeId) bool {
    if (type_id.index >= active.caches.canonical_types.items.len) return false;
    return switch (active.caches.canonical_types.items[type_id.index].key) {
        .builtin_scalar => |scalar| scalar == .unit,
        else => false,
    };
}

fn layoutForType(
    active: *session.Session,
    parent_key: layout.LayoutKey,
    type_id: types.CanonicalTypeId,
    resolvers: Resolvers,
) !layout.LayoutResult {
    return resolvers.layout_for_key(active, .{
        .type_id = type_id,
        .target_name = parent_key.target_name,
        .repr_context = try reprContextForType(active, type_id, resolvers),
    });
}

fn reprContextForType(
    active: *session.Session,
    type_id: types.CanonicalTypeId,
    resolvers: Resolvers,
) !layout.ReprContext {
    if (type_id.index >= active.caches.canonical_types.items.len) return .default;
    return switch (active.caches.canonical_types.items[type_id.index].key) {
        .nominal => |nominal| blk: {
            if (nominal.item_index >= active.semantic_index.items.items.len) break :blk .default;
            const checked = try resolvers.checked_signature(active, .{ .index = nominal.item_index });
            break :blk .{ .declared = checked.surface.declared_repr };
        },
        else => .default,
    };
}

fn sizedLayout(
    active: *session.Session,
    key: layout.LayoutKey,
    size: u64,
    alignment: u32,
    storage: layout.StorageShape,
    foreign_stable: bool,
) !layout.LayoutResult {
    return .{
        .key = try layout.cloneLayoutKey(active.allocator, key),
        .status = .sized,
        .size = size,
        .@"align" = alignment,
        .storage = storage,
        .lowerability = .lowerable,
        .foreign_stable = foreign_stable,
    };
}

fn unsizedLayout(active: *session.Session, key: layout.LayoutKey, storage: layout.StorageShape, reason: []const u8) !layout.LayoutResult {
    var result_key = try layout.cloneLayoutKey(active.allocator, key);
    errdefer layout.deinitLayoutKey(active.allocator, &result_key);
    return .{
        .key = result_key,
        .status = .unsized,
        .storage = storage,
        .lowerability = .not_lowerable,
        .unsupported_reason = try active.allocator.dupe(u8, reason),
    };
}

fn aggregateResult(
    active: *session.Session,
    key: layout.LayoutKey,
    size: u64,
    alignment: u32,
    storage: layout.StorageShape,
    foreign_stable: bool,
    fields: ?*array_list.Managed(layout.FieldLayout),
    variants: ?*array_list.Managed(layout.VariantLayout),
    tag: ?layout.TagLayout,
) !layout.LayoutResult {
    var result_key = try layout.cloneLayoutKey(active.allocator, key);
    errdefer layout.deinitLayoutKey(active.allocator, &result_key);

    const field_slice = if (fields) |field_list| try field_list.toOwnedSlice() else &.{};
    errdefer deinitFieldSlice(active.allocator, field_slice);
    const variant_slice = if (variants) |variant_list| try variant_list.toOwnedSlice() else &.{};
    errdefer deinitVariantSlice(active.allocator, variant_slice);

    return .{
        .key = result_key,
        .status = .sized,
        .size = size,
        .@"align" = alignment,
        .storage = storage,
        .lowerability = .lowerable,
        .foreign_stable = foreign_stable,
        .fields = field_slice,
        .variants = variant_slice,
        .tag = tag,
    };
}

fn appendField(
    allocator: std.mem.Allocator,
    fields: *array_list.Managed(layout.FieldLayout),
    name: []const u8,
    type_id: types.CanonicalTypeId,
    offset: u64,
    size: u64,
    alignment: u32,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try fields.append(.{
        .name = owned_name,
        .type_id = type_id,
        .offset = offset,
        .size = size,
        .@"align" = alignment,
    });
}

fn appendVariant(
    allocator: std.mem.Allocator,
    variants: *array_list.Managed(layout.VariantLayout),
    name: []const u8,
    tag_value: i128,
) !void {
    return appendVariantWithPayload(allocator, variants, name, tag_value, null);
}

fn appendVariantWithPayload(
    allocator: std.mem.Allocator,
    variants: *array_list.Managed(layout.VariantLayout),
    name: []const u8,
    tag_value: i128,
    payload_layout: ?types.CanonicalTypeId,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try variants.append(.{
        .name = owned_name,
        .tag_value = tag_value,
        .payload_layout = payload_layout,
    });
}

fn tupleFieldName(allocator: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "_{d}", .{index});
}

fn deinitFieldSlice(allocator: std.mem.Allocator, fields: []const layout.FieldLayout) void {
    deinitFieldItems(allocator, fields);
    if (fields.len != 0) allocator.free(fields);
}

fn deinitFieldItems(allocator: std.mem.Allocator, fields: []const layout.FieldLayout) void {
    for (fields) |field| {
        if (field.name.len != 0) allocator.free(field.name);
    }
}

fn deinitVariantSlice(allocator: std.mem.Allocator, variants: []const layout.VariantLayout) void {
    deinitVariantItems(allocator, variants);
    if (variants.len != 0) allocator.free(variants);
}

fn deinitVariantItems(allocator: std.mem.Allocator, variants: []const layout.VariantLayout) void {
    for (variants) |variant| {
        if (variant.name.len != 0) allocator.free(variant.name);
    }
}

fn alignForward(value: u64, alignment: u32) !u64 {
    if (alignment == 0) return error.InvalidLayoutAlignment;
    const alignment_value: u64 = alignment;
    const remainder = value % alignment_value;
    if (remainder == 0) return value;
    return std.math.add(u64, value, alignment_value - remainder);
}

fn declaredReprIsC(repr: types.DeclaredRepr) bool {
    return switch (repr) {
        .c, .c_enum => true,
        .default => false,
    };
}

fn targetLayoutModel(target_name: []const u8) ?TargetLayoutModel {
    if (std.mem.eql(u8, target_name, target.windows.name)) {
        return .{
            .pointer_size = 8,
            .pointer_alignment = 8,
            .c_long_size = 4,
            .c_long_alignment = 4,
            .c_wchar_size = 2,
            .c_wchar_alignment = 2,
        };
    }
    if (std.mem.eql(u8, target_name, target.linux.name)) {
        return .{
            .pointer_size = 8,
            .pointer_alignment = 8,
            .c_long_size = 8,
            .c_long_alignment = 8,
            .c_wchar_size = 4,
            .c_wchar_alignment = 4,
        };
    }
    return null;
}
