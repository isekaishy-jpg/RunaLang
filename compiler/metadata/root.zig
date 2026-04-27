const std = @import("std");
const array_list = std.array_list;
const query = @import("../query/root.zig");
const session = @import("../session/root.zig");
const typed = @import("../typed/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Packaged runtime reflection and boundary-surface metadata.";
pub const runtime_reflection_is_opt_in = true;
pub const runtime_reflection_is_exported_only = true;
pub const boundary_surface_is_packaged = true;

pub const CallableKind = enum {
    ordinary,
    @"suspend",
};

pub const ReflectionEntry = struct {
    name: []const u8,
    declaration_kind: []const u8,
    unsafe_item: bool,
    boundary_api: bool,

    fn deinit(self: ReflectionEntry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.declaration_kind);
    }
};

pub const BoundaryApiEntry = struct {
    canonical_identity: []const u8,
    callable_kind: CallableKind,
    input_type: []const u8,
    output_type: []const u8,
    export_name: ?[]const u8,
    referenced_capability_families: [][]const u8,

    fn deinit(self: BoundaryApiEntry, allocator: Allocator) void {
        allocator.free(self.canonical_identity);
        allocator.free(self.input_type);
        allocator.free(self.output_type);
        if (self.export_name) |value| allocator.free(value);
        for (self.referenced_capability_families) |family| allocator.free(family);
        allocator.free(self.referenced_capability_families);
    }
};

pub const PackagedMetadata = struct {
    package_name: []const u8,
    package_version: []const u8,
    product_name: []const u8,
    product_kind: []const u8,
    reflection: []ReflectionEntry,
    boundary_apis: []BoundaryApiEntry,

    pub fn deinit(self: *PackagedMetadata, allocator: Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        allocator.free(self.product_name);
        allocator.free(self.product_kind);
        for (self.reflection) |entry| entry.deinit(allocator);
        allocator.free(self.reflection);
        for (self.boundary_apis) |entry| entry.deinit(allocator);
        allocator.free(self.boundary_apis);
    }
};

pub fn collectPackagedMetadataFromSession(
    allocator: Allocator,
    active: *session.Session,
    package_name: []const u8,
    package_version: []const u8,
    product_name: []const u8,
    product_kind: []const u8,
    root_index: usize,
) !PackagedMetadata {
    const root_module_id = findRootModuleForProduct(active, root_index) orelse return error.MissingSemanticModule;

    var reflection = array_list.Managed(ReflectionEntry).init(allocator);
    defer reflection.deinit();

    var boundary_apis = array_list.Managed(BoundaryApiEntry).init(allocator);
    defer boundary_apis.deinit();

    const reflection_metadata = try query.collectModuleRuntimeMetadata(allocator, active, root_module_id);
    defer allocator.free(reflection_metadata);
    for (reflection_metadata) |item| {
        try reflection.append(.{
            .name = try allocator.dupe(u8, item.name),
            .declaration_kind = try allocator.dupe(u8, item.kind),
            .unsafe_item = item.unsafe_item,
            .boundary_api = item.boundary_api,
        });
    }

    const boundary_api_metadata = try query.collectModuleBoundaryApiMetadata(allocator, active, root_module_id);
    defer allocator.free(boundary_api_metadata);
    for (boundary_api_metadata) |api| {
        try boundary_apis.append(.{
            .canonical_identity = try std.fmt.allocPrint(allocator, "{s}::{s}::{s}", .{
                package_name,
                product_name,
                api.name,
            }),
            .callable_kind = if (api.is_suspend) .@"suspend" else .ordinary,
            .input_type = try renderPackedInputType(allocator, api.parameters),
            .output_type = try allocator.dupe(u8, typeName(api.return_type)),
            .export_name = if (api.export_name) |value| try allocator.dupe(u8, value) else null,
            .referenced_capability_families = try duplicateStringSlice(allocator, api.referenced_capability_families),
        });
    }

    return .{
        .package_name = try allocator.dupe(u8, package_name),
        .package_version = try allocator.dupe(u8, package_version),
        .product_name = try allocator.dupe(u8, product_name),
        .product_kind = try allocator.dupe(u8, product_kind),
        .reflection = try reflection.toOwnedSlice(),
        .boundary_apis = try boundary_apis.toOwnedSlice(),
    };
}

fn findRootModuleForProduct(active: *const session.Session, root_index: usize) ?session.ModuleId {
    for (active.semantic_index.modules.items, 0..) |entry, module_index| {
        const module_pipeline = active.pipeline.modules.items[entry.pipeline_index];
        if (module_pipeline.root_index != root_index) continue;
        if (module_pipeline.module_path.len != 0) continue;
        return .{ .index = module_index };
    }
    return null;
}

pub fn renderDocument(allocator: Allocator, metadata: *const PackagedMetadata) ![]u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("[package]\n");
    try appendTomlField(&out, "name", metadata.package_name);
    try appendTomlField(&out, "version", metadata.package_version);
    try appendTomlField(&out, "product", metadata.product_name);
    try appendTomlField(&out, "kind", metadata.product_kind);

    for (metadata.reflection) |entry| {
        try out.appendSlice("\n[[reflection]]\n");
        try appendTomlField(&out, "name", entry.name);
        try appendTomlField(&out, "declaration_kind", entry.declaration_kind);
        try appendTomlBool(&out, "unsafe", entry.unsafe_item);
        try appendTomlBool(&out, "boundary_api", entry.boundary_api);
    }

    for (metadata.boundary_apis) |entry| {
        try out.appendSlice("\n[[boundary_apis]]\n");
        try appendTomlField(&out, "canonical_identity", entry.canonical_identity);
        try appendTomlField(&out, "callable_kind", @tagName(entry.callable_kind));
        try appendTomlField(&out, "input_type", entry.input_type);
        try appendTomlField(&out, "output_type", entry.output_type);
        if (entry.export_name) |value| try appendTomlField(&out, "export_name", value);
        try appendStringArray(&out, "referenced_capability_families", entry.referenced_capability_families);
    }

    return out.toOwnedSlice();
}

fn renderPackedInputType(allocator: Allocator, parameters: []const typed.Parameter) ![]const u8 {
    if (parameters.len == 0) return allocator.dupe(u8, "Unit");
    if (parameters.len == 1) return allocator.dupe(u8, typeName(parameters[0].ty));

    var rendered = array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();

    try rendered.append('(');
    for (parameters, 0..) |parameter, index| {
        if (index != 0) try rendered.appendSlice(", ");
        try rendered.appendSlice(typeName(parameter.ty));
    }
    try rendered.append(')');
    return rendered.toOwnedSlice();
}

fn typeName(value: @import("../types/root.zig").TypeRef) []const u8 {
    return switch (value) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| name,
        .unsupported => "Unsupported",
    };
}

fn appendTomlField(out: *array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(key);
    try out.appendSlice(" = \"");
    try out.appendSlice(value);
    try out.appendSlice("\"\n");
}

fn appendTomlBool(out: *array_list.Managed(u8), key: []const u8, value: bool) !void {
    try out.appendSlice(key);
    try out.appendSlice(" = ");
    try out.appendSlice(if (value) "true\n" else "false\n");
}

fn appendStringArray(out: *array_list.Managed(u8), key: []const u8, values: []const []const u8) !void {
    try out.appendSlice(key);
    try out.appendSlice(" = [");
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(", ");
        try out.appendSlice("\"");
        try out.appendSlice(value);
        try out.appendSlice("\"");
    }
    try out.appendSlice("]\n");
}

fn duplicateStringSlice(allocator: Allocator, values: []const []const u8) ![][]const u8 {
    const duplicated = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(duplicated);
    for (values, 0..) |value, index| {
        duplicated[index] = try allocator.dupe(u8, value);
    }
    return duplicated;
}
