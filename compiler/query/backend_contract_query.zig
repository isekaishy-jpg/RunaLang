const std = @import("std");
const abi = @import("../abi/root.zig");
const backend_contract = @import("../backend_contract/root.zig");
const dynamic_library = @import("../runtime/dynamic_library/root.zig");
const layout = @import("../layout/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const target = @import("../target/root.zig");
const types = @import("../types/root.zig");

const array_list = std.array_list;

pub const Resolvers = struct {
    canonical_type_expression: *const fn (*session.Session, session.ModuleId, []const u8) anyerror!types.CanonicalTypeId,
    checked_signature: *const fn (*session.Session, session.ItemId) anyerror!query_types.CheckedSignature,
    checked_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.CheckedBody,
    statements_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.StatementResult,
    expressions_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.ExpressionResult,
    ownership_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.OwnershipResult,
    borrow_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.BorrowResult,
    lifetimes_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.LifetimeResult,
    regions_by_body: *const fn (*session.Session, session.BodyId) anyerror!query_types.RegionResult,
    runtime_requirements: *const fn (*session.Session, backend_contract.RuntimeRequirementKey) anyerror!backend_contract.RuntimeRequirementResult,
    layout_for_key: *const fn (*session.Session, layout.LayoutKey) anyerror!layout.LayoutResult,
    abi_type_for_key: *const fn (*session.Session, abi.AbiTypeKey) anyerror!abi.AbiTypeResult,
    abi_callable_for_key: *const fn (*session.Session, abi.AbiCallableKey) anyerror!abi.AbiCallableResult,
    program_descriptors: *const fn (*session.Session, session.ModuleId) anyerror!backend_contract.program.Module,
};

pub fn build(active: *session.Session, key: backend_contract.LoweredModuleKey, resolvers: Resolvers) !backend_contract.LoweredModule {
    var storage = array_list.Managed(backend_contract.StorageDescriptor).init(active.allocator);
    defer storage.deinit();
    var aggregates = array_list.Managed(backend_contract.AggregateDescriptor).init(active.allocator);
    defer aggregates.deinit();
    var callables = array_list.Managed(backend_contract.CallableDescriptor).init(active.allocator);
    defer callables.deinit();
    var bodies = array_list.Managed(backend_contract.FunctionBodyDescriptor).init(active.allocator);
    defer bodies.deinit();
    var imports = array_list.Managed(backend_contract.ImportDescriptor).init(active.allocator);
    defer imports.deinit();
    errdefer deinitImportItems(active.allocator, imports.items);
    var exports = array_list.Managed(backend_contract.ExportDescriptor).init(active.allocator);
    defer exports.deinit();
    errdefer deinitExportItems(active.allocator, exports.items);
    var boundary_surfaces = array_list.Managed(backend_contract.BoundarySurfaceDescriptor).init(active.allocator);
    defer boundary_surfaces.deinit();
    errdefer deinitBoundarySurfaceItems(active.allocator, boundary_surfaces.items);
    var consts = array_list.Managed(backend_contract.ConstDescriptor).init(active.allocator);
    defer consts.deinit();
    var unsupported = array_list.Managed(backend_contract.UnsupportedLowering).init(active.allocator);
    defer unsupported.deinit();
    errdefer deinitUnsupportedItems(active.allocator, unsupported.items);
    const runtime_result = try resolvers.runtime_requirements(active, .{
        .module_id = key.module_id,
        .target_name = key.target_name,
        .output_kind = key.output_kind,
    });
    for (runtime_result.unsupported) |item| {
        try appendUnsupported(active.allocator, &unsupported, item.code, item.message);
    }
    var dynamic_library_required = false;

    for (active.semantic_index.items.items, 0..) |item_entry, item_index| {
        if (item_entry.module_id.index != key.module_id.index) continue;
        const item_id = session.ItemId{ .index = item_index };
        const item = active.item(item_id);
        const checked = try resolvers.checked_signature(active, item_id);
        switch (checked.facts) {
            .struct_type, .union_type, .enum_type, .opaque_type => try appendTypeDescriptors(
                active,
                key,
                item_id,
                item.name,
                checked.facts,
                checked.surface.declared_repr,
                &storage,
                &aggregates,
                &unsupported,
                resolvers,
            ),
            .function => |function| try appendCallableDescriptors(
                active,
                key,
                item_id,
                item.name,
                item_entry.body_id,
                item.has_body,
                checked.boundary_kind == .api,
                checked.module_id,
                checked.surface.abi_role,
                function,
                &callables,
                &bodies,
                &imports,
                &exports,
                &boundary_surfaces,
                &unsupported,
                &dynamic_library_required,
                resolvers,
            ),
            .const_item => |const_item| try appendConstDescriptor(
                active,
                key,
                item_entry.const_id,
                checked.module_id,
                const_item,
                &consts,
                &unsupported,
                resolvers,
            ),
            else => {},
        }
    }

    var result_key = try backend_contract.cloneLoweredModuleKey(active.allocator, key);
    errdefer backend_contract.deinitLoweredModuleKey(active.allocator, &result_key);
    const storage_slice = try storage.toOwnedSlice();
    errdefer if (storage_slice.len != 0) active.allocator.free(storage_slice);
    const aggregate_slice = try aggregates.toOwnedSlice();
    errdefer if (aggregate_slice.len != 0) active.allocator.free(aggregate_slice);
    const callable_slice = try callables.toOwnedSlice();
    errdefer if (callable_slice.len != 0) active.allocator.free(callable_slice);
    const body_slice = try bodies.toOwnedSlice();
    errdefer if (body_slice.len != 0) active.allocator.free(body_slice);
    const import_slice = try imports.toOwnedSlice();
    errdefer deinitImports(active.allocator, import_slice);
    const export_slice = try exports.toOwnedSlice();
    errdefer deinitExports(active.allocator, export_slice);
    const boundary_surface_slice = try boundary_surfaces.toOwnedSlice();
    errdefer deinitBoundarySurfaces(active.allocator, boundary_surface_slice);
    const const_slice = try consts.toOwnedSlice();
    errdefer if (const_slice.len != 0) active.allocator.free(const_slice);
    const runtime_requirement_slice = try cloneRuntimeRequirementsWithDynamic(
        active.allocator,
        runtime_result.requirements,
        dynamic_library_required,
        key.target_name,
        &unsupported,
    );
    errdefer if (runtime_requirement_slice.len != 0) active.allocator.free(runtime_requirement_slice);
    var program = try resolvers.program_descriptors(active, key.module_id);
    errdefer program.deinit();
    const unsupported_slice = try unsupported.toOwnedSlice();
    errdefer deinitUnsupported(active.allocator, unsupported_slice);

    return .{
        .key = result_key,
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
        .program = program,
    };
}

fn appendTypeDescriptors(
    active: *session.Session,
    key: backend_contract.LoweredModuleKey,
    item_id: session.ItemId,
    item_name: []const u8,
    facts: query_types.SignatureFacts,
    declared_repr: types.DeclaredRepr,
    storage: *array_list.Managed(backend_contract.StorageDescriptor),
    aggregates: *array_list.Managed(backend_contract.AggregateDescriptor),
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    resolvers: Resolvers,
) !void {
    const type_id = try resolvers.canonical_type_expression(active, key.module_id, item_name);
    const type_layout = try resolvers.layout_for_key(active, .{
        .type_id = type_id,
        .target_name = key.target_name,
        .repr_context = .{ .declared = declared_repr },
    });
    const type_abi = try resolvers.abi_type_for_key(active, .{
        .type_id = type_id,
        .target_name = key.target_name,
        .family = .c,
    });
    try storage.append(.{
        .type_id = type_id,
        .layout = layoutDescriptor(type_layout),
        .abi_info = abiDescriptor(type_abi),
    });
    switch (facts) {
        .struct_type, .union_type, .enum_type => try aggregates.append(.{
            .item_id = item_id,
            .type_id = type_id,
            .layout = layoutDescriptor(type_layout),
            .abi_info = abiDescriptor(type_abi),
        }),
        else => {},
    }
    if (type_layout.status == .unsupported) {
        try appendUnsupported(active.allocator, unsupported, "backend.layout.unsupported", type_layout.unsupported_reason orelse "type layout is unsupported");
    }
}

fn appendCallableDescriptors(
    active: *session.Session,
    key: backend_contract.LoweredModuleKey,
    item_id: session.ItemId,
    item_name: []const u8,
    body_id: ?session.BodyId,
    has_body: bool,
    is_boundary_api: bool,
    module_id: session.ModuleId,
    role: query_types.AbiSurfaceRole,
    function: query_types.FunctionSignature,
    callables: *array_list.Managed(backend_contract.CallableDescriptor),
    bodies: *array_list.Managed(backend_contract.FunctionBodyDescriptor),
    imports: *array_list.Managed(backend_contract.ImportDescriptor),
    exports: *array_list.Managed(backend_contract.ExportDescriptor),
    boundary_surfaces: *array_list.Managed(backend_contract.BoundarySurfaceDescriptor),
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    dynamic_library_required: *bool,
    resolvers: Resolvers,
) !void {
    const family = abiFamilyForConvention(function.abi);
    var callable_safe = true;
    var variadic = false;
    var no_unwind = false;
    var failure_policy = abi.ForeignFailurePolicy.none;
    if (family) |abi_family| {
        const callable_abi = try resolvers.abi_callable_for_key(active, .{
            .subject = .{ .item = item_id },
            .target_name = key.target_name,
            .family = abi_family,
            .role = switch (role) {
                .foreign_import => .foreign_import,
                .foreign_export => .foreign_export,
                .none => .ordinary,
            },
        });
        callable_safe = callable_abi.callable_safe;
        if (!callable_abi.callable_safe) {
            try appendUnsupported(active.allocator, unsupported, "backend.abi.callable", callable_abi.reason orelse "callable ABI classification failed");
        }
        variadic = callable_abi.variadic;
        no_unwind = callable_abi.no_unwind;
        failure_policy = callable_abi.failure_policy;
    } else if (role != .none) {
        callable_safe = false;
        try appendUnsupported(active.allocator, unsupported, "backend.abi.convention", "foreign callable has no supported ABI convention");
    }

    try callables.append(.{
        .item_id = item_id,
        .abi_family = family,
        .callable_safe = callable_safe,
        .variadic = variadic,
        .no_unwind = no_unwind,
        .failure_policy = failure_policy,
    });
    if (is_boundary_api) {
        try appendBoundarySurface(
            active,
            boundary_surfaces,
            item_id,
            callables.items.len - 1,
            item_name,
            module_id,
            function,
            resolvers,
        );
    }
    if (has_body) {
        if (body_id) |id| {
            const checked_body = try resolvers.checked_body(active, id);
            if (checkedBodyUsesDynamicLibrary(checked_body)) dynamic_library_required.* = true;
            _ = try resolvers.statements_by_body(active, id);
            _ = try resolvers.expressions_by_body(active, id);
            _ = try resolvers.ownership_by_body(active, id);
            _ = try resolvers.borrow_by_body(active, id);
            _ = try resolvers.lifetimes_by_body(active, id);
            _ = try resolvers.regions_by_body(active, id);
            try bodies.append(.{
                .item_id = item_id,
                .body_id = id,
                .program_checked = true,
                .statements_checked = true,
                .expressions_checked = true,
                .ownership_checked = true,
                .borrow_checked = true,
                .lifetimes_checked = true,
                .regions_checked = true,
            });
        }
    }
    switch (role) {
        .foreign_import => try appendImport(active.allocator, imports, item_name, function.link_name, callables.items.len - 1, family, no_unwind),
        .foreign_export => try appendExport(active.allocator, exports, item_name, function.export_name orelse item_name, item_id, family, no_unwind, failure_policy),
        .none => {},
    }
}

fn appendBoundarySurface(
    active: *session.Session,
    boundary_surfaces: *array_list.Managed(backend_contract.BoundarySurfaceDescriptor),
    item_id: session.ItemId,
    callable_index: usize,
    item_name: []const u8,
    module_id: session.ModuleId,
    function: query_types.FunctionSignature,
    resolvers: Resolvers,
) !void {
    const name = try active.allocator.dupe(u8, item_name);
    errdefer active.allocator.free(name);
    const input_type_name = try renderPackedInputType(active.allocator, function.parameters);
    errdefer active.allocator.free(input_type_name);
    const output_type_name = try active.allocator.dupe(u8, function.return_type_name);
    errdefer active.allocator.free(output_type_name);
    const capability_families = try collectCapabilityFamilies(active, module_id, function, resolvers);
    errdefer freeStringSlice(active.allocator, capability_families);

    try boundary_surfaces.append(.{
        .item_id = item_id,
        .callable_index = callable_index,
        .name = name,
        .is_suspend = function.is_suspend,
        .transport = .direct_api,
        .invocation_shape = .typed_stub,
        .failure_surface = .none,
        .input_type_name = input_type_name,
        .output_type_name = output_type_name,
        .capability_families = capability_families,
    });
}

fn appendConstDescriptor(
    active: *session.Session,
    key: backend_contract.LoweredModuleKey,
    const_id: ?session.ConstId,
    module_id: session.ModuleId,
    const_item: query_types.ConstSignature,
    consts: *array_list.Managed(backend_contract.ConstDescriptor),
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    resolvers: Resolvers,
) !void {
    const id = const_id orelse return;
    const type_id = try resolvers.canonical_type_expression(active, module_id, const_item.type_name);
    const type_layout = try resolvers.layout_for_key(active, .{
        .type_id = type_id,
        .target_name = key.target_name,
        .repr_context = try reprContextForType(active, type_id, resolvers),
    });
    const lowerable = type_layout.lowerability == .lowerable;
    try consts.append(.{
        .const_id = id,
        .type_id = type_id,
        .lowerable = lowerable,
    });
    if (!lowerable) {
        try appendUnsupported(active.allocator, unsupported, "backend.const.lowering", type_layout.unsupported_reason orelse "const type is not lowerable");
    }
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

fn renderPackedInputType(allocator: std.mem.Allocator, parameters: anytype) ![]const u8 {
    if (parameters.len == 0) return allocator.dupe(u8, "Unit");
    if (parameters.len == 1) return allocator.dupe(u8, parameters[0].type_name);

    var rendered = array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();

    try rendered.append('(');
    for (parameters, 0..) |parameter, index| {
        if (index != 0) try rendered.appendSlice(", ");
        try rendered.appendSlice(parameter.type_name);
    }
    try rendered.append(')');
    return rendered.toOwnedSlice();
}

fn collectCapabilityFamilies(
    active: *session.Session,
    module_id: session.ModuleId,
    function: query_types.FunctionSignature,
    resolvers: Resolvers,
) ![]const []const u8 {
    var families = array_list.Managed([]const u8).init(active.allocator);
    errdefer {
        for (families.items) |family| active.allocator.free(family);
        families.deinit();
    }

    for (function.parameters) |parameter| {
        try appendCapabilityFamily(active, &families, module_id, parameter.type_name, resolvers);
    }
    try appendCapabilityFamily(active, &families, module_id, function.return_type_name, resolvers);
    return families.toOwnedSlice();
}

fn appendCapabilityFamily(
    active: *session.Session,
    families: *array_list.Managed([]const u8),
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    resolvers: Resolvers,
) !void {
    const type_name = baseBoundaryTypeName(raw_type_name);
    if (type_name.len == 0) return;

    const item_id = resolveTypeItemId(active, module_id, type_name) orelse return;
    const signature = try resolvers.checked_signature(active, item_id);
    if (signature.boundary_kind != .capability) return;

    for (families.items) |existing| {
        if (std.mem.eql(u8, existing, signature.item.name)) return;
    }
    try families.append(try active.allocator.dupe(u8, signature.item.name));
}

fn resolveTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        for (active.semantic_index.items.items, 0..) |_, index| {
            const item = active.item(.{ .index = index });
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return .{ .index = index };
        }
    }

    return null;
}

fn baseBoundaryTypeName(raw_type_name: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, raw_type_name, " \t");
    if (trimmed.len == 0) return "";
    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const closing = std.mem.indexOfScalar(u8, trimmed, ']') orelse return trimmed;
        trimmed = std.mem.trim(u8, trimmed[closing + 1 ..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "read ")) trimmed = std.mem.trim(u8, trimmed["read ".len..], " \t");
    if (std.mem.startsWith(u8, trimmed, "edit ")) trimmed = std.mem.trim(u8, trimmed["edit ".len..], " \t");
    if (std.mem.indexOfAny(u8, trimmed, "[(")) |index| return std.mem.trim(u8, trimmed[0..index], " \t");
    return trimmed;
}

fn checkedBodyUsesDynamicLibrary(checked_body: query_types.CheckedBody) bool {
    for (checked_body.effect_sites) |site| {
        if (site.callee_name) |callee| {
            if (dynamic_library.isLeafCallee(callee)) return true;
        }
    }
    return false;
}

fn cloneRuntimeRequirementsWithDynamic(
    allocator: std.mem.Allocator,
    requirements: []const backend_contract.RuntimeRequirementDescriptor,
    dynamic_required: bool,
    target_name: []const u8,
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
) ![]const backend_contract.RuntimeRequirementDescriptor {
    var cloned = try allocator.dupe(backend_contract.RuntimeRequirementDescriptor, requirements);
    errdefer if (cloned.len != 0) allocator.free(cloned);
    if (!dynamic_required) return cloned;

    const dynamic_supported = std.mem.eql(u8, target_name, target.windows.name);
    var found = false;
    for (cloned) |*requirement| {
        if (requirement.kind != .dynamic_library_hooks) continue;
        requirement.required = true;
        requirement.supported = dynamic_supported;
        found = true;
        break;
    }
    if (!found) {
        const grown = try allocator.realloc(cloned, cloned.len + 1);
        cloned = grown;
        cloned[cloned.len - 1] = .{
            .kind = .dynamic_library_hooks,
            .required = true,
            .supported = dynamic_supported,
        };
    }
    if (!dynamic_supported) {
        try appendUnsupported(allocator, unsupported, "runtime.dynamic_library_hooks.unsupported", "dynamic-library runtime hooks are unsupported for target");
    }
    return cloned;
}

fn layoutDescriptor(result: layout.LayoutResult) backend_contract.LayoutDescriptor {
    return .{
        .status = result.status,
        .storage = result.storage,
        .size = result.size,
        .@"align" = result.@"align",
        .lowerability = result.lowerability,
        .foreign_stable = result.foreign_stable,
    };
}

fn abiDescriptor(result: abi.AbiTypeResult) backend_contract.AbiDescriptor {
    return .{
        .family = result.key.family,
        .safe = result.safe,
        .passable = result.passable,
        .returnable = result.returnable,
        .pass_mode = result.pass_mode,
    };
}

fn abiFamilyForConvention(convention: ?[]const u8) ?abi.AbiFamily {
    const value = convention orelse return null;
    if (std.mem.eql(u8, value, "c")) return .c;
    if (std.mem.eql(u8, value, "system")) return .system;
    return null;
}

fn appendImport(
    allocator: std.mem.Allocator,
    imports: *array_list.Managed(backend_contract.ImportDescriptor),
    name: []const u8,
    link_name: ?[]const u8,
    callable_index: usize,
    family: ?abi.AbiFamily,
    no_unwind: bool,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_link_name = if (link_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_link_name) |value| allocator.free(value);
    try imports.append(.{
        .name = owned_name,
        .link_name = owned_link_name,
        .callable_index = callable_index,
        .abi_family = family,
        .no_unwind = no_unwind,
    });
}

fn appendExport(
    allocator: std.mem.Allocator,
    exports: *array_list.Managed(backend_contract.ExportDescriptor),
    local_name: []const u8,
    name: []const u8,
    item_id: session.ItemId,
    family: ?abi.AbiFamily,
    no_unwind: bool,
    failure_policy: abi.ForeignFailurePolicy,
) !void {
    const owned_local_name = try allocator.dupe(u8, local_name);
    errdefer allocator.free(owned_local_name);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try exports.append(.{
        .local_name = owned_local_name,
        .name = owned_name,
        .item_id = item_id,
        .abi_family = family,
        .no_unwind = no_unwind,
        .failure_policy = failure_policy,
    });
}

fn appendUnsupported(
    allocator: std.mem.Allocator,
    unsupported: *array_list.Managed(backend_contract.UnsupportedLowering),
    code: []const u8,
    message: []const u8,
) !void {
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try unsupported.append(.{
        .code = owned_code,
        .message = owned_message,
    });
}

fn deinitImports(allocator: std.mem.Allocator, imports: []const backend_contract.ImportDescriptor) void {
    deinitImportItems(allocator, imports);
    if (imports.len != 0) allocator.free(imports);
}

fn deinitImportItems(allocator: std.mem.Allocator, imports: []const backend_contract.ImportDescriptor) void {
    for (imports) |import_desc| {
        if (import_desc.name.len != 0) allocator.free(import_desc.name);
        if (import_desc.link_name) |link_name| allocator.free(link_name);
    }
}

fn deinitExports(allocator: std.mem.Allocator, exports: []const backend_contract.ExportDescriptor) void {
    deinitExportItems(allocator, exports);
    if (exports.len != 0) allocator.free(exports);
}

fn deinitBoundarySurfaces(allocator: std.mem.Allocator, boundary_surfaces: []const backend_contract.BoundarySurfaceDescriptor) void {
    deinitBoundarySurfaceItems(allocator, boundary_surfaces);
    if (boundary_surfaces.len != 0) allocator.free(boundary_surfaces);
}

fn deinitBoundarySurfaceItems(allocator: std.mem.Allocator, boundary_surfaces: []const backend_contract.BoundarySurfaceDescriptor) void {
    for (boundary_surfaces) |item| {
        if (item.name.len != 0) allocator.free(item.name);
        if (item.input_type_name.len != 0) allocator.free(item.input_type_name);
        if (item.output_type_name.len != 0) allocator.free(item.output_type_name);
        freeStringSlice(allocator, item.capability_families);
    }
}

fn deinitExportItems(allocator: std.mem.Allocator, exports: []const backend_contract.ExportDescriptor) void {
    for (exports) |export_desc| {
        if (export_desc.local_name.len != 0) allocator.free(export_desc.local_name);
        if (export_desc.name.len != 0) allocator.free(export_desc.name);
    }
}

fn deinitUnsupported(allocator: std.mem.Allocator, unsupported: []const backend_contract.UnsupportedLowering) void {
    deinitUnsupportedItems(allocator, unsupported);
    if (unsupported.len != 0) allocator.free(unsupported);
}

fn deinitUnsupportedItems(allocator: std.mem.Allocator, unsupported: []const backend_contract.UnsupportedLowering) void {
    for (unsupported) |item| {
        if (item.code.len != 0) allocator.free(item.code);
        if (item.message.len != 0) allocator.free(item.message);
    }
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| {
        if (value.len != 0) allocator.free(value);
    }
    if (values.len != 0) allocator.free(values);
}
