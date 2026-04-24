const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const body_syntax_bridge = @import("body_syntax_bridge.zig");
const declaration_parse = @import("declaration_parse.zig");
const typed_decls = @import("declarations.zig");
const diag = @import("../diag/root.zig");
const hir = @import("../hir/root.zig");
const source = @import("../source/root.zig");
const typed_attributes = @import("attributes.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const FunctionData = typed_decls.FunctionData;
const GenericParam = typed_decls.GenericParam;
const MethodReceiverMode = declaration_parse.MethodReceiverMode;
const Parameter = typed_decls.Parameter;
const ParameterMode = typed_decls.ParameterMode;
const TraitMethod = typed_decls.TraitMethod;
const WherePredicate = typed_decls.WherePredicate;
const symbolNameForSyntheticName = typed_attributes.symbolNameForSyntheticName;

const ParsedImplMethod = struct {
    method_name: []const u8,
    receiver_mode: MethodReceiverMode,
    function: FunctionData,
};

pub fn appendImplMethodItems(
    allocator: Allocator,
    typed_module: anytype,
    item: hir.Item,
    typed_item_index: usize,
    symbol_prefix: []const u8,
    module_path: []const u8,
    diagnostics: *diag.Bag,
    prototypes: anytype,
) !void {
    if (typed_item_index >= typed_module.items.items.len) return;
    const impl_data = switch (typed_module.items.items[typed_item_index].payload) {
        .impl_block => |*impl_block| impl_block,
        else => return,
    };
    const impl_target_type = impl_data.target_type;
    const impl_trait_name = impl_data.trait_name;
    const impl_generic_params = impl_data.generic_params;
    const impl_methods = impl_data.methods;

    switch (item.body_syntax) {
        .impl_body => |body| {
            for (body.methods) |method| {
                const maybe_parsed = try body_syntax_bridge.parseExecutableMethodFromSyntax(
                    allocator,
                    impl_target_type,
                    impl_generic_params,
                    method,
                    diagnostics,
                );
                if (maybe_parsed) |parsed| {
                    try appendExecutableMethodItem(
                        allocator,
                        typed_module,
                        impl_target_type,
                        .{
                            .method_name = parsed.method_name,
                            .receiver_mode = switch (parsed.receiver_mode) {
                                .take => .take,
                                .read => .read,
                                .edit => .edit,
                                .owned => unreachable,
                            },
                            .function = parsed.function,
                        },
                        item.span,
                        symbol_prefix,
                        module_path,
                        diagnostics,
                        prototypes,
                    );
                }
            }
        },
        .none => {
            if (item.has_body) return error.InvalidParse;
        },
        else => return error.InvalidParse,
    }

    if (impl_trait_name) |trait_name| {
        const trait_methods = findLocalTraitMethods(typed_module, trait_name) orelse return;
        for (trait_methods) |trait_method| {
            if (implContainsMethod(impl_methods, trait_method.name)) continue;
            if (trait_method.has_default_body) {
                const parsed = (try body_syntax_bridge.parseExecutableMethodFromTraitMethod(
                    allocator,
                    impl_target_type,
                    impl_generic_params,
                    trait_method,
                    diagnostics,
                )) orelse {
                    try diagnostics.add(.@"error", "type.method.syntax.missing", item.span, "default trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
                        trait_method.name,
                    });
                    continue;
                };
                try appendExecutableMethodItem(
                    allocator,
                    typed_module,
                    impl_target_type,
                    .{
                        .method_name = parsed.method_name,
                        .receiver_mode = switch (parsed.receiver_mode) {
                            .take => .take,
                            .read => .read,
                            .edit => .edit,
                            .owned => unreachable,
                        },
                        .function = parsed.function,
                    },
                    item.span,
                    symbol_prefix,
                    module_path,
                    diagnostics,
                    prototypes,
                );
            } else {
                try diagnostics.add(.@"error", "type.impl.method_missing", item.span, "trait impl for '{s}' is missing required method '{s}'", .{
                    impl_target_type,
                    trait_method.name,
                });
            }
        }
    }
}

pub fn synthesizeImportedTraitDefaultMethods(
    allocator: Allocator,
    typed_module: anytype,
    diagnostics: *diag.Bag,
    prototypes: anytype,
) !void {
    for (typed_module.items.items) |item| {
        const impl_data = switch (item.payload) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        const trait_name = impl_data.trait_name orelse continue;
        if (findLocalTraitMethods(typed_module, trait_name) != null) continue;

        const trait_methods = findImportedTraitMethods(typed_module, trait_name) orelse continue;
        for (trait_methods) |trait_method| {
            if (implContainsMethod(impl_data.methods, trait_method.name)) continue;
            if (trait_method.has_default_body) {
                const parsed = (try body_syntax_bridge.parseExecutableMethodFromTraitMethod(
                    allocator,
                    impl_data.target_type,
                    impl_data.generic_params,
                    trait_method,
                    diagnostics,
                )) orelse {
                    try diagnostics.add(.@"error", "type.method.syntax.missing", item.span, "imported default trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
                        trait_method.name,
                    });
                    continue;
                };
                try appendExecutableMethodItem(
                    allocator,
                    typed_module,
                    impl_data.target_type,
                    .{
                        .method_name = parsed.method_name,
                        .receiver_mode = switch (parsed.receiver_mode) {
                            .take => .take,
                            .read => .read,
                            .edit => .edit,
                            .owned => unreachable,
                        },
                        .function = parsed.function,
                    },
                    item.span,
                    typed_module.symbol_prefix,
                    typed_module.module_path,
                    diagnostics,
                    prototypes,
                );
            } else {
                try diagnostics.add(.@"error", "type.impl.method_missing", item.span, "trait impl for '{s}' is missing required method '{s}'", .{
                    impl_data.target_type,
                    trait_method.name,
                });
            }
        }
    }
}

fn appendExecutableMethodItem(
    allocator: Allocator,
    typed_module: anytype,
    target_type: []const u8,
    parsed: ParsedImplMethod,
    span: source.Span,
    symbol_prefix: []const u8,
    module_path: []const u8,
    diagnostics: *diag.Bag,
    prototypes: anytype,
) !void {
    if (findMethodPrototype(typed_module.methods.items, target_type, parsed.method_name) != null) {
        var duplicate_function = parsed.function;
        duplicate_function.deinit(allocator);
        try diagnostics.add(.@"error", "type.method.duplicate", span, "duplicate executable method '{s}.{s}' in stage0", .{
            target_type,
            parsed.method_name,
        });
        return;
    }

    var function = parsed.function;
    errdefer function.deinit(allocator);

    const internal_name = try std.fmt.allocPrint(allocator, "{s}__{s}", .{
        target_type,
        parsed.method_name,
    });
    errdefer allocator.free(internal_name);
    const symbol_name = try symbolNameForSyntheticName(allocator, symbol_prefix, module_path, internal_name);
    errdefer allocator.free(symbol_name);

    const parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
    errdefer allocator.free(parameter_types);
    const parameter_type_names = try duplicateParameterTypeNames(allocator, function.parameters.items);
    errdefer allocator.free(parameter_type_names);
    const parameter_modes = try allocator.alloc(ParameterMode, function.parameters.items.len);
    errdefer allocator.free(parameter_modes);
    for (function.parameters.items, 0..) |parameter, parameter_index| {
        parameter_types[parameter_index] = parameter.ty;
        parameter_modes[parameter_index] = parameter.mode;
    }

    const method_parameter_types = try allocator.dupe(types.TypeRef, parameter_types);
    errdefer allocator.free(method_parameter_types);
    const method_parameter_type_names = try allocator.dupe([]const u8, parameter_type_names);
    errdefer allocator.free(method_parameter_type_names);
    const method_parameter_modes = try allocator.dupe(ParameterMode, parameter_modes);
    errdefer allocator.free(method_parameter_modes);

    try typed_module.items.append(.{
        .name = internal_name,
        .owns_name = true,
        .symbol_name = symbol_name,
        .category = .value,
        .kind = .function,
        .visibility = .private,
        .attributes = try allocator.alloc(ast.Attribute, 0),
        .span = span,
        .has_body = true,
        .is_synthetic = true,
        .is_reflectable = false,
        .is_boundary_api = false,
        .is_unsafe = false,
        .is_domain_root = false,
        .is_domain_context = false,
        .payload = .{ .function = function },
    });

    try prototypes.append(.{
        .name = internal_name,
        .target_name = parsed.method_name,
        .target_symbol = symbol_name,
        .return_type = typed_module.items.items[typed_module.items.items.len - 1].payload.function.return_type,
        .generic_params = if (function.generic_params.len != 0) try allocator.dupe(GenericParam, function.generic_params) else &.{},
        .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(WherePredicate, function.where_predicates) else &.{},
        .is_suspend = function.is_suspend,
        .parameter_types = parameter_types,
        .parameter_type_names = parameter_type_names,
        .parameter_modes = parameter_modes,
        .unsafe_required = false,
    });

    try typed_module.methods.append(.{
        .target_type = target_type,
        .method_name = parsed.method_name,
        .function_name = internal_name,
        .function_symbol = symbol_name,
        .receiver_mode = parsed.receiver_mode,
        .return_type = typed_module.items.items[typed_module.items.items.len - 1].payload.function.return_type,
        .generic_params = if (function.generic_params.len != 0) try allocator.dupe(GenericParam, function.generic_params) else &.{},
        .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(WherePredicate, function.where_predicates) else &.{},
        .is_suspend = function.is_suspend,
        .parameter_types = method_parameter_types,
        .parameter_type_names = method_parameter_type_names,
        .parameter_modes = method_parameter_modes,
    });
}

fn findLocalTraitMethods(module: anytype, trait_name: []const u8) ?[]const TraitMethod {
    for (module.items.items) |*item| {
        if (!std.mem.eql(u8, item.name, trait_name)) continue;
        switch (item.payload) {
            .trait_type => |*trait_type| return trait_type.methods,
            else => {},
        }
    }
    return null;
}

fn findImportedTraitMethods(module: anytype, trait_name: []const u8) ?[]const TraitMethod {
    for (module.imports.items) |binding| {
        if (binding.category != .trait_decl) continue;
        if (!std.mem.eql(u8, binding.local_name, trait_name)) continue;
        if (binding.trait_methods) |methods| return methods;
    }
    return null;
}

fn implContainsMethod(methods: []const TraitMethod, method_name: []const u8) bool {
    for (methods) |method| {
        if (std.mem.eql(u8, method.name, method_name)) return true;
    }
    return false;
}

fn duplicateParameterTypeNames(allocator: Allocator, parameters: []const Parameter) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, parameters.len);
    for (parameters, 0..) |parameter, index| {
        names[index] = parameter.type_name;
    }
    return names;
}

fn findMethodPrototype(method_prototypes: anytype, target_type: []const u8, method_name: []const u8) ?std.meta.Child(@TypeOf(method_prototypes)) {
    for (method_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.target_type, target_type) and std.mem.eql(u8, prototype.method_name, method_name)) {
            return prototype;
        }
    }
    return null;
}
