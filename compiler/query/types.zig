const borrow = @import("../borrow/root.zig");
const boundary_checks = @import("boundary_checks.zig");
const checked_body = @import("checked_body.zig");
const const_ir = @import("const_ir.zig");
const domain_state_body = @import("domain_state_body.zig");
const lifetimes = @import("../lifetimes/root.zig");
const ownership = @import("../ownership/root.zig");
const reflect = @import("../reflect/root.zig");
const regions = @import("../regions/root.zig");
const intern = @import("../intern/root.zig");
const session_ids = @import("../session/ids.zig");
const domain_state = @import("../typed/domain_state.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");

pub const QueryFamily = enum {
    signature,
    body,
    statements,
    expressions,
    module_signature,
    const_eval,
    associated_const_eval,
    reflection,
    runtime_reflections,
    module_reflections,
    package_reflections,
    module_boundary_apis,
    trait_goal,
    impl_index,
    impl_lookup,
    local_const,
    callables,
    patterns,
    send,
    ownership,
    borrow,
    lifetimes,
    regions,
    domain_state_item,
    domain_state_body,
};

pub const ConstExpr = const_ir.Expr;

pub const CanonicalTypeHead = union(enum) {
    builtin: types.Builtin,
    item: session_ids.ItemId,
    generic_param: intern.SymbolId,
    opaque_name: intern.SymbolId,
};

pub const CanonicalTraitHead = union(enum) {
    builtin_send,
    trait_item: session_ids.TraitId,
    opaque_name: intern.SymbolId,
};

pub const TraitGoalKey = struct {
    module_id: session_ids.ModuleId,
    trait_head: CanonicalTraitHead,
    self_head: CanonicalTypeHead,
    self_type_symbol: intern.SymbolId,
    where_env_symbol: intern.SymbolId,
};

pub const ImplLookupKey = struct {
    module_id: session_ids.ModuleId,
    trait_head: CanonicalTraitHead,
    self_head: CanonicalTypeHead,
};

pub const ImplIndexEntry = struct {
    module_id: session_ids.ModuleId,
    trait_head: CanonicalTraitHead,
    self_head: CanonicalTypeHead,
    impl_id: session_ids.ImplId,
};

pub const ImplIndexResult = struct {
    entries: []const ImplIndexEntry,
};

pub const ImplLookupResult = struct {
    key: ImplLookupKey,
    impl_ids: []const session_ids.ImplId,
};

pub const TraitGoalResult = struct {
    key: TraitGoalKey,
    satisfied: bool,
    impl_id: ?session_ids.ImplId = null,
    inherited_default_method_count: usize = 0,
};

pub const LocalConstSummary = struct {
    checked_count: usize = 0,
    rejected_count: usize = 0,
    checked_array_repetition_lengths: usize = 0,
    rejected_array_repetition_lengths: usize = 0,
};

pub const LocalConstResult = struct {
    body_id: session_ids.BodyId,
    summary: LocalConstSummary,
};

pub const CallableSummary = struct {
    checked_function_value_count: usize = 0,
    rejected_generic_function_values: usize = 0,
    rejected_borrow_parameter_function_values: usize = 0,
    checked_dispatch_count: usize = 0,
    rejected_dispatch_count: usize = 0,
    rejected_arity_count: usize = 0,
    rejected_arg_count: usize = 0,
    rejected_suspend_context_count: usize = 0,
};

pub const CallableResult = struct {
    body_id: session_ids.BodyId,
    summary: CallableSummary,
};

pub const PatternSummary = struct {
    checked_subject_pattern_count: usize = 0,
    irrefutable_subject_pattern_count: usize = 0,
    rejected_unreachable_pattern_count: usize = 0,
    rejected_non_exhaustive_pattern_count: usize = 0,
    rejected_structural_pattern_count: usize = 0,
    checked_constant_pattern_count: usize = 0,
    rejected_constant_pattern_count: usize = 0,
    checked_repeat_iteration_count: usize = 0,
    rejected_repeat_iterable_count: usize = 0,
};

pub const PatternResult = struct {
    body_id: session_ids.BodyId,
    summary: PatternSummary,
};

pub const StatementSummary = struct {
    checked_statement_count: usize = 0,
    prepared_issue_count: usize = 0,
};

pub const StatementResult = struct {
    body_id: session_ids.BodyId,
    summary: StatementSummary,
};

pub const ExpressionSummary = struct {
    checked_expression_count: usize = 0,
    prepared_issue_count: usize = 0,
    checked_conversion_count: usize = 0,
    rejected_conversion_count: usize = 0,
};

pub const ExpressionResult = struct {
    body_id: session_ids.BodyId,
    summary: ExpressionSummary,
    conversion_facts: []const CheckedConversionFact = &.{},

    pub fn deinit(self: ExpressionResult, allocator: @import("std").mem.Allocator) void {
        if (self.conversion_facts.len != 0) allocator.free(self.conversion_facts);
    }
};

pub const ConversionMode = enum {
    implicit,
    explicit_infallible,
    explicit_checked,
};

pub const ConversionStatus = enum {
    accepted,
    rejected,
};

pub const CheckedConversionFact = struct {
    expression_id: checked_body.ExpressionId,
    mode: ConversionMode,
    source_type: types.TypeRef,
    target_type: types.TypeRef,
    result_type: types.TypeRef,
    status: ConversionStatus,
    diagnostic_code: ?[]const u8 = null,
};

pub const ModuleSignatureSummary = struct {
    prepared_issue_count: usize = 0,
};

pub const ModuleSignatureResult = struct {
    module_id: session_ids.ModuleId,
    summary: ModuleSignatureSummary,
};

pub const SendSummary = struct {
    rejected_callable_count: usize = 0,
    rejected_input_count: usize = 0,
    rejected_output_count: usize = 0,
};

pub const SendResult = struct {
    body_id: session_ids.BodyId,
    summary: SendSummary,
};

pub const FunctionSignature = struct {
    is_suspend: bool,
    foreign: bool,
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    parameters: []const typed.Parameter,
    return_type_name: []const u8,
    return_type: types.TypeRef,
    export_name: ?[]const u8,
    abi: ?[]const u8,
};

pub const ConstSignature = struct {
    type_name: []const u8,
    ty: types.Builtin,
    type_ref: types.TypeRef,
    initializer_source: []const u8,
    expr: ?*const const_ir.Expr,
    lower_error: ?anyerror = null,
};

pub const StructSignature = struct {
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    fields: []const typed.StructField,
};

pub const UnionSignature = struct {
    fields: []const typed.StructField,
};

pub const EnumSignature = struct {
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    variants: []const typed.EnumVariant,
};

pub const OpaqueTypeSignature = struct {
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
};

pub const TraitSignature = struct {
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    methods: []const typed.TraitMethod,
    associated_types: []const typed.TraitAssociatedType,
    associated_consts: []const typed.TraitAssociatedConst,
};

pub const AssociatedConstBindingSignature = struct {
    name: []const u8,
    const_item: ConstSignature,
};

pub const ImplSignature = struct {
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    target_type: []const u8,
    trait_name: ?[]const u8,
    associated_types: []const typed.TraitAssociatedTypeBinding,
    associated_consts: []const AssociatedConstBindingSignature,
    methods: []const typed.TraitMethod,
};

pub const SignatureFacts = union(enum) {
    none,
    function: FunctionSignature,
    const_item: ConstSignature,
    struct_type: StructSignature,
    union_type: UnionSignature,
    enum_type: EnumSignature,
    opaque_type: OpaqueTypeSignature,
    trait_type: TraitSignature,
    impl_block: ImplSignature,
};

pub const CheckedSignature = struct {
    item_id: session_ids.ItemId,
    module_id: session_ids.ModuleId,
    item: *const typed.Item,
    boundary_kind: boundary_checks.BoundaryKind,
    domain_signature: domain_state.ItemSignature,
    reflectable: bool,
    exported: bool,
    unsafe_required: bool,
    facts: SignatureFacts,

    pub fn deinit(self: CheckedSignature, allocator: @import("std").mem.Allocator) void {
        switch (self.facts) {
            .const_item => |const_item| {
                if (const_item.expr) |expr| const_ir.destroyExpr(allocator, expr);
            },
            .impl_block => |impl_block| {
                for (impl_block.associated_consts) |binding| {
                    if (binding.const_item.expr) |expr| const_ir.destroyExpr(allocator, expr);
                }
                if (impl_block.associated_consts.len != 0) allocator.free(impl_block.associated_consts);
            },
            else => {},
        }
    }
};

pub const CheckedBody = struct {
    body_id: session_ids.BodyId,
    item_id: session_ids.ItemId,
    module_id: session_ids.ModuleId,
    module: *const typed.Module,
    item: *const typed.Item,
    function: *const typed.FunctionData,
    parameters: []const typed.Parameter,
    root_block_id: usize,
    block_sites: []const checked_body.BlockSite,
    statement_sites: []const checked_body.StatementSite,
    summary: checked_body.Summary,
    places: []const checked_body.CanonicalPlace,
    cfg_edges: []const checked_body.CfgEdge,
    effect_sites: []const checked_body.EffectSite,
    suspension_sites: []const checked_body.SuspensionSite,
    spawn_sites: []const checked_body.SpawnSite,
    function_value_sites: []const checked_body.FunctionValueSite,
    callable_dispatch_sites: []const checked_body.CallableDispatchSite,
    subject_pattern_sites: []const checked_body.SubjectPatternSite,
    unreachable_pattern_sites: []const checked_body.UnreachablePatternSite,
    pattern_diagnostic_sites: []const checked_body.PatternDiagnosticSite,
    repeat_iteration_sites: []const checked_body.RepeatIterationSite,
    lexical_scopes: []const checked_body.LexicalScope,
    local_const_decl_sites: []const checked_body.LocalConstDeclSite,
    array_repetition_length_sites: []const checked_body.ArrayRepetitionLengthSite,
    call_argument_sites: []const checked_body.CallArgumentSite,
    constructor_argument_sites: []const checked_body.ConstructorArgumentSite,
    return_value_sites: []const checked_body.ReturnValueSite,
    expression_sites: []const checked_body.ExpressionSite,

    pub fn deinit(self: CheckedBody, allocator: @import("std").mem.Allocator) void {
        const facts = checked_body.Facts{
            .summary = self.summary,
            .root_block_id = self.root_block_id,
            .block_sites = self.block_sites,
            .statement_sites = self.statement_sites,
            .places = self.places,
            .cfg_edges = self.cfg_edges,
            .effect_sites = self.effect_sites,
            .suspension_sites = self.suspension_sites,
            .spawn_sites = self.spawn_sites,
            .function_value_sites = self.function_value_sites,
            .callable_dispatch_sites = self.callable_dispatch_sites,
            .subject_pattern_sites = self.subject_pattern_sites,
            .unreachable_pattern_sites = self.unreachable_pattern_sites,
            .pattern_diagnostic_sites = self.pattern_diagnostic_sites,
            .repeat_iteration_sites = self.repeat_iteration_sites,
            .lexical_scopes = self.lexical_scopes,
            .local_const_decl_sites = self.local_const_decl_sites,
            .array_repetition_length_sites = self.array_repetition_length_sites,
            .call_argument_sites = self.call_argument_sites,
            .constructor_argument_sites = self.constructor_argument_sites,
            .return_value_sites = self.return_value_sites,
            .expression_sites = self.expression_sites,
        };
        facts.deinit(allocator);
    }
};

pub const ReflectionMetadata = struct {
    reflection_id: session_ids.ReflectionId,
    item_id: session_ids.ItemId,
    metadata: reflect.ItemMetadata,
};

pub const RuntimeReflectionResult = struct {
    metadata: []const reflect.ItemMetadata,
};

pub const ModuleReflectionResult = struct {
    module_id: session_ids.ModuleId,
    metadata: []const reflect.ItemMetadata,
};

pub const PackageReflectionResult = struct {
    package_id: session_ids.PackageId,
    metadata: []const reflect.ItemMetadata,
};

pub const BoundaryApiMetadata = struct {
    item_id: session_ids.ItemId,
    name: []const u8,
    is_suspend: bool,
    parameters: []const typed.Parameter,
    return_type: types.TypeRef,
    export_name: ?[]const u8,
};

pub const ModuleBoundaryApiResult = struct {
    module_id: session_ids.ModuleId,
    apis: []const BoundaryApiMetadata,
};

pub const OwnershipResult = struct {
    body_id: session_ids.BodyId,
    summary: ownership.BodySummary,
};

pub const BorrowResult = struct {
    body_id: session_ids.BodyId,
    summary: borrow.BodySummary,
};

pub const LifetimeResult = struct {
    body_id: session_ids.BodyId,
    summary: lifetimes.BodySummary,
};

pub const RegionResult = struct {
    body_id: session_ids.BodyId,
    summary: regions.BodySummary,
};

pub const DomainStateItemResult = struct {
    item_id: session_ids.ItemId,
    signature: domain_state.ItemSignature,
};

pub const DomainStateBodyResult = struct {
    body_id: session_ids.BodyId,
    domain_item: ?session_ids.ItemId = null,
    summary: domain_state_body.Summary = .{},
};

pub const ConstResult = struct {
    const_id: session_ids.ConstId,
    value: const_ir.Value,
};

pub const AssociatedConstResult = struct {
    associated_const_id: session_ids.AssociatedConstId,
    value: const_ir.Value,
};
