const callee_helpers = @import("callee_helpers.zig");
const const_ir = @import("const_ir.zig");
const c_va_list = @import("../abi/c/va_list.zig");
const source = @import("../source/root.zig");
const std = @import("std");
const typed = @import("../typed/root.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;
pub const exit_statement = std.math.maxInt(usize);

pub const Summary = struct {
    statement_count: usize = 0,
    top_level_statement_count: usize = 0,
    block_count: usize = 0,
    cfg_edge_count: usize = 0,
    let_count: usize = 0,
    const_count: usize = 0,
    assign_count: usize = 0,
    select_count: usize = 0,
    loop_count: usize = 0,
    unsafe_block_count: usize = 0,
    defer_count: usize = 0,
    return_count: usize = 0,
    break_count: usize = 0,
    continue_count: usize = 0,
    expr_statement_count: usize = 0,
    binding_count: usize = 0,
    parameter_count: usize = 0,
    mutable_parameter_count: usize = 0,
    owned_parameter_count: usize = 0,
    take_parameter_count: usize = 0,
    read_parameter_count: usize = 0,
    edit_parameter_count: usize = 0,
    call_count: usize = 0,
    spawn_call_count: usize = 0,
    suspend_call_count: usize = 0,
    constructor_count: usize = 0,
    function_value_count: usize = 0,
    callable_dispatch_count: usize = 0,
    subject_select_pattern_count: usize = 0,
    irrefutable_subject_pattern_count: usize = 0,
    pattern_diagnostic_count: usize = 0,
    repeat_iteration_count: usize = 0,
    expression_count: usize = 0,
};

pub const PlaceId = struct { index: usize };

pub const PlaceKind = enum {
    parameter,
    local,
    local_const,
    select_binding,
    assignment_target,
};

pub const CanonicalPlace = struct {
    id: PlaceId,
    kind: PlaceKind,
    name: []const u8,
    ty: types.TypeRef,
    mutable: bool,
    parameter_index: ?usize = null,
};

pub const CfgEdgeKind = enum {
    sequence,
    select_subject,
    select_arm,
    select_else,
    loop_condition,
    loop_body,
    loop_back,
    break_exit,
    continue_exit,
    return_exit,
    defer_exit,
    unsafe_body,
};

pub const CfgEdge = struct {
    from_statement: usize,
    to_statement: usize,
    kind: CfgEdgeKind,
};

pub const EffectKind = enum {
    call,
    spawn,
    spawn_boundary,
    suspend_call,
    suspend_boundary,
    constructor,
    enum_constructor,
    return_value,
    defer_expr,
    unsafe_block,
};

pub const EffectSite = struct {
    statement_index: usize,
    kind: EffectKind,
    callee_name: ?[]const u8 = null,
    target_type_name: ?[]const u8 = null,
};

pub const SuspensionSite = struct {
    statement_index: usize,
    callee_name: []const u8,
};

pub const SpawnSite = struct {
    statement_index: usize,
    callee_name: []const u8,
    worker_crossing: bool,
    detached: bool,
    callable_arg_type: ?types.TypeRef = null,
    input_arg_type: ?types.TypeRef = null,
    callable_output_type: ?types.TypeRef = null,
};

pub const FunctionValueIssue = enum {
    none,
    generic,
    borrow_parameter,
};

pub const FunctionValueSite = struct {
    statement_index: usize,
    function_name: []const u8,
    issue: FunctionValueIssue,
};

pub const CallableDispatchKind = enum {
    local_callable,
    non_callable_local,
};

pub const CallableDispatchSite = struct {
    statement_index: usize,
    callee_name: []const u8,
    kind: CallableDispatchKind,
    arg_count: usize,
    arg_types: []const types.TypeRef,
    input_type: ?types.TypeRef = null,
    output_type: ?types.TypeRef = null,
    is_suspend: bool = false,
};

pub const SubjectPatternSite = struct {
    statement_index: usize,
    arm_index: usize,
    irrefutable: bool,
};

pub const UnreachablePatternSite = struct {
    statement_index: usize,
    arm_index: ?usize,
    is_else: bool,
};

pub const PatternDiagnosticSite = struct {
    statement_index: usize,
    code: []const u8,
    message: []const u8,
};

pub const RepeatIterationSite = struct {
    statement_index: usize,
    iterable_type: types.TypeRef,
};

pub const BlockSite = struct {
    id: usize,
    parent_statement: ?usize = null,
    scope_id: usize,
    statement_indices: []const usize,
};

pub const StatementKind = enum {
    placeholder,
    let_decl,
    const_decl,
    assign_stmt,
    select_stmt,
    loop_stmt,
    unsafe_block,
    defer_stmt,
    break_stmt,
    continue_stmt,
    return_stmt,
    expr_stmt,
};

pub const SelectBindingSite = struct {
    name: []const u8,
    ty: types.TypeRef,
    expr: *const typed.Expr,
};

pub const SelectArmSite = struct {
    condition: *const typed.Expr,
    bindings: []const SelectBindingSite,
    body_block_id: usize,
    pattern_irrefutable: bool = false,
    constant_pattern_expr: ?*const const_ir.Expr = null,
    constant_pattern_lower_error: ?anyerror = null,
};

pub const StatementSite = struct {
    index: usize,
    block_id: usize,
    scope_id: usize,
    kind: StatementKind,
    binding_name: ?[]const u8 = null,
    binding_ty: types.TypeRef = .unsupported,
    binding_explicit_type: bool = false,
    binding_span: ?source.Span = null,
    binding_expr: ?*const typed.Expr = null,
    assign_name: ?[]const u8 = null,
    assign_owns_name: bool = false,
    assign_ty: types.TypeRef = .unsupported,
    assign_op: ?typed.BinaryOp = null,
    assign_expr: ?*const typed.Expr = null,
    select_subject: ?*const typed.Expr = null,
    select_subject_temp_name: ?[]const u8 = null,
    select_arms: []const SelectArmSite = &.{},
    select_else_block_id: ?usize = null,
    loop_condition: ?*const typed.Expr = null,
    loop_body_block_id: ?usize = null,
    unsafe_block_id: ?usize = null,
    expr: ?*const typed.Expr = null,
};

pub const LexicalScope = struct {
    id: usize,
    parent: ?usize = null,
};

pub const LocalConstDeclSite = struct {
    statement_index: usize,
    scope_id: usize,
    name: []const u8,
    ty: types.TypeRef,
    explicit_type: bool,
    span: source.Span,
    expr: ?*const const_ir.Expr = null,
    lower_error: ?anyerror = null,
};

pub const ArrayRepetitionLengthSite = struct {
    statement_index: usize,
    scope_id: usize,
    span: ?source.Span,
    length_expr: ?*const const_ir.Expr = null,
    lower_error: ?anyerror = null,
};

pub const CallArgumentSite = struct {
    statement_index: usize,
    callee_name: []const u8,
    arg_index: usize,
    arg_type: types.TypeRef,
    arg_expr: *const typed.Expr,
};

pub const ConstructorArgumentKind = enum {
    struct_constructor,
    enum_constructor,
};

pub const ConstructorArgumentSite = struct {
    statement_index: usize,
    kind: ConstructorArgumentKind,
    target_type_name: []const u8,
    arg_type: types.TypeRef,
};

pub const ReturnValueSite = struct {
    statement_index: usize,
    value_type: types.TypeRef,
};

pub const AssignmentWriteSite = struct {
    statement_index: usize,
    target_name: []const u8,
    target_type: types.TypeRef,
    target_base_type: ?types.TypeRef = null,
    value_type: types.TypeRef,
};

pub const ExpressionId = struct { index: usize };

pub const ExpressionKind = enum {
    integer,
    bool_lit,
    string,
    identifier,
    enum_variant,
    enum_tag,
    enum_constructor_target,
    enum_construct,
    call,
    constructor,
    method_target,
    field,
    tuple,
    array,
    array_repeat,
    index,
    conversion,
    unary,
    binary,
};

pub const ExpressionSite = struct {
    id: ExpressionId,
    statement_index: usize,
    kind: ExpressionKind,
    ty: types.TypeRef,
    callee_name: ?[]const u8 = null,
    target_type_name: ?[]const u8 = null,
    field_name: ?[]const u8 = null,
    binary_op: ?typed.BinaryOp = null,
    unary_op: ?typed.UnaryOp = null,
    conversion_mode: ?typed.ConversionMode = null,
    source_type: types.TypeRef = .unsupported,
    target_type: types.TypeRef = .unsupported,
};

pub const Facts = struct {
    summary: Summary,
    root_block_id: usize,
    block_sites: []const BlockSite,
    statement_sites: []const StatementSite,
    places: []const CanonicalPlace,
    cfg_edges: []const CfgEdge,
    effect_sites: []const EffectSite,
    suspension_sites: []const SuspensionSite,
    spawn_sites: []const SpawnSite,
    function_value_sites: []const FunctionValueSite,
    callable_dispatch_sites: []const CallableDispatchSite,
    subject_pattern_sites: []const SubjectPatternSite,
    unreachable_pattern_sites: []const UnreachablePatternSite,
    pattern_diagnostic_sites: []const PatternDiagnosticSite,
    repeat_iteration_sites: []const RepeatIterationSite,
    lexical_scopes: []const LexicalScope,
    local_const_decl_sites: []const LocalConstDeclSite,
    array_repetition_length_sites: []const ArrayRepetitionLengthSite,
    call_argument_sites: []const CallArgumentSite,
    constructor_argument_sites: []const ConstructorArgumentSite,
    return_value_sites: []const ReturnValueSite,
    assignment_write_sites: []const AssignmentWriteSite,
    expression_sites: []const ExpressionSite,

    pub fn deinit(self: Facts, allocator: Allocator) void {
        for (self.block_sites) |block| {
            if (block.statement_indices.len != 0) allocator.free(block.statement_indices);
        }
        allocator.free(self.block_sites);
        for (self.statement_sites) |site| {
            for (site.select_arms) |arm| {
                if (arm.constant_pattern_expr) |expr| const_ir.destroyExpr(allocator, expr);
                if (arm.bindings.len != 0) allocator.free(arm.bindings);
            }
            if (site.select_arms.len != 0) allocator.free(site.select_arms);
        }
        allocator.free(self.statement_sites);
        allocator.free(self.places);
        allocator.free(self.cfg_edges);
        allocator.free(self.effect_sites);
        allocator.free(self.suspension_sites);
        allocator.free(self.spawn_sites);
        allocator.free(self.function_value_sites);
        for (self.callable_dispatch_sites) |site| allocator.free(site.arg_types);
        allocator.free(self.callable_dispatch_sites);
        allocator.free(self.subject_pattern_sites);
        allocator.free(self.unreachable_pattern_sites);
        allocator.free(self.pattern_diagnostic_sites);
        allocator.free(self.repeat_iteration_sites);
        allocator.free(self.lexical_scopes);
        for (self.local_const_decl_sites) |site| {
            if (site.expr) |expr| const_ir.destroyExpr(allocator, expr);
        }
        allocator.free(self.local_const_decl_sites);
        for (self.array_repetition_length_sites) |site| {
            if (site.length_expr) |expr| const_ir.destroyExpr(allocator, expr);
        }
        allocator.free(self.array_repetition_length_sites);
        allocator.free(self.call_argument_sites);
        allocator.free(self.constructor_argument_sites);
        allocator.free(self.return_value_sites);
        allocator.free(self.assignment_write_sites);
        allocator.free(self.expression_sites);
    }
};

pub fn buildFacts(
    allocator: Allocator,
    function: *const typed.FunctionData,
    callable_resolver: anytype,
) !Facts {
    var builder = Builder.init(allocator);
    defer builder.deinit();

    builder.summary.parameter_count = function.parameters.items.len;
    for (function.parameters.items, 0..) |parameter, parameter_index| {
        switch (parameter.mode) {
            .owned => {
                builder.summary.owned_parameter_count += 1;
                builder.summary.mutable_parameter_count += 1;
            },
            .take => {
                builder.summary.take_parameter_count += 1;
                builder.summary.mutable_parameter_count += 1;
            },
            .read => builder.summary.read_parameter_count += 1,
            .edit => {
                builder.summary.edit_parameter_count += 1;
                builder.summary.mutable_parameter_count += 1;
            },
        }
        try builder.addPlace(.{
            .kind = .parameter,
            .name = c_va_list.localName(parameter.name),
            .ty = parameter.ty,
            .mutable = parameter.mode != .read,
            .parameter_index = parameter_index,
        });
    }
    builder.summary.top_level_statement_count = function.body.statements.items.len;
    const root_range = try builder.visitBlock(callable_resolver, null, .sequence, &function.body);

    return .{
        .summary = builder.summary,
        .root_block_id = root_range.block_id,
        .block_sites = try builder.block_sites.toOwnedSlice(),
        .statement_sites = try builder.statement_sites.toOwnedSlice(),
        .places = try builder.places.toOwnedSlice(),
        .cfg_edges = try builder.cfg_edges.toOwnedSlice(),
        .effect_sites = try builder.effect_sites.toOwnedSlice(),
        .suspension_sites = try builder.suspension_sites.toOwnedSlice(),
        .spawn_sites = try builder.spawn_sites.toOwnedSlice(),
        .function_value_sites = try builder.function_value_sites.toOwnedSlice(),
        .callable_dispatch_sites = try builder.callable_dispatch_sites.toOwnedSlice(),
        .subject_pattern_sites = try builder.subject_pattern_sites.toOwnedSlice(),
        .unreachable_pattern_sites = try builder.unreachable_pattern_sites.toOwnedSlice(),
        .pattern_diagnostic_sites = try builder.pattern_diagnostic_sites.toOwnedSlice(),
        .repeat_iteration_sites = try builder.repeat_iteration_sites.toOwnedSlice(),
        .lexical_scopes = try builder.lexical_scopes.toOwnedSlice(),
        .local_const_decl_sites = try builder.local_const_decl_sites.toOwnedSlice(),
        .array_repetition_length_sites = try builder.array_repetition_length_sites.toOwnedSlice(),
        .call_argument_sites = try builder.call_argument_sites.toOwnedSlice(),
        .constructor_argument_sites = try builder.constructor_argument_sites.toOwnedSlice(),
        .return_value_sites = try builder.return_value_sites.toOwnedSlice(),
        .assignment_write_sites = try builder.assignment_write_sites.toOwnedSlice(),
        .expression_sites = try builder.expression_sites.toOwnedSlice(),
    };
}

const Builder = struct {
    allocator: Allocator,
    summary: Summary = .{},
    block_sites: std.array_list.Managed(BlockSite),
    statement_sites: std.array_list.Managed(StatementSite),
    places: std.array_list.Managed(CanonicalPlace),
    cfg_edges: std.array_list.Managed(CfgEdge),
    effect_sites: std.array_list.Managed(EffectSite),
    suspension_sites: std.array_list.Managed(SuspensionSite),
    spawn_sites: std.array_list.Managed(SpawnSite),
    function_value_sites: std.array_list.Managed(FunctionValueSite),
    callable_dispatch_sites: std.array_list.Managed(CallableDispatchSite),
    subject_pattern_sites: std.array_list.Managed(SubjectPatternSite),
    unreachable_pattern_sites: std.array_list.Managed(UnreachablePatternSite),
    pattern_diagnostic_sites: std.array_list.Managed(PatternDiagnosticSite),
    repeat_iteration_sites: std.array_list.Managed(RepeatIterationSite),
    lexical_scopes: std.array_list.Managed(LexicalScope),
    local_const_decl_sites: std.array_list.Managed(LocalConstDeclSite),
    array_repetition_length_sites: std.array_list.Managed(ArrayRepetitionLengthSite),
    call_argument_sites: std.array_list.Managed(CallArgumentSite),
    constructor_argument_sites: std.array_list.Managed(ConstructorArgumentSite),
    return_value_sites: std.array_list.Managed(ReturnValueSite),
    assignment_write_sites: std.array_list.Managed(AssignmentWriteSite),
    expression_sites: std.array_list.Managed(ExpressionSite),
    scope_stack: std.array_list.Managed(usize),
    loop_stack: std.array_list.Managed(usize),
    defer_stack: std.array_list.Managed(usize),
    next_statement_index: usize = 0,

    fn init(allocator: Allocator) Builder {
        return .{
            .allocator = allocator,
            .block_sites = std.array_list.Managed(BlockSite).init(allocator),
            .statement_sites = std.array_list.Managed(StatementSite).init(allocator),
            .places = std.array_list.Managed(CanonicalPlace).init(allocator),
            .cfg_edges = std.array_list.Managed(CfgEdge).init(allocator),
            .effect_sites = std.array_list.Managed(EffectSite).init(allocator),
            .suspension_sites = std.array_list.Managed(SuspensionSite).init(allocator),
            .spawn_sites = std.array_list.Managed(SpawnSite).init(allocator),
            .function_value_sites = std.array_list.Managed(FunctionValueSite).init(allocator),
            .callable_dispatch_sites = std.array_list.Managed(CallableDispatchSite).init(allocator),
            .subject_pattern_sites = std.array_list.Managed(SubjectPatternSite).init(allocator),
            .unreachable_pattern_sites = std.array_list.Managed(UnreachablePatternSite).init(allocator),
            .pattern_diagnostic_sites = std.array_list.Managed(PatternDiagnosticSite).init(allocator),
            .repeat_iteration_sites = std.array_list.Managed(RepeatIterationSite).init(allocator),
            .lexical_scopes = std.array_list.Managed(LexicalScope).init(allocator),
            .local_const_decl_sites = std.array_list.Managed(LocalConstDeclSite).init(allocator),
            .array_repetition_length_sites = std.array_list.Managed(ArrayRepetitionLengthSite).init(allocator),
            .call_argument_sites = std.array_list.Managed(CallArgumentSite).init(allocator),
            .constructor_argument_sites = std.array_list.Managed(ConstructorArgumentSite).init(allocator),
            .return_value_sites = std.array_list.Managed(ReturnValueSite).init(allocator),
            .assignment_write_sites = std.array_list.Managed(AssignmentWriteSite).init(allocator),
            .expression_sites = std.array_list.Managed(ExpressionSite).init(allocator),
            .scope_stack = std.array_list.Managed(usize).init(allocator),
            .loop_stack = std.array_list.Managed(usize).init(allocator),
            .defer_stack = std.array_list.Managed(usize).init(allocator),
        };
    }

    fn deinit(self: *Builder) void {
        for (self.block_sites.items) |block| {
            if (block.statement_indices.len != 0) self.allocator.free(block.statement_indices);
        }
        for (self.statement_sites.items) |site| {
            self.freeSelectArms(site.select_arms);
        }
        self.block_sites.deinit();
        self.statement_sites.deinit();
        self.places.deinit();
        self.cfg_edges.deinit();
        self.effect_sites.deinit();
        self.suspension_sites.deinit();
        self.spawn_sites.deinit();
        self.function_value_sites.deinit();
        self.callable_dispatch_sites.deinit();
        self.subject_pattern_sites.deinit();
        self.unreachable_pattern_sites.deinit();
        self.pattern_diagnostic_sites.deinit();
        self.repeat_iteration_sites.deinit();
        self.lexical_scopes.deinit();
        for (self.local_const_decl_sites.items) |site| {
            if (site.expr) |expr| const_ir.destroyExpr(self.allocator, expr);
        }
        self.local_const_decl_sites.deinit();
        for (self.array_repetition_length_sites.items) |site| {
            if (site.length_expr) |expr| const_ir.destroyExpr(self.allocator, expr);
        }
        self.array_repetition_length_sites.deinit();
        self.call_argument_sites.deinit();
        self.constructor_argument_sites.deinit();
        self.return_value_sites.deinit();
        self.assignment_write_sites.deinit();
        self.expression_sites.deinit();
        self.scope_stack.deinit();
        self.loop_stack.deinit();
        self.defer_stack.deinit();
    }

    fn addPlace(self: *Builder, place: struct {
        kind: PlaceKind,
        name: []const u8,
        ty: types.TypeRef,
        mutable: bool,
        parameter_index: ?usize = null,
    }) !void {
        try self.places.append(.{
            .id = .{ .index = self.places.items.len },
            .kind = place.kind,
            .name = place.name,
            .ty = place.ty,
            .mutable = place.mutable,
            .parameter_index = place.parameter_index,
        });
    }

    fn addEdge(self: *Builder, from_statement: usize, to_statement: usize, kind: CfgEdgeKind) !void {
        try self.cfg_edges.append(.{
            .from_statement = from_statement,
            .to_statement = to_statement,
            .kind = kind,
        });
        self.summary.cfg_edge_count += 1;
    }

    fn addDeferredExitEdges(self: *Builder, exit_from: usize, defer_base: usize) !void {
        var index = self.defer_stack.items.len;
        while (index > defer_base) {
            index -= 1;
            try self.addEdge(exit_from, self.defer_stack.items[index], .defer_exit);
        }
    }

    fn currentLoopStatement(self: *const Builder) ?usize {
        if (self.loop_stack.items.len == 0) return null;
        return self.loop_stack.items[self.loop_stack.items.len - 1];
    }

    fn addEffect(self: *Builder, statement_index: usize, kind: EffectKind, callee_name: ?[]const u8, target_type_name: ?[]const u8) !void {
        try self.effect_sites.append(.{
            .statement_index = statement_index,
            .kind = kind,
            .callee_name = callee_name,
            .target_type_name = target_type_name,
        });
    }

    fn currentScopeId(self: *const Builder) usize {
        return self.scope_stack.items[self.scope_stack.items.len - 1];
    }

    fn pushScope(self: *Builder) !usize {
        const parent = if (self.scope_stack.items.len == 0) null else self.scope_stack.items[self.scope_stack.items.len - 1];
        const id = self.lexical_scopes.items.len;
        try self.lexical_scopes.append(.{ .id = id, .parent = parent });
        try self.scope_stack.append(id);
        return id;
    }

    const BlockRange = struct {
        block_id: usize,
        first: ?usize = null,
        last: ?usize = null,
    };

    fn visitBlock(self: *Builder, callable_resolver: anytype, parent_statement: ?usize, parent_edge: CfgEdgeKind, block: *const typed.Block) anyerror!BlockRange {
        self.summary.block_count += 1;
        const block_id = self.block_sites.items.len;
        try self.block_sites.append(.{
            .id = block_id,
            .parent_statement = parent_statement,
            .scope_id = 0,
            .statement_indices = &.{},
        });

        const scope_id = try self.pushScope();
        defer self.scope_stack.items.len -= 1;
        self.block_sites.items[block_id].scope_id = scope_id;

        const defer_base = self.defer_stack.items.len;
        defer self.defer_stack.items.len = defer_base;

        var statement_indices = std.array_list.Managed(usize).init(self.allocator);
        errdefer statement_indices.deinit();

        var first_statement: ?usize = null;
        var previous_statement: ?usize = null;
        for (block.statements.items) |statement| {
            const statement_index = try self.visitStatement(callable_resolver, block_id, statement);
            try statement_indices.append(statement_index);
            if (first_statement == null) {
                first_statement = statement_index;
                if (parent_statement) |parent| try self.addEdge(parent, statement_index, parent_edge);
            }
            if (previous_statement) |previous| {
                try self.addEdge(previous, statement_index, .sequence);
            }
            previous_statement = statement_index;
        }

        self.block_sites.items[block_id].statement_indices = try statement_indices.toOwnedSlice();
        return .{
            .block_id = block_id,
            .first = first_statement,
            .last = previous_statement,
        };
    }

    fn visitStatement(self: *Builder, callable_resolver: anytype, block_id: usize, statement: typed.Statement) anyerror!usize {
        const statement_index = self.next_statement_index;
        self.next_statement_index += 1;
        const scope_id = self.currentScopeId();
        try self.statement_sites.append(.{
            .index = statement_index,
            .block_id = block_id,
            .scope_id = scope_id,
            .kind = .placeholder,
        });
        var site = StatementSite{
            .index = statement_index,
            .block_id = block_id,
            .scope_id = scope_id,
            .kind = .placeholder,
        };
        var owned_select_arms: []SelectArmSite = &.{};
        var owns_select_arms = false;
        errdefer if (owns_select_arms) self.freeSelectArms(owned_select_arms);

        self.summary.statement_count += 1;
        switch (statement) {
            .let_decl => |binding| {
                site.kind = .let_decl;
                site.binding_name = binding.name;
                site.binding_ty = binding.ty;
                site.binding_explicit_type = binding.explicit_type;
                site.binding_span = binding.span;
                site.binding_expr = binding.expr;
                self.summary.let_count += 1;
                self.summary.binding_count += 1;
                try self.addPlace(.{
                    .kind = .local,
                    .name = binding.name,
                    .ty = binding.ty,
                    .mutable = true,
                });
                try self.visitExpr(callable_resolver, statement_index, binding.span, binding.expr);
            },
            .const_decl => |binding| {
                site.kind = .const_decl;
                site.binding_name = binding.name;
                site.binding_ty = binding.ty;
                site.binding_explicit_type = binding.explicit_type;
                site.binding_span = binding.span;
                site.binding_expr = binding.expr;
                self.summary.const_count += 1;
                self.summary.binding_count += 1;
                const lowered = try self.lowerConstExpr(binding.expr);
                try self.local_const_decl_sites.append(.{
                    .statement_index = statement_index,
                    .scope_id = self.currentScopeId(),
                    .name = binding.name,
                    .ty = binding.ty,
                    .explicit_type = binding.explicit_type,
                    .span = binding.span,
                    .expr = lowered.expr,
                    .lower_error = lowered.lower_error,
                });
                try self.addPlace(.{
                    .kind = .local_const,
                    .name = binding.name,
                    .ty = binding.ty,
                    .mutable = false,
                });
                try self.visitExpr(callable_resolver, statement_index, binding.span, binding.expr);
            },
            .assign_stmt => |assign| {
                site.kind = .assign_stmt;
                site.assign_name = assign.name;
                site.assign_owns_name = assign.owns_name;
                site.assign_ty = assign.ty;
                site.assign_op = assign.op;
                site.assign_expr = assign.expr;
                self.summary.assign_count += 1;
                try self.addPlace(.{
                    .kind = .assignment_target,
                    .name = assign.name,
                    .ty = assign.ty,
                    .mutable = true,
                });
                try self.assignment_write_sites.append(.{
                    .statement_index = statement_index,
                    .target_name = assign.name,
                    .target_type = assign.ty,
                    .target_base_type = self.assignmentBaseType(assign.name),
                    .value_type = assign.expr.ty,
                });
                try self.visitExpr(callable_resolver, statement_index, null, assign.expr);
            },
            .select_stmt => |select_data| {
                site.kind = .select_stmt;
                site.select_subject = select_data.subject;
                site.select_subject_temp_name = select_data.subject_temp_name;
                owned_select_arms = try self.allocator.alloc(SelectArmSite, select_data.arms.len);
                owns_select_arms = true;
                for (owned_select_arms) |*arm_site| {
                    arm_site.* = .{
                        .condition = undefined,
                        .bindings = &.{},
                        .body_block_id = 0,
                    };
                }
                self.summary.select_count += 1;
                if (select_data.subject) |subject| {
                    try self.visitExpr(callable_resolver, statement_index, null, subject);
                    try self.recordSubjectPatterns(statement_index, select_data);
                }
                if (select_data.subject_temp_name) |name| {
                    self.summary.binding_count += 1;
                    try self.addPlace(.{
                        .kind = .select_binding,
                        .name = name,
                        .ty = if (select_data.subject) |subject| subject.ty else .unsupported,
                        .mutable = false,
                    });
                }
                for (select_data.arms, 0..) |arm, arm_index| {
                    const binding_sites = try self.allocator.alloc(SelectBindingSite, arm.bindings.len);
                    for (arm.bindings, 0..) |binding, binding_index| {
                        binding_sites[binding_index] = .{
                            .name = binding.name,
                            .ty = binding.ty,
                            .expr = binding.expr,
                        };
                    }
                    owned_select_arms[arm_index] = .{
                        .condition = arm.condition,
                        .bindings = binding_sites,
                        .body_block_id = 0,
                        .pattern_irrefutable = arm.pattern_irrefutable,
                    };
                    try self.recordConstantPatternExpr(&owned_select_arms[arm_index], select_data.subject_temp_name);
                    try self.visitExpr(callable_resolver, statement_index, null, arm.condition);
                    self.summary.binding_count += arm.bindings.len;
                    for (arm.bindings) |binding| {
                        try self.addPlace(.{
                            .kind = .select_binding,
                            .name = binding.name,
                            .ty = binding.ty,
                            .mutable = true,
                        });
                        try self.visitExpr(callable_resolver, statement_index, null, binding.expr);
                    }
                    const arm_range = try self.visitBlock(callable_resolver, statement_index, .select_arm, arm.body);
                    owned_select_arms[arm_index].body_block_id = arm_range.block_id;
                }
                if (select_data.else_body) |else_body| {
                    const else_range = try self.visitBlock(callable_resolver, statement_index, .select_else, else_body);
                    site.select_else_block_id = else_range.block_id;
                }
                site.select_arms = owned_select_arms;
                owns_select_arms = false;
            },
            .loop_stmt => |loop_data| {
                site.kind = .loop_stmt;
                site.loop_condition = loop_data.condition;
                self.summary.loop_count += 1;
                if (loop_data.iteration_type) |iterable_type| {
                    self.summary.repeat_iteration_count += 1;
                    try self.repeat_iteration_sites.append(.{
                        .statement_index = statement_index,
                        .iterable_type = iterable_type,
                    });
                }
                if (loop_data.condition) |condition| {
                    try self.addEdge(statement_index, statement_index, .loop_condition);
                    try self.visitExpr(callable_resolver, statement_index, null, condition);
                }
                try self.loop_stack.append(statement_index);
                defer self.loop_stack.items.len -= 1;
                const range = try self.visitBlock(callable_resolver, statement_index, .loop_body, loop_data.body);
                site.loop_body_block_id = range.block_id;
                if (range.last) |last| {
                    try self.addEdge(last, statement_index, .loop_back);
                }
            },
            .unsafe_block => |body| {
                site.kind = .unsafe_block;
                self.summary.unsafe_block_count += 1;
                try self.addEffect(statement_index, .unsafe_block, null, null);
                const range = try self.visitBlock(callable_resolver, statement_index, .unsafe_body, body);
                site.unsafe_block_id = range.block_id;
            },
            .defer_stmt => |expr| {
                site.kind = .defer_stmt;
                site.expr = expr;
                self.summary.defer_count += 1;
                try self.defer_stack.append(statement_index);
                try self.addEffect(statement_index, .defer_expr, null, null);
                try self.visitExpr(callable_resolver, statement_index, null, expr);
            },
            .return_stmt => |maybe_expr| {
                site.kind = .return_stmt;
                site.expr = maybe_expr;
                self.summary.return_count += 1;
                try self.addDeferredExitEdges(statement_index, 0);
                try self.addEdge(statement_index, exit_statement, .return_exit);
                if (maybe_expr) |expr| {
                    try self.addEffect(statement_index, .return_value, null, null);
                    try self.return_value_sites.append(.{
                        .statement_index = statement_index,
                        .value_type = expr.ty,
                    });
                    try self.visitExpr(callable_resolver, statement_index, null, expr);
                }
            },
            .expr_stmt => |expr| {
                site.kind = .expr_stmt;
                site.expr = expr;
                self.summary.expr_statement_count += 1;
                try self.visitExpr(callable_resolver, statement_index, null, expr);
            },
            .break_stmt => {
                site.kind = .break_stmt;
                self.summary.break_count += 1;
                try self.addDeferredExitEdges(statement_index, 0);
                if (self.currentLoopStatement()) |loop_statement| {
                    try self.addEdge(statement_index, loop_statement, .break_exit);
                }
            },
            .continue_stmt => {
                site.kind = .continue_stmt;
                self.summary.continue_count += 1;
                try self.addDeferredExitEdges(statement_index, 0);
                if (self.currentLoopStatement()) |loop_statement| {
                    try self.addEdge(statement_index, loop_statement, .continue_exit);
                }
            },
            .placeholder => site.kind = .placeholder,
        }
        self.statement_sites.items[statement_index] = site;
        return statement_index;
    }

    fn freeSelectArms(self: *Builder, arms: []const SelectArmSite) void {
        for (arms) |arm| {
            if (arm.constant_pattern_expr) |expr| const_ir.destroyExpr(self.allocator, expr);
            if (arm.bindings.len != 0) self.allocator.free(arm.bindings);
        }
        if (arms.len != 0) self.allocator.free(arms);
    }

    fn visitExpr(self: *Builder, callable_resolver: anytype, statement_index: usize, span: ?source.Span, expr: *const typed.Expr) anyerror!void {
        try self.addExpressionSite(statement_index, expr);
        switch (expr.node) {
            .call => |call| {
                self.summary.call_count += 1;
                try self.addEffect(statement_index, .call, call.callee, null);
                try self.recordCallableDispatch(statement_index, call);
                if (callee_helpers.isSpawnHelper(call.callee)) {
                    self.summary.spawn_call_count += 1;
                    try self.spawn_sites.append(.{
                        .statement_index = statement_index,
                        .callee_name = call.callee,
                        .worker_crossing = callee_helpers.isWorkerCrossingSpawnHelper(call.callee),
                        .detached = callee_helpers.isDetachedSpawnHelper(call.callee),
                        .callable_arg_type = if (call.args.len > 0) call.args[0].ty else null,
                        .input_arg_type = if (call.args.len > 1) call.args[1].ty else null,
                        .callable_output_type = if (call.args.len > 0)
                            self.callableOutputType(callable_resolver, call.args[0])
                        else
                            null,
                    });
                    try self.addEffect(statement_index, .spawn, call.callee, null);
                    try self.addEffect(statement_index, .spawn_boundary, call.callee, null);
                }
                if (callable_resolver.isSuspendFunction(call.callee)) {
                    self.summary.suspend_call_count += 1;
                    try self.suspension_sites.append(.{
                        .statement_index = statement_index,
                        .callee_name = call.callee,
                    });
                    try self.addEffect(statement_index, .suspend_call, call.callee, null);
                    try self.addEffect(statement_index, .suspend_boundary, call.callee, null);
                }
                for (call.args, 0..) |arg, arg_index| {
                    try self.call_argument_sites.append(.{
                        .statement_index = statement_index,
                        .callee_name = call.callee,
                        .arg_index = arg_index,
                        .arg_type = arg.ty,
                        .arg_expr = arg,
                    });
                    try self.visitExpr(callable_resolver, statement_index, span, arg);
                }
            },
            .constructor => |constructor| {
                self.summary.constructor_count += 1;
                try self.addEffect(statement_index, .constructor, null, constructor.type_name);
                for (constructor.args) |arg| {
                    try self.constructor_argument_sites.append(.{
                        .statement_index = statement_index,
                        .kind = .struct_constructor,
                        .target_type_name = constructor.type_name,
                        .arg_type = arg.ty,
                    });
                    try self.visitExpr(callable_resolver, statement_index, span, arg);
                }
            },
            .enum_construct => |construct| {
                try self.addEffect(statement_index, .enum_constructor, null, construct.enum_name);
                for (construct.args) |arg| {
                    try self.constructor_argument_sites.append(.{
                        .statement_index = statement_index,
                        .kind = .enum_constructor,
                        .target_type_name = construct.enum_name,
                        .arg_type = arg.ty,
                    });
                    try self.visitExpr(callable_resolver, statement_index, span, arg);
                }
            },
            .method_target => |target| try self.visitExpr(callable_resolver, statement_index, span, target.base),
            .field => |field| try self.visitExpr(callable_resolver, statement_index, span, field.base),
            .tuple => |tuple| {
                for (tuple.items) |item| try self.visitExpr(callable_resolver, statement_index, span, item);
            },
            .array => |array| {
                for (array.items) |item| try self.visitExpr(callable_resolver, statement_index, span, item);
            },
            .array_repeat => |array_repeat| {
                const lowered = try self.lowerConstExpr(array_repeat.length);
                try self.array_repetition_length_sites.append(.{
                    .statement_index = statement_index,
                    .scope_id = self.currentScopeId(),
                    .span = span,
                    .length_expr = lowered.expr,
                    .lower_error = lowered.lower_error,
                });
                try self.visitExpr(callable_resolver, statement_index, span, array_repeat.value);
                try self.visitExpr(callable_resolver, statement_index, span, array_repeat.length);
            },
            .index => |index| {
                try self.visitExpr(callable_resolver, statement_index, span, index.base);
                try self.visitExpr(callable_resolver, statement_index, span, index.index);
            },
            .conversion => |conversion| try self.visitExpr(callable_resolver, statement_index, span, conversion.operand),
            .unary => |unary| try self.visitExpr(callable_resolver, statement_index, span, unary.operand),
            .binary => |binary| {
                try self.visitExpr(callable_resolver, statement_index, span, binary.lhs);
                try self.visitExpr(callable_resolver, statement_index, span, binary.rhs);
            },
            .integer,
            .bool_lit,
            .string,
            .enum_variant,
            .enum_tag,
            .enum_constructor_target,
            => {},
            .identifier => |name| {
                if (callable_resolver.functionValueIssue(name)) |issue| {
                    self.summary.function_value_count += 1;
                    try self.function_value_sites.append(.{
                        .statement_index = statement_index,
                        .function_name = name,
                        .issue = issue,
                    });
                }
            },
        }
    }

    fn callableOutputType(self: *Builder, callable_resolver: anytype, expr: *const typed.Expr) ?types.TypeRef {
        if (type_support.callableFromTypeRef(self.allocator, expr.ty) catch null) |callable| {
            return callable.output_type;
        }

        switch (expr.node) {
            .identifier => |name| {
                const output_name = callable_resolver.outputTypeName(name) orelse return null;
                return switch (types.Builtin.fromName(output_name)) {
                    .unsupported => .{ .named = output_name },
                    else => |builtin| types.TypeRef.fromBuiltin(builtin),
                };
            },
            else => return null,
        }
    }

    fn addExpressionSite(self: *Builder, statement_index: usize, expr: *const typed.Expr) !void {
        const site = switch (expr.node) {
            .integer => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .integer,
                .ty = expr.ty,
            },
            .bool_lit => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .bool_lit,
                .ty = expr.ty,
            },
            .string => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .string,
                .ty = expr.ty,
            },
            .identifier => |name| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .identifier,
                .ty = expr.ty,
                .callee_name = name,
            },
            .enum_variant => |value| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .enum_variant,
                .ty = expr.ty,
                .target_type_name = value.enum_name,
                .field_name = value.variant_name,
            },
            .enum_tag => |value| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .enum_tag,
                .ty = expr.ty,
                .target_type_name = value.enum_name,
                .field_name = value.variant_name,
            },
            .enum_constructor_target => |value| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .enum_constructor_target,
                .ty = expr.ty,
                .target_type_name = value.enum_name,
                .field_name = value.variant_name,
            },
            .enum_construct => |construct| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .enum_construct,
                .ty = expr.ty,
                .target_type_name = construct.enum_name,
                .field_name = construct.variant_name,
            },
            .call => |call| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .call,
                .ty = expr.ty,
                .callee_name = call.callee,
            },
            .constructor => |constructor| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .constructor,
                .ty = expr.ty,
                .target_type_name = constructor.type_name,
            },
            .method_target => |target| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .method_target,
                .ty = expr.ty,
                .target_type_name = target.target_type,
                .field_name = target.method_name,
            },
            .field => |field| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .field,
                .ty = expr.ty,
                .field_name = field.field_name,
            },
            .tuple => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .tuple,
                .ty = expr.ty,
            },
            .array => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .array,
                .ty = expr.ty,
            },
            .array_repeat => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .array_repeat,
                .ty = expr.ty,
            },
            .index => ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .index,
                .ty = expr.ty,
            },
            .conversion => |conversion| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .conversion,
                .ty = expr.ty,
                .conversion_mode = conversion.mode,
                .source_type = conversion.operand.ty,
                .target_type = conversion.target_type,
            },
            .unary => |unary| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .unary,
                .ty = expr.ty,
                .unary_op = unary.op,
            },
            .binary => |binary| ExpressionSite{
                .id = .{ .index = self.expression_sites.items.len },
                .statement_index = statement_index,
                .kind = .binary,
                .ty = expr.ty,
                .binary_op = binary.op,
            },
        };
        try self.expression_sites.append(site);
        self.summary.expression_count += 1;
    }

    fn assignmentBaseType(self: *const Builder, target_name: []const u8) ?types.TypeRef {
        const dot_index = std.mem.indexOfScalar(u8, target_name, '.') orelse return null;
        const base_name = std.mem.trim(u8, target_name[0..dot_index], " \t");
        return self.placeTypeForName(base_name);
    }

    fn recordCallableDispatch(self: *Builder, statement_index: usize, call: typed.Expr.Call) !void {
        const local_type = self.placeTypeForName(call.callee) orelse return;
        const arg_types = try self.allocator.alloc(types.TypeRef, call.args.len);
        errdefer self.allocator.free(arg_types);
        for (call.args, 0..) |arg, index| arg_types[index] = arg.ty;
        if (try type_support.foreignCallableFromTypeRef(self.allocator, local_type)) |foreign_callable| {
            var owned = foreign_callable;
            defer owned.deinit(self.allocator);
            self.allocator.free(arg_types);
            return;
        }
        if (try type_support.callableFromTypeRef(self.allocator, local_type)) |callable| {
            self.summary.callable_dispatch_count += 1;
            try self.callable_dispatch_sites.append(.{
                .statement_index = statement_index,
                .callee_name = call.callee,
                .kind = .local_callable,
                .arg_count = call.args.len,
                .arg_types = arg_types,
                .input_type = callable.input_type,
                .output_type = callable.output_type,
                .is_suspend = callable.is_suspend,
            });
            return;
        }
        self.summary.callable_dispatch_count += 1;
        try self.callable_dispatch_sites.append(.{
            .statement_index = statement_index,
            .callee_name = call.callee,
            .kind = .non_callable_local,
            .arg_count = call.args.len,
            .arg_types = arg_types,
        });
    }

    fn lowerConstExpr(self: *Builder, expr: *const typed.Expr) !struct {
        expr: ?*const const_ir.Expr,
        lower_error: ?anyerror,
    } {
        const lowered = const_ir.lowerExpr(self.allocator, expr) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .expr = null, .lower_error = err },
        };
        return .{ .expr = lowered, .lower_error = null };
    }

    fn recordConstantPatternExpr(self: *Builder, arm_site: *SelectArmSite, subject_temp_name: ?[]const u8) !void {
        const temp_name = subject_temp_name orelse return;
        const pattern_expr = equalityPatternExpr(arm_site.condition, temp_name) orelse return;
        const lowered = try self.lowerConstExpr(pattern_expr);
        arm_site.constant_pattern_expr = lowered.expr;
        arm_site.constant_pattern_lower_error = lowered.lower_error;
    }

    fn recordSubjectPatterns(self: *Builder, statement_index: usize, select_data: *const typed.Statement.SelectData) !void {
        var saw_irrefutable = false;
        for (select_data.arms, 0..) |arm, arm_index| {
            self.summary.subject_select_pattern_count += 1;
            if (saw_irrefutable) {
                try self.unreachable_pattern_sites.append(.{
                    .statement_index = statement_index,
                    .arm_index = arm_index,
                    .is_else = false,
                });
            }
            if (arm.pattern_irrefutable) {
                self.summary.irrefutable_subject_pattern_count += 1;
            }
            try self.subject_pattern_sites.append(.{
                .statement_index = statement_index,
                .arm_index = arm_index,
                .irrefutable = arm.pattern_irrefutable,
            });
            saw_irrefutable = saw_irrefutable or arm.pattern_irrefutable;
        }
        if (select_data.else_body != null and saw_irrefutable) {
            try self.unreachable_pattern_sites.append(.{
                .statement_index = statement_index,
                .arm_index = null,
                .is_else = true,
            });
        }
        for (select_data.pattern_diagnostics) |pattern_diagnostic| {
            self.summary.pattern_diagnostic_count += 1;
            try self.pattern_diagnostic_sites.append(.{
                .statement_index = statement_index,
                .code = pattern_diagnostic.code,
                .message = pattern_diagnostic.message,
            });
        }
    }

    fn placeTypeForName(self: *const Builder, name: []const u8) ?types.TypeRef {
        var index = self.places.items.len;
        while (index > 0) {
            index -= 1;
            const place = self.places.items[index];
            if (place.kind == .assignment_target) continue;
            if (std.mem.eql(u8, place.name, name)) return place.ty;
        }
        return null;
    }
};

fn equalityPatternExpr(expr: *const typed.Expr, subject_temp_name: []const u8) ?*const typed.Expr {
    return switch (expr.node) {
        .binary => |binary| {
            if (binary.op != .eq) return null;
            if (isSubjectPatternComparable(binary.lhs, subject_temp_name)) return binary.rhs;
            if (isSubjectPatternComparable(binary.rhs, subject_temp_name)) return binary.lhs;
            return null;
        },
        else => null,
    };
}

fn isSubjectPatternComparable(expr: *const typed.Expr, subject_temp_name: []const u8) bool {
    return isSubjectTemp(expr, subject_temp_name) or isSubjectTag(expr, subject_temp_name);
}

fn isSubjectTemp(expr: *const typed.Expr, subject_temp_name: []const u8) bool {
    return switch (expr.node) {
        .identifier => |name| std.mem.eql(u8, name, subject_temp_name),
        else => false,
    };
}

fn isSubjectTag(expr: *const typed.Expr, subject_temp_name: []const u8) bool {
    return switch (expr.node) {
        .field => |field| std.mem.eql(u8, field.field_name, "tag") and isSubjectTemp(field.base, subject_temp_name),
        else => false,
    };
}
