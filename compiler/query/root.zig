const std = @import("std");
const borrow = @import("../borrow/root.zig");
const boundary_checks = @import("boundary_checks.zig");
pub const checked_body = @import("checked_body.zig");
const callable_checks = @import("callable_checks.zig");
const coherence_checks = @import("coherence_checks.zig");
const const_contexts = @import("const_contexts.zig");
const const_ir = @import("const_ir.zig");
const const_eval = @import("const_eval.zig");
const diag = @import("../diag/root.zig");
const domain_state_body = @import("domain_state_body.zig");
const domain_state_checks = @import("domain_state_checks.zig");
const expression_checks = @import("expression_checks.zig");
const lifetimes = @import("../lifetimes/root.zig");
const local_const_checks = @import("local_const_checks.zig");
const mir = @import("../mir/root.zig");
const ownership = @import("../ownership/root.zig");
const pattern_checks = @import("pattern_checks.zig");
const reflect = @import("../reflect/root.zig");
const resolve = @import("../resolve/root.zig");
const regions = @import("../regions/root.zig");
const session = @import("../session/root.zig");
const send_checks = @import("send_checks.zig");
const statement_checks = @import("statement_checks.zig");
const trait_solver = @import("trait_solver.zig");
const typed = @import("../typed/root.zig");
const query_types = @import("types.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Demand-driven compiler queries with session-owned ids and caches.";

pub const QueryFamily = query_types.QueryFamily;
pub const BoundaryKind = @import("boundary_checks.zig").BoundaryKind;
pub const CheckedSignature = query_types.CheckedSignature;
pub const CheckedBody = query_types.CheckedBody;
pub const ReflectionMetadata = query_types.ReflectionMetadata;
pub const RuntimeReflectionResult = query_types.RuntimeReflectionResult;
pub const ModuleReflectionResult = query_types.ModuleReflectionResult;
pub const PackageReflectionResult = query_types.PackageReflectionResult;
pub const OwnershipResult = query_types.OwnershipResult;
pub const BorrowResult = query_types.BorrowResult;
pub const LifetimeResult = query_types.LifetimeResult;
pub const RegionResult = query_types.RegionResult;
pub const SendResult = query_types.SendResult;
pub const CallableResult = query_types.CallableResult;
pub const PatternResult = query_types.PatternResult;
pub const StatementResult = query_types.StatementResult;
pub const ExpressionResult = query_types.ExpressionResult;
pub const ModuleSignatureResult = query_types.ModuleSignatureResult;
pub const DomainStateItemResult = query_types.DomainStateItemResult;
pub const DomainStateBodyResult = query_types.DomainStateBodyResult;
pub const ConstResult = query_types.ConstResult;
pub const ConstExpr = query_types.ConstExpr;
pub const TraitGoalResult = query_types.TraitGoalResult;
pub const LocalConstResult = query_types.LocalConstResult;

pub const testing = if (@import("builtin").is_test) struct {
    pub fn findItemIdByName(active: *const session.Session, name: []const u8) ?session.ItemId {
        return lookupItemIdByName(active, name);
    }

    pub fn findConstIdByName(active: *const session.Session, name: []const u8) ?session.ConstId {
        return lookupConstIdByName(active, name);
    }

    pub fn evalConstByName(active: *session.Session, name: []const u8) !const_ir.Value {
        return evalConstByNameForTesting(active, name);
    }

    pub fn findTopLevel(active: *const session.Session, name: []const u8) ?resolve.Symbol {
        return lookupTopLevel(active, name);
    }

    pub fn internedName(active: *const session.Session, id: @import("../intern/root.zig").SymbolId) ?[]const u8 {
        return active.internedName(id);
    }

    pub fn traitGoalKeyByName(
        active: *session.Session,
        module_id: session.ModuleId,
        self_type_name: []const u8,
        trait_name: []const u8,
        where_predicates: []const typed.WherePredicate,
    ) !query_types.TraitGoalKey {
        return trait_solver.traitGoalKeyFromNames(active, module_id, self_type_name, trait_name, where_predicates);
    }
} else struct {};

pub fn checkedSignature(active: *session.Session, item_id: session.ItemId) !CheckedSignature {
    var entry = &active.caches.signatures[item_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.signature, item_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const item_entry = active.semantic_index.itemEntry(item_id);
    const item = active.item(item_id);
    const boundary_kind = boundary_checks.kindForItem(item);
    const facts = try signatureFactsForItem(active.allocator, item);
    var value = CheckedSignature{
        .item_id = item_id,
        .module_id = item_entry.module_id,
        .item = item,
        .boundary_kind = boundary_kind,
        .domain_signature = domain_state_checks.signatureForItem(active, item_entry.module_id, item, facts),
        .reflectable = item.is_reflectable,
        .exported = item.visibility == .pub_item,
        .unsafe_required = item.is_unsafe,
        .facts = facts,
    };
    var value_owned = true;
    errdefer if (value_owned) value.deinit(active.allocator);
    try replayDeferredDiagnostics(&active.pipeline.diagnostics, item.signature_diagnostics);
    try validateSemanticAttributes(item, &active.pipeline.diagnostics);
    try boundary_checks.validateItem(item, &active.pipeline.diagnostics);
    try boundary_checks.validateSignature(active, value, &active.pipeline.diagnostics, checkedSignature);
    try domain_state_checks.validateSignature(active, value, &active.pipeline.diagnostics);
    _ = try const_contexts.validateSignature(active, value, &active.pipeline.diagnostics, resolveConstIdentifier);

    entry.value = value;
    value_owned = false;
    entry.state = .complete;
    return value;
}

fn replayDeferredDiagnostics(diagnostics: *diag.Bag, deferred: []const diag.Diagnostic) !void {
    for (deferred) |diagnostic| {
        try diagnostics.add(diagnostic.severity, diagnostic.code, diagnostic.span, "{s}", .{diagnostic.message});
    }
}

fn validateSemanticAttributes(item: *const typed.Item, diagnostics: *diag.Bag) !void {
    if (item.is_domain_root and item.kind != .struct_type) {
        try diagnostics.add(.@"error", "type.domain_root.target", item.span, "#domain_root is valid only on struct declarations", .{});
    }
    if (item.is_domain_context and item.kind != .struct_type) {
        try diagnostics.add(.@"error", "type.domain_context.target", item.span, "#domain_context is valid only on struct declarations", .{});
    }
    if (item.is_domain_root and item.is_domain_context) {
        try diagnostics.add(.@"error", "type.domain_attr.conflict", item.span, "a declaration may not be both #domain_root and #domain_context", .{});
    }

    if (!item.is_reflectable) return;
    for (item.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "reflect")) continue;
        const after_name_start = if (attribute.raw.len > 0 and attribute.raw[0] == '#') "reflect".len + 1 else "reflect".len;
        if (attribute.raw.len > after_name_start and std.mem.trim(u8, attribute.raw[after_name_start..], " \t\r\n").len != 0) {
            try diagnostics.add(.@"error", "type.reflect.args", attribute.span, "#reflect is a bare attribute and does not take arguments", .{});
        }
    }

    if (item.visibility != .pub_item) {
        try diagnostics.add(.@"error", "type.reflect.exported", item.span, "#reflect runtime metadata requires an exported declaration", .{});
    }

    switch (item.kind) {
        .function,
        .suspend_function,
        .foreign_function,
        .const_item,
        .struct_type,
        .enum_type,
        .opaque_type,
        => {},
        else => try diagnostics.add(.@"error", "type.reflect.target", item.span, "#reflect is not valid on this declaration kind", .{}),
    }
}

pub fn checkedBody(active: *session.Session, body_id: session.BodyId) !CheckedBody {
    var entry = &active.caches.bodies[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.body, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = active.body(body_id);
    const facts = try checked_body.buildFacts(
        active.allocator,
        body.function,
        body.item.body_diagnostics,
        CheckedCallableResolver{ .active = active, .module_id = body.module_id },
    );
    const value = CheckedBody{
        .body_id = body_id,
        .item_id = body.item_id,
        .module_id = body.module_id,
        .module = body.module,
        .item = body.item,
        .function = body.function,
        .parameters = body.function.parameters.items,
        .root_block_id = facts.root_block_id,
        .block_sites = facts.block_sites,
        .statement_sites = facts.statement_sites,
        .summary = facts.summary,
        .places = facts.places,
        .cfg_edges = facts.cfg_edges,
        .effect_sites = facts.effect_sites,
        .suspension_sites = facts.suspension_sites,
        .spawn_sites = facts.spawn_sites,
        .function_value_sites = facts.function_value_sites,
        .callable_dispatch_sites = facts.callable_dispatch_sites,
        .subject_pattern_sites = facts.subject_pattern_sites,
        .unreachable_pattern_sites = facts.unreachable_pattern_sites,
        .pattern_diagnostic_sites = facts.pattern_diagnostic_sites,
        .repeat_iteration_sites = facts.repeat_iteration_sites,
        .lexical_scopes = facts.lexical_scopes,
        .local_const_decl_sites = facts.local_const_decl_sites,
        .array_repetition_length_sites = facts.array_repetition_length_sites,
        .call_argument_sites = facts.call_argument_sites,
        .constructor_argument_sites = facts.constructor_argument_sites,
        .return_value_sites = facts.return_value_sites,
        .expression_sites = facts.expression_sites,
        .diagnostic_sites = facts.diagnostic_sites,
    };

    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn moduleSignatureDiagnostics(active: *session.Session, module_id: session.ModuleId) !ModuleSignatureResult {
    var entry = &active.caches.module_signatures[module_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.module_signature, module_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const module = active.module(module_id);
    var replayed: usize = 0;
    for (module.signature_diagnostics) |diagnostic| {
        try active.pipeline.diagnostics.add(diagnostic.severity, diagnostic.code, diagnostic.span, "{s}", .{diagnostic.message});
        replayed += 1;
    }

    const value = ModuleSignatureResult{
        .module_id = module_id,
        .summary = .{ .replayed_diagnostic_count = replayed },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn constById(active: *session.Session, const_id: session.ConstId) !ConstResult {
    var entry = &active.caches.consts[const_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.const_eval, const_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const const_entry = active.semantic_index.constEntry(const_id);
    const item_entry = active.semantic_index.itemEntry(const_entry.item_id);
    const signature = try checkedSignature(active, const_entry.item_id);
    const const_item = switch (signature.facts) {
        .const_item => |const_item| const_item,
        else => {
            entry.state = .complete;
            entry.failed = true;
            return error.NotAConst;
        },
    };
    const expr = const_item.expr orelse {
        entry.state = .complete;
        entry.failed = true;
        const err = const_item.lower_error orelse error.MissingConstExpr;
        try reportConstEvalError(active, signature.item, err);
        return err;
    };

    const value = ConstResult{
        .const_id = const_id,
        .value = const_eval.evalExpr(active, item_entry.module_id, expr, resolveConstIdentifier) catch |err| {
            try reportConstEvalError(active, signature.item, err);
            return err;
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

fn evalConstByNameForTesting(active: *session.Session, name: []const u8) !const_ir.Value {
    for (active.semantic_index.consts.items, 0..) |const_entry, index| {
        const item = active.item(const_entry.item_id);
        if (!std.mem.eql(u8, item.name, name)) continue;
        return (try constById(active, .{ .index = index })).value;
    }
    return error.UnknownConst;
}

pub fn reflectionById(active: *session.Session, reflection_id: session.ReflectionId) !ReflectionMetadata {
    var entry = &active.caches.reflections[reflection_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        try reportReflectionCycle(active, reflection_id);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.reflection, reflection_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        try reportReflectionCycle(active, reflection_id);
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const reflection_entry = active.semantic_index.reflectionEntry(reflection_id);
    const signature = try checkedSignature(active, reflection_entry.item_id);
    if (!signature.reflectable or !signature.exported) {
        entry.state = .complete;
        entry.failed = true;
        return error.UnknownReflection;
    }

    const value = ReflectionMetadata{
        .reflection_id = reflection_id,
        .item_id = reflection_entry.item_id,
        .metadata = try metadataForCheckedSignature(active, signature),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn runtimeReflectionMetadata(active: *session.Session) !RuntimeReflectionResult {
    var entry = &active.caches.runtime_reflections;
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.runtime_reflections, 0)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var all = std.array_list.Managed(reflect.ItemMetadata).init(active.allocator);
    errdefer all.deinit();

    for (active.semantic_index.reflections.items, 0..) |_, index| {
        const item = reflectionById(active, .{ .index = index }) catch |err| switch (err) {
            error.UnknownReflection, error.CachedFailure => continue,
            else => return err,
        };
        try all.append(item.metadata);
    }

    const value = RuntimeReflectionResult{
        .metadata = try all.toOwnedSlice(),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn moduleReflectionMetadata(
    active: *session.Session,
    module_id: session.ModuleId,
) !ModuleReflectionResult {
    var entry = &active.caches.module_reflections[module_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.module_reflections, module_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var all = std.array_list.Managed(reflect.ItemMetadata).init(active.allocator);
    errdefer all.deinit();

    for (active.semantic_index.reflections.items, 0..) |reflection_entry, index| {
        const item_entry = active.semantic_index.itemEntry(reflection_entry.item_id);
        if (item_entry.module_id.index != module_id.index) continue;
        const item = reflectionById(active, .{ .index = index }) catch |err| switch (err) {
            error.UnknownReflection, error.CachedFailure => continue,
            else => return err,
        };
        try all.append(item.metadata);
    }

    const value = ModuleReflectionResult{
        .module_id = module_id,
        .metadata = try all.toOwnedSlice(),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn packageReflectionMetadata(
    active: *session.Session,
    package_id: session.PackageId,
) !PackageReflectionResult {
    var entry = &active.caches.package_reflections[package_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.package_reflections, package_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var all = std.array_list.Managed(reflect.ItemMetadata).init(active.allocator);
    errdefer all.deinit();

    for (active.semantic_index.reflections.items, 0..) |reflection_entry, index| {
        const item_entry = active.semantic_index.itemEntry(reflection_entry.item_id);
        const module_entry = active.semantic_index.moduleEntry(item_entry.module_id);
        if (module_entry.package_id.index != package_id.index) continue;
        const item = reflectionById(active, .{ .index = index }) catch |err| switch (err) {
            error.UnknownReflection, error.CachedFailure => continue,
            else => return err,
        };
        try all.append(item.metadata);
    }

    const value = PackageReflectionResult{
        .package_id = package_id,
        .metadata = try all.toOwnedSlice(),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn collectRuntimeMetadata(allocator: Allocator, active: *session.Session) ![]reflect.ItemMetadata {
    const result = try runtimeReflectionMetadata(active);
    return duplicateMetadataSlice(allocator, result.metadata);
}

pub fn collectModuleRuntimeMetadata(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]reflect.ItemMetadata {
    const result = try moduleReflectionMetadata(active, module_id);
    return duplicateMetadataSlice(allocator, result.metadata);
}

pub fn collectPackageRuntimeMetadata(
    allocator: Allocator,
    active: *session.Session,
    package_id: session.PackageId,
) ![]reflect.ItemMetadata {
    const result = try packageReflectionMetadata(active, package_id);
    return duplicateMetadataSlice(allocator, result.metadata);
}

fn duplicateMetadataSlice(allocator: Allocator, metadata: []const reflect.ItemMetadata) ![]reflect.ItemMetadata {
    return allocator.dupe(reflect.ItemMetadata, metadata);
}

pub fn finalizeSemanticChecks(active: *session.Session) !void {
    for (active.semantic_index.modules.items, 0..) |_, module_index| {
        _ = try moduleSignatureDiagnostics(active, .{ .index = module_index });
    }
    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.semantic_index.items.items, 0..) |_, index| {
        _ = try checkedSignature(active, .{ .index = index });
    }

    if (active.pipeline.diagnostics.hasErrors()) return;

    try coherence_checks.validate(active, &active.pipeline.diagnostics);

    if (active.pipeline.diagnostics.hasErrors()) return;

    try trait_solver.validateImplContractsWithResolver(active, &active.pipeline.diagnostics, checkedSignature);

    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.semantic_index.consts.items, 0..) |_, index| {
        _ = constById(active, .{ .index = index }) catch |err| switch (err) {
            error.CachedFailure,
            error.QueryCycle,
            error.UnsupportedConstExpr,
            error.ConstOverflow,
            error.DivideByZero,
            error.InvalidRemainder,
            error.InvalidShiftCount,
            error.UnknownConst,
            error.NotAConst,
            error.MissingConstExpr,
            => {},
            else => return err,
        };
    }

    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.semantic_index.bodies.items, 0..) |_, index| {
        const body_id: session.BodyId = .{ .index = index };
        _ = try checkedBody(active, body_id);
        _ = try statementsByBody(active, body_id);
        _ = try expressionsByBody(active, body_id);
        _ = try callablesByBody(active, body_id);
    }
    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.semantic_index.bodies.items, 0..) |_, index| {
        const body_id: session.BodyId = .{ .index = index };
        _ = try patternsByBody(active, body_id);
    }
    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.semantic_index.bodies.items, 0..) |_, index| {
        const body_id: session.BodyId = .{ .index = index };
        _ = try localConstsByBody(active, body_id);
        if (active.pipeline.diagnostics.hasErrors()) return;
        _ = try sendByBody(active, body_id);
        if (active.pipeline.diagnostics.hasErrors()) return;
        _ = try ownershipByBody(active, body_id);
        _ = try borrowByBody(active, body_id);
        _ = try lifetimesByBody(active, body_id);
        _ = try regionsByBody(active, body_id);
        _ = try domainStateByBody(active, body_id);
        if (active.pipeline.diagnostics.hasErrors()) return;
    }

    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.pipeline.modules.items, 0..) |*module_pipeline, pipeline_module_index| {
        if (module_pipeline.mir != null) continue;

        const module_id = moduleIdForPipelineIndex(active, pipeline_module_index) orelse return error.MissingSemanticModule;
        var checked_bodies = std.array_list.Managed(CheckedBody).init(active.allocator);
        defer checked_bodies.deinit();
        for (active.semantic_index.bodies.items, 0..) |body_entry, body_index| {
            if (body_entry.module_id.index != module_id.index) continue;
            try checked_bodies.append(try checkedBody(active, .{ .index = body_index }));
        }
        module_pipeline.mir = try mir.lowerModuleFromCheckedBodies(active.allocator, module_pipeline.typed, checked_bodies.items);
    }
}

fn moduleIdForPipelineIndex(active: *const session.Session, pipeline_module_index: usize) ?session.ModuleId {
    for (active.semantic_index.modules.items, 0..) |module_entry, index| {
        if (module_entry.pipeline_index == pipeline_module_index) return .{ .index = index };
    }
    return null;
}

pub fn satisfiesTraitKey(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    where_predicates: []const typed.WherePredicate,
) !TraitGoalResult {
    return trait_solver.satisfiesTraitKeyWithResolver(active, key, where_predicates, checkedSignature);
}

fn satisfiesTrait(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !TraitGoalResult {
    return trait_solver.satisfiesTraitWithResolver(active, module_id, self_type_name, trait_name, where_predicates, checkedSignature);
}

pub fn associatedTypeEqualsKey(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    associated_name: []const u8,
    value_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !bool {
    return trait_solver.associatedTypeEqualsKeyWithResolver(
        active,
        key,
        associated_name,
        value_type_name,
        where_predicates,
        checkedSignature,
    );
}

fn associatedTypeEquals(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    associated_name: []const u8,
    value_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !bool {
    return trait_solver.associatedTypeEqualsWithResolver(
        active,
        module_id,
        self_type_name,
        trait_name,
        associated_name,
        value_type_name,
        where_predicates,
        checkedSignature,
    );
}

pub fn localConstsByBody(active: *session.Session, body_id: session.BodyId) !LocalConstResult {
    var entry = &active.caches.local_consts[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.local_const, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    _ = try expressionsByBody(active, body_id);
    const local_summary = try local_const_checks.analyzeBody(active, body, &active.pipeline.diagnostics, resolveConstIdentifier);
    const value = LocalConstResult{
        .body_id = body_id,
        .summary = .{
            .checked_count = local_summary.checked_count,
            .rejected_count = local_summary.rejected_count,
            .checked_array_repetition_lengths = local_summary.checked_array_repetition_lengths,
            .rejected_array_repetition_lengths = local_summary.rejected_array_repetition_lengths,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn statementsByBody(active: *session.Session, body_id: session.BodyId) !StatementResult {
    var entry = &active.caches.statements[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.statements, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const statement_summary = try statement_checks.analyzeBody(body, &active.pipeline.diagnostics);
    const value = StatementResult{
        .body_id = body_id,
        .summary = .{
            .checked_statement_count = statement_summary.checked_statement_count,
            .replayed_diagnostic_count = statement_summary.replayed_diagnostic_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn expressionsByBody(active: *session.Session, body_id: session.BodyId) !ExpressionResult {
    var entry = &active.caches.expressions[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.expressions, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const expression_summary = try expression_checks.analyzeBody(body, &active.pipeline.diagnostics);
    const value = ExpressionResult{
        .body_id = body_id,
        .summary = .{
            .checked_expression_count = expression_summary.checked_expression_count,
            .replayed_diagnostic_count = expression_summary.replayed_diagnostic_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn callablesByBody(active: *session.Session, body_id: session.BodyId) !CallableResult {
    var entry = &active.caches.callables[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.callables, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const callable_summary = try callable_checks.analyzeBody(active.allocator, body, &active.pipeline.diagnostics);
    const value = CallableResult{
        .body_id = body_id,
        .summary = .{
            .checked_function_value_count = callable_summary.checked_function_value_count,
            .rejected_generic_function_values = callable_summary.rejected_generic_function_values,
            .rejected_borrow_parameter_function_values = callable_summary.rejected_borrow_parameter_function_values,
            .checked_dispatch_count = callable_summary.checked_dispatch_count,
            .rejected_dispatch_count = callable_summary.rejected_dispatch_count,
            .rejected_arity_count = callable_summary.rejected_arity_count,
            .rejected_arg_count = callable_summary.rejected_arg_count,
            .rejected_suspend_context_count = callable_summary.rejected_suspend_context_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn patternsByBody(active: *session.Session, body_id: session.BodyId) !PatternResult {
    var entry = &active.caches.patterns[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.patterns, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const pattern_summary = try pattern_checks.analyzeBody(active, body, &active.pipeline.diagnostics, satisfiesTrait);
    const value = PatternResult{
        .body_id = body_id,
        .summary = .{
            .checked_subject_pattern_count = pattern_summary.checked_subject_pattern_count,
            .irrefutable_subject_pattern_count = pattern_summary.irrefutable_subject_pattern_count,
            .rejected_unreachable_pattern_count = pattern_summary.rejected_unreachable_pattern_count,
            .rejected_structural_pattern_count = pattern_summary.rejected_structural_pattern_count,
            .checked_repeat_iteration_count = pattern_summary.checked_repeat_iteration_count,
            .rejected_repeat_iterable_count = pattern_summary.rejected_repeat_iterable_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn sendByBody(active: *session.Session, body_id: session.BodyId) !SendResult {
    var entry = &active.caches.send[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.send, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const send_summary = try send_checks.analyzeBody(
        active,
        body,
        &active.pipeline.diagnostics,
        CheckedCallableResolver{ .active = active, .module_id = body.module_id },
    );
    const value = SendResult{
        .body_id = body_id,
        .summary = .{
            .rejected_callable_count = send_summary.rejected_callable_count,
            .rejected_input_count = send_summary.rejected_input_count,
            .rejected_output_count = send_summary.rejected_output_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn ownershipByBody(active: *session.Session, body_id: session.BodyId) !OwnershipResult {
    var entry = &active.caches.ownership[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.ownership, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const value = OwnershipResult{
        .body_id = body_id,
        .summary = try ownership.validateCheckedBody(
            active.allocator,
            body,
            CheckedCallableResolver{ .active = active, .module_id = body.module_id },
            &active.pipeline.diagnostics,
        ),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

const CheckedCallableResolver = struct {
    active: *session.Session,
    module_id: session.ModuleId,

    pub fn parameterMode(self: CheckedCallableResolver, callee_name: []const u8, parameter_index: usize) ?typed.ParameterMode {
        const item_id = resolveCallableItemId(self.active, self.module_id, callee_name) orelse return null;
        const signature = checkedSignature(self.active, item_id) catch return null;
        const function = switch (signature.facts) {
            .function => |function| function,
            else => return null,
        };
        if (parameter_index >= function.parameters.len) return null;
        return function.parameters[parameter_index].mode;
    }

    pub fn isSuspendFunction(self: CheckedCallableResolver, callee_name: []const u8) bool {
        const item_id = resolveCallableItemId(self.active, self.module_id, callee_name) orelse return false;
        const signature = checkedSignature(self.active, item_id) catch return false;
        return switch (signature.facts) {
            .function => |function| function.is_suspend,
            else => false,
        };
    }

    pub fn outputTypeName(self: CheckedCallableResolver, callee_name: []const u8) ?[]const u8 {
        const item_id = resolveCallableItemId(self.active, self.module_id, callee_name) orelse return null;
        const signature = checkedSignature(self.active, item_id) catch return null;
        return switch (signature.facts) {
            .function => |function| function.return_type_name,
            else => null,
        };
    }

    pub fn functionValueIssue(self: CheckedCallableResolver, function_name: []const u8) ?checked_body.FunctionValueIssue {
        const item_id = resolveCallableItemId(self.active, self.module_id, function_name) orelse return null;
        const signature = checkedSignature(self.active, item_id) catch return null;
        const function = switch (signature.facts) {
            .function => |function| function,
            else => return null,
        };
        if (function.generic_params.len != 0) return .generic;
        if (!usesOwnedPackedCallableInput(function.parameters)) return .borrow_parameter;
        return .none;
    }
};

fn usesOwnedPackedCallableInput(parameters: []const typed.Parameter) bool {
    for (parameters) |parameter| {
        if (parameter.mode != .owned and parameter.mode != .take) return false;
    }
    return true;
}

pub fn borrowByBody(active: *session.Session, body_id: session.BodyId) !BorrowResult {
    var entry = &active.caches.borrow[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.borrow, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const value = BorrowResult{
        .body_id = body_id,
        .summary = try borrow.validateCheckedBody(body, &active.pipeline.diagnostics),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn lifetimesByBody(active: *session.Session, body_id: session.BodyId) !LifetimeResult {
    var entry = &active.caches.lifetimes[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.lifetimes, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const value = LifetimeResult{
        .body_id = body_id,
        .summary = try lifetimes.validateCheckedBody(active.allocator, body, &active.pipeline.diagnostics),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn regionsByBody(active: *session.Session, body_id: session.BodyId) !RegionResult {
    var entry = &active.caches.regions[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.regions, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const value = RegionResult{
        .body_id = body_id,
        .summary = try regions.analyzeCheckedBody(active.allocator, body, &active.pipeline.diagnostics),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn domainStateByItem(active: *session.Session, item_id: session.ItemId) !DomainStateItemResult {
    var entry = &active.caches.domain_state_items[item_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.domain_state_item, item_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const signature = try checkedSignature(active, item_id);
    const value = DomainStateItemResult{
        .item_id = item_id,
        .signature = signature.domain_signature,
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn domainStateByBody(active: *session.Session, body_id: session.BodyId) !DomainStateBodyResult {
    var entry = &active.caches.domain_state_bodies[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) return error.QueryCycle;

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.domain_state_body, body_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const body = try checkedBody(active, body_id);
    const item_result = try domainStateByItem(active, body.item_id);
    const lifetime_result = try lifetimesByBody(active, body_id);
    const value = DomainStateBodyResult{
        .body_id = body_id,
        .domain_item = if (item_result.signature == .none) null else body.item_id,
        .summary = try domain_state_body.analyzeBody(active, body, lifetime_result.summary, &active.pipeline.diagnostics),
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

fn lookupItemIdByName(active: *const session.Session, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }
    return null;
}

fn lookupConstIdByName(active: *const session.Session, name: []const u8) ?session.ConstId {
    for (active.semantic_index.consts.items, 0..) |const_entry, index| {
        const item = active.item(const_entry.item_id);
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }
    return null;
}

fn resolveCallableItemId(active: *const session.Session, module_id: session.ModuleId, callee_name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (!std.mem.eql(u8, item.name, callee_name) and !std.mem.eql(u8, item.symbol_name, callee_name)) continue;
        return .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, callee_name)) continue;
        for (active.semantic_index.items.items, 0..) |_, index| {
            const item = active.item(.{ .index = index });
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return .{ .index = index };
        }
    }

    return null;
}

fn resolveConstIdentifier(active: *session.Session, module_id: session.ModuleId, name: []const u8) !const_ir.Value {
    const const_id = findConstIdInModule(active, module_id, name) orelse return error.UnknownConst;
    return (try constById(active, const_id)).value;
}

fn findConstIdInModule(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ConstId {
    for (active.semantic_index.consts.items, 0..) |const_entry, index| {
        const item_entry = active.semantic_index.itemEntry(const_entry.item_id);
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(const_entry.item_id);
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        if (binding.const_type == null) continue;
        return findConstIdBySymbol(active, binding.target_symbol);
    }

    return null;
}

fn findConstIdBySymbol(active: *const session.Session, symbol_name: []const u8) ?session.ConstId {
    for (active.semantic_index.consts.items, 0..) |const_entry, index| {
        const item = active.item(const_entry.item_id);
        if (std.mem.eql(u8, item.symbol_name, symbol_name)) return .{ .index = index };
    }
    return null;
}

fn lookupTopLevel(active: *const session.Session, name: []const u8) ?resolve.Symbol {
    for (active.pipeline.modules.items) |module| {
        if (module.resolved.find(name)) |symbol| return symbol;
    }
    return null;
}

fn reportConstEvalError(active: *session.Session, item: *const typed.Item, err: anyerror) !void {
    switch (err) {
        error.QueryCycle => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.cycle",
            item.span,
            "const '{s}' participates in cyclic const evaluation",
            .{item.name},
        ),
        error.UnsupportedConstExpr => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.expr",
            item.span,
            "const '{s}' uses an unsupported const expression",
            .{item.name},
        ),
        error.ConstOverflow => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.overflow",
            item.span,
            "const '{s}' overflows during compile-time evaluation",
            .{item.name},
        ),
        error.DivideByZero => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            item.span,
            "const '{s}' divides by zero during compile-time evaluation",
            .{item.name},
        ),
        error.InvalidRemainder => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            item.span,
            "const '{s}' uses an invalid remainder operation during compile-time evaluation",
            .{item.name},
        ),
        error.InvalidShiftCount => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            item.span,
            "const '{s}' uses an invalid shift count during compile-time evaluation",
            .{item.name},
        ),
        error.UnknownConst => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.unknown",
            item.span,
            "const '{s}' references an unknown const item",
            .{item.name},
        ),
        else => {},
    }
}

fn reportReflectionCycle(active: *session.Session, reflection_id: session.ReflectionId) !void {
    const reflection_entry = active.semantic_index.reflectionEntry(reflection_id);
    const item = active.item(reflection_entry.item_id);
    try active.pipeline.diagnostics.add(
        .@"error",
        "type.reflection.cycle",
        item.span,
        "reflection metadata query for '{s}' participates in a semantic query cycle",
        .{item.name},
    );
}

fn constValueRetainedForReflection(active: *session.Session, signature: CheckedSignature) !bool {
    switch (signature.facts) {
        .const_item => |const_item| {
            if (const_item.expr == null) return false;
            const const_id = active.semantic_index.itemEntry(signature.item_id).const_id orelse return false;
            _ = try constById(active, const_id);
            return true;
        },
        else => return false,
    }
}

fn metadataForCheckedSignature(active: *session.Session, signature: CheckedSignature) !reflect.ItemMetadata {
    var metadata = reflect.ItemMetadata{
        .name = signature.item.name,
        .kind = @tagName(signature.item.kind),
        .exported = signature.exported,
        .runtime_retained = signature.reflectable,
        .boundary_api = signature.boundary_kind == .api,
        .unsafe_item = signature.unsafe_required,
    };

    switch (signature.facts) {
        .function => |function| {
            metadata.parameters = function.parameters;
            metadata.generic_params = function.generic_params;
            metadata.parameter_count = function.parameters.len;
            metadata.take_parameter_count = parameterModeCount(function.parameters, .take);
            metadata.read_parameter_count = parameterModeCount(function.parameters, .read);
            metadata.edit_parameter_count = parameterModeCount(function.parameters, .edit);
            metadata.generic_param_count = function.generic_params.len;
            metadata.return_type_name = function.return_type_name;
        },
        .const_item => |const_item| {
            metadata.const_type_name = const_item.type_name;
            if (const_item.expr != null) {
                const const_id = active.semantic_index.itemEntry(signature.item_id).const_id orelse return error.NotAConst;
                const value = try constById(active, const_id);
                metadata.const_value_retained = true;
                metadata.const_value = value.value;
            }
        },
        .struct_type => |struct_type| {
            metadata.field_count = struct_type.fields.len;
            metadata.public_field_count = publicFieldCount(struct_type.fields);
            metadata.public_fields = try publicFields(active.allocator, struct_type.fields);
            metadata.owns_public_fields = metadata.public_fields.len != 0;
            metadata.generic_params = struct_type.generic_params;
            metadata.generic_param_count = struct_type.generic_params.len;
        },
        .enum_type => |enum_type| {
            metadata.variants = enum_type.variants;
            metadata.variant_count = enum_type.variants.len;
            metadata.variant_payload_count = variantPayloadCount(enum_type.variants);
            metadata.generic_params = enum_type.generic_params;
            metadata.generic_param_count = enum_type.generic_params.len;
        },
        .opaque_type => |opaque_type| {
            metadata.generic_params = opaque_type.generic_params;
            metadata.generic_param_count = opaque_type.generic_params.len;
            metadata.opaque_nominal_only = true;
            metadata.handle_nominal_only = signature.boundary_kind == .capability;
        },
        else => {},
    }

    return metadata;
}

fn publicFieldCount(fields: []const typed.StructField) usize {
    var count: usize = 0;
    for (fields) |field| {
        if (field.visibility == .pub_item) count += 1;
    }
    return count;
}

fn parameterModeCount(parameters: []const typed.Parameter, mode: typed.ParameterMode) usize {
    var count: usize = 0;
    for (parameters) |parameter| {
        if (parameter.mode == mode) count += 1;
    }
    return count;
}

fn publicFields(allocator: Allocator, fields: []const typed.StructField) ![]const typed.StructField {
    const count = publicFieldCount(fields);
    if (count == 0) return &.{};

    var result = try allocator.alloc(typed.StructField, count);
    errdefer allocator.free(result);

    var index: usize = 0;
    for (fields) |field| {
        if (field.visibility != .pub_item) continue;
        result[index] = field;
        index += 1;
    }
    return result;
}

fn variantPayloadCount(variants: []const typed.EnumVariant) usize {
    var count: usize = 0;
    for (variants) |variant| {
        count += switch (variant.payload) {
            .none => 0,
            .tuple_fields => |fields| fields.len,
            .named_fields => |fields| fields.len,
        };
    }
    return count;
}

fn signatureFactsForItem(allocator: Allocator, item: *const typed.Item) !query_types.SignatureFacts {
    return switch (item.payload) {
        .none => .none,
        .function => |*function| .{ .function = .{
            .is_suspend = function.is_suspend,
            .foreign = function.foreign,
            .generic_params = function.generic_params,
            .where_predicates = function.where_predicates,
            .parameters = function.parameters.items,
            .return_type_name = function.return_type_name,
            .return_type = function.return_type,
            .export_name = function.export_name,
            .abi = function.abi,
        } },
        .const_item => |*const_item| .{ .const_item = try constSignatureForItem(allocator, const_item) },
        .struct_type => |*struct_type| .{ .struct_type = .{
            .generic_params = struct_type.generic_params,
            .where_predicates = struct_type.where_predicates,
            .fields = struct_type.fields,
        } },
        .union_type => |*union_type| .{ .union_type = .{
            .fields = union_type.fields,
        } },
        .enum_type => |*enum_type| .{ .enum_type = .{
            .generic_params = enum_type.generic_params,
            .where_predicates = enum_type.where_predicates,
            .variants = enum_type.variants,
        } },
        .opaque_type => |*opaque_type| .{ .opaque_type = .{
            .generic_params = opaque_type.generic_params,
            .where_predicates = opaque_type.where_predicates,
        } },
        .trait_type => |*trait_type| .{ .trait_type = .{
            .generic_params = trait_type.generic_params,
            .where_predicates = trait_type.where_predicates,
            .methods = trait_type.methods,
            .associated_types = trait_type.associated_types,
        } },
        .impl_block => |*impl_block| .{ .impl_block = .{
            .generic_params = impl_block.generic_params,
            .where_predicates = impl_block.where_predicates,
            .target_type = impl_block.target_type,
            .trait_name = impl_block.trait_name,
            .associated_types = impl_block.associated_types,
            .methods = impl_block.methods,
        } },
    };
}

fn constSignatureForItem(allocator: Allocator, const_item: *const typed.ConstData) !query_types.ConstSignature {
    var lowered: ?*const const_ir.Expr = null;
    var lower_error: ?anyerror = null;
    if (const_item.expr) |expr| {
        lowered = const_ir.lowerExpr(allocator, expr) catch |err| switch (err) {
            error.UnsupportedConstExpr,
            error.ConstOverflow,
            => blk: {
                lower_error = err;
                break :blk null;
            },
            else => return err,
        };
    }
    return .{
        .type_name = const_item.type_name,
        .ty = const_item.ty,
        .initializer_source = const_item.initializer_source,
        .expr = lowered,
        .lower_error = lower_error,
    };
}
