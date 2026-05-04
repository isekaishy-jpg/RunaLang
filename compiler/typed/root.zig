const std = @import("std");
const array_list = std.array_list;
const attribute_support = @import("../attribute_support.zig");
const ast = @import("../ast/root.zig");
const typed_decls = @import("declarations.zig");
const diag = @import("../diag/root.zig");
const typed_expr = @import("expr.zig");
const hir = @import("../hir/root.zig");
const signatures = @import("../signature_types.zig");
const source = @import("../source/root.zig");
const typed_statement = @import("statement.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const hasBareAttribute = attribute_support.hasBareAttribute;
const symbolNameFor = attribute_support.symbolNameFor;

pub const produced_by_type_checking = true;
pub const ownership_validation_runs_after = true;

pub const ItemCategory = enum {
    value,
    type_decl,
    trait_decl,
    impl_block,
    foreign_decl,
    module_decl,
    import_binding,
};

pub const ImportedBinding = struct {
    local_name: []const u8,
    target_name: []const u8,
    target_symbol: []const u8,
    category: ItemCategory,
    const_type: ?types.TypeRef = null,
    function_return_type: ?types.TypeRef = null,
    function_generic_params: []GenericParam = &.{},
    function_where_predicates: []WherePredicate = &.{},
    function_is_suspend: bool = false,
    function_parameter_types: ?[]types.TypeRef = null,
    function_parameter_type_names: ?[]const []const u8 = null,
    function_parameter_modes: ?[]ParameterMode = null,
    struct_fields: ?[]StructField = null,
    enum_variants: ?[]EnumVariant = null,
    trait_methods: ?[]TraitMethod = null,

    pub fn deinit(self: ImportedBinding, allocator: Allocator) void {
        if (self.function_generic_params.len != 0) allocator.free(self.function_generic_params);
        deinitWherePredicates(allocator, self.function_where_predicates);
        if (self.function_parameter_types) |value| allocator.free(value);
        if (self.function_parameter_type_names) |value| allocator.free(value);
        if (self.function_parameter_modes) |value| allocator.free(value);
        if (self.struct_fields) |fields| typed_decls.deinitStructFields(allocator, fields);
        if (self.enum_variants) |variants| {
            for (variants) |*variant| variant.deinit(allocator);
            allocator.free(variants);
        }
        if (self.trait_methods) |methods| {
            for (methods) |*method| method.deinit(allocator);
            allocator.free(methods);
        }
    }
};

pub const ParameterMode = typed_decls.ParameterMode;
pub const Parameter = typed_decls.Parameter;

pub const GenericParamKind = signatures.GenericParamKind;
pub const GenericParam = signatures.GenericParam;
pub const BoundPredicate = signatures.BoundPredicate;
pub const ProjectionEqualityPredicate = signatures.ProjectionEqualityPredicate;
pub const LifetimeOutlivesPredicate = signatures.LifetimeOutlivesPredicate;
pub const TypeOutlivesPredicate = signatures.TypeOutlivesPredicate;
pub const WherePredicate = signatures.WherePredicate;
pub const cloneWherePredicates = signatures.cloneWherePredicates;
pub const deinitWherePredicates = signatures.deinitWherePredicates;

pub const MethodReceiverMode = enum {
    take,
    read,
    edit,
};

pub const BinaryOp = typed_expr.BinaryOp;
pub const UnaryOp = typed_expr.UnaryOp;
pub const ConversionMode = typed_expr.ConversionMode;
pub const Expr = typed_expr.Expr;
pub const Statement = typed_statement.Statement;
pub const Block = typed_statement.Block;
pub const FunctionData = typed_decls.FunctionData;
pub const CheckedFunctionData = typed_decls.FunctionData;
pub const ConstData = typed_decls.ConstData;
pub const StructField = typed_decls.StructField;
pub const TupleField = typed_decls.TupleField;
pub const cloneStructFields = typed_decls.cloneStructFields;
pub const deinitStructFields = typed_decls.deinitStructFields;
pub const cloneTupleFields = typed_decls.cloneTupleFields;
pub const deinitTupleFields = typed_decls.deinitTupleFields;
pub const StructData = typed_decls.StructData;
pub const UnionData = typed_decls.UnionData;
pub const EnumVariantPayload = typed_decls.EnumVariantPayload;
pub const EnumVariant = typed_decls.EnumVariant;
pub const EnumData = typed_decls.EnumData;
pub const OpaqueTypeData = typed_decls.OpaqueTypeData;
pub const TraitMethod = typed_decls.TraitMethod;
pub const TraitAssociatedType = typed_decls.TraitAssociatedType;
pub const TraitAssociatedTypeBinding = typed_decls.TraitAssociatedTypeBinding;
pub const TraitAssociatedConst = typed_decls.TraitAssociatedConst;
pub const TraitAssociatedConstBinding = typed_decls.TraitAssociatedConstBinding;
pub const TraitData = typed_decls.TraitData;
pub const ImplData = typed_decls.ImplData;

pub const Payload = union(enum) {
    none,
    function: FunctionData,
    const_item: ConstData,
    struct_type: StructData,
    union_type: UnionData,
    enum_type: EnumData,
    opaque_type: OpaqueTypeData,
    trait_type: TraitData,
    impl_block: ImplData,

    fn deinit(self: *Payload, allocator: Allocator) void {
        switch (self.*) {
            .function => |*function| function.deinit(allocator),
            .const_item => |*const_item| const_item.deinit(allocator),
            .struct_type => |*struct_type| struct_type.deinit(allocator),
            .union_type => |*union_type| union_type.deinit(allocator),
            .enum_type => |*enum_type| enum_type.deinit(allocator),
            .opaque_type => |*opaque_type| opaque_type.deinit(allocator),
            .trait_type => |*trait_type| trait_type.deinit(allocator),
            .impl_block => |*impl_block| impl_block.deinit(allocator),
            .none => {},
        }
    }
};

pub const Item = struct {
    name: []const u8,
    owns_name: bool = false,
    symbol_name: []const u8,
    category: ItemCategory,
    kind: ast.ItemKind,
    visibility: ast.Visibility,
    attributes: []ast.Attribute,
    span: source.Span,
    has_body: bool,
    is_synthetic: bool,
    is_reflectable: bool,
    is_boundary_api: bool,
    is_unsafe: bool,
    is_domain_root: bool,
    is_domain_context: bool,
    payload: Payload = .none,

    fn deinit(self: *Item, allocator: Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        ast.deinitAttributes(allocator, self.attributes);
        allocator.free(self.symbol_name);
        self.payload.deinit(allocator);
    }
};

pub const Module = struct {
    file_id: source.FileId,
    module_path: []const u8,
    symbol_prefix: []const u8,
    items: array_list.Managed(Item),
    imports: array_list.Managed(ImportedBinding),
    methods: array_list.Managed(MethodPrototype),

    pub fn init(allocator: Allocator, file_id: source.FileId, module_path: []const u8, symbol_prefix: []const u8) Module {
        return .{
            .file_id = file_id,
            .module_path = module_path,
            .symbol_prefix = symbol_prefix,
            .items = array_list.Managed(Item).init(allocator),
            .imports = array_list.Managed(ImportedBinding).init(allocator),
            .methods = array_list.Managed(MethodPrototype).init(allocator),
        };
    }

    pub fn deinit(self: *Module, allocator: Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit();
        for (self.imports.items) |binding| binding.deinit(allocator);
        self.imports.deinit();
        for (self.methods.items) |method| method.deinit(allocator);
        self.methods.deinit();
        allocator.free(self.module_path);
        allocator.free(self.symbol_prefix);
    }
};

pub const FunctionPrototype = struct {
    name: []const u8,
    target_name: []const u8,
    target_symbol: []const u8,
    return_type: types.TypeRef,
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    is_suspend: bool,
    parameter_types: []types.TypeRef,
    parameter_type_names: []const []const u8,
    parameter_modes: []ParameterMode,
    unsafe_required: bool,

    pub fn deinit(self: FunctionPrototype, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        deinitWherePredicates(allocator, self.where_predicates);
        allocator.free(self.parameter_types);
        allocator.free(self.parameter_type_names);
        allocator.free(self.parameter_modes);
    }
};

pub const MethodPrototype = struct {
    target_type: []const u8,
    method_name: []const u8,
    function_name: []const u8,
    function_symbol: []const u8,
    receiver_mode: MethodReceiverMode,
    return_type: types.TypeRef,
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    is_suspend: bool,
    parameter_types: []types.TypeRef,
    parameter_type_names: []const []const u8,
    parameter_modes: []ParameterMode,

    pub fn deinit(self: MethodPrototype, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        deinitWherePredicates(allocator, self.where_predicates);
        allocator.free(self.parameter_types);
        allocator.free(self.parameter_type_names);
        allocator.free(self.parameter_modes);
    }
};

pub const StructPrototype = struct {
    name: []const u8,
    symbol_name: []const u8,
    fields: []const StructField,
};

pub const EnumPrototype = struct {
    name: []const u8,
    symbol_name: []const u8,
    variants: []const EnumVariant,
};

pub fn prepareModule(
    allocator: Allocator,
    module: hir.Module,
    module_path: []const u8,
    symbol_prefix: []const u8,
    diagnostics: *diag.Bag,
    prototypes: *array_list.Managed(FunctionPrototype),
) !Module {
    var typed_module = Module.init(allocator, module.file_id, module_path, try allocator.dupe(u8, symbol_prefix));
    errdefer typed_module.deinit(allocator);
    _ = diagnostics;
    _ = prototypes;

    for (module.items.items) |item| {
        const typed_item = try createTypedItem(allocator, item, module_path, symbol_prefix);
        try typed_module.items.append(typed_item);
    }
    return typed_module;
}

pub fn addImportedBinding(allocator: Allocator, module: *Module, binding: ImportedBinding) !void {
    for (module.imports.items) |existing| {
        if (std.mem.eql(u8, existing.local_name, binding.local_name)) {
            binding.deinit(allocator);
            return;
        }
    }
    try module.imports.append(binding);
}

pub fn addImportedMethodPrototype(allocator: Allocator, module: *Module, method: MethodPrototype) !void {
    _ = allocator;
    for (module.methods.items) |existing| {
        if (std.mem.eql(u8, existing.target_type, method.target_type) and std.mem.eql(u8, existing.method_name, method.method_name)) {
            if (std.mem.eql(u8, existing.function_symbol, method.function_symbol)) {
                var owned = method;
                owned.deinit(module.methods.allocator);
                return;
            }
            var owned = method;
            owned.deinit(module.methods.allocator);
            return;
        }
    }
    try module.methods.append(method);
}

fn createTypedItem(
    allocator: Allocator,
    item: hir.Item,
    module_path: []const u8,
    symbol_prefix: []const u8,
) !Item {
    const item_is_domain_root = hasBareAttribute(item.attributes, "domain_root");
    const item_is_domain_context = hasBareAttribute(item.attributes, "domain_context");

    const item_is_reflectable = hasBareAttribute(item.attributes, "reflect");

    const category: ItemCategory = switch (item.kind) {
        .function, .suspend_function, .const_item => .value,
        .type_alias, .struct_type, .enum_type, .union_type, .opaque_type => .type_decl,
        .trait_type => .trait_decl,
        .impl_block => .impl_block,
        .foreign_function => .foreign_decl,
        .module_decl => .module_decl,
        .use_decl => .import_binding,
    };

    var typed_item = Item{
        .name = item.name,
        .symbol_name = try symbolNameFor(allocator, symbol_prefix, module_path, item),
        .category = category,
        .kind = item.kind,
        .visibility = item.visibility,
        .attributes = try ast.cloneAttributes(allocator, item.attributes),
        .span = item.span,
        .has_body = item.has_body,
        .is_synthetic = false,
        .is_reflectable = item_is_reflectable,
        .is_boundary_api = attribute_support.boundaryKind(item.attributes) != null,
        .is_unsafe = hasBareAttribute(item.attributes, "unsafe"),
        .is_domain_root = item_is_domain_root,
        .is_domain_context = item_is_domain_context,
        .payload = .none,
    };
    errdefer typed_item.deinit(allocator);

    return typed_item;
}
