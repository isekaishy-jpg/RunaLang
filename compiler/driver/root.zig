const std = @import("std");
const array_list = std.array_list;
const diag = @import("../diag/root.zig");
const hir = @import("../hir/root.zig");
const lowering = @import("../lowering/root.zig");
const mir = @import("../mir/root.zig");
const parse = @import("../parse/root.zig");
const query_body_syntax_bridge = @import("../query/body_syntax_bridge.zig");
const query_item_syntax_bridge = @import("../query/item_syntax_bridge.zig");
const resolve = @import("../resolve/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Top-level compiler entry orchestration.";

pub const GraphDependency = struct {
    alias: []const u8,
    package_index: usize,
};

pub const GraphPackage = struct {
    package_name: []const u8,
    symbol_prefix: []const u8,
    import_root_path: ?[]const u8,
    dependencies: []const GraphDependency,
};

pub const GraphRoot = struct {
    root_path: []const u8,
    package_index: usize,
};

pub const GraphInput = struct {
    packages: []const GraphPackage,
    roots: []const GraphRoot,
};

pub const ImportBindingSite = struct {
    local_name: []const u8,
    span: source.Span,
};

pub const ModulePipeline = struct {
    root_index: usize,
    package_index: usize,
    module_path: []const u8,
    parsed: parse.ParsedFile,
    hir: hir.Module,
    resolved: resolve.Module,
    prototypes: array_list.Managed(typed.FunctionPrototype),
    import_binding_sites: array_list.Managed(ImportBindingSite),
    typed: typed.Module,
    mir: ?mir.Module = null,

    pub fn deinit(self: *ModulePipeline, allocator: Allocator) void {
        if (self.mir) |*module| module.deinit();
        self.typed.deinit(allocator);
        self.import_binding_sites.deinit();
        for (self.prototypes.items) |prototype| prototype.deinit(allocator);
        self.prototypes.deinit();
        self.resolved.deinit();
        self.hir.deinit(allocator);
        self.parsed.deinit(allocator);
        allocator.free(self.module_path);
    }
};

pub const Pipeline = struct {
    allocator: Allocator,
    sources: source.Table,
    diagnostics: diag.Bag,
    modules: array_list.Managed(ModulePipeline),

    pub fn deinit(self: *Pipeline) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit();
        self.diagnostics.deinit();
        self.sources.deinit();
    }

    pub fn itemCount(self: *const Pipeline) usize {
        var count: usize = 0;
        for (self.modules.items) |module| {
            for (module.typed.items.items) |item| {
                if (!item.is_synthetic) count += 1;
            }
        }
        return count;
    }

    pub fn sourceFileCount(self: *const Pipeline) usize {
        return self.sources.files.items.len;
    }
};

pub fn prepareFiles(allocator: Allocator, io: std.Io, file_paths: []const []const u8) !Pipeline {
    var pipeline = Pipeline{
        .allocator = allocator,
        .sources = source.Table.init(allocator),
        .diagnostics = diag.Bag.init(allocator),
        .modules = array_list.Managed(ModulePipeline).init(allocator),
    };
    errdefer pipeline.deinit();

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit();
    }

    for (file_paths, 0..) |path, root_index| {
        discoverSinglePackageModuleTree(allocator, io, &pipeline, &visited, path, "", root_index) catch |err| {
            try pipeline.diagnostics.add(.@"error", "workspace.root.missing", null, "missing product root '{s}': {s}", .{
                path,
                @errorName(err),
            });
        };
    }

    try resolveSinglePackageImports(allocator, &pipeline);

    return pipeline;
}

pub fn prepareGraph(allocator: Allocator, io: std.Io, graph: GraphInput) !Pipeline {
    var pipeline = Pipeline{
        .allocator = allocator,
        .sources = source.Table.init(allocator),
        .diagnostics = diag.Bag.init(allocator),
        .modules = array_list.Managed(ModulePipeline).init(allocator),
    };
    errdefer pipeline.deinit();

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit();
    }

    for (graph.roots, 0..) |root, root_index| {
        discoverGraphModuleTree(allocator, io, &pipeline, &visited, graph, root.package_index, root.root_path, "", root_index) catch |err| {
            try pipeline.diagnostics.add(.@"error", "workspace.root.missing", null, "missing product root '{s}': {s}", .{
                root.root_path,
                @errorName(err),
            });
        };
    }

    try resolveGraphImports(allocator, &pipeline, graph);

    return pipeline;
}

fn discoverSinglePackageModuleTree(
    allocator: Allocator,
    io: std.Io,
    pipeline: *Pipeline,
    visited: *std.StringHashMap(void),
    path: []const u8,
    module_path: []const u8,
    root_index: usize,
) !void {
    const visit = try visited.getOrPut(path);
    if (visit.found_existing) return;
    visit.key_ptr.* = try allocator.dupe(u8, path);
    errdefer allocator.free(visit.key_ptr.*);
    visit.value_ptr.* = {};

    const file_id = try pipeline.sources.loadFile(io, path);
    const file = pipeline.sources.get(file_id);

    var parsed = try parse.parseFile(allocator, file, &pipeline.diagnostics);
    errdefer parsed.deinit(allocator);

    var lowered_hir = try lowering.lowerParsedModule(allocator, parsed.module);
    errdefer lowered_hir.deinit(allocator);

    var resolved = try resolve.resolveModule(allocator, lowered_hir, &pipeline.diagnostics);
    errdefer resolved.deinit();

    var prototypes = array_list.Managed(typed.FunctionPrototype).init(allocator);
    errdefer {
        for (prototypes.items) |prototype| prototype.deinit(allocator);
        prototypes.deinit();
    }

    var lowered_typed = try typed.prepareModule(allocator, lowered_hir, try allocator.dupe(u8, module_path), "", &pipeline.diagnostics, &prototypes);
    errdefer lowered_typed.deinit(allocator);
    try appendPreparedFunctionPrototypes(allocator, lowered_hir, &lowered_typed, &prototypes);

    try pipeline.modules.append(.{
        .root_index = root_index,
        .package_index = 0,
        .module_path = try allocator.dupe(u8, module_path),
        .parsed = parsed,
        .hir = lowered_hir,
        .resolved = resolved,
        .prototypes = prototypes,
        .import_binding_sites = array_list.Managed(ImportBindingSite).init(allocator),
        .typed = lowered_typed,
        .mir = null,
    });

    const current_dir = std.fs.path.dirname(path) orelse ".";
    for (pipeline.modules.items[pipeline.modules.items.len - 1].hir.items.items) |item| {
        if (item.kind != .module_decl) continue;
        const child_path = try std.fs.path.join(allocator, &.{ current_dir, item.name, "mod.rna" });
        defer allocator.free(child_path);
        const child_module_path = if (module_path.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ module_path, item.name });
        defer allocator.free(child_module_path);
        discoverSinglePackageModuleTree(allocator, io, pipeline, visited, child_path, child_module_path, root_index) catch |err| {
            try pipeline.diagnostics.add(.@"error", "module.file.missing", item.span, "declared child module '{s}' is missing: {s}", .{
                item.name,
                @errorName(err),
            });
        };
    }
}

const GlobalItem = struct {
    source_module_index: usize,
    category: typed.ItemCategory,
    target_name: []const u8,
    target_symbol: []const u8,
    const_type: ?types.TypeRef,
    function_return_type: ?types.TypeRef = null,
    function_generic_params: []typed.GenericParam = &.{},
    function_where_predicates: []typed.WherePredicate = &.{},
    function_is_suspend: bool = false,
    function_parameter_types: ?[]types.TypeRef = null,
    function_parameter_type_names: ?[]const []const u8 = null,
    function_parameter_modes: ?[]typed.ParameterMode,
    function_unsafe_required: bool = false,
    struct_fields: ?[]typed.StructField = null,
    enum_variants: ?[]typed.EnumVariant = null,
    trait_methods: ?[]typed.TraitMethod = null,
};

fn appendPreparedFunctionPrototypes(
    allocator: Allocator,
    module: hir.Module,
    typed_module: *const typed.Module,
    prototypes: *array_list.Managed(typed.FunctionPrototype),
) !void {
    for (module.items.items, 0..) |item, item_index| {
        switch (item.kind) {
            .function, .suspend_function, .foreign_function => {},
            else => continue,
        }
        const typed_item = typed_module.items.items[item_index];
        var diagnostics = diag.Bag.init(allocator);
        defer diagnostics.deinit();

        var function = typed.FunctionData.init(allocator, item.kind == .suspend_function, item.kind == .foreign_function);
        defer function.deinit(allocator);
        const signature = switch (item.syntax) {
            .function => |signature| signature,
            else => continue,
        };
        try query_item_syntax_bridge.fillFunctionDataFromSyntax(allocator, &function, signature, item.span, &diagnostics);

        const parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
        errdefer allocator.free(parameter_types);
        const parameter_type_names = try duplicateParameterTypeNames(allocator, function.parameters.items);
        errdefer allocator.free(parameter_type_names);
        const parameter_modes = try allocator.alloc(typed.ParameterMode, function.parameters.items.len);
        errdefer allocator.free(parameter_modes);
        for (function.parameters.items, 0..) |parameter, parameter_index| {
            parameter_types[parameter_index] = parameter.ty;
            parameter_modes[parameter_index] = parameter.mode;
        }

        try prototypes.append(.{
            .name = item.name,
            .target_name = item.name,
            .target_symbol = typed_item.symbol_name,
            .return_type = function.return_type,
            .generic_params = if (function.generic_params.len != 0) try allocator.dupe(typed.GenericParam, function.generic_params) else &.{},
            .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, function.where_predicates) else &.{},
            .is_suspend = function.is_suspend,
            .parameter_types = parameter_types,
            .parameter_type_names = parameter_type_names,
            .parameter_modes = parameter_modes,
            .unsafe_required = typed_item.is_unsafe,
        });
    }
}

fn duplicateParameterTypeNames(allocator: Allocator, parameters: []const typed.Parameter) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, parameters.len);
    for (parameters, 0..) |parameter, index| {
        names[index] = parameter.type_name;
    }
    return names;
}

fn collectGlobalItemMetadata(
    allocator: Allocator,
    module_pipeline: *const ModulePipeline,
    source_module_index: usize,
    item_index: usize,
) !GlobalItem {
    const item = module_pipeline.typed.items.items[item_index];
    const source_item = module_pipeline.hir.items.items[item_index];
    var metadata = GlobalItem{
        .source_module_index = source_module_index,
        .category = item.category,
        .target_name = item.name,
        .target_symbol = item.symbol_name,
        .const_type = null,
        .function_parameter_modes = null,
    };
    errdefer deinitGlobalItemMetadata(allocator, &metadata);

    var diagnostics = diag.Bag.init(allocator);
    defer diagnostics.deinit();

    switch (source_item.kind) {
        .function, .suspend_function, .foreign_function => {
            var function = typed.FunctionData.init(allocator, source_item.kind == .suspend_function, source_item.kind == .foreign_function);
            defer function.deinit(allocator);
            const signature = switch (source_item.syntax) {
                .function => |signature| signature,
                else => return metadata,
            };
            try query_item_syntax_bridge.fillFunctionDataFromSyntax(allocator, &function, signature, source_item.span, &diagnostics);
            metadata.function_return_type = resolveModuleValueType(&module_pipeline.typed, function.return_type, function.return_type_name);
            metadata.function_generic_params = if (function.generic_params.len != 0) try allocator.dupe(typed.GenericParam, function.generic_params) else &.{};
            metadata.function_where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, function.where_predicates) else &.{};
            metadata.function_is_suspend = function.is_suspend;
            metadata.function_parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
            metadata.function_parameter_type_names = try duplicateParameterTypeNames(allocator, function.parameters.items);
            metadata.function_parameter_modes = try allocator.alloc(typed.ParameterMode, function.parameters.items.len);
            for (function.parameters.items, 0..) |parameter, parameter_index| {
                metadata.function_parameter_types.?[parameter_index] = resolveModuleValueType(
                    &module_pipeline.typed,
                    parameter.ty,
                    parameter.type_name,
                );
                metadata.function_parameter_modes.?[parameter_index] = parameter.mode;
            }
            metadata.function_unsafe_required = item.is_unsafe;
        },
        .const_item => {
            var const_item = switch (source_item.syntax) {
                .const_item => |signature| try query_item_syntax_bridge.parseConstDataFromSyntax(allocator, signature, source_item.span, &diagnostics),
                else => return metadata,
            };
            defer const_item.deinit(allocator);
            metadata.const_type = resolveModuleValueType(&module_pipeline.typed, const_item.type_ref, const_item.type_name);
        },
        .struct_type => switch (source_item.body_syntax) {
            .struct_fields => |fields| {
                metadata.struct_fields = try query_body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, source_item.name, source_item.span, &diagnostics);
                resolveStructFieldsInPlace(&module_pipeline.typed, metadata.struct_fields.?);
            },
            .none => metadata.struct_fields = try allocator.alloc(typed.StructField, 0),
            else => {},
        },
        .enum_type => switch (source_item.body_syntax) {
            .enum_variants => |variants| {
                metadata.enum_variants = try query_body_syntax_bridge.parseEnumVariantsFromSyntax(allocator, variants, source_item.name, source_item.span, &diagnostics);
                resolveEnumVariantsInPlace(&module_pipeline.typed, metadata.enum_variants.?);
            },
            .none => metadata.enum_variants = try allocator.alloc(typed.EnumVariant, 0),
            else => {},
        },
        .trait_type => {
            var header = switch (source_item.syntax) {
                .named_decl => |signature| try query_item_syntax_bridge.parseNamedDeclData(allocator, signature, true, source_item.span, &diagnostics),
                else => return metadata,
            };
            defer header.deinit(allocator);
            var parsed = switch (source_item.body_syntax) {
                .trait_body => |body| try query_body_syntax_bridge.parseTraitBodyFromSyntax(allocator, header.generic_params, body, source_item.name, source_item.span, &diagnostics),
                .none => query_body_syntax_bridge.ParsedTraitBody{
                    .methods = try allocator.alloc(typed.TraitMethod, 0),
                    .associated_types = try allocator.alloc(typed.TraitAssociatedType, 0),
                    .associated_consts = try allocator.alloc(typed.TraitAssociatedConst, 0),
                },
                else => return metadata,
            };
            defer parsed.deinit(allocator);
            metadata.trait_methods = parsed.methods;
            parsed.methods = &.{};
        },
        else => {},
    }

    return metadata;
}

fn deinitGlobalItemMetadata(allocator: Allocator, item: *GlobalItem) void {
    if (item.function_generic_params.len != 0) allocator.free(item.function_generic_params);
    if (item.function_where_predicates.len != 0) allocator.free(item.function_where_predicates);
    if (item.function_parameter_types) |value| allocator.free(value);
    if (item.function_parameter_type_names) |value| allocator.free(value);
    if (item.function_parameter_modes) |value| allocator.free(value);
    if (item.struct_fields) |fields| allocator.free(fields);
    if (item.enum_variants) |variants| {
        for (variants) |*variant| variant.deinit(allocator);
        allocator.free(variants);
    }
    if (item.trait_methods) |methods| {
        for (methods) |*method| method.deinit(allocator);
        allocator.free(methods);
    }
    item.* = .{
        .source_module_index = 0,
        .category = .value,
        .target_name = "",
        .target_symbol = "",
        .const_type = null,
        .function_parameter_modes = null,
    };
}

fn resolveSinglePackageImports(allocator: Allocator, pipeline: *Pipeline) !void {
    var modules = std.StringHashMap(usize).init(allocator);
    defer {
        var iter_modules = modules.iterator();
        while (iter_modules.next()) |entry| allocator.free(entry.key_ptr.*);
        modules.deinit();
    }
    var items = std.StringHashMap(GlobalItem).init(allocator);
    defer {
        var iter = items.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.function_generic_params.len != 0) allocator.free(entry.value_ptr.function_generic_params);
            if (entry.value_ptr.function_where_predicates.len != 0) allocator.free(entry.value_ptr.function_where_predicates);
            if (entry.value_ptr.function_parameter_types) |value| allocator.free(value);
            if (entry.value_ptr.function_parameter_type_names) |value| allocator.free(value);
            if (entry.value_ptr.function_parameter_modes) |value| allocator.free(value);
            if (entry.value_ptr.struct_fields) |fields| allocator.free(fields);
            if (entry.value_ptr.enum_variants) |variants| {
                for (variants) |*variant| variant.deinit(allocator);
                allocator.free(variants);
            }
            if (entry.value_ptr.trait_methods) |methods| {
                for (methods) |*method| method.deinit(allocator);
                allocator.free(methods);
            }
        }
        items.deinit();
    }

    for (pipeline.modules.items, 0..) |module_pipeline, index| {
        try modules.put(try allocator.dupe(u8, module_pipeline.module_path), index);
    }

    for (pipeline.modules.items, 0..) |module_pipeline, module_index| {
        for (module_pipeline.typed.items.items, 0..) |item, item_index| {
            if (item.is_synthetic) continue;
            if (item.name.len == 0) continue;
            if (item.kind == .module_decl or item.kind == .use_decl) continue;

            const canonical = try canonicalPath(allocator, module_pipeline.module_path, item.name);
            errdefer allocator.free(canonical);

            var metadata = try collectGlobalItemMetadata(allocator, &module_pipeline, module_index, item_index);

            const entry = try items.getOrPut(canonical);
            if (entry.found_existing) {
                allocator.free(canonical);
                deinitGlobalItemMetadata(allocator, &metadata);
                continue;
            }
            entry.value_ptr.* = metadata;
        }
    }

    for (pipeline.modules.items) |*module_pipeline| {
        for (module_pipeline.resolved.symbols.items) |symbol| {
            if (symbol.category != .import_binding) continue;
            const target_path = symbol.target_path orelse continue;
            if (modules.get(target_path) != null) continue;

            if (items.get(target_path)) |target| {
                const imported = typed.ImportedBinding{
                    .local_name = symbol.name,
                    .target_name = target.target_name,
                    .target_symbol = target.target_symbol,
                    .category = target.category,
                    .const_type = target.const_type,
                    .function_return_type = target.function_return_type,
                    .function_generic_params = if (target.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, target.function_generic_params) else &.{},
                    .function_where_predicates = if (target.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, target.function_where_predicates) else &.{},
                    .function_is_suspend = target.function_is_suspend,
                    .function_parameter_types = if (target.function_parameter_types) |values| try allocator.dupe(types.TypeRef, values) else null,
                    .function_parameter_type_names = if (target.function_parameter_type_names) |values| try allocator.dupe([]const u8, values) else null,
                    .function_parameter_modes = if (target.function_parameter_modes) |values| try allocator.dupe(typed.ParameterMode, values) else null,
                    .struct_fields = if (target.struct_fields) |fields| try duplicateStructFields(allocator, fields) else null,
                    .enum_variants = if (target.enum_variants) |variants| try duplicateEnumVariants(allocator, variants) else null,
                    .trait_methods = if (target.trait_methods) |methods| try duplicateTraitMethods(allocator, methods) else null,
                };
                try module_pipeline.import_binding_sites.append(.{
                    .local_name = symbol.name,
                    .span = symbol.span,
                });
                try typed.addImportedBinding(allocator, &module_pipeline.typed, imported);

                if (imported.function_parameter_types) |values| {
                    try module_pipeline.prototypes.append(.{
                        .name = imported.local_name,
                        .target_name = imported.target_name,
                        .target_symbol = imported.target_symbol,
                        .return_type = imported.function_return_type.?,
                        .generic_params = if (imported.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, imported.function_generic_params) else &.{},
                        .where_predicates = if (imported.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, imported.function_where_predicates) else &.{},
                        .is_suspend = imported.function_is_suspend,
                        .parameter_types = try allocator.dupe(types.TypeRef, values),
                        .parameter_type_names = if (imported.function_parameter_type_names) |type_names| try allocator.dupe([]const u8, type_names) else try allocator.alloc([]const u8, 0),
                        .parameter_modes = if (imported.function_parameter_modes) |modes| try allocator.dupe(typed.ParameterMode, modes) else try allocator.alloc(typed.ParameterMode, 0),
                        .unsafe_required = target.function_unsafe_required,
                    });
                }
                if (target.category == .type_decl) {
                }
                continue;
            }

            try pipeline.diagnostics.add(.@"error", "resolve.import.unknown", symbol.span, "unknown import path '{s}'", .{target_path});
        }
    }
}

fn canonicalPath(allocator: Allocator, module_path: []const u8, name: []const u8) ![]const u8 {
    if (module_path.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ module_path, name });
}

fn discoverGraphModuleTree(
    allocator: Allocator,
    io: std.Io,
    pipeline: *Pipeline,
    visited: *std.StringHashMap(void),
    graph: GraphInput,
    package_index: usize,
    path: []const u8,
    module_path: []const u8,
    root_index: usize,
) !void {
    const visit_key = try std.fmt.allocPrint(allocator, "{d}|{d}|{s}", .{ root_index, package_index, path });
    defer allocator.free(visit_key);

    const visit = try visited.getOrPut(visit_key);
    if (visit.found_existing) return;
    visit.key_ptr.* = try allocator.dupe(u8, visit_key);
    errdefer allocator.free(visit.key_ptr.*);
    visit.value_ptr.* = {};

    const file_id = try pipeline.sources.loadFile(io, path);
    const file = pipeline.sources.get(file_id);

    var parsed = try parse.parseFile(allocator, file, &pipeline.diagnostics);
    errdefer parsed.deinit(allocator);

    var lowered_hir = try lowering.lowerParsedModule(allocator, parsed.module);
    errdefer lowered_hir.deinit(allocator);

    var resolved = try resolve.resolveModule(allocator, lowered_hir, &pipeline.diagnostics);
    errdefer resolved.deinit();

    var prototypes = array_list.Managed(typed.FunctionPrototype).init(allocator);
    errdefer {
        for (prototypes.items) |prototype| prototype.deinit(allocator);
        prototypes.deinit();
    }

    var lowered_typed = try typed.prepareModule(
        allocator,
        lowered_hir,
        try allocator.dupe(u8, module_path),
        graph.packages[package_index].symbol_prefix,
        &pipeline.diagnostics,
        &prototypes,
    );
    errdefer lowered_typed.deinit(allocator);
    try appendPreparedFunctionPrototypes(allocator, lowered_hir, &lowered_typed, &prototypes);

    try pipeline.modules.append(.{
        .root_index = root_index,
        .package_index = package_index,
        .module_path = try allocator.dupe(u8, module_path),
        .parsed = parsed,
        .hir = lowered_hir,
        .resolved = resolved,
        .prototypes = prototypes,
        .import_binding_sites = array_list.Managed(ImportBindingSite).init(allocator),
        .typed = lowered_typed,
        .mir = null,
    });

    const current_dir = std.fs.path.dirname(path) orelse ".";
    for (pipeline.modules.items[pipeline.modules.items.len - 1].hir.items.items) |item| {
        if (item.kind != .module_decl) continue;
        const child_path = try std.fs.path.join(allocator, &.{ current_dir, item.name, "mod.rna" });
        defer allocator.free(child_path);
        const child_module_path = if (module_path.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ module_path, item.name });
        defer allocator.free(child_module_path);
        discoverGraphModuleTree(allocator, io, pipeline, visited, graph, package_index, child_path, child_module_path, root_index) catch |err| {
            try pipeline.diagnostics.add(.@"error", "module.file.missing", item.span, "declared child module '{s}' is missing: {s}", .{
                item.name,
                @errorName(err),
            });
        };
    }

    if (module_path.len == 0) {
        for (graph.packages[package_index].dependencies) |dependency| {
            const dependency_root = graph.packages[dependency.package_index].import_root_path orelse continue;
            discoverGraphModuleTree(allocator, io, pipeline, visited, graph, dependency.package_index, dependency_root, "", root_index) catch |err| {
                try pipeline.diagnostics.add(.@"error", "dependency.import.root", null, "dependency '{s}' import root is unavailable: {s}", .{
                    dependency.alias,
                    @errorName(err),
                });
            };
        }
    }
}

fn resolveGraphImports(allocator: Allocator, pipeline: *Pipeline, graph: GraphInput) !void {
    var items = std.StringHashMap(GlobalItem).init(allocator);
    defer {
        var iter = items.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.function_generic_params.len != 0) allocator.free(entry.value_ptr.function_generic_params);
            if (entry.value_ptr.function_where_predicates.len != 0) allocator.free(entry.value_ptr.function_where_predicates);
            if (entry.value_ptr.function_parameter_types) |value| allocator.free(value);
            if (entry.value_ptr.function_parameter_type_names) |value| allocator.free(value);
            if (entry.value_ptr.function_parameter_modes) |value| allocator.free(value);
            if (entry.value_ptr.struct_fields) |fields| allocator.free(fields);
            if (entry.value_ptr.enum_variants) |variants| {
                for (variants) |*variant| variant.deinit(allocator);
                allocator.free(variants);
            }
            if (entry.value_ptr.trait_methods) |methods| {
                for (methods) |*method| method.deinit(allocator);
                allocator.free(methods);
            }
        }
        items.deinit();
    }

    for (pipeline.modules.items, 0..) |module_pipeline, module_index| {
        for (module_pipeline.typed.items.items, 0..) |item, item_index| {
            if (item.is_synthetic) continue;
            if (item.name.len == 0) continue;
            if (item.kind == .module_decl or item.kind == .use_decl) continue;

            const local_key = try scopedCanonicalPath(allocator, module_pipeline.root_index, module_pipeline.package_index, module_pipeline.module_path, item.name);
            errdefer allocator.free(local_key);

            var metadata = try collectGlobalItemMetadata(allocator, &module_pipeline, module_index, item_index);

            const entry = try items.getOrPut(local_key);
            if (entry.found_existing) {
                allocator.free(local_key);
                deinitGlobalItemMetadata(allocator, &metadata);
                continue;
            }
            entry.value_ptr.* = metadata;
        }
    }

    for (pipeline.modules.items) |*module_pipeline| {
        const package_node = graph.packages[module_pipeline.package_index];
        for (module_pipeline.resolved.symbols.items) |symbol| {
            if (symbol.category != .import_binding) continue;
            const target_path = symbol.target_path orelse continue;

            const root_segment_end = std.mem.indexOfScalar(u8, target_path, '.') orelse target_path.len;
            const root_segment = target_path[0..root_segment_end];
            const local_collision = hasLocalRootName(module_pipeline, root_segment);

            if (findDependencyPackage(package_node.dependencies, root_segment)) |dependency| {
                if (local_collision) {
                    try pipeline.diagnostics.add(.@"error", "resolve.import.ambiguous_root", symbol.span, "ambiguous import root '{s}' between local package and dependency", .{root_segment});
                    continue;
                }

                const rest = if (root_segment_end < target_path.len) target_path[root_segment_end + 1 ..] else "";
                if (rest.len == 0) {
                    try pipeline.diagnostics.add(.@"error", "resolve.import.package_root", symbol.span, "imports must name an item inside dependency package '{s}'", .{root_segment});
                    continue;
                }

                const key = try scopedCanonicalPath(allocator, module_pipeline.root_index, dependency.package_index, pathModuleAndName(rest).module_path, pathModuleAndName(rest).name);
                defer allocator.free(key);
                if (items.get(key)) |target| {
                    const imported = typed.ImportedBinding{
                        .local_name = symbol.name,
                        .target_name = target.target_name,
                        .target_symbol = target.target_symbol,
                        .category = target.category,
                        .const_type = target.const_type,
                        .function_return_type = target.function_return_type,
                        .function_generic_params = if (target.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, target.function_generic_params) else &.{},
                        .function_where_predicates = if (target.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, target.function_where_predicates) else &.{},
                        .function_is_suspend = target.function_is_suspend,
                        .function_parameter_types = if (target.function_parameter_types) |values| try allocator.dupe(types.TypeRef, values) else null,
                        .function_parameter_type_names = if (target.function_parameter_type_names) |values| try allocator.dupe([]const u8, values) else null,
                        .function_parameter_modes = if (target.function_parameter_modes) |values| try allocator.dupe(typed.ParameterMode, values) else null,
                        .struct_fields = if (target.struct_fields) |fields| try duplicateStructFields(allocator, fields) else null,
                        .enum_variants = if (target.enum_variants) |variants| try duplicateEnumVariants(allocator, variants) else null,
                        .trait_methods = if (target.trait_methods) |methods| try duplicateTraitMethods(allocator, methods) else null,
                    };
                    try module_pipeline.import_binding_sites.append(.{
                        .local_name = symbol.name,
                        .span = symbol.span,
                    });
                    try typed.addImportedBinding(allocator, &module_pipeline.typed, imported);
                if (imported.function_parameter_types) |values| {
                    try module_pipeline.prototypes.append(.{
                        .name = imported.local_name,
                        .target_name = imported.target_name,
                        .target_symbol = imported.target_symbol,
                        .return_type = imported.function_return_type.?,
                        .generic_params = if (imported.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, imported.function_generic_params) else &.{},
                        .where_predicates = if (imported.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, imported.function_where_predicates) else &.{},
                        .is_suspend = imported.function_is_suspend,
                        .parameter_types = try allocator.dupe(types.TypeRef, values),
                        .parameter_type_names = if (imported.function_parameter_type_names) |type_names| try allocator.dupe([]const u8, type_names) else try allocator.alloc([]const u8, 0),
                        .parameter_modes = if (imported.function_parameter_modes) |modes| try allocator.dupe(typed.ParameterMode, modes) else try allocator.alloc(typed.ParameterMode, 0),
                        .unsafe_required = target.function_unsafe_required,
                    });
                }
                    if (target.category == .type_decl) {
                    }
                    continue;
                }
            } else {
                const target = pathModuleAndName(target_path);
                const key = try scopedCanonicalPath(allocator, module_pipeline.root_index, module_pipeline.package_index, target.module_path, target.name);
                defer allocator.free(key);
                if (items.get(key)) |resolved_target| {
                    const imported = typed.ImportedBinding{
                        .local_name = symbol.name,
                        .target_name = resolved_target.target_name,
                        .target_symbol = resolved_target.target_symbol,
                        .category = resolved_target.category,
                        .const_type = resolved_target.const_type,
                        .function_return_type = resolved_target.function_return_type,
                        .function_generic_params = if (resolved_target.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, resolved_target.function_generic_params) else &.{},
                        .function_where_predicates = if (resolved_target.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, resolved_target.function_where_predicates) else &.{},
                        .function_is_suspend = resolved_target.function_is_suspend,
                        .function_parameter_types = if (resolved_target.function_parameter_types) |values| try allocator.dupe(types.TypeRef, values) else null,
                        .function_parameter_type_names = if (resolved_target.function_parameter_type_names) |values| try allocator.dupe([]const u8, values) else null,
                        .function_parameter_modes = if (resolved_target.function_parameter_modes) |values| try allocator.dupe(typed.ParameterMode, values) else null,
                        .struct_fields = if (resolved_target.struct_fields) |fields| try duplicateStructFields(allocator, fields) else null,
                        .enum_variants = if (resolved_target.enum_variants) |variants| try duplicateEnumVariants(allocator, variants) else null,
                        .trait_methods = if (resolved_target.trait_methods) |methods| try duplicateTraitMethods(allocator, methods) else null,
                    };
                    try module_pipeline.import_binding_sites.append(.{
                        .local_name = symbol.name,
                        .span = symbol.span,
                    });
                    try typed.addImportedBinding(allocator, &module_pipeline.typed, imported);
                    if (imported.function_parameter_types) |values| {
                        try module_pipeline.prototypes.append(.{
                            .name = imported.local_name,
                            .target_name = imported.target_name,
                            .target_symbol = imported.target_symbol,
                            .return_type = imported.function_return_type.?,
                            .generic_params = if (imported.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, imported.function_generic_params) else &.{},
                            .where_predicates = if (imported.function_where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, imported.function_where_predicates) else &.{},
                            .is_suspend = imported.function_is_suspend,
                            .parameter_types = try allocator.dupe(types.TypeRef, values),
                            .parameter_type_names = if (imported.function_parameter_type_names) |type_names| try allocator.dupe([]const u8, type_names) else try allocator.alloc([]const u8, 0),
                            .parameter_modes = if (imported.function_parameter_modes) |modes| try allocator.dupe(typed.ParameterMode, modes) else try allocator.alloc(typed.ParameterMode, 0),
                            .unsafe_required = resolved_target.function_unsafe_required,
                        });
                    }
                    if (resolved_target.category == .type_decl) {
                    }
                    continue;
                }
            }

            try pipeline.diagnostics.add(.@"error", "resolve.import.unknown", symbol.span, "unknown import path '{s}'", .{target_path});
        }
    }
}

fn scopedCanonicalPath(allocator: Allocator, root_index: usize, package_index: usize, module_path: []const u8, name: []const u8) ![]const u8 {
    if (module_path.len == 0) {
        return std.fmt.allocPrint(allocator, "{d}|{d}|{s}", .{ root_index, package_index, name });
    }
    return std.fmt.allocPrint(allocator, "{d}|{d}|{s}.{s}", .{ root_index, package_index, module_path, name });
}

const PathParts = struct {
    module_path: []const u8,
    name: []const u8,
};

fn pathModuleAndName(path: []const u8) PathParts {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |index| {
        return .{
            .module_path = path[0..index],
            .name = path[index + 1 ..],
        };
    }
    return .{
        .module_path = "",
        .name = path,
    };
}

fn hasLocalRootName(module_pipeline: *const ModulePipeline, root_name: []const u8) bool {
    for (module_pipeline.resolved.symbols.items) |symbol| {
        if (std.mem.indexOfScalar(u8, symbol.name, '.')) |_| continue;
        if (std.mem.eql(u8, symbol.name, root_name)) return true;
    }
    return false;
}

fn findDependencyPackage(dependencies: []const GraphDependency, alias: []const u8) ?GraphDependency {
    for (dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.alias, alias)) return dependency;
    }
    return null;
}

fn duplicateStructFields(allocator: Allocator, fields: []const typed.StructField) ![]typed.StructField {
    const duplicated = try allocator.alloc(typed.StructField, fields.len);
    @memcpy(duplicated, fields);
    return duplicated;
}

fn resolveStructFieldsForImport(allocator: Allocator, module: *const typed.Module, fields: []const typed.StructField) ![]typed.StructField {
    const duplicated = try duplicateStructFields(allocator, fields);
    resolveStructFieldsInPlace(module, duplicated);
    return duplicated;
}

fn resolveStructFieldsInPlace(module: *const typed.Module, fields: []typed.StructField) void {
    for (fields) |*field| {
        field.ty = resolveModuleValueType(module, field.ty, field.type_name);
    }
}

fn resolveEnumVariantsInPlace(module: *const typed.Module, variants: []typed.EnumVariant) void {
    for (variants) |*variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |*field| {
                    field.ty = resolveModuleValueType(module, field.ty, field.type_name);
                }
            },
            .named_fields => |named_fields| resolveStructFieldsInPlace(module, named_fields),
        }
    }
}

fn resolveStructFieldsForImportOld(allocator: Allocator, module: *const typed.Module, fields: []const typed.StructField) ![]typed.StructField {
    const duplicated = try duplicateStructFields(allocator, fields);
    for (duplicated) |*field| {
        field.ty = resolveModuleValueType(module, field.ty, field.type_name);
    }
    return duplicated;
}

fn duplicateEnumVariants(allocator: Allocator, variants: []const typed.EnumVariant) ![]typed.EnumVariant {
    const duplicated = try allocator.alloc(typed.EnumVariant, variants.len);
    errdefer allocator.free(duplicated);

    for (variants, 0..) |variant, variant_index| {
        duplicated[variant_index] = .{
            .name = variant.name,
            .payload = switch (variant.payload) {
                .none => .none,
                .tuple_fields => |tuple_fields| blk: {
                    const fields = try allocator.alloc(typed.TupleField, tuple_fields.len);
                    @memcpy(fields, tuple_fields);
                    break :blk .{ .tuple_fields = fields };
                },
                .named_fields => |named_fields| .{ .named_fields = try duplicateStructFields(allocator, named_fields) },
            },
        };
    }

    return duplicated;
}

fn duplicateTraitMethods(allocator: Allocator, methods: []const typed.TraitMethod) ![]typed.TraitMethod {
    const duplicated = try allocator.alloc(typed.TraitMethod, methods.len);
    var initialized: usize = 0;
    errdefer {
        for (duplicated[0..initialized]) |*method| method.deinit(allocator);
        allocator.free(duplicated);
    }

    for (methods, 0..) |method, method_index| {
        duplicated[method_index] = .{
            .name = method.name,
            .is_suspend = method.is_suspend,
            .has_default_body = method.has_default_body,
            .generic_params = if (method.generic_params.len != 0) try allocator.dupe(typed.GenericParam, method.generic_params) else &.{},
            .where_predicates = if (method.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, method.where_predicates) else &.{},
            .syntax = if (method.syntax) |syntax| try syntax.clone(allocator) else null,
        };
        initialized = method_index + 1;
    }

    return duplicated;
}

fn resolveEnumVariantsForImport(allocator: Allocator, module: *const typed.Module, variants: []const typed.EnumVariant) ![]typed.EnumVariant {
    const duplicated = try duplicateEnumVariants(allocator, variants);
    for (duplicated) |*variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |*field| {
                    field.ty = resolveModuleValueType(module, field.ty, field.type_name);
                }
            },
            .named_fields => |named_fields| {
                for (named_fields) |*field| {
                    field.ty = resolveModuleValueType(module, field.ty, field.type_name);
                }
            },
        }
    }
    return duplicated;
}

fn resolveModuleValueType(module: *const typed.Module, current: types.TypeRef, type_name: []const u8) types.TypeRef {
    if (!current.isUnsupported()) return current;

    const builtin = types.Builtin.fromName(type_name);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);

    for (module.items.items) |item| {
        if ((item.category == .type_decl or item.category == .trait_decl) and std.mem.eql(u8, item.name, type_name)) {
            return .{ .named = item.name };
        }
    }

    for (module.imports.items) |binding| {
        if ((binding.category == .type_decl or binding.category == .trait_decl) and std.mem.eql(u8, binding.local_name, type_name)) {
            return .{ .named = binding.local_name };
        }
    }

    return .unsupported;
}
