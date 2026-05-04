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
    type_syntax: ?ast.TypeSyntax = null,
    ty: types.TypeRef,

    pub fn deinit(self: *Parameter, allocator: Allocator) void {
        if (self.type_syntax) |*type_syntax| type_syntax.deinit(allocator);
        self.* = .{
            .name = "",
            .mode = .owned,
            .ty = .unsupported,
        };
    }
};

pub const FunctionData = struct {
    is_suspend: bool,
    foreign: bool,
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    parameters: std.array_list.Managed(Parameter),
    return_type_syntax: ?ast.TypeSyntax = null,
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
            .return_type = types.TypeRef.fromBuiltin(.unit),
            .body = Block.init(allocator),
            .export_name = null,
            .link_name = null,
            .abi = null,
        };
    }

    pub fn deinit(self: *FunctionData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        for (self.parameters.items) |*parameter| parameter.deinit(allocator);
        self.parameters.deinit();
        if (self.return_type_syntax) |*return_type_syntax| return_type_syntax.deinit(allocator);
        if (self.block_syntax) |*block_syntax| block_syntax.deinit(allocator);
        self.body.deinit(allocator);
    }
};

pub const ConstData = struct {
    type_syntax: ast.TypeSyntax,
    ty: types.Builtin,
    type_ref: types.TypeRef,
    initializer_syntax: ?*ast.BodyExprSyntax = null,
    expr: ?*Expr = null,

    pub fn deinit(self: *ConstData, allocator: Allocator) void {
        self.type_syntax.deinit(allocator);
        if (self.initializer_syntax) |syntax_expr| {
            syntax_expr.deinit(allocator);
            allocator.destroy(syntax_expr);
        }
        if (self.expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        self.* = .{
            .type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .ty = .unsupported,
            .type_ref = .unsupported,
            .initializer_syntax = null,
            .expr = null,
        };
    }
};

pub const StructField = struct {
    name: []const u8,
    visibility: ast.Visibility,
    type_syntax: ast.TypeSyntax,
    ty: types.TypeRef = .unsupported,

    pub fn clone(self: StructField, allocator: Allocator) !StructField {
        return .{
            .name = self.name,
            .visibility = self.visibility,
            .type_syntax = try self.type_syntax.clone(allocator),
            .ty = self.ty,
        };
    }

    pub fn deinit(self: *StructField, allocator: Allocator) void {
        self.type_syntax.deinit(allocator);
        self.* = .{
            .name = "",
            .visibility = .private,
            .type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .ty = .unsupported,
        };
    }
};

pub const TupleField = struct {
    type_syntax: ast.TypeSyntax,
    ty: types.TypeRef = .unsupported,

    pub fn clone(self: TupleField, allocator: Allocator) !TupleField {
        return .{
            .type_syntax = try self.type_syntax.clone(allocator),
            .ty = self.ty,
        };
    }

    pub fn deinit(self: *TupleField, allocator: Allocator) void {
        self.type_syntax.deinit(allocator);
        self.* = .{
            .type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .ty = .unsupported,
        };
    }
};

pub const StructData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    fields: []StructField,

    pub fn deinit(self: *StructData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        deinitStructFields(allocator, self.fields);
    }
};

pub const UnionData = struct {
    fields: []StructField,

    pub fn deinit(self: *UnionData, allocator: Allocator) void {
        deinitStructFields(allocator, self.fields);
    }
};

pub const EnumVariantPayload = union(enum) {
    none,
    tuple_fields: []TupleField,
    named_fields: []StructField,

    pub fn deinit(self: *EnumVariantPayload, allocator: Allocator) void {
        switch (self.*) {
            .none => {},
            .tuple_fields => |tuple_fields| deinitTupleFields(allocator, tuple_fields),
            .named_fields => |named_fields| deinitStructFields(allocator, named_fields),
        }
    }
};

pub const EnumVariant = struct {
    name: []const u8,
    payload: EnumVariantPayload,
    discriminant_source: ?ast.SpanText = null,
    discriminant_syntax: ?*ast.BodyExprSyntax = null,

    pub fn clone(self: EnumVariant, allocator: Allocator) !EnumVariant {
        var cloned = EnumVariant{
            .name = self.name,
            .payload = switch (self.payload) {
                .none => .none,
                .tuple_fields => |tuple_fields| .{ .tuple_fields = try cloneTupleFields(allocator, tuple_fields) },
                .named_fields => |named_fields| .{ .named_fields = try cloneStructFields(allocator, named_fields) },
            },
            .discriminant_source = self.discriminant_source,
            .discriminant_syntax = null,
        };
        errdefer cloned.deinit(allocator);
        if (self.discriminant_syntax) |expr| cloned.discriminant_syntax = try expr.clone(allocator);
        return cloned;
    }

    pub fn deinit(self: *EnumVariant, allocator: Allocator) void {
        self.payload.deinit(allocator);
        if (self.discriminant_syntax) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        self.* = .{
            .name = "",
            .payload = .none,
            .discriminant_source = null,
            .discriminant_syntax = null,
        };
    }
};

pub const EnumData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    variants: []EnumVariant,

    pub fn deinit(self: *EnumData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
    }
};

pub const OpaqueTypeData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,

    pub fn deinit(self: *OpaqueTypeData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
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
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        if (self.syntax) |*syntax| syntax.deinit(allocator);
    }
};

pub const TraitAssociatedType = struct {
    name: []const u8,
};

pub const TraitAssociatedConst = struct {
    name: []const u8,
    type_syntax: ast.TypeSyntax,
    ty: types.Builtin,
    type_ref: types.TypeRef,

    pub fn deinit(self: *TraitAssociatedConst, allocator: Allocator) void {
        self.type_syntax.deinit(allocator);
        self.* = .{
            .name = "",
            .type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .ty = .unsupported,
            .type_ref = .unsupported,
        };
    }
};

pub const TraitAssociatedTypeBinding = struct {
    name: []const u8,
    value_type_syntax: ast.TypeSyntax,
    value_type: types.TypeRef = .unsupported,

    pub fn deinit(self: *TraitAssociatedTypeBinding, allocator: Allocator) void {
        self.value_type_syntax.deinit(allocator);
        self.* = .{
            .name = "",
            .value_type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .value_type = .unsupported,
        };
    }
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
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        for (self.methods) |*method| method.deinit(allocator);
        allocator.free(self.methods);
        allocator.free(self.associated_types);
        for (self.associated_consts) |*associated_const| associated_const.deinit(allocator);
        allocator.free(self.associated_consts);
    }
};

pub const ImplData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    target_type_syntax: ast.TypeSyntax,
    target_type: types.TypeRef,
    trait_syntax: ?ast.TypeSyntax = null,
    trait_type: ?types.TypeRef = null,
    associated_types: []TraitAssociatedTypeBinding,
    associated_consts: []TraitAssociatedConstBinding,
    methods: []TraitMethod,

    pub fn deinit(self: *ImplData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        self.target_type_syntax.deinit(allocator);
        if (self.trait_syntax) |*trait_syntax| trait_syntax.deinit(allocator);
        for (self.associated_types) |*binding| binding.deinit(allocator);
        allocator.free(self.associated_types);
        for (self.associated_consts) |*binding| binding.deinit(allocator);
        allocator.free(self.associated_consts);
        for (self.methods) |*method| method.deinit(allocator);
        allocator.free(self.methods);
    }
};

pub fn cloneStructFields(allocator: Allocator, fields: []const StructField) ![]StructField {
    if (fields.len == 0) return &.{};
    const cloned = try allocator.alloc(StructField, fields.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(cloned);
    }
    for (fields, 0..) |field, index| {
        cloned[index] = try field.clone(allocator);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitStructFields(allocator: Allocator, fields: []StructField) void {
    for (fields) |*field| field.deinit(allocator);
    if (fields.len != 0) allocator.free(fields);
}

pub fn cloneTupleFields(allocator: Allocator, fields: []const TupleField) ![]TupleField {
    if (fields.len == 0) return &.{};
    const cloned = try allocator.alloc(TupleField, fields.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(cloned);
    }
    for (fields, 0..) |field, index| {
        cloned[index] = try field.clone(allocator);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitTupleFields(allocator: Allocator, fields: []TupleField) void {
    for (fields) |*field| field.deinit(allocator);
    if (fields.len != 0) allocator.free(fields);
}
