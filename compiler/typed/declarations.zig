const std = @import("std");
const ast = @import("../ast/root.zig");
const typed_expr = @import("expr.zig");
const typed_signatures = @import("../signature_types.zig");
const typed_statement = @import("statement.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const Expr = typed_expr.Expr;
pub const GenericParam = typed_signatures.GenericParam;
pub const WherePredicate = typed_signatures.WherePredicate;
pub const Block = typed_statement.Block;

pub const ParameterMode = enum {
    owned,
    take,
    read,
    edit,
};

pub const Parameter = struct {
    name: []const u8,
    mode: ParameterMode,
    type_name: []const u8,
    ty: types.TypeRef,
};

pub const FunctionData = struct {
    is_suspend: bool,
    foreign: bool,
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    parameters: std.array_list.Managed(Parameter),
    return_type_name: []const u8,
    return_type: types.TypeRef,
    block_syntax: ?ast.BlockSyntax = null,
    body: Block,
    export_name: ?[]const u8,
    link_name: ?[]const u8,
    abi: ?[]const u8,

    pub fn init(allocator: Allocator, is_suspend: bool, foreign: bool) FunctionData {
        return .{
            .is_suspend = is_suspend,
            .foreign = foreign,
            .generic_params = &.{},
            .where_predicates = &.{},
            .parameters = std.array_list.Managed(Parameter).init(allocator),
            .return_type_name = "Unit",
            .return_type = types.TypeRef.fromBuiltin(.unit),
            .body = Block.init(allocator),
            .export_name = null,
            .link_name = null,
            .abi = null,
        };
    }

    pub fn deinit(self: *FunctionData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        self.parameters.deinit();
        if (self.block_syntax) |*block_syntax| block_syntax.deinit(allocator);
        self.body.deinit(allocator);
    }
};

pub const ConstData = struct {
    type_name: []const u8,
    ty: types.Builtin,
    type_ref: types.TypeRef,
    initializer_source: []const u8,
    initializer_syntax: ?*ast.BodyExprSyntax = null,
    expr: ?*Expr = null,

    pub fn deinit(self: *ConstData, allocator: Allocator) void {
        if (self.initializer_syntax) |syntax_expr| {
            syntax_expr.deinit(allocator);
            allocator.destroy(syntax_expr);
        }
        if (self.expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
    }
};

pub const StructField = struct {
    name: []const u8,
    visibility: ast.Visibility,
    type_name: []const u8,
    ty: types.TypeRef = .unsupported,
};

pub const TupleField = struct {
    type_name: []const u8,
    ty: types.TypeRef = .unsupported,
};

pub const StructData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    fields: []StructField,

    pub fn deinit(self: *StructData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        allocator.free(self.fields);
    }
};

pub const UnionData = struct {
    fields: []StructField,

    pub fn deinit(self: *UnionData, allocator: Allocator) void {
        allocator.free(self.fields);
    }
};

pub const EnumVariantPayload = union(enum) {
    none,
    tuple_fields: []TupleField,
    named_fields: []StructField,

    pub fn deinit(self: *EnumVariantPayload, allocator: Allocator) void {
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
    discriminant: ?[]const u8 = null,

    pub fn deinit(self: *EnumVariant, allocator: Allocator) void {
        self.payload.deinit(allocator);
    }
};

pub const EnumData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    variants: []EnumVariant,

    pub fn deinit(self: *EnumData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
    }
};

pub const OpaqueTypeData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,

    pub fn deinit(self: *OpaqueTypeData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
    }
};

pub const TraitMethod = struct {
    name: []const u8,
    is_suspend: bool,
    has_default_body: bool,
    generic_params: []GenericParam = &.{},
    where_predicates: []WherePredicate = &.{},
    syntax: ?ast.MethodDeclSyntax = null,

    pub fn deinit(self: *TraitMethod, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        if (self.syntax) |*syntax| syntax.deinit(allocator);
    }
};

pub const TraitAssociatedType = struct {
    name: []const u8,
};

pub const TraitAssociatedConst = struct {
    name: []const u8,
    type_name: []const u8,
    ty: types.Builtin,
    type_ref: types.TypeRef,
};

pub const TraitAssociatedTypeBinding = struct {
    name: []const u8,
    value_type_name: []const u8,
    value_type: types.TypeRef = .unsupported,
};

pub const TraitAssociatedConstBinding = struct {
    name: []const u8,
    const_data: ConstData,

    pub fn deinit(self: *TraitAssociatedConstBinding, allocator: Allocator) void {
        self.const_data.deinit(allocator);
    }
};

pub const TraitData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    methods: []TraitMethod,
    associated_types: []TraitAssociatedType,
    associated_consts: []TraitAssociatedConst,

    pub fn deinit(self: *TraitData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        for (self.methods) |*method| method.deinit(allocator);
        allocator.free(self.methods);
        allocator.free(self.associated_types);
        allocator.free(self.associated_consts);
    }
};

pub const ImplData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    target_type: []const u8,
    trait_name: ?[]const u8,
    associated_types: []TraitAssociatedTypeBinding,
    associated_consts: []TraitAssociatedConstBinding,
    methods: []TraitMethod,

    pub fn deinit(self: *ImplData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        allocator.free(self.associated_types);
        for (self.associated_consts) |*binding| binding.deinit(allocator);
        allocator.free(self.associated_consts);
        for (self.methods) |*method| method.deinit(allocator);
        allocator.free(self.methods);
    }
};
