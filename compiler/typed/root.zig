const std = @import("std");
const array_list = std.array_list;
const abi = @import("../abi/root.zig");
const ast = @import("../ast/root.zig");
const declaration_parse = @import("declaration_parse.zig");
const expression_parse = @import("expression_parse.zig");
const impl_methods = @import("impl_methods.zig");
const typed_decls = @import("declarations.zig");
const diag = @import("../diag/root.zig");
const typed_expr = @import("expr.zig");
const hir = @import("../hir/root.zig");
const pattern_parse = @import("pattern_parse.zig");
const signatures = @import("signatures.zig");
const source = @import("../source/root.zig");
const typed_statement = @import("statement.zig");
const type_support = @import("type_support.zig");
const typed_attributes = @import("attributes.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const cloneExprForTyped = typed_expr.cloneExpr;
const baseTypeName = typed_text.baseTypeName;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelScalar = typed_text.findTopLevelScalar;
const genericParamExists = signatures.genericParamExists;
const hasAttribute = typed_attributes.hasAttribute;
const isAllowedAttribute = typed_attributes.isAllowedAttribute;
const isBuiltinLifetime = signatures.isBuiltinLifetime;
const isIdentifierContinue = typed_text.isIdentifierContinue;
const isIdentifierStart = typed_text.isIdentifierStart;
const isLifetimeName = signatures.isLifetimeName;
const isPlainIdentifier = typed_text.isPlainIdentifier;
const mergeGenericParams = signatures.mergeGenericParams;
const parseExportName = typed_attributes.parseExportName;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;
const symbolNameFor = typed_attributes.symbolNameFor;
const symbolNameForSyntheticName = typed_attributes.symbolNameForSyntheticName;
const BoundaryType = type_support.BoundaryType;
const boundaryFromParameter = type_support.boundaryFromParameter;
const boundaryFromTypeRef = type_support.boundaryFromTypeRef;
const builtinOfTypeRef = type_support.builtinOfTypeRef;
const duplicateParameterTypeNames = type_support.duplicateParameterTypeNames;
const findEnumPrototype = type_support.findEnumPrototype;
const findEnumVariant = type_support.findEnumVariant;
const findMethodPrototype = type_support.findMethodPrototype;
const findPrototype = type_support.findPrototype;
const findStructPrototype = type_support.findStructPrototype;
const inferExprBoundaryTypeInScope = type_support.inferExprBoundaryTypeInScope;
const parseExpressionSyntax = expression_parse.parseExpressionSyntax;
const parseBoundaryType = type_support.parseBoundaryType;
const returnTypeStructurallyCompatible = type_support.returnTypeStructurallyCompatible;
const validateLifetimeReference = signatures.validateLifetimeReference;

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
        if (self.function_where_predicates.len != 0) allocator.free(self.function_where_predicates);
        if (self.function_parameter_types) |value| allocator.free(value);
        if (self.function_parameter_type_names) |value| allocator.free(value);
        if (self.function_parameter_modes) |value| allocator.free(value);
        if (self.struct_fields) |fields| allocator.free(fields);
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

pub const MethodReceiverMode = declaration_parse.MethodReceiverMode;

pub const BinaryOp = typed_expr.BinaryOp;
pub const UnaryOp = typed_expr.UnaryOp;
pub const Expr = typed_expr.Expr;
pub const Statement = typed_statement.Statement;
pub const Block = typed_statement.Block;
pub const FunctionData = typed_decls.FunctionData;
pub const ConstData = typed_decls.ConstData;
pub const StructField = typed_decls.StructField;
pub const TupleField = typed_decls.TupleField;
pub const StructData = typed_decls.StructData;
pub const UnionData = typed_decls.UnionData;
pub const EnumVariantPayload = typed_decls.EnumVariantPayload;
pub const EnumVariant = typed_decls.EnumVariant;
pub const EnumData = typed_decls.EnumData;
pub const OpaqueTypeData = typed_decls.OpaqueTypeData;
pub const TraitMethod = typed_decls.TraitMethod;
pub const TraitAssociatedType = typed_decls.TraitAssociatedType;
pub const TraitAssociatedTypeBinding = typed_decls.TraitAssociatedTypeBinding;
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
    signature_diagnostics: []diag.Diagnostic = &.{},
    body_diagnostics: []diag.Diagnostic = &.{},
    payload: Payload = .none,

    fn deinit(self: *Item, allocator: Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        allocator.free(self.attributes);
        allocator.free(self.symbol_name);
        deinitDiagnosticSlice(allocator, self.signature_diagnostics);
        deinitDiagnosticSlice(allocator, self.body_diagnostics);
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
    signature_diagnostics: []diag.Diagnostic = &.{},

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
        deinitDiagnosticSlice(allocator, self.signature_diagnostics);
        allocator.free(self.module_path);
        allocator.free(self.symbol_prefix);
    }
};

fn deinitDiagnosticSlice(allocator: Allocator, diagnostics: []diag.Diagnostic) void {
    for (diagnostics) |diagnostic| allocator.free(diagnostic.message);
    if (diagnostics.len != 0) allocator.free(diagnostics);
}

fn drainDiagnostics(bag: *diag.Bag) ![]diag.Diagnostic {
    if (bag.items.items.len == 0) {
        bag.items.deinit();
        return &.{};
    }
    return bag.items.toOwnedSlice();
}

fn appendDiagnostics(
    allocator: Allocator,
    target: *[]diag.Diagnostic,
    incoming: []diag.Diagnostic,
) !void {
    if (incoming.len == 0) return;
    errdefer deinitDiagnosticSlice(allocator, incoming);

    if (target.*.len == 0) {
        target.* = incoming;
        return;
    }

    const merged = try allocator.alloc(diag.Diagnostic, target.*.len + incoming.len);
    @memcpy(merged[0..target.*.len], target.*);
    @memcpy(merged[target.*.len..], incoming);
    allocator.free(target.*);
    allocator.free(incoming);
    target.* = merged;
}

fn appendDiagnostic(
    allocator: Allocator,
    target: *[]diag.Diagnostic,
    severity: diag.Severity,
    code: []const u8,
    span: ?source.Span,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var bag = diag.Bag.init(allocator);
    var drained = false;
    errdefer if (!drained) bag.deinit();
    try bag.add(severity, code, span, fmt, args);
    const diagnostics = try drainDiagnostics(&bag);
    drained = true;
    try appendDiagnostics(allocator, target, diagnostics);
}

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
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
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
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
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

    for (module.items.items) |item| {
        var semantic_diagnostics = diag.Bag.init(allocator);
        var diagnostics_drained = false;
        errdefer if (!diagnostics_drained) semantic_diagnostics.deinit();

        var typed_item = try createTypedItem(allocator, item, module_path, symbol_prefix, &semantic_diagnostics, prototypes);
        typed_item.signature_diagnostics = try drainDiagnostics(&semantic_diagnostics);
        diagnostics_drained = true;
        try typed_module.items.append(typed_item);
    }

    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .impl_block) continue;
        var semantic_diagnostics = diag.Bag.init(allocator);
        var diagnostics_drained = false;
        errdefer if (!diagnostics_drained) semantic_diagnostics.deinit();

        try impl_methods.appendImplMethodItems(
            allocator,
            &typed_module,
            item,
            item_index,
            symbol_prefix,
            module_path,
            &semantic_diagnostics,
            prototypes,
        );
        const drained = try drainDiagnostics(&semantic_diagnostics);
        diagnostics_drained = true;
        try appendDiagnostics(allocator, &typed_module.items.items[item_index].signature_diagnostics, drained);
    }

    _ = diagnostics;
    return typed_module;
}

pub fn finalizePreparedModule(
    allocator: Allocator,
    typed_module: *Module,
    prototypes: *array_list.Managed(FunctionPrototype),
    diagnostics: *diag.Bag,
) !void {
    var global_scope = Scope.init(allocator);
    defer global_scope.deinit();
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    var struct_prototypes = array_list.Managed(StructPrototype).init(allocator);
    defer struct_prototypes.deinit();
    var enum_prototypes = array_list.Managed(EnumPrototype).init(allocator);
    defer enum_prototypes.deinit();

    for (typed_module.items.items) |item| {
        switch (item.payload) {
            .const_item => |const_item| {
                if (item.name.len != 0) try global_scope.put(item.name, types.TypeRef.fromBuiltin(const_item.ty), false);
            },
            else => {},
        }
        if (item.category == .type_decl or item.category == .trait_decl) {
            if (item.name.len != 0) try type_scope.put(item.name);
        }
    }

    for (typed_module.imports.items) |binding| {
        if (binding.const_type) |ty| try global_scope.put(binding.local_name, ty, false);
        if (binding.category == .type_decl or binding.category == .trait_decl) {
            try type_scope.put(binding.local_name);
        }
        if (binding.struct_fields) |fields| {
            try struct_prototypes.append(.{
                .name = binding.local_name,
                .symbol_name = binding.target_symbol,
                .fields = fields,
            });
        }
        if (binding.enum_variants) |variants| {
            try enum_prototypes.append(.{
                .name = binding.local_name,
                .symbol_name = binding.target_symbol,
                .variants = variants,
            });
        }
    }

    var imported_default_diagnostics = diag.Bag.init(allocator);
    var imported_default_diagnostics_drained = false;
    errdefer if (!imported_default_diagnostics_drained) imported_default_diagnostics.deinit();
    try impl_methods.synthesizeImportedTraitDefaultMethods(allocator, typed_module, &imported_default_diagnostics, prototypes);
    const imported_default_drained = try drainDiagnostics(&imported_default_diagnostics);
    imported_default_diagnostics_drained = true;
    try appendDiagnostics(allocator, &typed_module.signature_diagnostics, imported_default_drained);

    for (typed_module.items.items) |*item| {
        switch (item.payload) {
            .function => |*function| {
                var semantic_diagnostics = diag.Bag.init(allocator);
                var diagnostics_drained = false;
                errdefer if (!diagnostics_drained) semantic_diagnostics.deinit();
                try resolveFunctionSignature(typed_module, item, function, &type_scope, prototypes.items, typed_module.methods.items, &semantic_diagnostics);
                const drained = try drainDiagnostics(&semantic_diagnostics);
                diagnostics_drained = true;
                try appendDiagnostics(allocator, &item.signature_diagnostics, drained);
            },
            else => {},
        }
    }

    for (typed_module.items.items) |*item| {
        var semantic_diagnostics = diag.Bag.init(allocator);
        var diagnostics_drained = false;
        errdefer if (!diagnostics_drained) semantic_diagnostics.deinit();

        switch (item.payload) {
            .struct_type => |*struct_type| {
                try declaration_parse.resolveStructFieldsWithContext(struct_type.fields, .{
                    .type_scope = &type_scope,
                    .generic_params = struct_type.generic_params,
                }, item.span, &semantic_diagnostics);
                try struct_prototypes.append(.{
                    .name = item.name,
                    .symbol_name = item.symbol_name,
                    .fields = struct_type.fields,
                });
            },
            .union_type => |*union_type| try declaration_parse.resolveStructFieldsWithContext(union_type.fields, .{
                .type_scope = &type_scope,
            }, item.span, &semantic_diagnostics),
            .enum_type => |*enum_type| {
                try declaration_parse.resolveEnumVariantsWithContext(enum_type.variants, .{
                    .type_scope = &type_scope,
                    .generic_params = enum_type.generic_params,
                }, item.span, &semantic_diagnostics);
                try enum_prototypes.append(.{
                    .name = item.name,
                    .symbol_name = item.symbol_name,
                    .variants = enum_type.variants,
                });
            },
            else => {},
        }

        const drained = try drainDiagnostics(&semantic_diagnostics);
        diagnostics_drained = true;
        try appendDiagnostics(allocator, &item.signature_diagnostics, drained);
    }

    for (typed_module.items.items) |*item| {
        var semantic_diagnostics = diag.Bag.init(allocator);
        var diagnostics_drained = false;
        errdefer if (!diagnostics_drained) semantic_diagnostics.deinit();
        try finalizeItem(allocator, typed_module, item, prototypes.items, typed_module.methods.items, &global_scope, &type_scope, struct_prototypes.items, enum_prototypes.items, &semantic_diagnostics);
        const drained = try drainDiagnostics(&semantic_diagnostics);
        diagnostics_drained = true;
        switch (item.payload) {
            .function => try appendDiagnostics(allocator, &item.body_diagnostics, drained),
            else => try appendDiagnostics(allocator, &item.signature_diagnostics, drained),
        }
    }

    _ = diagnostics;
}

fn resolveFunctionSignature(
    module: *const Module,
    item: *Item,
    function: *FunctionData,
    type_scope: *const NameSet,
    prototypes: []FunctionPrototype,
    method_prototypes: []MethodPrototype,
    diagnostics: *diag.Bag,
) !void {
    var self_type_name: ?[]const u8 = null;
    for (method_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.function_symbol, item.symbol_name)) {
            self_type_name = prototype.target_type;
            break;
        }
    }

    const context: TypeResolutionContext = .{
        .type_scope = type_scope,
        .generic_params = function.generic_params,
        .allow_self = self_type_name != null,
        .self_type_name = self_type_name,
    };

    function.return_type = try declaration_parse.resolveValueTypeWithContext(function.return_type_name, context, item.span, diagnostics);
    for (function.parameters.items) |*parameter| {
        parameter.ty = try declaration_parse.resolveValueTypeWithContext(parameter.type_name, context, item.span, diagnostics);
    }

    try declaration_parse.validateWherePredicates(module, function.where_predicates, context, item.span, diagnostics);

    for (prototypes) |*prototype| {
        if (!std.mem.eql(u8, prototype.target_symbol, item.symbol_name)) continue;
        prototype.return_type = function.return_type;
        if (prototype.parameter_types.len == function.parameters.items.len) {
            for (function.parameters.items, 0..) |parameter, index| {
                prototype.parameter_types[index] = parameter.ty;
                prototype.parameter_modes[index] = parameter.mode;
            }
        }
        break;
    }

    for (method_prototypes) |*prototype| {
        if (!std.mem.eql(u8, prototype.function_symbol, item.symbol_name)) continue;
        prototype.return_type = function.return_type;
        if (prototype.parameter_types.len == function.parameters.items.len) {
            for (function.parameters.items, 0..) |parameter, index| {
                prototype.parameter_types[index] = parameter.ty;
                prototype.parameter_modes[index] = parameter.mode;
            }
        }
        break;
    }

    if (function.foreign) {
        if (builtinOfTypeRef(function.return_type) == .unsupported) {
            try diagnostics.add(.@"error", "type.stage0.return", item.span, "unsupported stage0 foreign return type '{s}'", .{function.return_type_name});
        }
        for (function.parameters.items) |parameter| {
            if (builtinOfTypeRef(parameter.ty) == .unsupported) {
                try diagnostics.add(.@"error", "type.stage0.param_type", item.span, "unsupported stage0 foreign parameter type in function '{s}'", .{item.name});
            }
        }
        try abi.validateForeignFunction(item.span, item.has_body, item.is_unsafe, function, diagnostics);
    }
}

pub fn addImportedBinding(allocator: Allocator, module: *Module, binding: ImportedBinding) !void {
    for (module.imports.items) |existing| {
        if (std.mem.eql(u8, existing.local_name, binding.local_name)) {
            try appendDiagnostic(
                allocator,
                &module.signature_diagnostics,
                .@"error",
                "type.import.duplicate",
                null,
                "duplicate imported name '{s}'",
                .{binding.local_name},
            );
            binding.deinit(allocator);
            return;
        }
    }
    try module.imports.append(binding);
}

pub fn addImportedMethodPrototype(allocator: Allocator, module: *Module, method: MethodPrototype) !void {
    for (module.methods.items) |existing| {
        if (std.mem.eql(u8, existing.target_type, method.target_type) and std.mem.eql(u8, existing.method_name, method.method_name)) {
            if (std.mem.eql(u8, existing.function_symbol, method.function_symbol)) {
                var owned = method;
                owned.deinit(module.methods.allocator);
                return;
            }
            try appendDiagnostic(
                allocator,
                &module.signature_diagnostics,
                .@"error",
                "type.method.duplicate",
                null,
                "duplicate imported method '{s}.{s}'",
                .{
                    method.target_type,
                    method.method_name,
                },
            );
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
    diagnostics: *diag.Bag,
    prototypes: *array_list.Managed(FunctionPrototype),
) !Item {
    for (item.attributes) |attribute| {
        if (!isAllowedAttribute(attribute.name)) {
            try diagnostics.add(.@"error", "type.attr.unknown", attribute.span, "unknown attribute '{s}'", .{attribute.name});
        }
    }

    const item_is_domain_root = hasAttribute(item.attributes, "domain_root");
    const item_is_domain_context = hasAttribute(item.attributes, "domain_context");

    const item_is_reflectable = hasAttribute(item.attributes, "reflect");

    if ((item.kind == .function or item.kind == .suspend_function) and !item.has_body) {
        try diagnostics.add(.@"error", "type.fn.body", item.span, "functions require a body in v1", .{});
    }
    if (item.kind == .opaque_type and item.has_body) {
        try diagnostics.add(.@"error", "type.opaque.body", item.span, "opaque type declarations do not have a body", .{});
    }

    const category: ItemCategory = switch (item.kind) {
        .function, .suspend_function, .const_item => .value,
        .struct_type, .enum_type, .union_type, .opaque_type => .type_decl,
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
        .attributes = try allocator.dupe(ast.Attribute, item.attributes),
        .span = item.span,
        .has_body = item.has_body,
        .is_synthetic = false,
        .is_reflectable = item_is_reflectable,
        .is_boundary_api = hasAttribute(item.attributes, "boundary"),
        .is_unsafe = hasAttribute(item.attributes, "unsafe"),
        .is_domain_root = item_is_domain_root,
        .is_domain_context = item_is_domain_context,
        .payload = .none,
    };
    errdefer typed_item.deinit(allocator);

    switch (item.kind) {
        .function, .suspend_function, .foreign_function => {
            var function = try declaration_parse.parseFunctionSignature(allocator, item, diagnostics);
            errdefer function.deinit(allocator);

            const parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
            errdefer allocator.free(parameter_types);
            const parameter_type_names = try duplicateParameterTypeNames(allocator, function.parameters.items);
            errdefer allocator.free(parameter_type_names);
            const parameter_modes = try allocator.alloc(ParameterMode, function.parameters.items.len);
            errdefer allocator.free(parameter_modes);
            for (function.parameters.items, 0..) |parameter, index| {
                parameter_types[index] = parameter.ty;
                parameter_modes[index] = parameter.mode;
            }

            try prototypes.append(.{
                .name = item.name,
                .target_name = item.name,
                .target_symbol = typed_item.symbol_name,
                .return_type = function.return_type,
                .generic_params = if (function.generic_params.len != 0) try allocator.dupe(GenericParam, function.generic_params) else &.{},
                .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(WherePredicate, function.where_predicates) else &.{},
                .is_suspend = function.is_suspend,
                .parameter_types = parameter_types,
                .parameter_type_names = parameter_type_names,
                .parameter_modes = parameter_modes,
                .unsafe_required = typed_item.is_unsafe,
            });

            typed_item.payload = .{ .function = function };
        },
        .const_item => {
            typed_item.payload = .{ .const_item = try declaration_parse.parseConstDeclaration(allocator, item, diagnostics) };
        },
        .struct_type => {
            typed_item.payload = .{ .struct_type = try declaration_parse.parseStructDeclaration(allocator, item, diagnostics) };
        },
        .union_type => {
            typed_item.payload = .{ .union_type = try declaration_parse.parseUnionDeclaration(allocator, item, diagnostics) };
        },
        .enum_type => {
            typed_item.payload = .{ .enum_type = try declaration_parse.parseEnumDeclaration(allocator, item, diagnostics) };
        },
        .opaque_type => {
            typed_item.payload = .{ .opaque_type = try declaration_parse.parseOpaqueTypeDeclaration(allocator, item, diagnostics) };
        },
        .trait_type => {
            typed_item.payload = .{ .trait_type = try declaration_parse.parseTraitDeclaration(allocator, item, diagnostics) };
        },
        .impl_block => {
            typed_item.payload = .{ .impl_block = try declaration_parse.parseImplDeclaration(allocator, item, diagnostics) };
        },
        else => {},
    }

    return typed_item;
}

fn finalizeItem(
    allocator: Allocator,
    module: *const Module,
    item: *Item,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    global_scope: *const Scope,
    type_scope: *const NameSet,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
) !void {
    switch (item.payload) {
        .function => |*function| {
            if (item.kind != .foreign_function) {
                try parseFunctionBody(allocator, item, function, prototypes, method_prototypes, global_scope, struct_prototypes, enum_prototypes, diagnostics);
            }
        },
        .const_item => |*const_item| {
            try parseConstInitializer(allocator, item, const_item, prototypes, method_prototypes, global_scope, struct_prototypes, enum_prototypes, diagnostics);
        },
        .struct_type => |*struct_type| {
            const context: TypeResolutionContext = .{
                .type_scope = type_scope,
                .generic_params = struct_type.generic_params,
            };
            try declaration_parse.validateWherePredicates(module, struct_type.where_predicates, context, item.span, diagnostics);
            try declaration_parse.validateStructFieldsWithContext(struct_type.fields, context, item.span, diagnostics);
        },
        .union_type => |*union_type| try declaration_parse.validateStructFieldsWithContext(union_type.fields, .{
            .type_scope = type_scope,
        }, item.span, diagnostics),
        .enum_type => |*enum_type| {
            const context: TypeResolutionContext = .{
                .type_scope = type_scope,
                .generic_params = enum_type.generic_params,
            };
            try declaration_parse.validateWherePredicates(module, enum_type.where_predicates, context, item.span, diagnostics);
            try declaration_parse.validateEnumVariantsWithContext(enum_type.variants, context, item.span, diagnostics);
        },
        .opaque_type => |*opaque_type| try declaration_parse.validateWherePredicates(module, opaque_type.where_predicates, .{
            .type_scope = type_scope,
            .generic_params = opaque_type.generic_params,
        }, item.span, diagnostics),
        .trait_type => |*trait_type| {
            try declaration_parse.validateWherePredicates(module, trait_type.where_predicates, .{
                .type_scope = type_scope,
                .generic_params = trait_type.generic_params,
                .allow_self = true,
            }, item.span, diagnostics);
            for (trait_type.methods) |*method| {
                try declaration_parse.validateTraitMethodSignature(allocator, module, method, trait_type.generic_params, trait_type.associated_types, type_scope, item.span, diagnostics);
            }
        },
        .impl_block => |*impl_block| try declaration_parse.validateImplBlock(module, impl_block, type_scope, item.span, diagnostics),
        else => {},
    }
}

const TypeResolutionContext = struct {
    type_scope: *const NameSet,
    generic_params: []const GenericParam = &.{},
    associated_types: []const TraitAssociatedType = &.{},
    allow_self: bool = false,
    self_type_name: ?[]const u8 = null,
};

fn parseConstInitializer(
    allocator: Allocator,
    item: *Item,
    const_item: *ConstData,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    global_scope: *const Scope,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
) !void {
    var scope = Scope.init(allocator);
    defer scope.deinit();
    try scope.extendFrom(global_scope);

    const initializer_syntax = const_item.initializer_syntax orelse return error.InvalidParse;
    const expr = try parseExpressionSyntax(allocator, initializer_syntax, types.TypeRef.fromBuiltin(const_item.ty), &scope, &.{}, prototypes, method_prototypes, struct_prototypes, enum_prototypes, diagnostics, item.span, false, false);
    if (const_item.ty != .unsupported and !expr.ty.isUnsupported() and !expr.ty.eql(types.TypeRef.fromBuiltin(const_item.ty))) {
        try diagnostics.add(.@"error", "type.const.mismatch", item.span, "const '{s}' initializer type does not match declared type", .{item.name});
    }
    const_item.expr = expr;
}

fn parseFunctionBody(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    global_scope: *const Scope,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
) !void {
    var scope = Scope.init(allocator);
    defer scope.deinit();
    try scope.extendFrom(global_scope);

    for (function.parameters.items) |parameter| {
        try scope.putWithOrigin(parameter.name, parameter.ty, switch (parameter.mode) {
            .read => false,
            .owned, .take, .edit => true,
        }, boundaryFromParameter(parameter));
    }

    const block = function.block_syntax orelse return error.InvalidParse;
    try appendStructuredBlockStatements(
        allocator,
        item,
        function,
        &function.body,
        &block.structured,
        &scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        0,
        function.is_suspend,
        item.is_unsafe,
    );

    if (!function.return_type.eql(types.TypeRef.fromBuiltin(.unit))) {
        const missing_explicit_return = !blockDefinitelyReturns(&function.body);
        if (missing_explicit_return) {
            try diagnostics.add(.@"error", "type.return.missing", item.span, "non-Unit function '{s}' must end with an explicit return", .{item.name});
        }
    }
}

fn parseStructuredBlockAllocated(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!*Block {
    const body = try allocator.create(Block);
    errdefer allocator.destroy(body);
    body.* = Block.init(allocator);
    errdefer body.deinit(allocator);

    try appendStructuredBlockStatements(
        allocator,
        item,
        function,
        body,
        block_syntax,
        scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        loop_depth,
        suspend_context,
        unsafe_context,
    );
    return body;
}

fn appendStructuredBlockStatements(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    body: *Block,
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!void {
    try predeclareStructuredBlockConstBindings(
        block_syntax,
        scope,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        item.span,
    );

    for (block_syntax.statements) |statement_syntax| {
        try body.statements.append(try parseStructuredStatement(
            allocator,
            item,
            function,
            statement_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ));
    }
}

fn predeclareStructuredBlockConstBindings(
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
) !void {
    for (block_syntax.statements) |statement_syntax| {
        switch (statement_syntax) {
            .const_decl => |binding| {
                const declared_type_syntax = binding.declared_type orelse continue;
                const name = std.mem.trim(u8, binding.name.text, " \t");
                const declared_type = try resolveDeclaredValueType(
                    std.mem.trim(u8, declared_type_syntax.text, " \t"),
                    struct_prototypes,
                    enum_prototypes,
                    span,
                    diagnostics,
                );
                try scope.put(name, declared_type, false);
            },
            else => {},
        }
    }
}

fn parseStructuredStatement(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    statement_syntax: ast.BodyStatementSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    return switch (statement_syntax) {
        .placeholder => |line| parsePlaceholderStatement(item, line, diagnostics),
        .let_decl => |binding| parseBindingStatementSyntax(
            allocator,
            binding,
            false,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .const_decl => |binding| parseBindingStatementSyntax(
            allocator,
            binding,
            true,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .assign_stmt => |assign| parseAssignmentStatementSyntax(
            allocator,
            assign,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .select_stmt => |select_syntax| parseStructuredSelect(
            allocator,
            item,
            function,
            select_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ),
        .repeat_stmt => |repeat_syntax| parseStructuredRepeat(
            allocator,
            item,
            function,
            repeat_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ),
        .unsafe_block => |unsafe_block| .{ .unsafe_block = try parseStructuredBlockAllocated(
            allocator,
            item,
            function,
            unsafe_block,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            true,
        ) },
        .defer_stmt => |expr_syntax| .{ .defer_stmt = try parseExpressionSyntax(
            allocator,
            expr_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ) },
        .break_stmt => blk: {
            if (loop_depth == 0) {
                try diagnostics.add(.@"error", "type.repeat.break", item.span, "break is only valid inside repeat", .{});
                break :blk .placeholder;
            }
            break :blk .break_stmt;
        },
        .continue_stmt => blk: {
            if (loop_depth == 0) {
                try diagnostics.add(.@"error", "type.repeat.continue", item.span, "continue is only valid inside repeat", .{});
                break :blk .placeholder;
            }
            break :blk .continue_stmt;
        },
        .return_stmt => |maybe_expr_syntax| blk: {
            if (maybe_expr_syntax) |expr_syntax| {
                const expr = try parseExpressionSyntax(
                    allocator,
                    expr_syntax,
                    function.return_type,
                    scope,
                    function.where_predicates,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    item.span,
                    suspend_context,
                    unsafe_context,
                );
                if (!function.return_type.isUnsupported() and !expr.ty.isUnsupported() and
                    !returnTypeStructurallyCompatible(expr.ty, function.return_type))
                {
                    try diagnostics.add(.@"error", "type.return.mismatch", item.span, "return type mismatch in function '{s}'", .{item.name});
                }
                break :blk .{ .return_stmt = expr };
            }

            if (!function.return_type.eql(types.TypeRef.fromBuiltin(.unit))) {
                try diagnostics.add(.@"error", "type.return.missing_value", item.span, "non-Unit function '{s}' must return a value", .{item.name});
            }
            break :blk .{ .return_stmt = null };
        },
        .expr_stmt => |expr_syntax| .{ .expr_stmt = try parseExpressionSyntax(
            allocator,
            expr_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ) },
    };
}

fn parsePlaceholderStatement(item: *Item, line: ast.SpanText, diagnostics: *diag.Bag) !Statement {
    const text = std.mem.trim(u8, line.text, " \t");
    if (std.mem.eql(u8, text, "...")) return .placeholder;

    if (std.mem.eql(u8, text, "#unsafe:") or
        std.mem.eql(u8, text, "select:") or
        (std.mem.startsWith(u8, text, "select ") and std.mem.endsWith(u8, text, ":")) or
        std.mem.eql(u8, text, "repeat:") or
        std.mem.eql(u8, text, "repeat") or
        std.mem.startsWith(u8, text, "repeat "))
    {
        try diagnostics.add(.@"error", "type.statement.block", item.span, "statement form '{s}' requires its own indented body", .{text});
        return .placeholder;
    }

    if (text.len != 0) {
        try diagnostics.add(.@"error", "type.stage0.statement", item.span, "stage0 does not yet implement statement form '{s}'", .{text});
    }
    return .placeholder;
}

fn parseStructuredSelect(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    select_syntax: *const ast.BodyStatementSyntax.SelectStmt,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const select_data = try allocator.create(Statement.SelectData);
    errdefer allocator.destroy(select_data);
    select_data.* = .{
        .arms = &.{},
    };
    errdefer select_data.deinit(allocator);

    var arms = array_list.Managed(Statement.SelectArm).init(allocator);
    defer arms.deinit();
    var pattern_diagnostics = array_list.Managed(Statement.PatternDiagnostic).init(allocator);
    errdefer {
        for (pattern_diagnostics.items) |pattern_diagnostic| pattern_diagnostic.deinit(allocator);
        pattern_diagnostics.deinit();
    }

    if (select_syntax.subject) |subject_syntax| {
        const subject = try parseExpressionSyntax(
            allocator,
            subject_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        );
        select_data.subject = subject;
        select_data.subject_temp_name = try std.fmt.allocPrint(allocator, "runa_select_subject_{d}_{d}", .{
            item.span.file_id,
            item.span.start,
        });

        const subject_value = try makeIdentifierExpr(allocator, subject.ty, select_data.subject_temp_name.?);
        defer {
            subject_value.deinit(allocator);
            allocator.destroy(subject_value);
        }

        for (select_syntax.arms) |arm_syntax| {
            const pattern_syntax = switch (arm_syntax.head) {
                .pattern => |pattern| pattern,
                .guard => {
                    try diagnostics.add(.@"error", "type.select.arm", item.span, "unsupported select arm head in subject select", .{});
                    continue;
                },
            };

            var pattern = try pattern_parse.parseSubjectPatternSyntax(
                parseExpressionSyntax,
                allocator,
                pattern_syntax,
                subject_value,
                itemSymbolPrefix(item),
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                suspend_context,
                unsafe_context,
            );
            defer pattern.deinit(allocator);
            for (pattern.diagnostics) |pattern_diagnostic| try pattern_diagnostics.append(pattern_diagnostic);
            allocator.free(pattern.diagnostics);
            pattern.diagnostics = &.{};

            var arm_scope = try cloneScope(allocator, scope);
            defer arm_scope.deinit();
            for (pattern.bindings) |binding| {
                try arm_scope.put(binding.name, binding.ty, true);
            }

            const moved_cleanup_condition = try makeIdentifierExpr(allocator, types.TypeRef.fromBuiltin(.bool), "runa_pattern_moved");
            const moved_cleanup_bindings = try allocator.alloc(Statement.SelectBinding, 0);
            try arms.append(.{
                .condition = pattern.condition,
                .bindings = pattern.bindings,
                .pattern_irrefutable = pattern.irrefutable,
                .body = try parseStructuredBlockAllocated(
                    allocator,
                    item,
                    function,
                    arm_syntax.body,
                    &arm_scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    loop_depth,
                    suspend_context,
                    unsafe_context,
                ),
            });
            pattern.condition = moved_cleanup_condition;
            pattern.bindings = moved_cleanup_bindings;
        }

        if (select_syntax.else_body) |else_body| {
            var arm_scope = try cloneScope(allocator, scope);
            defer arm_scope.deinit();
            select_data.else_body = try parseStructuredBlockAllocated(
                allocator,
                item,
                function,
                else_body,
                &arm_scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                loop_depth,
                suspend_context,
                unsafe_context,
            );
        }
    } else {
        for (select_syntax.arms) |arm_syntax| {
            const guard_syntax = switch (arm_syntax.head) {
                .guard => |guard| guard,
                .pattern => {
                    try diagnostics.add(.@"error", "type.select.arm", item.span, "malformed guarded select arm", .{});
                    continue;
                },
            };
            const condition = try parseExpressionSyntax(
                allocator,
                guard_syntax,
                types.TypeRef.fromBuiltin(.bool),
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            if (!condition.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !condition.ty.isUnsupported()) {
                try diagnostics.add(.@"error", "type.select.guard", item.span, "guarded select conditions must be Bool", .{});
            }

            try arms.append(.{
                .condition = condition,
                .bindings = try allocator.alloc(Statement.SelectBinding, 0),
                .body = try parseStructuredBlockAllocated(
                    allocator,
                    item,
                    function,
                    arm_syntax.body,
                    scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    loop_depth,
                    suspend_context,
                    unsafe_context,
                ),
            });
        }

        if (select_syntax.else_body) |else_body| {
            select_data.else_body = try parseStructuredBlockAllocated(
                allocator,
                item,
                function,
                else_body,
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                loop_depth,
                suspend_context,
                unsafe_context,
            );
        }
    }

    if (arms.items.len == 0) {
        try diagnostics.add(.@"error", "type.select.empty", item.span, "select requires at least one when arm", .{});
    }

    select_data.arms = try arms.toOwnedSlice();
    select_data.pattern_diagnostics = try pattern_diagnostics.toOwnedSlice();
    return .{ .select_stmt = select_data };
}

fn parseStructuredRepeat(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    repeat_syntax: *const ast.BodyStatementSyntax.RepeatStmt,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    var condition: ?*Expr = null;
    var reject_iteration = false;
    var iteration_type: ?types.TypeRef = null;
    var iteration_scope: ?Scope = null;
    defer if (iteration_scope) |*scoped| scoped.deinit();

    switch (repeat_syntax.header) {
        .infinite => {},
        .while_condition => |condition_syntax| {
            condition = try parseExpressionSyntax(
                allocator,
                condition_syntax,
                types.TypeRef.fromBuiltin(.bool),
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            if (!condition.?.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !condition.?.ty.isUnsupported()) {
                try diagnostics.add(.@"error", "type.repeat.cond", item.span, "repeat while condition must be Bool", .{});
            }
        },
        .iteration => |iteration| {
            reject_iteration = true;

            const items_expr = try parseExpressionSyntax(
                allocator,
                iteration.iterable,
                .unsupported,
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            defer {
                items_expr.deinit(allocator);
                allocator.destroy(items_expr);
            }
            iteration_type = items_expr.ty;

            switch (iteration.binding.node) {
                .wildcard => {
                    reject_iteration = false;
                },
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.text, "true") or std.mem.eql(u8, binding.text, "false")) {
                        try diagnostics.add(.@"error", "type.repeat.pattern", item.span, "repeat iteration requires an irrefutable binding pattern", .{});
                    } else {
                        var scoped = try cloneScope(allocator, scope);
                        errdefer scoped.deinit();
                        try scoped.put(binding.text, .unsupported, false);
                        iteration_scope = scoped;
                        reject_iteration = false;
                    }
                },
                .tuple => {
                    try diagnostics.add(.@"error", "type.repeat.pattern.tuple", item.span, "repeat tuple binding patterns require tuple iteration item types", .{});
                },
                else => {
                    try diagnostics.add(.@"error", "type.repeat.pattern", item.span, "repeat iteration requires an irrefutable binding pattern", .{});
                },
            }

        },
        .invalid => |invalid| {
            reject_iteration = true;
            try diagnostics.add(.@"error", "type.repeat.syntax", item.span, "malformed repeat statement '{s}'", .{invalid.text});
        },
    }

    const body_scope = if (iteration_scope) |*scoped| scoped else scope;
    const body = try parseStructuredBlockAllocated(
        allocator,
        item,
        function,
        repeat_syntax.body,
        body_scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        loop_depth + 1,
        suspend_context,
        unsafe_context,
    );
    errdefer {
        body.deinit(allocator);
        allocator.destroy(body);
    }

    if (reject_iteration) {
        body.deinit(allocator);
        allocator.destroy(body);
        return .placeholder;
    }

    const loop_data = try allocator.create(Statement.LoopData);
    errdefer allocator.destroy(loop_data);
    loop_data.* = .{
        .condition = condition,
        .body = body,
        .iteration_type = iteration_type,
    };
    return .{ .loop_stmt = loop_data };
}

fn parseBindingStatementSyntax(
    allocator: Allocator,
    binding: ast.BodyStatementSyntax.BindingDecl,
    is_const: bool,
    scope: *Scope,
    current_where_predicates: []const WherePredicate,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const name = std.mem.trim(u8, binding.name.text, " \t");
    var declared_type: types.TypeRef = .unsupported;
    if (binding.declared_type) |declared_type_syntax| {
        declared_type = try resolveDeclaredValueType(
            std.mem.trim(u8, declared_type_syntax.text, " \t"),
            struct_prototypes,
            enum_prototypes,
            span,
            diagnostics,
        );
    } else if (is_const) {
        try diagnostics.add(.@"error", "type.const.type", span, "local const '{s}' requires an explicit const-safe type", .{name});
    }

    const expr = try parseExpressionSyntax(
        allocator,
        binding.expr,
        declared_type,
        scope,
        current_where_predicates,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        span,
        suspend_context,
        unsafe_context,
    );
    const binding_type = if (!declared_type.isUnsupported()) declared_type else expr.ty;

    if (!declared_type.isUnsupported() and !expr.ty.isUnsupported() and !expr.ty.eql(declared_type)) {
        try diagnostics.add(.@"error", "type.binding.mismatch", span, "local binding '{s}' initializer type does not match declared type", .{name});
    }

    try scope.putWithOrigin(name, binding_type, !is_const, inferExprBoundaryTypeInScope(scope, expr));

    const lowered = Statement.BindingDecl{
        .name = name,
        .ty = binding_type,
        .explicit_type = binding.declared_type != null,
        .span = span,
        .expr = expr,
    };
    return if (is_const)
        .{ .const_decl = lowered }
    else
        .{ .let_decl = lowered };
}

fn parseAssignmentStatementSyntax(
    allocator: Allocator,
    assign: ast.BodyStatementSyntax.AssignStmt,
    scope: *Scope,
    current_where_predicates: []const WherePredicate,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const resolved_target = try resolveAssignmentTargetSyntax(allocator, assign.target, scope, struct_prototypes, diagnostics, span) orelse return .placeholder;
    errdefer if (resolved_target.owns_name) allocator.free(resolved_target.rendered_name);

    const binary_op = if (assign.op) |op| syntaxAssignOpToBinaryOp(op) else null;
    const rhs_expected_type = if (binary_op) |op| compoundAssignmentExpectedRhs(op, resolved_target.ty) else resolved_target.ty;
    const expr = try parseExpressionSyntax(
        allocator,
        assign.expr,
        rhs_expected_type,
        scope,
        current_where_predicates,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        span,
        suspend_context,
        unsafe_context,
    );
    if (binary_op) |op| {
        const target_builtin = switch (resolved_target.ty) {
            .builtin => |value| value,
            else => .unsupported,
        };
        const expr_builtin = switch (expr.ty) {
            .builtin => |value| value,
            else => .unsupported,
        };
        const result_type = compoundAssignmentResult(op, target_builtin, expr_builtin);
        if (result_type == .unsupported and !resolved_target.ty.isUnsupported() and !expr.ty.isUnsupported()) {
            try diagnostics.add(.@"error", "type.assign.compound", span, "compound assignment requires matching numeric operands in stage0", .{});
        } else if (result_type != .unsupported and !resolved_target.ty.eql(types.TypeRef.fromBuiltin(result_type))) {
            try diagnostics.add(.@"error", "type.assign.compound", span, "compound assignment result must match the target type", .{});
        }
    } else if (!resolved_target.ty.isUnsupported() and !expr.ty.isUnsupported() and !resolved_target.ty.eql(expr.ty)) {
        try diagnostics.add(.@"error", "type.assign.mismatch", span, "assignment target '{s}' does not match the right-hand type", .{resolved_target.rendered_name});
    }

    if (assign.op == null and std.mem.indexOfScalar(u8, resolved_target.rendered_name, '.') == null) {
        scope.updateOrigin(resolved_target.rendered_name, inferExprBoundaryTypeInScope(scope, expr));
    }

    return .{ .assign_stmt = .{
        .name = resolved_target.rendered_name,
        .owns_name = resolved_target.owns_name,
        .ty = resolved_target.ty,
        .op = binary_op,
        .expr = expr,
    } };
}

fn resolveAssignmentTargetSyntax(
    allocator: Allocator,
    target: *const ast.BodyExprSyntax,
    scope: *Scope,
    struct_prototypes: []const StructPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
) !?ResolvedAssignmentTarget {
    switch (target.node) {
        .name => |name| {
            const name_text = std.mem.trim(u8, name.text, " \t");
            if (!isPlainIdentifier(name_text)) {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }
            const target_type = scope.get(name_text) orelse {
                try diagnostics.add(.@"error", "type.assign.unknown", span, "assignment target '{s}' is not a known local name", .{name_text});
                return null;
            };
            if (!scope.isMutable(name_text)) {
                try diagnostics.add(.@"error", "type.assign.immutable", span, "assignment target '{s}' is not mutable in stage0", .{name_text});
                return null;
            }
            return .{
                .rendered_name = name_text,
                .ty = target_type,
            };
        },
        .field => |field| {
            const base_name = switch (field.base.node) {
                .name => |name| std.mem.trim(u8, name.text, " \t"),
                else => {
                    try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                    return null;
                },
            };
            const field_name = std.mem.trim(u8, field.field_name.text, " \t");
            if (!isPlainIdentifier(base_name) or !isPlainIdentifier(field_name)) {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }

            const base_type = scope.get(base_name) orelse {
                try diagnostics.add(.@"error", "type.assign.unknown", span, "assignment target '{s}' is not a known local name", .{base_name});
                return null;
            };
            if (!scope.isMutable(base_name)) {
                try diagnostics.add(.@"error", "type.assign.immutable", span, "assignment target '{s}' is not mutable in stage0", .{base_name});
                return null;
            }

            const struct_name = switch (base_type) {
                .named => |name| name,
                else => {
                    try diagnostics.add(.@"error", "type.assign.target", span, "field assignment requires a struct-typed base expression", .{});
                    return null;
                },
            };
            const prototype = findStructPrototype(struct_prototypes, struct_name) orelse {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 field assignment supports only locally declared struct types", .{});
                return null;
            };
            for (prototype.fields) |field_proto| {
                if (std.mem.eql(u8, field_proto.name, field_name)) {
                    return .{
                        .rendered_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, field_name }),
                        .owns_name = true,
                        .ty = field_proto.ty,
                    };
                }
            }

            try diagnostics.add(.@"error", "type.field.unknown", span, "unknown field '{s}' on struct '{s}'", .{
                field_name,
                struct_name,
            });
            return null;
        },
        else => {
            try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
            return null;
        },
    }
}

fn syntaxAssignOpToBinaryOp(op: ast.AssignOpSyntax) BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .shl => .shl,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_xor => .bit_xor,
        .bit_or => .bit_or,
    };
}

fn makeIdentifierExpr(allocator: Allocator, ty: types.TypeRef, name: []const u8) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = ty,
        .node = .{ .identifier = name },
    };
    return expr;
}

fn itemSymbolPrefix(item: *const Item) []const u8 {
    if (std.mem.endsWith(u8, item.symbol_name, item.name)) {
        return item.symbol_name[0 .. item.symbol_name.len - item.name.len];
    }
    return "";
}

fn cloneScope(allocator: Allocator, scope: *const Scope) !Scope {
    var cloned = Scope.init(allocator);
    try cloned.extendFrom(scope);
    return cloned;
}

fn blockDefinitelyReturns(block: *const Block) bool {
    if (block.statements.items.len == 0) return false;
    const last = block.statements.items[block.statements.items.len - 1];
    return statementDefinitelyReturns(last);
}

fn statementDefinitelyReturns(statement: Statement) bool {
    return switch (statement) {
        .return_stmt => true,
        .select_stmt => |select_data| selectDefinitelyReturns(select_data),
        .unsafe_block => |body| blockDefinitelyReturns(body),
        else => false,
    };
}

fn selectDefinitelyReturns(select_data: *const Statement.SelectData) bool {
    var covered = false;
    for (select_data.arms) |arm| {
        if (!blockDefinitelyReturns(arm.body)) return false;
        if (isDefinitelyTrueExpr(arm.condition)) {
            covered = true;
            break;
        }
    }

    if (covered) return true;
    if (select_data.else_body) |else_body| return blockDefinitelyReturns(else_body);
    return false;
}

fn isDefinitelyTrueExpr(expr: *const Expr) bool {
    return switch (expr.node) {
        .bool_lit => |value| value,
        else => false,
    };
}

const ResolvedAssignmentTarget = struct {
    rendered_name: []const u8,
    owns_name: bool = false,
    ty: types.TypeRef,
};

fn compoundAssignmentResult(op: BinaryOp, lhs: types.Builtin, rhs: types.Builtin) types.Builtin {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => if (lhs == rhs and lhs.isNumeric()) lhs else .unsupported,
        .bit_and, .bit_xor, .bit_or => if (lhs == rhs and lhs.isInteger()) lhs else .unsupported,
        .shl, .shr => if (lhs.isInteger() and rhs == .index) lhs else .unsupported,
        else => .unsupported,
    };
}

fn compoundAssignmentExpectedRhs(op: BinaryOp, lhs: types.TypeRef) types.TypeRef {
    return switch (op) {
        .shl, .shr => types.TypeRef.fromBuiltin(.index),
        else => lhs,
    };
}

fn resolveDeclaredValueType(
    type_name: []const u8,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !types.TypeRef {
    const builtin = types.Builtin.fromName(type_name);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    if (findStructPrototype(struct_prototypes, type_name) != null) return .{ .named = type_name };
    if (findEnumPrototype(enum_prototypes, type_name) != null) return .{ .named = type_name };
    try diagnostics.add(.@"error", "type.binding.declared", span, "unsupported stage0 local binding type '{s}'", .{type_name});
    return .unsupported;
}

const NameSet = struct {
    allocator: Allocator,
    names: array_list.Managed([]const u8),

    fn init(allocator: Allocator) NameSet {
        return .{
            .allocator = allocator,
            .names = array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *NameSet) void {
        self.names.deinit();
    }

    fn put(self: *NameSet, name: []const u8) !void {
        if (self.contains(name)) return;
        try self.names.append(name);
    }

    pub fn contains(self: *const NameSet, name: []const u8) bool {
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }
};

const Scope = struct {
    allocator: Allocator,
    names: array_list.Managed([]const u8),
    types_list: array_list.Managed(types.TypeRef),
    mutable_list: array_list.Managed(bool),
    origins: array_list.Managed(BoundaryType),

    fn init(allocator: Allocator) Scope {
        return .{
            .allocator = allocator,
            .names = array_list.Managed([]const u8).init(allocator),
            .types_list = array_list.Managed(types.TypeRef).init(allocator),
            .mutable_list = array_list.Managed(bool).init(allocator),
            .origins = array_list.Managed(BoundaryType).init(allocator),
        };
    }

    fn deinit(self: *Scope) void {
        self.names.deinit();
        self.types_list.deinit();
        self.mutable_list.deinit();
        self.origins.deinit();
    }

    fn extendFrom(self: *Scope, other: *const Scope) !void {
        for (other.names.items, other.types_list.items, other.mutable_list.items, other.origins.items) |name, ty, mutable, origin| {
            try self.putWithOrigin(name, ty, mutable, origin);
        }
    }

    fn put(self: *Scope, name: []const u8, ty: types.TypeRef, mutable: bool) !void {
        try self.putWithOrigin(name, ty, mutable, boundaryFromTypeRef(ty));
    }

    fn putWithOrigin(self: *Scope, name: []const u8, ty: types.TypeRef, mutable: bool, origin: BoundaryType) !void {
        try self.names.append(name);
        try self.types_list.append(ty);
        try self.mutable_list.append(mutable);
        try self.origins.append(origin);
    }

    pub fn get(self: *const Scope, name: []const u8) ?types.TypeRef {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.types_list.items[index];
        }
        return null;
    }

    pub fn isMutable(self: *const Scope, name: []const u8) bool {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.mutable_list.items[index];
        }
        return false;
    }

    pub fn getOrigin(self: *const Scope, name: []const u8) ?BoundaryType {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.origins.items[index];
        }
        return null;
    }

    fn updateOrigin(self: *Scope, name: []const u8, origin: BoundaryType) void {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) {
                self.origins.items[index] = origin;
                return;
            }
        }
    }
};

test "function body parsing uses structured block syntax when available" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var function = FunctionData.init(std.testing.allocator, false, false);
    defer function.deinit(std.testing.allocator);
    function.return_type_name = "I32";
    function.return_type = types.TypeRef.fromBuiltin(.i32);
    try function.parameters.append(.{
        .name = "value",
        .mode = .read,
        .type_name = "I32",
        .ty = types.TypeRef.fromBuiltin(.i32),
    });
    function.block_syntax = .{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
            .{
                .text = .{
                    .text = "return value",
                    .span = .{ .file_id = 0, .start = 0, .end = 12 },
                },
            },
        }),
    };

    var item = Item{
        .name = "main",
        .symbol_name = try std.testing.allocator.dupe(u8, "main"),
        .category = .value,
        .kind = .function,
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 6 },
        .has_body = true,
        .is_synthetic = false,
        .is_reflectable = false,
        .is_boundary_api = false,
        .is_unsafe = false,
        .is_domain_root = false,
        .is_domain_context = false,
    };
    defer item.deinit(std.testing.allocator);

    var global_scope = Scope.init(std.testing.allocator);
    defer global_scope.deinit();

    try parseFunctionBody(
        std.testing.allocator,
        &item,
        &function,
        &.{},
        &.{},
        &global_scope,
        &.{},
        &.{},
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), function.body.statements.items.len);
    switch (function.body.statements.items[0]) {
        .return_stmt => |maybe_expr| {
            const expr = maybe_expr orelse return error.UnexpectedStructure;
            switch (expr.node) {
                .identifier => |name| try std.testing.expectEqualStrings("value", name),
                else => return error.UnexpectedStructure,
            }
        },
        else => return error.UnexpectedStructure,
    }
}

