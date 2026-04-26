const std = @import("std");
const body_syntax = @import("body_syntax.zig");
const block_syntax = @import("block_syntax.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const Visibility = enum {
    private,
    pub_item,
    pub_package,
};

pub const SpanText = struct {
    text: []const u8,
    span: source.Span,
};

pub const BlockSyntax = block_syntax.Block;
pub const ExprSyntax = body_syntax.Expr;

pub const Parameter = struct {
    mode: ?SpanText = null,
    name: ?SpanText = null,
    ty: ?SpanText = null,
};

pub const FunctionSignature = struct {
    name: ?SpanText = null,
    generic_params: ?SpanText = null,
    parameters: []Parameter = &.{},
    return_type: ?SpanText = null,
    where_clauses: []SpanText = &.{},
    foreign_abi: ?SpanText = null,

    pub fn clone(self: FunctionSignature, allocator: Allocator) !FunctionSignature {
        return .{
            .name = self.name,
            .generic_params = self.generic_params,
            .parameters = try cloneSlice(allocator, Parameter, self.parameters),
            .return_type = self.return_type,
            .where_clauses = try cloneSlice(allocator, SpanText, self.where_clauses),
            .foreign_abi = self.foreign_abi,
        };
    }

    pub fn deinit(self: *FunctionSignature, allocator: Allocator) void {
        freeSlice(allocator, self.parameters);
        freeSlice(allocator, self.where_clauses);
        self.* = .{};
    }
};

pub const ConstSignature = struct {
    name: ?SpanText = null,
    ty: ?SpanText = null,
    initializer: ?SpanText = null,
    initializer_expr: ?*ExprSyntax = null,

    pub fn clone(self: ConstSignature, allocator: Allocator) !ConstSignature {
        return .{
            .name = self.name,
            .ty = self.ty,
            .initializer = self.initializer,
            .initializer_expr = if (self.initializer_expr) |expr| try expr.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *ConstSignature, allocator: Allocator) void {
        if (self.initializer_expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        self.* = .{};
    }
};

pub const NamedDecl = struct {
    name: ?SpanText = null,
    generic_params: ?SpanText = null,
    where_clauses: []SpanText = &.{},

    pub fn clone(self: NamedDecl, allocator: Allocator) !NamedDecl {
        return .{
            .name = self.name,
            .generic_params = self.generic_params,
            .where_clauses = try cloneSlice(allocator, SpanText, self.where_clauses),
        };
    }

    pub fn deinit(self: *NamedDecl, allocator: Allocator) void {
        freeSlice(allocator, self.where_clauses);
        self.* = .{};
    }
};

pub const UseBinding = struct {
    prefix: ?SpanText = null,
    leaf: ?SpanText = null,
    alias: ?SpanText = null,

    pub fn clone(self: UseBinding, allocator: Allocator) !UseBinding {
        _ = allocator;
        return self;
    }

    pub fn deinit(self: *UseBinding, allocator: Allocator) void {
        _ = allocator;
        self.* = .{};
    }
};

pub const ImplSignature = struct {
    generic_params: ?SpanText = null,
    trait_name: ?SpanText = null,
    target_type: ?SpanText = null,
    where_clauses: []SpanText = &.{},

    pub fn clone(self: ImplSignature, allocator: Allocator) !ImplSignature {
        return .{
            .generic_params = self.generic_params,
            .trait_name = self.trait_name,
            .target_type = self.target_type,
            .where_clauses = try cloneSlice(allocator, SpanText, self.where_clauses),
        };
    }

    pub fn deinit(self: *ImplSignature, allocator: Allocator) void {
        freeSlice(allocator, self.where_clauses);
        self.* = .{};
    }
};

pub const FieldDecl = struct {
    visibility: Visibility = .private,
    name: ?SpanText = null,
    ty: ?SpanText = null,

    pub fn clone(self: FieldDecl, allocator: Allocator) !FieldDecl {
        _ = allocator;
        return self;
    }

    pub fn deinit(self: *FieldDecl, allocator: Allocator) void {
        _ = allocator;
        self.* = .{};
    }
};

pub const EnumVariant = struct {
    name: ?SpanText = null,
    tuple_payload: ?SpanText = null,
    discriminant: ?SpanText = null,
    named_fields: []FieldDecl = &.{},

    pub fn clone(self: EnumVariant, allocator: Allocator) !EnumVariant {
        return .{
            .name = self.name,
            .tuple_payload = self.tuple_payload,
            .discriminant = self.discriminant,
            .named_fields = try cloneSlice(allocator, FieldDecl, self.named_fields),
        };
    }

    pub fn deinit(self: *EnumVariant, allocator: Allocator) void {
        freeSlice(allocator, self.named_fields);
        self.* = .{};
    }
};

pub const AssociatedTypeDecl = struct {
    name: ?SpanText = null,
    value: ?SpanText = null,

    pub fn clone(self: AssociatedTypeDecl, allocator: Allocator) !AssociatedTypeDecl {
        _ = allocator;
        return self;
    }

    pub fn deinit(self: *AssociatedTypeDecl, allocator: Allocator) void {
        _ = allocator;
        self.* = .{};
    }
};

pub const MethodDecl = struct {
    span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 },
    is_suspend: bool = false,
    signature: FunctionSignature = .{},
    block_syntax: ?BlockSyntax = null,

    pub fn clone(self: MethodDecl, allocator: Allocator) !MethodDecl {
        return .{
            .span = self.span,
            .is_suspend = self.is_suspend,
            .signature = try self.signature.clone(allocator),
            .block_syntax = if (self.block_syntax) |block| try block.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *MethodDecl, allocator: Allocator) void {
        self.signature.deinit(allocator);
        if (self.block_syntax) |*block| block.deinit(allocator);
        self.* = .{};
    }
};

pub const TraitBody = struct {
    methods: []MethodDecl = &.{},
    associated_types: []AssociatedTypeDecl = &.{},
    associated_consts: []ConstSignature = &.{},

    pub fn clone(self: TraitBody, allocator: Allocator) !TraitBody {
        return .{
            .methods = try cloneComplexSlice(allocator, MethodDecl, self.methods),
            .associated_types = try cloneSlice(allocator, AssociatedTypeDecl, self.associated_types),
            .associated_consts = try cloneComplexSlice(allocator, ConstSignature, self.associated_consts),
        };
    }

    pub fn deinit(self: *TraitBody, allocator: Allocator) void {
        freeComplexSlice(allocator, MethodDecl, self.methods);
        freeSlice(allocator, self.associated_types);
        freeComplexSlice(allocator, ConstSignature, self.associated_consts);
        self.* = .{};
    }
};

pub const ImplBody = struct {
    methods: []MethodDecl = &.{},
    associated_types: []AssociatedTypeDecl = &.{},
    associated_consts: []ConstSignature = &.{},

    pub fn clone(self: ImplBody, allocator: Allocator) !ImplBody {
        return .{
            .methods = try cloneComplexSlice(allocator, MethodDecl, self.methods),
            .associated_types = try cloneSlice(allocator, AssociatedTypeDecl, self.associated_types),
            .associated_consts = try cloneComplexSlice(allocator, ConstSignature, self.associated_consts),
        };
    }

    pub fn deinit(self: *ImplBody, allocator: Allocator) void {
        freeComplexSlice(allocator, MethodDecl, self.methods);
        freeSlice(allocator, self.associated_types);
        freeComplexSlice(allocator, ConstSignature, self.associated_consts);
        self.* = .{};
    }
};

pub const ItemBodySyntax = union(enum) {
    none,
    struct_fields: []FieldDecl,
    union_fields: []FieldDecl,
    enum_variants: []EnumVariant,
    trait_body: TraitBody,
    impl_body: ImplBody,

    pub fn clone(self: ItemBodySyntax, allocator: Allocator) !ItemBodySyntax {
        return switch (self) {
            .none => .none,
            .struct_fields => |fields| .{ .struct_fields = try cloneSlice(allocator, FieldDecl, fields) },
            .union_fields => |fields| .{ .union_fields = try cloneSlice(allocator, FieldDecl, fields) },
            .enum_variants => |variants| .{ .enum_variants = try cloneComplexSlice(allocator, EnumVariant, variants) },
            .trait_body => |body| .{ .trait_body = try body.clone(allocator) },
            .impl_body => |body| .{ .impl_body = try body.clone(allocator) },
        };
    }

    pub fn deinit(self: *ItemBodySyntax, allocator: Allocator) void {
        switch (self.*) {
            .none => {},
            .struct_fields => |fields| freeSlice(allocator, fields),
            .union_fields => |fields| freeSlice(allocator, fields),
            .enum_variants => |variants| freeComplexSlice(allocator, EnumVariant, variants),
            .trait_body => |*body| body.deinit(allocator),
            .impl_body => |*body| body.deinit(allocator),
        }
        self.* = .none;
    }
};

pub const ItemSyntax = union(enum) {
    none,
    function: FunctionSignature,
    const_item: ConstSignature,
    named_decl: NamedDecl,
    use_decl: UseBinding,
    impl_block: ImplSignature,

    pub fn clone(self: ItemSyntax, allocator: Allocator) !ItemSyntax {
        return switch (self) {
            .none => .none,
            .function => |signature| .{ .function = try signature.clone(allocator) },
            .const_item => |signature| .{ .const_item = try signature.clone(allocator) },
            .named_decl => |signature| .{ .named_decl = try signature.clone(allocator) },
            .use_decl => |signature| .{ .use_decl = try signature.clone(allocator) },
            .impl_block => |signature| .{ .impl_block = try signature.clone(allocator) },
        };
    }

    pub fn deinit(self: *ItemSyntax, allocator: Allocator) void {
        switch (self.*) {
            .none => {},
            .function => |*signature| signature.deinit(allocator),
            .const_item => |*signature| signature.deinit(allocator),
            .named_decl => |*signature| signature.deinit(allocator),
            .use_decl => |*signature| signature.deinit(allocator),
            .impl_block => |*signature| signature.deinit(allocator),
        }
        self.* = .none;
    }
};

fn cloneSlice(allocator: Allocator, comptime T: type, items: []const T) ![]T {
    if (items.len == 0) return &.{};
    return try allocator.dupe(T, items);
}

fn cloneComplexSlice(allocator: Allocator, comptime T: type, items: []const T) ![]T {
    if (items.len == 0) return &.{};

    const cloned = try allocator.alloc(T, items.len);
    errdefer allocator.free(cloned);

    for (items, 0..) |item, index| {
        cloned[index] = try item.clone(allocator);
    }
    return cloned;
}

fn freeSlice(allocator: Allocator, items: anytype) void {
    if (items.len != 0) allocator.free(items);
}

fn freeComplexSlice(allocator: Allocator, comptime T: type, items: []T) void {
    for (items) |*item| item.deinit(allocator);
    freeSlice(allocator, items);
}
