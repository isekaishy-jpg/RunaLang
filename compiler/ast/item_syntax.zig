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

pub const BorrowAccess = enum {
    read,
    edit,
};

pub const RawPointerAccess = enum {
    read,
    edit,
};

pub const TypeNode = struct {
    source: SpanText,
    child_start: u32 = 0,
    child_len: u32 = 0,
    payload: Payload,

    pub const Borrow = struct {
        access: BorrowAccess,
        lifetime: ?SpanText = null,
    };

    pub const RawPointer = struct {
        access: RawPointerAccess,
    };

    pub const Assoc = struct {
        member: SpanText,
    };

    pub const FixedArray = struct {
        length: SpanText,
    };

    pub const ForeignCallable = struct {
        abi: SpanText,
        parameter_count: u32,
        has_variadic_tail: bool = false,
    };

    pub const Payload = union(enum) {
        invalid,
        name_ref,
        lifetime,
        apply,
        borrow: Borrow,
        raw_pointer: RawPointer,
        assoc: Assoc,
        tuple,
        fixed_array: FixedArray,
        foreign_callable: ForeignCallable,
    };
};

pub const TypeSyntax = struct {
    source: SpanText,
    nodes: []TypeNode = &.{},
    child_indices: []u32 = &.{},

    pub fn text(self: TypeSyntax) []const u8 {
        return self.source.text;
    }

    pub fn span(self: TypeSyntax) source.Span {
        return self.source.span;
    }

    pub fn clone(self: TypeSyntax, allocator: Allocator) !TypeSyntax {
        return .{
            .source = self.source,
            .nodes = try cloneSlice(allocator, TypeNode, self.nodes),
            .child_indices = try cloneSlice(allocator, u32, self.child_indices),
        };
    }

    pub fn deinit(self: *TypeSyntax, allocator: Allocator) void {
        freeSlice(allocator, self.nodes);
        freeSlice(allocator, self.child_indices);
        self.* = .{
            .source = .{
                .text = "",
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            },
        };
    }

    pub fn isStructured(self: TypeSyntax) bool {
        return self.nodes.len != 0;
    }

    pub fn rootNode(self: TypeSyntax) TypeNode {
        if (self.nodes.len != 0) return self.nodes[0];
        return .{
            .source = self.source,
            .payload = legacyPayload(self.source),
        };
    }

    pub fn childNodeIndices(self: TypeSyntax, node_index: usize) []const u32 {
        const node = if (self.nodes.len == 0) self.rootNode() else self.nodes[node_index];
        return self.child_indices[node.child_start .. node.child_start + node.child_len];
    }

    fn legacyPayload(source_text: SpanText) TypeNode.Payload {
        if (source_text.text.len == 0) return .invalid;
        return if (source_text.text[0] == '\'') .lifetime else .name_ref;
    }
};

pub const ParameterMode = union(enum) {
    owned,
    take: source.Span,
    read: source.Span,
    edit: source.Span,
    invalid: SpanText,

    pub fn span(self: ParameterMode) ?source.Span {
        return switch (self) {
            .owned => null,
            .take => |mode_span| mode_span,
            .read => |mode_span| mode_span,
            .edit => |mode_span| mode_span,
            .invalid => |value| value.span,
        };
    }
};

pub const GenericParamKind = enum {
    type_param,
    lifetime_param,
};

pub const GenericParam = struct {
    name: []const u8,
    span: source.Span,
    kind: GenericParamKind,
};

pub const GenericParamListInvalidKind = enum {
    empty_list,
    malformed_entry,
};

pub const GenericParamList = struct {
    span: source.Span,
    params: []GenericParam = &.{},
    invalid_kind: ?GenericParamListInvalidKind = null,

    pub fn clone(self: GenericParamList, allocator: Allocator) !GenericParamList {
        return .{
            .span = self.span,
            .params = try cloneSlice(allocator, GenericParam, self.params),
            .invalid_kind = self.invalid_kind,
        };
    }

    pub fn deinit(self: *GenericParamList, allocator: Allocator) void {
        freeSlice(allocator, self.params);
        self.* = .{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .params = &.{},
            .invalid_kind = null,
        };
    }
};

pub const BoundWherePredicate = struct {
    subject_name: []const u8,
    contract_type: TypeSyntax,
    span: source.Span,
};

pub const ProjectionEqualityWherePredicate = struct {
    subject_name: []const u8,
    associated_name: []const u8,
    value_type: TypeSyntax,
    span: source.Span,
};

pub const LifetimeOutlivesWherePredicate = struct {
    longer_name: []const u8,
    shorter_name: []const u8,
    span: source.Span,
};

pub const TypeOutlivesWherePredicate = struct {
    type_name: []const u8,
    lifetime_name: []const u8,
    span: source.Span,
};

pub const WherePredicate = union(enum) {
    bound: BoundWherePredicate,
    projection_equality: ProjectionEqualityWherePredicate,
    lifetime_outlives: LifetimeOutlivesWherePredicate,
    type_outlives: TypeOutlivesWherePredicate,
    invalid: SpanText,
};

pub const WhereClauseInvalidKind = enum {
    empty_clause,
};

pub const WhereClause = struct {
    span: source.Span,
    predicates: []WherePredicate = &.{},
    invalid_kind: ?WhereClauseInvalidKind = null,

    pub fn clone(self: WhereClause, allocator: Allocator) !WhereClause {
        const predicates = try allocator.alloc(WherePredicate, self.predicates.len);
        errdefer allocator.free(predicates);
        for (self.predicates, 0..) |predicate, index| {
            predicates[index] = try cloneWherePredicate(predicate, allocator);
        }
        return .{
            .span = self.span,
            .predicates = predicates,
            .invalid_kind = self.invalid_kind,
        };
    }

    pub fn deinit(self: *WhereClause, allocator: Allocator) void {
        for (self.predicates) |*predicate| deinitWherePredicate(predicate, allocator);
        freeSlice(allocator, self.predicates);
        self.* = .{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .predicates = &.{},
            .invalid_kind = null,
        };
    }
};

pub const BlockSyntax = block_syntax.Block;
pub const ExprSyntax = body_syntax.Expr;

pub const Parameter = struct {
    mode: ParameterMode = .owned,
    name: ?SpanText = null,
    ty: ?TypeSyntax = null,

    pub fn clone(self: Parameter, allocator: Allocator) !Parameter {
        return .{
            .mode = self.mode,
            .name = self.name,
            .ty = if (self.ty) |ty| try ty.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *Parameter, allocator: Allocator) void {
        if (self.ty) |*ty| ty.deinit(allocator);
        self.* = .{};
    }
};

pub const FunctionSignature = struct {
    name: ?SpanText = null,
    generic_params: ?GenericParamList = null,
    parameters: []Parameter = &.{},
    return_type: ?TypeSyntax = null,
    where_clauses: []WhereClause = &.{},
    foreign_abi: ?SpanText = null,

    pub fn clone(self: FunctionSignature, allocator: Allocator) !FunctionSignature {
        return .{
            .name = self.name,
            .generic_params = if (self.generic_params) |generic_params| try generic_params.clone(allocator) else null,
            .parameters = try cloneComplexSlice(allocator, Parameter, self.parameters),
            .return_type = if (self.return_type) |return_type| try return_type.clone(allocator) else null,
            .where_clauses = try cloneComplexSlice(allocator, WhereClause, self.where_clauses),
            .foreign_abi = self.foreign_abi,
        };
    }

    pub fn deinit(self: *FunctionSignature, allocator: Allocator) void {
        if (self.generic_params) |*generic_params| generic_params.deinit(allocator);
        freeComplexSlice(allocator, Parameter, self.parameters);
        if (self.return_type) |*return_type| return_type.deinit(allocator);
        freeComplexSlice(allocator, WhereClause, self.where_clauses);
        self.* = .{};
    }
};

pub const ConstSignature = struct {
    name: ?SpanText = null,
    ty: ?TypeSyntax = null,
    initializer: ?SpanText = null,
    initializer_expr: ?*ExprSyntax = null,

    pub fn clone(self: ConstSignature, allocator: Allocator) !ConstSignature {
        return .{
            .name = self.name,
            .ty = if (self.ty) |ty| try ty.clone(allocator) else null,
            .initializer = self.initializer,
            .initializer_expr = if (self.initializer_expr) |expr| try expr.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *ConstSignature, allocator: Allocator) void {
        if (self.ty) |*ty| ty.deinit(allocator);
        if (self.initializer_expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        self.* = .{};
    }
};

pub const NamedDecl = struct {
    name: ?SpanText = null,
    generic_params: ?GenericParamList = null,
    where_clauses: []WhereClause = &.{},

    pub fn clone(self: NamedDecl, allocator: Allocator) !NamedDecl {
        return .{
            .name = self.name,
            .generic_params = if (self.generic_params) |generic_params| try generic_params.clone(allocator) else null,
            .where_clauses = try cloneComplexSlice(allocator, WhereClause, self.where_clauses),
        };
    }

    pub fn deinit(self: *NamedDecl, allocator: Allocator) void {
        if (self.generic_params) |*generic_params| generic_params.deinit(allocator);
        freeComplexSlice(allocator, WhereClause, self.where_clauses);
        self.* = .{};
    }
};

pub const TypeAlias = struct {
    name: ?SpanText = null,
    generic_params: ?GenericParamList = null,
    target: ?TypeSyntax = null,
    where_clauses: []WhereClause = &.{},

    pub fn clone(self: TypeAlias, allocator: Allocator) !TypeAlias {
        return .{
            .name = self.name,
            .generic_params = if (self.generic_params) |generic_params| try generic_params.clone(allocator) else null,
            .target = if (self.target) |target| try target.clone(allocator) else null,
            .where_clauses = try cloneComplexSlice(allocator, WhereClause, self.where_clauses),
        };
    }

    pub fn deinit(self: *TypeAlias, allocator: Allocator) void {
        if (self.generic_params) |*generic_params| generic_params.deinit(allocator);
        if (self.target) |*target| target.deinit(allocator);
        freeComplexSlice(allocator, WhereClause, self.where_clauses);
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
    generic_params: ?GenericParamList = null,
    trait_name: ?TypeSyntax = null,
    target_type: ?TypeSyntax = null,
    where_clauses: []WhereClause = &.{},

    pub fn clone(self: ImplSignature, allocator: Allocator) !ImplSignature {
        return .{
            .generic_params = if (self.generic_params) |generic_params| try generic_params.clone(allocator) else null,
            .trait_name = if (self.trait_name) |trait_name| try trait_name.clone(allocator) else null,
            .target_type = if (self.target_type) |target_type| try target_type.clone(allocator) else null,
            .where_clauses = try cloneComplexSlice(allocator, WhereClause, self.where_clauses),
        };
    }

    pub fn deinit(self: *ImplSignature, allocator: Allocator) void {
        if (self.generic_params) |*generic_params| generic_params.deinit(allocator);
        if (self.trait_name) |*trait_name| trait_name.deinit(allocator);
        if (self.target_type) |*target_type| target_type.deinit(allocator);
        freeComplexSlice(allocator, WhereClause, self.where_clauses);
        self.* = .{};
    }
};

pub const FieldDecl = struct {
    visibility: Visibility = .private,
    name: ?SpanText = null,
    ty: ?TypeSyntax = null,

    pub fn clone(self: FieldDecl, allocator: Allocator) !FieldDecl {
        return .{
            .visibility = self.visibility,
            .name = self.name,
            .ty = if (self.ty) |ty| try ty.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *FieldDecl, allocator: Allocator) void {
        if (self.ty) |*ty| ty.deinit(allocator);
        self.* = .{};
    }
};

pub const TuplePayloadInvalidKind = enum {
    malformed_payload,
    empty_payload,
    empty_entry,
};

pub const TuplePayload = struct {
    span: source.Span,
    types: []TypeSyntax = &.{},
    invalid_kind: ?TuplePayloadInvalidKind = null,

    pub fn clone(self: TuplePayload, allocator: Allocator) !TuplePayload {
        const types = try allocator.alloc(TypeSyntax, self.types.len);
        errdefer allocator.free(types);
        for (self.types, 0..) |ty, index| {
            types[index] = try ty.clone(allocator);
        }
        return .{
            .span = self.span,
            .types = types,
            .invalid_kind = self.invalid_kind,
        };
    }

    pub fn deinit(self: *TuplePayload, allocator: Allocator) void {
        freeComplexSlice(allocator, TypeSyntax, self.types);
        self.* = .{
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
            .types = &.{},
            .invalid_kind = null,
        };
    }
};

pub const EnumVariant = struct {
    name: ?SpanText = null,
    tuple_payload: ?TuplePayload = null,
    discriminant_source: ?SpanText = null,
    discriminant_expr: ?*ExprSyntax = null,
    named_fields: []FieldDecl = &.{},

    pub fn clone(self: EnumVariant, allocator: Allocator) !EnumVariant {
        var cloned = EnumVariant{
            .name = self.name,
            .tuple_payload = if (self.tuple_payload) |payload| try payload.clone(allocator) else null,
            .discriminant_source = self.discriminant_source,
            .discriminant_expr = null,
            .named_fields = &.{},
        };
        errdefer cloned.deinit(allocator);
        if (self.discriminant_expr) |expr| cloned.discriminant_expr = try expr.clone(allocator);
        cloned.named_fields = try cloneComplexSlice(allocator, FieldDecl, self.named_fields);
        return cloned;
    }

    pub fn deinit(self: *EnumVariant, allocator: Allocator) void {
        if (self.tuple_payload) |*payload| payload.deinit(allocator);
        if (self.discriminant_expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
        freeComplexSlice(allocator, FieldDecl, self.named_fields);
        self.* = .{};
    }
};

pub const AssociatedTypeDecl = struct {
    name: ?SpanText = null,
    value: ?TypeSyntax = null,

    pub fn clone(self: AssociatedTypeDecl, allocator: Allocator) !AssociatedTypeDecl {
        return .{
            .name = self.name,
            .value = if (self.value) |value| try value.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *AssociatedTypeDecl, allocator: Allocator) void {
        if (self.value) |*value| value.deinit(allocator);
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
            .associated_types = try cloneComplexSlice(allocator, AssociatedTypeDecl, self.associated_types),
            .associated_consts = try cloneComplexSlice(allocator, ConstSignature, self.associated_consts),
        };
    }

    pub fn deinit(self: *TraitBody, allocator: Allocator) void {
        freeComplexSlice(allocator, MethodDecl, self.methods);
        freeComplexSlice(allocator, AssociatedTypeDecl, self.associated_types);
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
            .associated_types = try cloneComplexSlice(allocator, AssociatedTypeDecl, self.associated_types),
            .associated_consts = try cloneComplexSlice(allocator, ConstSignature, self.associated_consts),
        };
    }

    pub fn deinit(self: *ImplBody, allocator: Allocator) void {
        freeComplexSlice(allocator, MethodDecl, self.methods);
        freeComplexSlice(allocator, AssociatedTypeDecl, self.associated_types);
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
            .struct_fields => |fields| .{ .struct_fields = try cloneComplexSlice(allocator, FieldDecl, fields) },
            .union_fields => |fields| .{ .union_fields = try cloneComplexSlice(allocator, FieldDecl, fields) },
            .enum_variants => |variants| .{ .enum_variants = try cloneComplexSlice(allocator, EnumVariant, variants) },
            .trait_body => |body| .{ .trait_body = try body.clone(allocator) },
            .impl_body => |body| .{ .impl_body = try body.clone(allocator) },
        };
    }

    pub fn deinit(self: *ItemBodySyntax, allocator: Allocator) void {
        switch (self.*) {
            .none => {},
            .struct_fields => |fields| freeComplexSlice(allocator, FieldDecl, fields),
            .union_fields => |fields| freeComplexSlice(allocator, FieldDecl, fields),
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
    type_alias: TypeAlias,
    named_decl: NamedDecl,
    use_decl: UseBinding,
    impl_block: ImplSignature,

    pub fn clone(self: ItemSyntax, allocator: Allocator) !ItemSyntax {
        return switch (self) {
            .none => .none,
            .function => |signature| .{ .function = try signature.clone(allocator) },
            .const_item => |signature| .{ .const_item = try signature.clone(allocator) },
            .type_alias => |signature| .{ .type_alias = try signature.clone(allocator) },
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
            .type_alias => |*signature| signature.deinit(allocator),
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

fn cloneWherePredicate(predicate: WherePredicate, allocator: Allocator) !WherePredicate {
    return switch (predicate) {
        .bound => |bound| .{ .bound = .{
            .subject_name = bound.subject_name,
            .contract_type = try bound.contract_type.clone(allocator),
            .span = bound.span,
        } },
        .projection_equality => |projection| .{ .projection_equality = .{
            .subject_name = projection.subject_name,
            .associated_name = projection.associated_name,
            .value_type = try projection.value_type.clone(allocator),
            .span = projection.span,
        } },
        .lifetime_outlives => |outlives| .{ .lifetime_outlives = outlives },
        .type_outlives => |outlives| .{ .type_outlives = outlives },
        .invalid => |invalid| .{ .invalid = invalid },
    };
}

fn deinitWherePredicate(predicate: *WherePredicate, allocator: Allocator) void {
    switch (predicate.*) {
        .bound => |*bound| bound.contract_type.deinit(allocator),
        .projection_equality => |*projection| projection.value_type.deinit(allocator),
        else => {},
    }
}
