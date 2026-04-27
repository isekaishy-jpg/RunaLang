const std = @import("std");
const array_list = std.array_list;
const abi = @import("../abi/root.zig");
const layout = @import("../layout/root.zig");
pub const program = @import("program.zig");
const session_ids = @import("../session/ids.zig");
const types = @import("../types/root.zig");

pub const summary = "Backend lowering contract descriptors consumed by codegen.";

pub const LoweredModuleKey = struct {
    module_id: session_ids.ModuleId,
    target_name: []const u8,
    output_kind: OutputKind = .module,

    pub fn eql(lhs: LoweredModuleKey, rhs: LoweredModuleKey) bool {
        return lhs.module_id.index == rhs.module_id.index and
            std.mem.eql(u8, lhs.target_name, rhs.target_name) and
            lhs.output_kind == rhs.output_kind;
    }
};

pub const OutputKind = enum {
    module,
    bin,
    cdylib,
};

pub const LayoutDescriptor = struct {
    status: layout.LayoutStatus,
    storage: layout.StorageShape,
    size: ?u64 = null,
    @"align": ?u32 = null,
    lowerability: layout.Lowerability,
    foreign_stable: bool = false,
};

pub const AbiDescriptor = struct {
    family: abi.AbiFamily,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: abi.PassMode,
};

pub fn cBuiltinTypeName(ty: types.Builtin) []const u8 {
    return ty.cName();
}

pub fn cAbiAliasTypeName(alias: types.CAbiAlias) []const u8 {
    return switch (alias) {
        .c_bool => "bool",
        .c_char => "char",
        .c_signed_char => "signed char",
        .c_unsigned_char => "unsigned char",
        .c_short => "short",
        .c_ushort => "unsigned short",
        .c_int => "int",
        .c_uint => "unsigned int",
        .c_long => "long",
        .c_ulong => "unsigned long",
        .c_long_long => "long long",
        .c_ulong_long => "unsigned long long",
        .c_size => "size_t",
        .c_ptr_diff => "ptrdiff_t",
        .c_wchar => "wchar_t",
        .c_void => "void",
    };
}

pub const StorageDescriptor = struct {
    type_id: types.CanonicalTypeId,
    layout: LayoutDescriptor,
    abi_info: ?AbiDescriptor = null,
};

pub const AggregateDescriptor = struct {
    item_id: session_ids.ItemId,
    type_id: types.CanonicalTypeId,
    layout: LayoutDescriptor,
    abi_info: ?AbiDescriptor = null,
};

pub const CallableDescriptor = struct {
    item_id: ?session_ids.ItemId = null,
    type_id: ?types.CanonicalTypeId = null,
    abi_family: ?abi.AbiFamily = null,
    callable_safe: bool = false,
    variadic: bool = false,
    callback: bool = false,
    no_unwind: bool = false,
    failure_policy: abi.ForeignFailurePolicy = .none,
};

pub const FunctionBodyDescriptor = struct {
    item_id: session_ids.ItemId,
    body_id: session_ids.BodyId,
    program_checked: bool,
    statements_checked: bool = false,
    expressions_checked: bool = false,
    ownership_checked: bool = false,
    borrow_checked: bool = false,
    lifetimes_checked: bool = false,
    regions_checked: bool = false,
};

pub const ImportDescriptor = struct {
    name: []const u8,
    link_name: ?[]const u8 = null,
    callable_index: ?usize = null,
    abi_family: ?abi.AbiFamily = null,
    no_unwind: bool = false,
};

pub const ExportDescriptor = struct {
    local_name: []const u8,
    name: []const u8,
    item_id: session_ids.ItemId,
    abi_family: ?abi.AbiFamily = null,
    no_unwind: bool = false,
    failure_policy: abi.ForeignFailurePolicy = .none,
};

pub const BoundaryTransportFamily = enum {
    direct_api,
    message,
    host_plugin,
};

pub const BoundaryInvocationShape = enum {
    typed_stub,
    typed_adapter,
};

pub const BoundaryFailureSurface = enum {
    none,
    explicit_transport_failure,
};

pub const BoundarySurfaceDescriptor = struct {
    item_id: session_ids.ItemId,
    callable_index: usize,
    name: []const u8,
    is_suspend: bool,
    transport: BoundaryTransportFamily,
    invocation_shape: BoundaryInvocationShape,
    failure_surface: BoundaryFailureSurface,
    input_type_name: []const u8,
    output_type_name: []const u8,
    capability_families: []const []const u8 = &.{},
};

pub const ConstDescriptor = struct {
    const_id: session_ids.ConstId,
    type_id: types.CanonicalTypeId,
    lowerable: bool,
};

pub const RuntimeRequirementKind = enum {
    entry_adapter,
    fatal_abort,
    async_hooks,
    dynamic_library_hooks,
    observability_hooks,
};

pub const RuntimeRequirementDescriptor = struct {
    kind: RuntimeRequirementKind,
    required: bool,
    supported: bool,
};

pub const RuntimeRequirementKey = struct {
    module_id: session_ids.ModuleId,
    target_name: []const u8,
    output_kind: OutputKind,

    pub fn eql(lhs: RuntimeRequirementKey, rhs: RuntimeRequirementKey) bool {
        return lhs.module_id.index == rhs.module_id.index and
            std.mem.eql(u8, lhs.target_name, rhs.target_name) and
            lhs.output_kind == rhs.output_kind;
    }
};

pub const RuntimeRequirementResult = struct {
    key: RuntimeRequirementKey,
    requirements: []const RuntimeRequirementDescriptor = &.{},
    unsupported: []const UnsupportedLowering = &.{},
};

pub const UnsupportedLowering = struct {
    code: []const u8,
    message: []const u8,
};

pub const LoweredModule = struct {
    key: LoweredModuleKey,
    storage: []const StorageDescriptor = &.{},
    aggregates: []const AggregateDescriptor = &.{},
    callables: []const CallableDescriptor = &.{},
    bodies: []const FunctionBodyDescriptor = &.{},
    imports: []const ImportDescriptor = &.{},
    exports: []const ExportDescriptor = &.{},
    boundary_surfaces: []const BoundarySurfaceDescriptor = &.{},
    consts: []const ConstDescriptor = &.{},
    runtime_requirements: []const RuntimeRequirementDescriptor = &.{},
    unsupported: []const UnsupportedLowering = &.{},
    program: ?program.Module = null,
};

pub fn emptyLoweredModule(allocator: std.mem.Allocator, key: LoweredModuleKey) !LoweredModule {
    return .{
        .key = try cloneLoweredModuleKey(allocator, key),
    };
}

pub fn cloneLoweredModuleKey(allocator: std.mem.Allocator, key: LoweredModuleKey) !LoweredModuleKey {
    return .{
        .module_id = key.module_id,
        .target_name = try allocator.dupe(u8, key.target_name),
        .output_kind = key.output_kind,
    };
}

pub fn deinitLoweredModuleKey(allocator: std.mem.Allocator, key: *LoweredModuleKey) void {
    if (key.target_name.len != 0) allocator.free(key.target_name);
    key.* = .{
        .module_id = .{ .index = 0 },
        .target_name = "",
        .output_kind = .module,
    };
}

pub fn cloneRuntimeRequirementKey(allocator: std.mem.Allocator, key: RuntimeRequirementKey) !RuntimeRequirementKey {
    return .{
        .module_id = key.module_id,
        .target_name = try allocator.dupe(u8, key.target_name),
        .output_kind = key.output_kind,
    };
}

pub fn deinitRuntimeRequirementKey(allocator: std.mem.Allocator, key: *RuntimeRequirementKey) void {
    if (key.target_name.len != 0) allocator.free(key.target_name);
    key.* = .{
        .module_id = .{ .index = 0 },
        .target_name = "",
        .output_kind = .module,
    };
}

pub fn deinitRuntimeRequirementResult(allocator: std.mem.Allocator, result: *RuntimeRequirementResult) void {
    deinitRuntimeRequirementKey(allocator, &result.key);
    if (result.requirements.len != 0) allocator.free(result.requirements);
    for (result.unsupported) |unsupported| {
        if (unsupported.code.len != 0) allocator.free(unsupported.code);
        if (unsupported.message.len != 0) allocator.free(unsupported.message);
    }
    if (result.unsupported.len != 0) allocator.free(result.unsupported);
    result.* = .{
        .key = .{
            .module_id = .{ .index = 0 },
            .target_name = "",
            .output_kind = .module,
        },
    };
}

pub fn deinitLoweredModule(allocator: std.mem.Allocator, lowered: *LoweredModule) void {
    deinitLoweredModuleKey(allocator, &lowered.key);
    if (lowered.storage.len != 0) allocator.free(lowered.storage);
    if (lowered.aggregates.len != 0) allocator.free(lowered.aggregates);
    if (lowered.callables.len != 0) allocator.free(lowered.callables);
    if (lowered.bodies.len != 0) allocator.free(lowered.bodies);
    for (lowered.imports) |import_desc| {
        if (import_desc.name.len != 0) allocator.free(import_desc.name);
        if (import_desc.link_name) |link_name| allocator.free(link_name);
    }
    if (lowered.imports.len != 0) allocator.free(lowered.imports);
    for (lowered.exports) |export_desc| {
        if (export_desc.local_name.len != 0) allocator.free(export_desc.local_name);
        if (export_desc.name.len != 0) allocator.free(export_desc.name);
    }
    if (lowered.exports.len != 0) allocator.free(lowered.exports);
    deinitBoundarySurfaces(allocator, lowered.boundary_surfaces);
    if (lowered.consts.len != 0) allocator.free(lowered.consts);
    if (lowered.runtime_requirements.len != 0) allocator.free(lowered.runtime_requirements);
    for (lowered.unsupported) |unsupported| {
        if (unsupported.code.len != 0) allocator.free(unsupported.code);
        if (unsupported.message.len != 0) allocator.free(unsupported.message);
    }
    if (lowered.unsupported.len != 0) allocator.free(lowered.unsupported);
    if (lowered.program) |*module| module.deinit();
    lowered.* = .{
        .key = .{
            .module_id = .{ .index = 0 },
            .target_name = "",
            .output_kind = .module,
        },
    };
}

pub fn mergeLoweredModules(
    allocator: std.mem.Allocator,
    key: LoweredModuleKey,
    modules: []const *const LoweredModule,
) !LoweredModule {
    var merged_key = try cloneLoweredModuleKey(allocator, key);
    errdefer deinitLoweredModuleKey(allocator, &merged_key);

    var storage = array_list.Managed(StorageDescriptor).init(allocator);
    defer storage.deinit();
    var aggregates = array_list.Managed(AggregateDescriptor).init(allocator);
    defer aggregates.deinit();
    var callables = array_list.Managed(CallableDescriptor).init(allocator);
    defer callables.deinit();
    var bodies = array_list.Managed(FunctionBodyDescriptor).init(allocator);
    defer bodies.deinit();
    var imports = array_list.Managed(ImportDescriptor).init(allocator);
    defer imports.deinit();
    errdefer deinitImportItems(allocator, imports.items);
    var exports = array_list.Managed(ExportDescriptor).init(allocator);
    defer exports.deinit();
    errdefer deinitExportItems(allocator, exports.items);
    var boundary_surfaces = array_list.Managed(BoundarySurfaceDescriptor).init(allocator);
    defer boundary_surfaces.deinit();
    errdefer deinitBoundarySurfaceItems(allocator, boundary_surfaces.items);
    var consts = array_list.Managed(ConstDescriptor).init(allocator);
    defer consts.deinit();
    var runtime_requirements = array_list.Managed(RuntimeRequirementDescriptor).init(allocator);
    defer runtime_requirements.deinit();
    var unsupported = array_list.Managed(UnsupportedLowering).init(allocator);
    defer unsupported.deinit();
    errdefer deinitUnsupportedItems(allocator, unsupported.items);
    var program_descriptors = array_list.Managed(*const program.Module).init(allocator);
    defer program_descriptors.deinit();

    for (modules) |module| {
        try storage.appendSlice(module.storage);
        try aggregates.appendSlice(module.aggregates);
        try callables.appendSlice(module.callables);
        try bodies.appendSlice(module.bodies);
        try consts.appendSlice(module.consts);
        try runtime_requirements.appendSlice(module.runtime_requirements);
        for (module.imports) |item| try appendImport(allocator, &imports, item);
        for (module.exports) |item| try appendExport(allocator, &exports, item);
        for (module.boundary_surfaces) |item| try appendBoundarySurface(allocator, &boundary_surfaces, item);
        for (module.unsupported) |item| try appendUnsupported(allocator, &unsupported, item);
        if (module.program) |*program_module| try program_descriptors.append(program_module);
    }

    const storage_slice = try storage.toOwnedSlice();
    errdefer if (storage_slice.len != 0) allocator.free(storage_slice);
    const aggregate_slice = try aggregates.toOwnedSlice();
    errdefer if (aggregate_slice.len != 0) allocator.free(aggregate_slice);
    const callable_slice = try callables.toOwnedSlice();
    errdefer if (callable_slice.len != 0) allocator.free(callable_slice);
    const body_slice = try bodies.toOwnedSlice();
    errdefer if (body_slice.len != 0) allocator.free(body_slice);
    const import_slice = try imports.toOwnedSlice();
    errdefer deinitImports(allocator, import_slice);
    const export_slice = try exports.toOwnedSlice();
    errdefer deinitExports(allocator, export_slice);
    const boundary_surface_slice = try boundary_surfaces.toOwnedSlice();
    errdefer deinitBoundarySurfaces(allocator, boundary_surface_slice);
    const const_slice = try consts.toOwnedSlice();
    errdefer if (const_slice.len != 0) allocator.free(const_slice);
    const runtime_requirement_slice = try runtime_requirements.toOwnedSlice();
    errdefer if (runtime_requirement_slice.len != 0) allocator.free(runtime_requirement_slice);
    const unsupported_slice = try unsupported.toOwnedSlice();
    errdefer deinitUnsupported(allocator, unsupported_slice);

    return .{
        .key = merged_key,
        .storage = storage_slice,
        .aggregates = aggregate_slice,
        .callables = callable_slice,
        .bodies = body_slice,
        .imports = import_slice,
        .exports = export_slice,
        .boundary_surfaces = boundary_surface_slice,
        .consts = const_slice,
        .runtime_requirements = runtime_requirement_slice,
        .unsupported = unsupported_slice,
        .program = if (program_descriptors.items.len != 0)
            try program.mergeModules(allocator, program_descriptors.items)
        else
            null,
    };
}

fn appendBoundarySurface(allocator: std.mem.Allocator, boundary_surfaces: *array_list.Managed(BoundarySurfaceDescriptor), item: BoundarySurfaceDescriptor) !void {
    const owned_name = try allocator.dupe(u8, item.name);
    errdefer allocator.free(owned_name);
    const owned_input = try allocator.dupe(u8, item.input_type_name);
    errdefer allocator.free(owned_input);
    const owned_output = try allocator.dupe(u8, item.output_type_name);
    errdefer allocator.free(owned_output);
    const owned_capabilities = try cloneStringSlice(allocator, item.capability_families);
    errdefer freeStringSlice(allocator, owned_capabilities);

    try boundary_surfaces.append(.{
        .item_id = item.item_id,
        .callable_index = item.callable_index,
        .name = owned_name,
        .is_suspend = item.is_suspend,
        .transport = item.transport,
        .invocation_shape = item.invocation_shape,
        .failure_surface = item.failure_surface,
        .input_type_name = owned_input,
        .output_type_name = owned_output,
        .capability_families = owned_capabilities,
    });
}

fn appendImport(allocator: std.mem.Allocator, imports: *array_list.Managed(ImportDescriptor), item: ImportDescriptor) !void {
    const owned_name = try allocator.dupe(u8, item.name);
    errdefer allocator.free(owned_name);
    const owned_link_name = if (item.link_name) |link_name| try allocator.dupe(u8, link_name) else null;
    errdefer if (owned_link_name) |link_name| allocator.free(link_name);
    try imports.append(.{
        .name = owned_name,
        .link_name = owned_link_name,
        .callable_index = item.callable_index,
        .abi_family = item.abi_family,
        .no_unwind = item.no_unwind,
    });
}

fn appendExport(allocator: std.mem.Allocator, exports: *array_list.Managed(ExportDescriptor), item: ExportDescriptor) !void {
    const owned_local_name = try allocator.dupe(u8, item.local_name);
    errdefer allocator.free(owned_local_name);
    const owned_name = try allocator.dupe(u8, item.name);
    errdefer allocator.free(owned_name);
    try exports.append(.{
        .local_name = owned_local_name,
        .name = owned_name,
        .item_id = item.item_id,
        .abi_family = item.abi_family,
        .no_unwind = item.no_unwind,
        .failure_policy = item.failure_policy,
    });
}

fn appendUnsupported(allocator: std.mem.Allocator, unsupported: *array_list.Managed(UnsupportedLowering), item: UnsupportedLowering) !void {
    const owned_code = try allocator.dupe(u8, item.code);
    errdefer allocator.free(owned_code);
    const owned_message = try allocator.dupe(u8, item.message);
    errdefer allocator.free(owned_message);
    try unsupported.append(.{
        .code = owned_code,
        .message = owned_message,
    });
}

fn deinitImports(allocator: std.mem.Allocator, imports: []const ImportDescriptor) void {
    deinitImportItems(allocator, imports);
    if (imports.len != 0) allocator.free(imports);
}

fn deinitImportItems(allocator: std.mem.Allocator, imports: []const ImportDescriptor) void {
    for (imports) |item| {
        if (item.name.len != 0) allocator.free(item.name);
        if (item.link_name) |link_name| allocator.free(link_name);
    }
}

fn deinitExports(allocator: std.mem.Allocator, exports: []const ExportDescriptor) void {
    deinitExportItems(allocator, exports);
    if (exports.len != 0) allocator.free(exports);
}

fn deinitBoundarySurfaces(allocator: std.mem.Allocator, boundary_surfaces: []const BoundarySurfaceDescriptor) void {
    deinitBoundarySurfaceItems(allocator, boundary_surfaces);
    if (boundary_surfaces.len != 0) allocator.free(boundary_surfaces);
}

fn deinitBoundarySurfaceItems(allocator: std.mem.Allocator, boundary_surfaces: []const BoundarySurfaceDescriptor) void {
    for (boundary_surfaces) |item| {
        if (item.name.len != 0) allocator.free(item.name);
        if (item.input_type_name.len != 0) allocator.free(item.input_type_name);
        if (item.output_type_name.len != 0) allocator.free(item.output_type_name);
        freeStringSlice(allocator, item.capability_families);
    }
}

fn deinitExportItems(allocator: std.mem.Allocator, exports: []const ExportDescriptor) void {
    for (exports) |item| {
        if (item.local_name.len != 0) allocator.free(item.local_name);
        if (item.name.len != 0) allocator.free(item.name);
    }
}

fn deinitUnsupported(allocator: std.mem.Allocator, unsupported: []const UnsupportedLowering) void {
    deinitUnsupportedItems(allocator, unsupported);
    if (unsupported.len != 0) allocator.free(unsupported);
}

fn deinitUnsupportedItems(allocator: std.mem.Allocator, unsupported: []const UnsupportedLowering) void {
    for (unsupported) |item| {
        if (item.code.len != 0) allocator.free(item.code);
        if (item.message.len != 0) allocator.free(item.message);
    }
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
    }
    return cloned;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| {
        if (value.len != 0) allocator.free(value);
    }
    if (values.len != 0) allocator.free(values);
}
