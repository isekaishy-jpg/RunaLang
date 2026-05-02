const std = @import("std");
const array_list = std.array_list;
const const_ir = @import("../query/const_ir.zig");
const query_types = @import("../query/types.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const requires_ownership_validation = true;

pub const BinaryOp = typed.BinaryOp;
pub const UnaryOp = typed.UnaryOp;
pub const ConversionMode = typed.ConversionMode;
pub const ConstExpr = const_ir.Expr;
pub const ConstValue = const_ir.Value;

pub const ImportedBinding = struct {
    local_name: []const u8,
    target_name: []const u8,
    target_symbol: []const u8,
    category: typed.ItemCategory,
    const_type: ?types.TypeRef = null,
    function_return_type: ?types.TypeRef = null,
    function_generic_params: []typed.GenericParam = &.{},
    function_where_predicates: []typed.WherePredicate = &.{},
    function_is_suspend: bool = false,
    function_parameter_types: ?[]types.TypeRef = null,
    function_parameter_type_names: ?[]const []const u8 = null,
    function_parameter_modes: ?[]typed.ParameterMode = null,
    struct_fields: ?[]typed.StructField = null,
    enum_variants: ?[]typed.EnumVariant = null,
    trait_methods: ?[]typed.TraitMethod = null,

    pub fn deinit(self: ImportedBinding, allocator: Allocator) void {
        if (self.function_generic_params.len != 0) allocator.free(self.function_generic_params);
        typed.deinitWherePredicates(allocator, self.function_where_predicates);
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

pub const ModuleInput = struct {
    file_id: source.FileId,
    module_path: []const u8,
    imports: []const ImportedBinding,
};

pub const Expr = struct {
    ty: types.TypeRef,
    owned_callee: ?[]u8 = null,
    node: Node,

    pub const Node = union(enum) {
        integer: i64,
        bool_lit: bool,
        string: []const u8,
        identifier: []const u8,
        enum_variant: EnumVariantValue,
        enum_tag: EnumVariantValue,
        enum_constructor_target: EnumVariantValue,
        enum_construct: EnumConstruct,
        call: Call,
        constructor: Constructor,
        field: Field,
        tuple: Tuple,
        array: Array,
        array_repeat: ArrayRepeat,
        index: Index,
        conversion: Conversion,
        unary: Unary,
        binary: Binary,
    };

    pub const Call = struct {
        callee: []const u8,
        args: []*Expr,
    };

    pub const EnumVariantValue = struct {
        enum_name: []const u8,
        enum_symbol: []const u8,
        variant_name: []const u8,
    };

    pub const EnumConstruct = struct {
        enum_name: []const u8,
        enum_symbol: []const u8,
        variant_name: []const u8,
        args: []*Expr,
    };

    pub const Constructor = struct {
        type_name: []const u8,
        type_symbol: []const u8,
        args: []*Expr,
    };

    pub const Field = struct {
        base: *Expr,
        field_name: []const u8,
    };

    pub const Tuple = struct {
        items: []*Expr,
    };

    pub const Array = struct {
        items: []*Expr,
    };

    pub const ArrayRepeat = struct {
        value: *Expr,
        length: *Expr,
    };

    pub const Index = struct {
        base: *Expr,
        index: *Expr,
    };

    pub const Conversion = struct {
        operand: *Expr,
        mode: ConversionMode,
        target_type: types.TypeRef,
        target_type_name: []const u8,
    };

    pub const Binary = struct {
        op: BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    fn deinit(self: *Expr, allocator: Allocator) void {
        if (self.owned_callee) |owned_callee| allocator.free(owned_callee);
        switch (self.node) {
            .enum_construct => |construct| {
                for (construct.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(construct.args);
            },
            .call => |call| {
                for (call.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(call.args);
            },
            .constructor => |constructor| {
                for (constructor.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(constructor.args);
            },
            .field => |field| {
                field.base.deinit(allocator);
                allocator.destroy(field.base);
            },
            .tuple => |tuple| {
                for (tuple.items) |item| {
                    item.deinit(allocator);
                    allocator.destroy(item);
                }
                allocator.free(tuple.items);
            },
            .array => |array| {
                for (array.items) |item| {
                    item.deinit(allocator);
                    allocator.destroy(item);
                }
                allocator.free(array.items);
            },
            .array_repeat => |array_repeat| {
                array_repeat.value.deinit(allocator);
                allocator.destroy(array_repeat.value);
                array_repeat.length.deinit(allocator);
                allocator.destroy(array_repeat.length);
            },
            .index => |index| {
                index.base.deinit(allocator);
                allocator.destroy(index.base);
                index.index.deinit(allocator);
                allocator.destroy(index.index);
            },
            .conversion => |conversion| {
                conversion.operand.deinit(allocator);
                allocator.destroy(conversion.operand);
            },
            .unary => |unary| {
                unary.operand.deinit(allocator);
                allocator.destroy(unary.operand);
            },
            .binary => |binary| {
                binary.lhs.deinit(allocator);
                allocator.destroy(binary.lhs);
                binary.rhs.deinit(allocator);
                allocator.destroy(binary.rhs);
            },
            else => {},
        }
    }
};

pub const Statement = union(enum) {
    placeholder,
    let_decl: BindingDecl,
    const_decl: BindingDecl,
    assign_stmt: AssignData,
    select_stmt: *SelectData,
    loop_stmt: *LoopData,
    unsafe_block: *Block,
    defer_stmt: *Expr,
    break_stmt,
    continue_stmt,
    return_stmt: ?*Expr,
    expr_stmt: *Expr,

    pub const BindingDecl = struct {
        name: []const u8,
        ty: types.TypeRef,
        expr: *Expr,
    };

    pub const AssignData = struct {
        name: []const u8,
        ty: types.TypeRef,
        op: ?BinaryOp,
        expr: *Expr,
    };

    pub const SelectBinding = struct {
        name: []const u8,
        ty: types.TypeRef,
        expr: *Expr,

        fn deinit(self: SelectBinding, allocator: Allocator) void {
            self.expr.deinit(allocator);
            allocator.destroy(self.expr);
        }
    };

    pub const SelectArm = struct {
        condition: *Expr,
        bindings: []SelectBinding,
        body: *Block,

        fn deinit(self: SelectArm, allocator: Allocator) void {
            self.condition.deinit(allocator);
            allocator.destroy(self.condition);
            for (self.bindings) |binding| binding.deinit(allocator);
            allocator.free(self.bindings);
            self.body.deinit(allocator);
            allocator.destroy(self.body);
        }
    };

    pub const SelectData = struct {
        subject: ?*Expr = null,
        subject_temp_name: ?[]const u8 = null,
        arms: []SelectArm,
        else_body: ?*Block = null,

        fn deinit(self: *SelectData, allocator: Allocator) void {
            if (self.subject) |subject| {
                subject.deinit(allocator);
                allocator.destroy(subject);
            }
            if (self.subject_temp_name) |name| allocator.free(name);
            for (self.arms) |arm| arm.deinit(allocator);
            allocator.free(self.arms);
            if (self.else_body) |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            }
        }
    };

    pub const LoopData = struct {
        condition: ?*Expr = null,
        body: *Block,

        fn deinit(self: *LoopData, allocator: Allocator) void {
            if (self.condition) |condition| {
                condition.deinit(allocator);
                allocator.destroy(condition);
            }
            self.body.deinit(allocator);
            allocator.destroy(self.body);
        }
    };

    fn deinit(self: Statement, allocator: Allocator) void {
        switch (self) {
            .let_decl, .const_decl => |binding| {
                binding.expr.deinit(allocator);
                allocator.destroy(binding.expr);
            },
            .assign_stmt => |assign| {
                assign.expr.deinit(allocator);
                allocator.destroy(assign.expr);
            },
            .select_stmt => |select_data| {
                select_data.deinit(allocator);
                allocator.destroy(select_data);
            },
            .loop_stmt => |loop_data| {
                loop_data.deinit(allocator);
                allocator.destroy(loop_data);
            },
            .unsafe_block => |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            },
            .defer_stmt => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .return_stmt => |maybe_expr| if (maybe_expr) |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .expr_stmt => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .placeholder, .break_stmt, .continue_stmt => {},
        }
    }
};

pub const Block = struct {
    statements: array_list.Managed(Statement),

    pub fn init(allocator: Allocator) Block {
        return .{
            .statements = array_list.Managed(Statement).init(allocator),
        };
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        for (self.statements.items) |statement| statement.deinit(allocator);
        self.statements.deinit();
    }
};

pub const Parameter = struct {
    name: []const u8,
    mode: typed.ParameterMode,
    ty: types.TypeRef,
};

pub const FunctionData = struct {
    return_type: types.TypeRef,
    parameters: []Parameter,
    body: Block,
    export_name: ?[]const u8,
    is_suspend: bool,
    foreign: bool,

    fn deinit(self: *FunctionData, allocator: Allocator) void {
        allocator.free(self.parameters);
        self.body.deinit(allocator);
    }
};

pub const ConstData = struct {
    ty: types.Builtin,
    type_ref: types.TypeRef,
    expr: *const ConstExpr,

    fn deinit(self: *ConstData, allocator: Allocator) void {
        const_ir.destroyExpr(allocator, self.expr);
    }
};

pub const StructField = struct {
    name: []const u8,
    type_name: []const u8,
    ty: types.TypeRef,
};

pub const TupleField = struct {
    type_name: []const u8,
    ty: types.TypeRef,
};

pub const StructData = struct {
    fields: []StructField,

    fn deinit(self: *StructData, allocator: Allocator) void {
        allocator.free(self.fields);
    }
};

pub const EnumVariantPayload = union(enum) {
    none,
    tuple_fields: []TupleField,
    named_fields: []StructField,

    fn deinit(self: *EnumVariantPayload, allocator: Allocator) void {
        switch (self.*) {
            .none => {},
            .tuple_fields => |tuple_fields| allocator.free(tuple_fields),
            .named_fields => |named_fields| allocator.free(named_fields),
        }
    }
};

pub const EnumVariant = struct {
    name: []const u8,
    payload: EnumVariantPayload,

    fn deinit(self: *EnumVariant, allocator: Allocator) void {
        self.payload.deinit(allocator);
    }
};

pub const EnumData = struct {
    variants: []EnumVariant,

    fn deinit(self: *EnumData, allocator: Allocator) void {
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
    }
};

pub const OpaqueData = struct {
    fn deinit(self: *OpaqueData, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const Payload = union(enum) {
    none,
    function: FunctionData,
    const_item: ConstData,
    struct_type: StructData,
    enum_type: EnumData,
    opaque_type: OpaqueData,

    fn deinit(self: *Payload, allocator: Allocator) void {
        switch (self.*) {
            .function => |*function| function.deinit(allocator),
            .const_item => |*const_item| const_item.deinit(allocator),
            .struct_type => |*struct_type| struct_type.deinit(allocator),
            .enum_type => |*enum_type| enum_type.deinit(allocator),
            .opaque_type => |*opaque_type| opaque_type.deinit(allocator),
            .none => {},
        }
    }
};

pub const Item = struct {
    name: []const u8,
    owned_name: ?[]u8 = null,
    symbol_name: []const u8,
    owned_symbol_name: ?[]u8 = null,
    kind: typed.ItemCategory,
    is_entry_candidate: bool,
    span: source.Span,
    payload: Payload = .none,

    pub fn deinit(self: *Item, allocator: Allocator) void {
        if (self.owned_name) |owned_name| allocator.free(owned_name);
        if (self.owned_symbol_name) |owned_symbol_name| allocator.free(owned_symbol_name);
        self.payload.deinit(allocator);
    }
};

pub const Module = struct {
    file_id: source.FileId,
    module_path: []const u8,
    items: array_list.Managed(Item),
    imports: array_list.Managed(ImportedBinding),
    retained_checked_functions: []*typed.CheckedFunctionData = &.{},

    pub fn init(allocator: Allocator, file_id: source.FileId, module_path: []const u8) Module {
        return .{
            .file_id = file_id,
            .module_path = module_path,
            .items = array_list.Managed(Item).init(allocator),
            .imports = array_list.Managed(ImportedBinding).init(allocator),
        };
    }

    pub fn appendRetainedCheckedFunction(self: *Module, function: *typed.CheckedFunctionData) !void {
        const allocator = self.items.allocator;
        const next_len = self.retained_checked_functions.len + 1;
        self.retained_checked_functions = if (self.retained_checked_functions.len == 0)
            try allocator.alloc(*typed.CheckedFunctionData, next_len)
        else
            try allocator.realloc(self.retained_checked_functions, next_len);
        self.retained_checked_functions[next_len - 1] = function;
    }

    pub fn deinit(self: *Module) void {
        for (self.items.items) |*item| item.deinit(self.items.allocator);
        self.items.deinit();
        for (self.imports.items) |binding| binding.deinit(self.items.allocator);
        self.imports.deinit();
        for (self.retained_checked_functions) |function| {
            var owned = function;
            owned.deinit(self.items.allocator);
            self.items.allocator.destroy(owned);
        }
        if (self.retained_checked_functions.len != 0) self.items.allocator.free(self.retained_checked_functions);
        self.items.allocator.free(self.module_path);
    }
};

fn lowerModuleWithFacts(
    allocator: Allocator,
    module: ModuleInput,
    checked_signatures: []const query_types.CheckedSignature,
    checked_bodies: []const query_types.CheckedBody,
) !Module {
    var mir_module = Module.init(allocator, module.file_id, try allocator.dupe(u8, module.module_path));
    errdefer mir_module.deinit();
    for (checked_bodies) |checked_body| {
        const function = checked_body.owned_function orelse continue;
        try mir_module.appendRetainedCheckedFunction(function);
    }

    for (module.imports) |binding| {
        try mir_module.imports.append(.{
            .local_name = binding.local_name,
            .target_name = binding.target_name,
            .target_symbol = binding.target_symbol,
            .category = binding.category,
            .const_type = binding.const_type,
            .function_return_type = binding.function_return_type,
            .function_generic_params = if (binding.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, binding.function_generic_params) else &.{},
            .function_where_predicates = if (binding.function_where_predicates.len != 0) try typed.cloneWherePredicates(allocator, binding.function_where_predicates) else &.{},
            .function_is_suspend = binding.function_is_suspend,
            .function_parameter_types = if (binding.function_parameter_types) |values| try allocator.dupe(types.TypeRef, values) else null,
            .function_parameter_type_names = if (binding.function_parameter_type_names) |values| try allocator.dupe([]const u8, values) else null,
            .function_parameter_modes = if (binding.function_parameter_modes) |values| try allocator.dupe(typed.ParameterMode, values) else null,
            .struct_fields = if (binding.struct_fields) |fields| try allocator.dupe(typed.StructField, fields) else null,
            .enum_variants = if (binding.enum_variants) |variants| try duplicateImportedEnumVariants(allocator, variants) else null,
            .trait_methods = if (binding.trait_methods) |methods| try duplicateImportedTraitMethods(allocator, methods) else null,
        });
    }

    for (checked_signatures) |checked_signature| {
        const item = checked_signature.item;
        var mir_item = Item{
            .name = item.name,
            .symbol_name = item.symbol_name,
            .kind = item.category,
            .is_entry_candidate = item.kind == .function and std.mem.eql(u8, item.name, "main"),
            .span = item.span,
            .payload = .none,
        };
        errdefer mir_item.deinit(allocator);

        switch (checked_signature.facts) {
            .function => |function| {
                const checked_body = findCheckedBodyByItemId(checked_bodies, checked_signature.item_id) orelse return error.MissingCheckedBody;
                const parameters = checked_body.parameters;

                const params = try allocator.alloc(Parameter, parameters.len);
                errdefer allocator.free(params);
                for (parameters, 0..) |parameter, index| {
                    params[index] = .{
                        .name = parameter.name,
                        .mode = parameter.mode,
                        .ty = parameter.ty,
                    };
                }

                var body = try lowerCheckedBlock(allocator, checked_body, checked_body.root_block_id);
                errdefer body.deinit(allocator);

                mir_item.payload = .{ .function = .{
                    .return_type = function.return_type,
                    .parameters = params,
                    .body = body,
                    .export_name = function.export_name,
                    .is_suspend = function.is_suspend,
                    .foreign = function.foreign,
                } };
            },
            .const_item => |const_signature| {
                const expr = const_signature.expr orelse return error.InvalidMirLowering;
                mir_item.payload = .{ .const_item = .{
                    .ty = const_signature.ty,
                    .type_ref = const_signature.type_ref,
                    .expr = try cloneConstExpr(allocator, expr),
                } };
            },
            .struct_type => |struct_type| {
                const fields = try allocator.alloc(StructField, struct_type.fields.len);
                errdefer allocator.free(fields);
                for (struct_type.fields, 0..) |field, field_index| {
                    fields[field_index] = .{
                        .name = field.name,
                        .type_name = field.type_name,
                        .ty = field.ty,
                    };
                }
                mir_item.payload = .{ .struct_type = .{ .fields = fields } };
            },
            .enum_type => |enum_type| {
                const variants = try allocator.alloc(EnumVariant, enum_type.variants.len);
                errdefer allocator.free(variants);
                for (enum_type.variants, 0..) |variant, variant_index| {
                    variants[variant_index] = .{
                        .name = variant.name,
                        .payload = switch (variant.payload) {
                            .none => .none,
                            .tuple_fields => |tuple_fields| blk: {
                                const fields = try allocator.alloc(TupleField, tuple_fields.len);
                                for (tuple_fields, 0..) |field, field_index| {
                                    fields[field_index] = .{
                                        .type_name = field.type_name,
                                        .ty = field.ty,
                                    };
                                }
                                break :blk .{ .tuple_fields = fields };
                            },
                            .named_fields => |named_fields| blk: {
                                const fields = try allocator.alloc(StructField, named_fields.len);
                                for (named_fields, 0..) |field, field_index| {
                                    fields[field_index] = .{
                                        .name = field.name,
                                        .type_name = field.type_name,
                                        .ty = field.ty,
                                    };
                                }
                                break :blk .{ .named_fields = fields };
                            },
                        },
                    };
                }
                mir_item.payload = .{ .enum_type = .{ .variants = variants } };
            },
            .opaque_type => {
                mir_item.payload = .{ .opaque_type = .{} };
            },
            .type_alias => continue,
            .union_type, .trait_type, .impl_block, .none => {},
        }

        try mir_module.items.append(mir_item);
    }

    return mir_module;
}

pub fn lowerModuleFromCheckedFacts(
    allocator: Allocator,
    module: ModuleInput,
    checked_signatures: anytype,
    checked_bodies: anytype,
) !Module {
    for (checked_signatures) |checked_signature| {
        switch (checked_signature.facts) {
            .function => {
                if (findCheckedBodyByItemId(checked_bodies, checked_signature.item_id) == null) return error.MissingCheckedBody;
            },
            .const_item => |const_signature| {
                if (const_signature.expr == null) return error.InvalidMirLowering;
            },
            else => {},
        }
    }

    return lowerModuleWithFacts(allocator, module, checked_signatures, checked_bodies);
}

fn findCheckedBodyByItemId(checked_bodies: []const query_types.CheckedBody, item_id: @import("../session/ids.zig").ItemId) ?query_types.CheckedBody {
    for (checked_bodies) |body| {
        if (body.item_id.index == item_id.index) return body;
    }
    return null;
}

pub fn mergeModules(allocator: Allocator, modules: []const *const Module) !Module {
    var merged = Module.init(allocator, if (modules.len != 0) modules[0].file_id else 0, if (modules.len != 0) try allocator.dupe(u8, modules[0].module_path) else try allocator.dupe(u8, ""));
    errdefer merged.deinit();

    for (modules) |module| {
        for (module.imports.items) |binding| {
            try merged.imports.append(.{
                .local_name = binding.local_name,
                .target_name = binding.target_name,
                .target_symbol = binding.target_symbol,
                .category = binding.category,
                .const_type = binding.const_type,
                .function_return_type = binding.function_return_type,
                .function_generic_params = if (binding.function_generic_params.len != 0) try allocator.dupe(typed.GenericParam, binding.function_generic_params) else &.{},
                .function_where_predicates = if (binding.function_where_predicates.len != 0) try typed.cloneWherePredicates(allocator, binding.function_where_predicates) else &.{},
                .function_is_suspend = binding.function_is_suspend,
                .function_parameter_types = if (binding.function_parameter_types) |values| try allocator.dupe(types.TypeRef, values) else null,
                .function_parameter_type_names = if (binding.function_parameter_type_names) |values| try allocator.dupe([]const u8, values) else null,
                .function_parameter_modes = if (binding.function_parameter_modes) |values| try allocator.dupe(typed.ParameterMode, values) else null,
                .struct_fields = if (binding.struct_fields) |fields| try allocator.dupe(typed.StructField, fields) else null,
                .enum_variants = if (binding.enum_variants) |variants| try duplicateImportedEnumVariants(allocator, variants) else null,
                .trait_methods = if (binding.trait_methods) |methods| try duplicateImportedTraitMethods(allocator, methods) else null,
            });
        }

        for (module.items.items) |item| {
            var merged_item = Item{
                .name = item.name,
                .symbol_name = item.symbol_name,
                .kind = item.kind,
                .is_entry_candidate = item.is_entry_candidate,
                .span = item.span,
                .payload = .none,
            };
            errdefer merged_item.deinit(allocator);

            switch (item.payload) {
                .function => |function| {
                    const params = try allocator.alloc(Parameter, function.parameters.len);
                    errdefer allocator.free(params);
                    @memcpy(params, function.parameters);

                    const body = try cloneBlock(allocator, &function.body);

                    merged_item.payload = .{ .function = .{
                        .return_type = function.return_type,
                        .parameters = params,
                        .body = body,
                        .export_name = function.export_name,
                        .is_suspend = function.is_suspend,
                        .foreign = function.foreign,
                    } };
                },
                .const_item => |const_item| {
                    merged_item.payload = .{ .const_item = .{
                        .ty = const_item.ty,
                        .type_ref = const_item.type_ref,
                        .expr = try cloneConstExpr(allocator, const_item.expr),
                    } };
                },
                .struct_type => |struct_type| {
                    const fields = try allocator.alloc(StructField, struct_type.fields.len);
                    errdefer allocator.free(fields);
                    @memcpy(fields, struct_type.fields);
                    merged_item.payload = .{ .struct_type = .{ .fields = fields } };
                },
                .enum_type => |enum_type| {
                    const variants = try allocator.alloc(EnumVariant, enum_type.variants.len);
                    errdefer allocator.free(variants);
                    for (enum_type.variants, 0..) |variant, variant_index| {
                        variants[variant_index] = .{
                            .name = variant.name,
                            .payload = switch (variant.payload) {
                                .none => .none,
                                .tuple_fields => |tuple_fields| blk: {
                                    const fields = try allocator.alloc(TupleField, tuple_fields.len);
                                    @memcpy(fields, tuple_fields);
                                    break :blk .{ .tuple_fields = fields };
                                },
                                .named_fields => |named_fields| blk: {
                                    const fields = try allocator.alloc(StructField, named_fields.len);
                                    @memcpy(fields, named_fields);
                                    break :blk .{ .named_fields = fields };
                                },
                            },
                        };
                    }
                    merged_item.payload = .{ .enum_type = .{ .variants = variants } };
                },
                .opaque_type => {
                    merged_item.payload = .{ .opaque_type = .{} };
                },
                .none => {},
            }

            try merged.items.append(merged_item);
        }
    }

    return merged;
}

fn cloneBlock(allocator: Allocator, block: *const Block) anyerror!Block {
    var cloned = Block.init(allocator);
    errdefer cloned.deinit(allocator);
    for (block.statements.items) |statement| {
        try cloned.statements.append(try cloneStatement(allocator, statement));
    }
    return cloned;
}

fn cloneStatement(allocator: Allocator, statement: Statement) anyerror!Statement {
    return switch (statement) {
        .placeholder => .placeholder,
        .let_decl => |binding| .{ .let_decl = .{
            .name = binding.name,
            .ty = binding.ty,
            .expr = try cloneExpr(allocator, binding.expr),
        } },
        .const_decl => |binding| .{ .const_decl = .{
            .name = binding.name,
            .ty = binding.ty,
            .expr = try cloneExpr(allocator, binding.expr),
        } },
        .assign_stmt => |assign| .{ .assign_stmt = .{
            .name = assign.name,
            .ty = assign.ty,
            .op = assign.op,
            .expr = try cloneExpr(allocator, assign.expr),
        } },
        .select_stmt => |select_data| blk: {
            var arms = try allocator.alloc(Statement.SelectArm, select_data.arms.len);
            errdefer allocator.free(arms);
            for (select_data.arms, 0..) |arm, index| {
                const body = try allocator.create(Block);
                errdefer allocator.destroy(body);
                body.* = try cloneBlock(allocator, arm.body);
                const bindings = try allocator.alloc(Statement.SelectBinding, arm.bindings.len);
                errdefer allocator.free(bindings);
                for (arm.bindings, 0..) |binding, binding_index| {
                    bindings[binding_index] = .{
                        .name = binding.name,
                        .ty = binding.ty,
                        .expr = try cloneExpr(allocator, binding.expr),
                    };
                }
                arms[index] = .{
                    .condition = try cloneExpr(allocator, arm.condition),
                    .bindings = bindings,
                    .body = body,
                };
            }

            const cloned = try allocator.create(Statement.SelectData);
            errdefer allocator.destroy(cloned);
            cloned.* = .{
                .subject = if (select_data.subject) |subject| try cloneExpr(allocator, subject) else null,
                .subject_temp_name = if (select_data.subject_temp_name) |name| try allocator.dupe(u8, name) else null,
                .arms = arms,
                .else_body = if (select_data.else_body) |body| blk_body: {
                    const cloned_body = try allocator.create(Block);
                    errdefer allocator.destroy(cloned_body);
                    cloned_body.* = try cloneBlock(allocator, body);
                    break :blk_body cloned_body;
                } else null,
            };
            break :blk .{ .select_stmt = cloned };
        },
        .loop_stmt => |loop_data| blk: {
            const cloned = try allocator.create(Statement.LoopData);
            errdefer allocator.destroy(cloned);
            const body = try allocator.create(Block);
            errdefer allocator.destroy(body);
            body.* = try cloneBlock(allocator, loop_data.body);
            cloned.* = .{
                .condition = if (loop_data.condition) |condition| try cloneExpr(allocator, condition) else null,
                .body = body,
            };
            break :blk .{ .loop_stmt = cloned };
        },
        .unsafe_block => |body| blk: {
            const cloned = try allocator.create(Block);
            errdefer allocator.destroy(cloned);
            cloned.* = try cloneBlock(allocator, body);
            break :blk .{ .unsafe_block = cloned };
        },
        .defer_stmt => |expr| .{ .defer_stmt = try cloneExpr(allocator, expr) },
        .break_stmt => .break_stmt,
        .continue_stmt => .continue_stmt,
        .return_stmt => |maybe_expr| .{ .return_stmt = if (maybe_expr) |expr| try cloneExpr(allocator, expr) else null },
        .expr_stmt => |expr| .{ .expr_stmt = try cloneExpr(allocator, expr) },
    };
}

fn lowerCheckedBlock(allocator: Allocator, body: query_types.CheckedBody, block_id: usize) anyerror!Block {
    var lowered = Block.init(allocator);
    errdefer lowered.deinit(allocator);
    if (block_id >= body.block_sites.len) return error.InvalidMirLowering;

    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (statement_index >= body.statement_sites.len) return error.InvalidMirLowering;
        try lowered.statements.append(try lowerCheckedStatement(allocator, body, body.statement_sites[statement_index]));
    }
    return lowered;
}

fn lowerCheckedStatement(
    allocator: Allocator,
    body: query_types.CheckedBody,
    statement: @import("../query/checked_body.zig").StatementSite,
) anyerror!Statement {
    return switch (statement.kind) {
        .placeholder => .placeholder,
        .let_decl => .{ .let_decl = .{
            .name = statement.binding_name orelse return error.InvalidMirLowering,
            .ty = statement.binding_ty,
            .expr = try cloneTypedExpr(allocator, statement.binding_expr orelse return error.InvalidMirLowering),
        } },
        .const_decl => .{ .const_decl = .{
            .name = statement.binding_name orelse return error.InvalidMirLowering,
            .ty = statement.binding_ty,
            .expr = try cloneTypedExpr(allocator, statement.binding_expr orelse return error.InvalidMirLowering),
        } },
        .assign_stmt => .{ .assign_stmt = .{
            .name = statement.assign_name orelse return error.InvalidMirLowering,
            .ty = statement.assign_ty,
            .op = statement.assign_op,
            .expr = try cloneTypedExpr(allocator, statement.assign_expr orelse return error.InvalidMirLowering),
        } },
        .select_stmt => blk: {
            var arms = try allocator.alloc(Statement.SelectArm, statement.select_arms.len);
            errdefer allocator.free(arms);
            for (statement.select_arms, 0..) |arm, index| {
                const arm_body = try allocator.create(Block);
                errdefer allocator.destroy(arm_body);
                arm_body.* = try lowerCheckedBlock(allocator, body, arm.body_block_id);
                errdefer arm_body.deinit(allocator);

                const bindings = try allocator.alloc(Statement.SelectBinding, arm.bindings.len);
                errdefer allocator.free(bindings);
                for (arm.bindings, 0..) |binding, binding_index| {
                    bindings[binding_index] = .{
                        .name = binding.name,
                        .ty = binding.ty,
                        .expr = try cloneTypedExpr(allocator, binding.expr),
                    };
                }
                arms[index] = .{
                    .condition = try cloneTypedExpr(allocator, arm.condition),
                    .bindings = bindings,
                    .body = arm_body,
                };
            }

            var else_body: ?*Block = null;
            if (statement.select_else_block_id) |else_block_id| {
                const lowered_else = try allocator.create(Block);
                errdefer allocator.destroy(lowered_else);
                lowered_else.* = try lowerCheckedBlock(allocator, body, else_block_id);
                else_body = lowered_else;
            }

            const result = try allocator.create(Statement.SelectData);
            errdefer allocator.destroy(result);
            result.* = .{
                .subject = if (statement.select_subject) |subject| try cloneTypedExpr(allocator, subject) else null,
                .subject_temp_name = if (statement.select_subject_temp_name) |name| try allocator.dupe(u8, name) else null,
                .arms = arms,
                .else_body = else_body,
            };
            break :blk .{ .select_stmt = result };
        },
        .loop_stmt => blk: {
            const lowered_body = try allocator.create(Block);
            errdefer allocator.destroy(lowered_body);
            lowered_body.* = try lowerCheckedBlock(allocator, body, statement.loop_body_block_id orelse return error.InvalidMirLowering);

            const result = try allocator.create(Statement.LoopData);
            errdefer allocator.destroy(result);
            result.* = .{
                .condition = if (statement.loop_condition) |condition| try cloneTypedExpr(allocator, condition) else null,
                .body = lowered_body,
            };
            break :blk .{ .loop_stmt = result };
        },
        .unsafe_block => blk: {
            const lowered_body = try allocator.create(Block);
            errdefer allocator.destroy(lowered_body);
            lowered_body.* = try lowerCheckedBlock(allocator, body, statement.unsafe_block_id orelse return error.InvalidMirLowering);
            break :blk .{ .unsafe_block = lowered_body };
        },
        .defer_stmt => .{ .defer_stmt = try cloneTypedExpr(allocator, statement.expr orelse return error.InvalidMirLowering) },
        .break_stmt => .break_stmt,
        .continue_stmt => .continue_stmt,
        .return_stmt => .{ .return_stmt = if (statement.expr) |expr| try cloneTypedExpr(allocator, expr) else null },
        .expr_stmt => .{ .expr_stmt = try cloneTypedExpr(allocator, statement.expr orelse return error.InvalidMirLowering) },
    };
}

pub fn cloneTypedExpr(allocator: Allocator, expr: *const typed.Expr) !*Expr {
    const result = try allocator.create(Expr);
    errdefer allocator.destroy(result);

    result.ty = expr.ty;
    var owned_callee: ?[]u8 = null;
    result.node = switch (expr.node) {
        .integer => |value| .{ .integer = value },
        .bool_lit => |value| .{ .bool_lit = value },
        .string => |value| .{ .string = value },
        .identifier => |value| .{ .identifier = value },
        .enum_variant => |value| .{ .enum_variant = .{
            .enum_name = value.enum_name,
            .enum_symbol = value.enum_symbol,
            .variant_name = value.variant_name,
        } },
        .enum_tag => |value| .{ .enum_tag = .{
            .enum_name = value.enum_name,
            .enum_symbol = value.enum_symbol,
            .variant_name = value.variant_name,
        } },
        .enum_constructor_target => |value| .{ .enum_constructor_target = .{
            .enum_name = value.enum_name,
            .enum_symbol = value.enum_symbol,
            .variant_name = value.variant_name,
        } },
        .enum_construct => |construct| blk: {
            const args = try allocator.alloc(*Expr, construct.args.len);
            errdefer allocator.free(args);
            for (construct.args, 0..) |arg, index| {
                args[index] = try cloneTypedExpr(allocator, arg);
            }
            break :blk .{ .enum_construct = .{
                .enum_name = construct.enum_name,
                .enum_symbol = construct.enum_symbol,
                .variant_name = construct.variant_name,
                .args = args,
            } };
        },
        .call => |call| blk: {
            const args = try allocator.alloc(*Expr, call.args.len);
            errdefer allocator.free(args);
            for (call.args, 0..) |arg, index| {
                args[index] = try cloneTypedExpr(allocator, arg);
            }
            owned_callee = try allocator.dupe(u8, call.callee);
            errdefer {
                if (owned_callee) |value| allocator.free(value);
            }
            break :blk .{ .call = .{
                .callee = owned_callee.?,
                .args = args,
            } };
        },
        .constructor => |constructor| blk: {
            const args = try allocator.alloc(*Expr, constructor.args.len);
            errdefer allocator.free(args);
            for (constructor.args, 0..) |arg, index| {
                args[index] = try cloneTypedExpr(allocator, arg);
            }
            break :blk .{ .constructor = .{
                .type_name = constructor.type_name,
                .type_symbol = constructor.type_symbol,
                .args = args,
            } };
        },
        .method_target => return error.InvalidMirLowering,
        .field => |field| .{ .field = .{
            .base = try cloneTypedExpr(allocator, field.base),
            .field_name = field.field_name,
        } },
        .tuple => |tuple| blk: {
            const items = try allocator.alloc(*Expr, tuple.items.len);
            errdefer allocator.free(items);
            for (tuple.items, 0..) |item, index| {
                items[index] = try cloneTypedExpr(allocator, item);
            }
            break :blk .{ .tuple = .{ .items = items } };
        },
        .array => |array| blk: {
            const items = try allocator.alloc(*Expr, array.items.len);
            errdefer allocator.free(items);
            for (array.items, 0..) |item, index| {
                items[index] = try cloneTypedExpr(allocator, item);
            }
            break :blk .{ .array = .{ .items = items } };
        },
        .array_repeat => |array_repeat| .{ .array_repeat = .{
            .value = try cloneTypedExpr(allocator, array_repeat.value),
            .length = try cloneTypedExpr(allocator, array_repeat.length),
        } },
        .index => |index| .{ .index = .{
            .base = try cloneTypedExpr(allocator, index.base),
            .index = try cloneTypedExpr(allocator, index.index),
        } },
        .conversion => |conversion| .{ .conversion = .{
            .operand = try cloneTypedExpr(allocator, conversion.operand),
            .mode = conversion.mode,
            .target_type = conversion.target_type,
            .target_type_name = conversion.target_type_name,
        } },
        .unary => |unary| .{ .unary = .{
            .op = unary.op,
            .operand = try cloneTypedExpr(allocator, unary.operand),
        } },
        .binary => |binary| .{ .binary = .{
            .op = binary.op,
            .lhs = try cloneTypedExpr(allocator, binary.lhs),
            .rhs = try cloneTypedExpr(allocator, binary.rhs),
        } },
    };
    result.owned_callee = owned_callee;

    return result;
}

fn cloneExpr(allocator: Allocator, expr: *const Expr) !*Expr {
    const result = try allocator.create(Expr);
    errdefer allocator.destroy(result);

    result.ty = expr.ty;
    var owned_callee: ?[]u8 = null;
    result.node = switch (expr.node) {
        .integer => |value| .{ .integer = value },
        .bool_lit => |value| .{ .bool_lit = value },
        .string => |value| .{ .string = value },
        .identifier => |value| .{ .identifier = value },
        .enum_variant => |value| .{ .enum_variant = value },
        .enum_tag => |value| .{ .enum_tag = value },
        .enum_constructor_target => |value| .{ .enum_constructor_target = value },
        .enum_construct => |construct| blk: {
            const args = try allocator.alloc(*Expr, construct.args.len);
            errdefer allocator.free(args);
            for (construct.args, 0..) |arg, index| {
                args[index] = try cloneExpr(allocator, arg);
            }
            break :blk .{ .enum_construct = .{
                .enum_name = construct.enum_name,
                .enum_symbol = construct.enum_symbol,
                .variant_name = construct.variant_name,
                .args = args,
            } };
        },
        .call => |call| blk: {
            const args = try allocator.alloc(*Expr, call.args.len);
            errdefer allocator.free(args);
            for (call.args, 0..) |arg, index| {
                args[index] = try cloneExpr(allocator, arg);
            }
            owned_callee = try allocator.dupe(u8, call.callee);
            errdefer {
                if (owned_callee) |value| allocator.free(value);
            }
            break :blk .{ .call = .{
                .callee = owned_callee.?,
                .args = args,
            } };
        },
        .constructor => |constructor| blk: {
            const args = try allocator.alloc(*Expr, constructor.args.len);
            errdefer allocator.free(args);
            for (constructor.args, 0..) |arg, index| {
                args[index] = try cloneExpr(allocator, arg);
            }
            break :blk .{ .constructor = .{
                .type_name = constructor.type_name,
                .type_symbol = constructor.type_symbol,
                .args = args,
            } };
        },
        .field => |field| .{ .field = .{
            .base = try cloneExpr(allocator, field.base),
            .field_name = field.field_name,
        } },
        .tuple => |tuple| blk: {
            const items = try allocator.alloc(*Expr, tuple.items.len);
            errdefer allocator.free(items);
            for (tuple.items, 0..) |item, index| {
                items[index] = try cloneExpr(allocator, item);
            }
            break :blk .{ .tuple = .{ .items = items } };
        },
        .array => |array| blk: {
            const items = try allocator.alloc(*Expr, array.items.len);
            errdefer allocator.free(items);
            for (array.items, 0..) |item, index| {
                items[index] = try cloneExpr(allocator, item);
            }
            break :blk .{ .array = .{ .items = items } };
        },
        .array_repeat => |array_repeat| .{ .array_repeat = .{
            .value = try cloneExpr(allocator, array_repeat.value),
            .length = try cloneExpr(allocator, array_repeat.length),
        } },
        .index => |index| .{ .index = .{
            .base = try cloneExpr(allocator, index.base),
            .index = try cloneExpr(allocator, index.index),
        } },
        .conversion => |conversion| .{ .conversion = .{
            .operand = try cloneExpr(allocator, conversion.operand),
            .mode = conversion.mode,
            .target_type = conversion.target_type,
            .target_type_name = conversion.target_type_name,
        } },
        .unary => |unary| .{ .unary = .{
            .op = unary.op,
            .operand = try cloneExpr(allocator, unary.operand),
        } },
        .binary => |binary| .{ .binary = .{
            .op = binary.op,
            .lhs = try cloneExpr(allocator, binary.lhs),
            .rhs = try cloneExpr(allocator, binary.rhs),
        } },
    };
    result.owned_callee = owned_callee;

    return result;
}

fn cloneConstExpr(allocator: Allocator, expr: *const ConstExpr) anyerror!*ConstExpr {
    const result = try allocator.create(ConstExpr);
    var initialized = false;
    errdefer {
        if (initialized) {
            const_ir.destroyExpr(allocator, result);
        } else {
            allocator.destroy(result);
        }
    }

    result.result_type = expr.result_type;
    result.node = switch (expr.node) {
        .literal => |value| .{ .literal = try const_ir.cloneValue(allocator, value) },
        .const_ref => |name| .{ .const_ref = name },
        .associated_const_ref => |ref| .{ .associated_const_ref = .{
            .owner_name = ref.owner_name,
            .const_name = ref.const_name,
        } },
        .enum_variant => |variant| .{ .enum_variant = .{
            .enum_name = variant.enum_name,
            .variant_name = variant.variant_name,
        } },
        .enum_tag => |variant| .{ .enum_tag = .{
            .enum_name = variant.enum_name,
            .variant_name = variant.variant_name,
        } },
        .enum_construct => |construct| .{ .enum_construct = .{
            .enum_name = construct.enum_name,
            .variant_name = construct.variant_name,
            .args = try cloneConstExprSlice(allocator, construct.args),
        } },
        .constructor => |constructor| .{ .constructor = .{
            .type_name = constructor.type_name,
            .args = try cloneConstExprSlice(allocator, constructor.args),
        } },
        .field => |field| .{ .field = .{
            .base = try cloneConstExpr(allocator, field.base),
            .field_name = field.field_name,
        } },
        .array => |array| .{ .array = .{
            .items = try cloneConstExprSlice(allocator, array.items),
        } },
        .array_repeat => |array_repeat| .{ .array_repeat = .{
            .value = try cloneConstExpr(allocator, array_repeat.value),
            .length = try cloneConstExpr(allocator, array_repeat.length),
        } },
        .index => |index| .{ .index = .{
            .base = try cloneConstExpr(allocator, index.base),
            .index = try cloneConstExpr(allocator, index.index),
        } },
        .conversion => |conversion| .{ .conversion = .{
            .operand = try cloneConstExpr(allocator, conversion.operand),
            .mode = conversion.mode,
            .target_type = conversion.target_type,
        } },
        .unary => |unary| .{ .unary = .{
            .op = unary.op,
            .operand = try cloneConstExpr(allocator, unary.operand),
        } },
        .binary => |binary| blk: {
            const lhs = try cloneConstExpr(allocator, binary.lhs);
            errdefer const_ir.destroyExpr(allocator, lhs);
            const rhs = try cloneConstExpr(allocator, binary.rhs);
            break :blk .{ .binary = .{
                .op = binary.op,
                .lhs = lhs,
                .rhs = rhs,
            } };
        },
    };
    initialized = true;
    return result;
}

fn cloneConstExprSlice(allocator: Allocator, exprs: []*ConstExpr) anyerror![]*ConstExpr {
    const cloned = try allocator.alloc(*ConstExpr, exprs.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |expr| const_ir.destroyExpr(allocator, expr);
        allocator.free(cloned);
    }
    for (exprs, 0..) |expr, index| {
        cloned[index] = try cloneConstExpr(allocator, expr);
        initialized += 1;
    }
    return cloned;
}

fn duplicateImportedEnumVariants(allocator: Allocator, variants: []typed.EnumVariant) ![]typed.EnumVariant {
    const cloned = try allocator.alloc(typed.EnumVariant, variants.len);
    for (variants, 0..) |variant, index| {
        cloned[index] = .{
            .name = variant.name,
            .discriminant = variant.discriminant,
            .payload = switch (variant.payload) {
                .none => .none,
                .tuple_fields => |tuple_fields| blk: {
                    const fields = try allocator.alloc(typed.TupleField, tuple_fields.len);
                    @memcpy(fields, tuple_fields);
                    break :blk .{ .tuple_fields = fields };
                },
                .named_fields => |named_fields| .{ .named_fields = try allocator.dupe(typed.StructField, named_fields) },
            },
        };
    }
    return cloned;
}

fn duplicateImportedTraitMethods(allocator: Allocator, methods: []typed.TraitMethod) ![]typed.TraitMethod {
    const cloned = try allocator.alloc(typed.TraitMethod, methods.len);
    for (methods, 0..) |method, index| {
        cloned[index] = .{
            .name = method.name,
            .is_suspend = method.is_suspend,
            .has_default_body = method.has_default_body,
            .generic_params = if (method.generic_params.len != 0) try allocator.dupe(typed.GenericParam, method.generic_params) else &.{},
            .where_predicates = if (method.where_predicates.len != 0) try typed.cloneWherePredicates(allocator, method.where_predicates) else &.{},
            .syntax = if (method.syntax) |syntax| try syntax.clone(allocator) else null,
        };
    }
    return cloned;
}
