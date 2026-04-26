const std = @import("std");
const abi = @import("../abi/root.zig");
const ast = @import("../ast/root.zig");
const borrow = @import("../borrow/root.zig");
const boundary_checks = @import("boundary_checks.zig");
pub const checked_body = @import("checked_body.zig");
const callable_checks = @import("callable_checks.zig");
const coherence_checks = @import("coherence_checks.zig");
const const_contexts = @import("const_contexts.zig");
pub const const_ir = @import("const_ir.zig");
pub const const_eval = @import("const_eval.zig");
const body_syntax_bridge = @import("body_syntax_bridge.zig");
const body_parse = @import("body_parse.zig");
const body_syntax_lower = @import("../parse/body_syntax_lower.zig");
const diag = @import("../diag/root.zig");
const domain_state_body = @import("domain_state_body.zig");
const domain_state_checks = @import("domain_state_checks.zig");
const expression_parse = @import("expression_parse.zig");
const expression_checks = @import("expression_checks.zig");
const hir = @import("../hir/root.zig");
const item_syntax_bridge = @import("item_syntax_bridge.zig");
const lifetimes = @import("../lifetimes/root.zig");
const local_const_checks = @import("local_const_checks.zig");
const mir = @import("../mir/root.zig");
const ownership = @import("../ownership/root.zig");
const pattern_checks = @import("pattern_checks.zig");
const reflect = @import("../reflect/root.zig");
const resolve = @import("../resolve/root.zig");
const regions = @import("../regions/root.zig");
const session = @import("../session/root.zig");
const signature_syntax_checks = @import("signature_syntax_checks.zig");
const source = @import("../source/root.zig");
const send_checks = @import("send_checks.zig");
const statement_checks = @import("statement_checks.zig");
const trait_solver = @import("trait_solver.zig");
const typed = @import("../typed/root.zig");
const typed_attributes = @import("attributes.zig");
const typed_text = @import("text.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");
const query_types = @import("types.zig");
const Allocator = std.mem.Allocator;
const baseTypeName = typed_text.baseTypeName;
const builtinOfTypeRef = type_support.builtinOfTypeRef;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findMethodPrototype = type_support.findMethodPrototype;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const isPlainIdentifier = typed_text.isPlainIdentifier;
const parseExportName = typed_attributes.parseExportName;
const symbolNameForSyntheticName = typed_attributes.symbolNameForSyntheticName;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub const summary = "Demand-driven compiler queries with session-owned ids and caches.";

pub const QueryFamily = query_types.QueryFamily;
pub const BoundaryKind = @import("boundary_checks.zig").BoundaryKind;
pub const CheckedSignature = query_types.CheckedSignature;
pub const CheckedBody = query_types.CheckedBody;
pub const ReflectionMetadata = query_types.ReflectionMetadata;
pub const RuntimeReflectionResult = query_types.RuntimeReflectionResult;
pub const ModuleReflectionResult = query_types.ModuleReflectionResult;
pub const PackageReflectionResult = query_types.PackageReflectionResult;
pub const BoundaryApiMetadata = query_types.BoundaryApiMetadata;
pub const ModuleBoundaryApiResult = query_types.ModuleBoundaryApiResult;
pub const OwnershipResult = query_types.OwnershipResult;
pub const BorrowResult = query_types.BorrowResult;
pub const LifetimeResult = query_types.LifetimeResult;
pub const RegionResult = query_types.RegionResult;
pub const SendResult = query_types.SendResult;
pub const CallableResult = query_types.CallableResult;
pub const PatternResult = query_types.PatternResult;
pub const StatementResult = query_types.StatementResult;
pub const ExpressionResult = query_types.ExpressionResult;
pub const CheckedConversionFact = query_types.CheckedConversionFact;
pub const ConversionMode = query_types.ConversionMode;
pub const ConversionStatus = query_types.ConversionStatus;
pub const ModuleSignatureResult = query_types.ModuleSignatureResult;
pub const DomainStateItemResult = query_types.DomainStateItemResult;
pub const DomainStateBodyResult = query_types.DomainStateBodyResult;
pub const ConstResult = query_types.ConstResult;
pub const AssociatedConstResult = query_types.AssociatedConstResult;
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

fn markCycleFailure(entry: anytype) void {
    entry.value = null;
    entry.failed = true;
    entry.state = .complete;
}

pub fn checkedSignature(active: *session.Session, item_id: session.ItemId) !CheckedSignature {
    var entry = &active.caches.signatures[item_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    const hir_items = active.pipeline.modules.items[item_entry.pipeline_module_index].hir.items.items;
    const source_item: ?hir.Item = if (!item.is_synthetic and item_entry.item_index < hir_items.len) hir_items[item_entry.item_index] else null;
    if (source_item) |syntax_item| {
        try signature_syntax_checks.validateItemSyntax(active.allocator, syntax_item, item, &active.pipeline.diagnostics);
    }
    const facts = try buildCheckedSignatureFacts(active, item_entry.module_id, item, source_item, &active.pipeline.diagnostics);
    const const_required_expr_sites = try buildConstRequiredExprSites(active, item_entry.module_id, item, facts, &active.pipeline.diagnostics);
    var value = CheckedSignature{
        .item_id = item_id,
        .module_id = item_entry.module_id,
        .item = item,
        .boundary_kind = boundary_kind,
        .domain_signature = domain_state_checks.signatureForItem(active, item_entry.module_id, item, facts),
        .reflectable = item.is_reflectable,
        .exported = item.visibility == .pub_item,
        .unsafe_required = item.is_unsafe,
        .const_required_expr_sites = const_required_expr_sites,
        .facts = facts,
    };
    var value_owned = true;
    errdefer if (value_owned) value.deinit(active.allocator);
    try validateSemanticAttributes(item, &active.pipeline.diagnostics);
    try validateSignatureSemantics(active, value, &active.pipeline.diagnostics);
    try boundary_checks.validateItem(item, &active.pipeline.diagnostics);
    try boundary_checks.validateSignature(active, value, &active.pipeline.diagnostics, checkedSignature);
    try domain_state_checks.validateSignature(active, value, &active.pipeline.diagnostics);
    _ = try const_contexts.validateSignature(active, value, &active.pipeline.diagnostics, resolveConstIdentifier, resolveAssociatedConstIdentifier);

    entry.value = value;
    value_owned = false;
    entry.state = .complete;
    return value;
}

fn validateSemanticAttributes(item: *const typed.Item, diagnostics: *diag.Bag) !void {
    for (item.attributes) |attribute| {
        if (!typed_attributes.isAllowedAttribute(attribute.name)) {
            try diagnostics.add(.@"error", "type.attr.unknown", attribute.span, "unknown attribute '{s}'", .{attribute.name});
        }
    }

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

const TraitMethodSource = enum {
    local,
    imported,
};

const ResolvedTraitMethods = struct {
    source: TraitMethodSource,
    methods: []const typed.TraitMethod,
};

const SeenMethodKind = enum {
    executable,
    imported,
};

const SeenMethod = struct {
    target_type: []const u8,
    method_name: []const u8,
    kind: SeenMethodKind,
    function_symbol: ?[]const u8 = null,
};

fn validateSignatureSemantics(active: *session.Session, checked: CheckedSignature, diagnostics: *diag.Bag) anyerror!void {
    try validateItemShape(checked.item, diagnostics);

    switch (checked.facts) {
        .function => |function| try validateFunctionSignatureSemantics(checked.item, function, diagnostics),
        .const_item => |const_item| try validateConstInitializerType(checked.item.span, checked.item.name, const_item, diagnostics),
        .trait_type => |trait_type| try validateTraitMethodSyntax(checked.item.span, trait_type.methods, diagnostics),
        .impl_block => |impl_block| {
            for (impl_block.associated_consts) |binding| {
                try validateConstInitializerType(checked.item.span, binding.name, binding.const_item, diagnostics);
            }
            try validateImplTraitRequirements(active, checked.module_id, checked.item.span, impl_block, diagnostics);
        },
        else => {},
    }
}

fn validateItemShape(item: *const typed.Item, diagnostics: *diag.Bag) !void {
    if ((item.kind == .function or item.kind == .suspend_function) and !item.has_body) {
        try diagnostics.add(.@"error", "type.fn.body", item.span, "functions require a body in v1", .{});
    }
    if (item.kind == .opaque_type and item.has_body) {
        try diagnostics.add(.@"error", "type.opaque.body", item.span, "opaque type declarations do not have a body", .{});
    }
}

fn validateFunctionSignatureSemantics(
    item: *const typed.Item,
    function: query_types.FunctionSignature,
    diagnostics: *diag.Bag,
) !void {
    if (!function.foreign) return;

    if (builtinOfTypeRef(function.return_type) == .unsupported) {
        try diagnostics.add(.@"error", "type.stage0.return", item.span, "unsupported stage0 foreign return type '{s}'", .{function.return_type_name});
    }
    for (function.parameters) |parameter| {
        if (builtinOfTypeRef(parameter.ty) == .unsupported) {
            try diagnostics.add(.@"error", "type.stage0.param_type", item.span, "unsupported stage0 foreign parameter type in function '{s}'", .{item.name});
        }
    }

    var typed_function = typed.FunctionData.init(diagnostics.allocator, function.is_suspend, function.foreign);
    defer typed_function.deinit(diagnostics.allocator);
    typed_function.return_type_name = function.return_type_name;
    typed_function.return_type = function.return_type;
    typed_function.export_name = function.export_name;
    typed_function.abi = function.abi;
    for (function.parameters) |parameter| try typed_function.parameters.append(parameter);
    try abi.validateForeignFunction(item.span, item.has_body, item.is_unsafe, &typed_function, diagnostics);
}

fn validateConstInitializerType(
    span: source.Span,
    const_name: []const u8,
    const_item: query_types.ConstSignature,
    diagnostics: *diag.Bag,
) !void {
    if (const_item.type_ref.isUnsupported() or const_item.initializer_type_ref.isUnsupported()) return;
    if (const_item.initializer_type_ref.eql(const_item.type_ref)) return;
    try diagnostics.add(.@"error", "type.const.mismatch", span, "const '{s}' initializer type does not match declared type", .{const_name});
}

fn validateTraitMethodSyntax(
    span: source.Span,
    methods: []const typed.TraitMethod,
    diagnostics: *diag.Bag,
) anyerror!void {
    for (methods) |method| {
        if (method.syntax != null) continue;
        try diagnostics.add(.@"error", "type.method.syntax.missing", span, "trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
            method.name,
        });
    }
}

fn validateImplTraitRequirements(
    active: *session.Session,
    module_id: session.ModuleId,
    span: source.Span,
    impl_block: query_types.ImplSignature,
    diagnostics: *diag.Bag,
) anyerror!void {
    const trait_name = impl_block.trait_name orelse return;
    const resolved = try resolveTraitMethods(active, module_id, trait_name) orelse return;
    for (resolved.methods) |trait_method| {
        if (implContainsTraitMethod(impl_block.methods, trait_method.name)) continue;
        if (trait_method.has_default_body) {
            if (trait_method.syntax != null) continue;
            switch (resolved.source) {
                .local => try diagnostics.add(.@"error", "type.method.syntax.missing", span, "default trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
                    trait_method.name,
                }),
                .imported => try diagnostics.add(.@"error", "type.method.syntax.missing", span, "imported default trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
                    trait_method.name,
                }),
            }
            continue;
        }
        try diagnostics.add(.@"error", "type.impl.method_missing", span, "trait impl for '{s}' is missing required method '{s}'", .{
            impl_block.target_type,
            trait_method.name,
        });
    }
}

pub fn checkedBody(active: *session.Session, body_id: session.BodyId) !CheckedBody {
    var entry = &active.caches.bodies[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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

    const body_entry = active.semantic_index.bodyEntry(body_id);
    const body = active.body(body_id);
    const item_entry = active.semantic_index.itemEntry(body.item_id);
    const source_item = active.pipeline.modules.items[item_entry.pipeline_module_index].hir.items.items[item_entry.item_index];
    const signature = try checkedSignature(active, body.item_id);
    const function_signature = switch (signature.facts) {
        .function => |function| function,
        else => {
            entry.state = .complete;
            entry.failed = true;
            return error.NotABody;
        },
    };

    const owned_function = try buildFunctionForCheckedBody(active.allocator, source_item, function_signature);
    errdefer {
        owned_function.deinit(active.allocator);
        active.allocator.destroy(owned_function);
    }

    const imported_method_prototypes = try buildImportedMethodPrototypes(
        active.allocator,
        active,
        body_entry.module_id,
        true,
        &active.pipeline.diagnostics,
    );
    defer deinitMethodPrototypes(active.allocator, imported_method_prototypes);
    const synthesized_default_methods = try buildSynthesizedDefaultMethods(
        active.allocator,
        active,
        body_entry.module_id,
        imported_method_prototypes,
        &active.pipeline.diagnostics,
    );
    defer deinitSynthesizedDefaultMethods(active.allocator, synthesized_default_methods);
    const local_methods = try buildDeclaredExecutableMethods(
        active.allocator,
        active,
        body_entry.module_id,
        &active.pipeline.diagnostics,
    );
    defer deinitOwnedExecutableMethods(active.allocator, local_methods);

    var global_scope = body_parse.Scope.init(active.allocator);
    defer global_scope.deinit();
    try seedBodyGlobalScope(active, body_entry.module_id, &global_scope);

    const function_prototypes = try buildResolvedFunctionPrototypes(active.allocator, active, body_entry.module_id);
    errdefer deinitFunctionPrototypes(active.allocator, function_prototypes);
    const method_prototypes = try buildResolvedMethodPrototypes(
        active.allocator,
        imported_method_prototypes,
        local_methods,
        synthesized_default_methods,
    );
    errdefer deinitMethodPrototypes(active.allocator, method_prototypes);
    const module_consts = try buildModuleConstBindings(active.allocator, active, body_entry.module_id);
    errdefer if (module_consts.len != 0) active.allocator.free(module_consts);
    const struct_prototypes = try buildResolvedStructPrototypes(active.allocator, active, body_entry.module_id);
    errdefer if (struct_prototypes.len != 0) active.allocator.free(struct_prototypes);
    const enum_prototypes = try buildResolvedEnumPrototypes(active.allocator, active, body_entry.module_id);
    defer if (enum_prototypes.len != 0) active.allocator.free(enum_prototypes);

    if (body.item.kind != .foreign_function and body.item.has_body) {
        try body_parse.parseFunctionBody(
            active.allocator,
            @constCast(body.item),
            owned_function,
            function_prototypes,
            method_prototypes,
            &global_scope,
            struct_prototypes,
            enum_prototypes,
            &active.pipeline.diagnostics,
        );
    }

    const facts = try checked_body.buildFacts(
        active.allocator,
        owned_function,
        CheckedCallableResolver{ .active = active, .module_id = body.module_id },
    );
    const value = CheckedBody{
        .body_id = body_id,
        .item_id = body.item_id,
        .module_id = body.module_id,
        .module = body.module,
        .item = body.item,
        .function = owned_function,
        .owned_function = owned_function,
        .function_prototypes = function_prototypes,
        .method_prototypes = method_prototypes,
        .struct_prototypes = struct_prototypes,
        .module_consts = module_consts,
        .parameters = owned_function.parameters.items,
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
        .assignment_write_sites = facts.assignment_write_sites,
        .expression_sites = facts.expression_sites,
    };

    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn moduleSignatureDiagnostics(active: *session.Session, module_id: session.ModuleId) !ModuleSignatureResult {
    var entry = &active.caches.module_signatures[module_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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

    const issue_count = try validateModuleSignatureSemantics(active, module_id, &active.pipeline.diagnostics);

    const value = ModuleSignatureResult{
        .module_id = module_id,
        .summary = .{ .prepared_issue_count = issue_count },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

fn validateModuleSignatureSemantics(
    active: *session.Session,
    module_id: session.ModuleId,
    diagnostics: *diag.Bag,
) !usize {
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const module_pipeline = &active.pipeline.modules.items[module_entry.pipeline_index];
    var issue_count: usize = 0;
    var seen_methods = std.array_list.Managed(SeenMethod).init(active.allocator);
    defer seen_methods.deinit();

    for (module_pipeline.import_binding_sites.items, 0..) |site, index| {
        for (module_pipeline.import_binding_sites.items[0..index]) |prior| {
            if (!std.mem.eql(u8, prior.local_name, site.local_name)) continue;
            issue_count += 1;
            try diagnostics.add(.@"error", "type.import.duplicate", null, "duplicate imported name '{s}'", .{site.local_name});
            break;
        }
    }

    try validateExecutableMethodPhase(active, module_id, .local, &seen_methods, diagnostics, &issue_count);

    const imported_method_prototypes = try buildImportedMethodPrototypes(active.allocator, active, module_id, false, diagnostics);
    defer deinitMethodPrototypes(active.allocator, imported_method_prototypes);
    for (imported_method_prototypes) |prototype| {
        if (try validateImportedMethodPrototype(&seen_methods, prototype, diagnostics)) {
            issue_count += 1;
        }
    }

    try validateExecutableMethodPhase(active, module_id, .imported, &seen_methods, diagnostics, &issue_count);

    return issue_count;
}

const ExecutableMethodPhase = enum {
    local,
    imported,
};

fn validateExecutableMethodPhase(
    active: *session.Session,
    module_id: session.ModuleId,
    phase: ExecutableMethodPhase,
    seen_methods: *std.array_list.Managed(SeenMethod),
    diagnostics: *diag.Bag,
    issue_count: *usize,
) !void {
    const module = active.module(module_id);
    for (module.items.items, 0..) |_, item_index| {
        const item_id = findItemIdForModuleItem(active, module_id, item_index) orelse continue;
        const checked = checkedSignature(active, item_id) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => continue,
            else => return err,
        };
        const impl_block = switch (checked.facts) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };

        if (phase == .local) {
            for (impl_block.methods) |method| {
                if (try validateExecutableMethodSite(seen_methods, impl_block.target_type, method.name, checked.item.span, diagnostics)) {
                    issue_count.* += 1;
                }
            }
        }

        const trait_name = impl_block.trait_name orelse continue;
        const resolved = try resolveTraitMethods(active, checked.module_id, trait_name) orelse continue;
        const expected_source: TraitMethodSource = switch (phase) {
            .local => .local,
            .imported => .imported,
        };
        if (resolved.source != expected_source) continue;

        for (resolved.methods) |trait_method| {
            if (implContainsTraitMethod(impl_block.methods, trait_method.name)) continue;
            if (!trait_method.has_default_body or trait_method.syntax == null) continue;
            if (try validateExecutableMethodSite(seen_methods, impl_block.target_type, trait_method.name, checked.item.span, diagnostics)) {
                issue_count.* += 1;
            }
        }
    }
}

fn validateExecutableMethodSite(
    seen_methods: *std.array_list.Managed(SeenMethod),
    target_type: []const u8,
    method_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
) !bool {
    if (findSeenMethod(seen_methods.items, target_type, method_name) != null) {
        try diagnostics.add(.@"error", "type.method.duplicate", span, "duplicate executable method '{s}.{s}' in stage0", .{
            target_type,
            method_name,
        });
        return true;
    }
    try seen_methods.append(.{
        .target_type = target_type,
        .method_name = method_name,
        .kind = .executable,
    });
    return false;
}

fn validateImportedMethodPrototype(
    seen_methods: *std.array_list.Managed(SeenMethod),
    prototype: typed.MethodPrototype,
    diagnostics: *diag.Bag,
) !bool {
    if (findSeenMethod(seen_methods.items, prototype.target_type, prototype.method_name)) |existing| {
        if (existing.kind == .imported and existing.function_symbol != null and std.mem.eql(u8, existing.function_symbol.?, prototype.function_symbol)) {
            return false;
        }
        try diagnostics.add(.@"error", "type.method.duplicate", null, "duplicate imported method '{s}.{s}'", .{
            prototype.target_type,
            prototype.method_name,
        });
        return true;
    }
    try seen_methods.append(.{
        .target_type = prototype.target_type,
        .method_name = prototype.method_name,
        .kind = .imported,
        .function_symbol = prototype.function_symbol,
    });
    return false;
}

fn findSeenMethod(
    seen_methods: []const SeenMethod,
    target_type: []const u8,
    method_name: []const u8,
) ?SeenMethod {
    for (seen_methods) |seen| {
        if (!std.mem.eql(u8, seen.target_type, target_type)) continue;
        if (!std.mem.eql(u8, seen.method_name, method_name)) continue;
        return seen;
    }
    return null;
}

fn resolveTraitMethods(
    active: *session.Session,
    module_id: session.ModuleId,
    trait_name: []const u8,
) anyerror!?ResolvedTraitMethods {
    if (findLocalTraitItemId(active, module_id, trait_name)) |item_id| {
        if (try traitMethodsForItem(active, item_id)) |methods| {
            return .{
                .source = .local,
                .methods = methods,
            };
        }
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (binding.category != .trait_decl) continue;
        if (!std.mem.eql(u8, binding.local_name, trait_name)) continue;
        if (findItemIdBySymbol(active, binding.target_symbol)) |item_id| {
            if (try traitMethodsForItem(active, item_id)) |methods| {
                return .{
                    .source = .imported,
                    .methods = methods,
                };
            }
        }
        if (binding.trait_methods) |methods| {
            return .{
                .source = .imported,
                .methods = methods,
            };
        }
        return null;
    }

    return null;
}

fn traitMethodsForItem(
    active: *session.Session,
    item_id: session.ItemId,
) anyerror!?[]const typed.TraitMethod {
    const checked = checkedSignature(active, item_id) catch |err| switch (err) {
        error.CachedFailure, error.QueryCycle => return null,
        else => return err,
    };
    return switch (checked.facts) {
        .trait_type => |trait_type| trait_type.methods,
        else => null,
    };
}

fn findLocalTraitItemId(
    active: *const session.Session,
    module_id: session.ModuleId,
    trait_name: []const u8,
) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        if (item_entry.trait_id == null) continue;
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.name, trait_name)) return .{ .index = index };
    }
    return null;
}

fn findItemIdBySymbol(active: *const session.Session, symbol_name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item = active.item(.{ .index = index });
        if (std.mem.eql(u8, item.symbol_name, symbol_name)) return .{ .index = index };
    }
    return null;
}

fn findItemIdForModuleItem(
    active: *const session.Session,
    module_id: session.ModuleId,
    item_index: usize,
) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        if (item_entry.item_index != item_index) continue;
        return .{ .index = index };
    }

    return null;
}

fn implContainsTraitMethod(methods: []const typed.TraitMethod, method_name: []const u8) bool {
    for (methods) |method| {
        if (std.mem.eql(u8, method.name, method_name)) return true;
    }
    return false;
}

pub fn constById(active: *session.Session, const_id: session.ConstId) !ConstResult {
    var entry = &active.caches.consts[const_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
        .value = const_eval.evalExprWithAssociated(active, item_entry.module_id, expr, resolveConstIdentifier, resolveAssociatedConstIdentifier, checkedSignature) catch |err| {
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

pub fn associatedConstById(active: *session.Session, associated_const_id: session.AssociatedConstId) !AssociatedConstResult {
    var entry = &active.caches.associated_consts[associated_const_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.associated_const_eval, associated_const_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const associated_entry = active.semantic_index.associatedConstEntry(associated_const_id);
    const item_entry = active.semantic_index.itemEntry(associated_entry.item_id);
    const signature = try checkedSignature(active, associated_entry.item_id);
    const binding = switch (signature.facts) {
        .impl_block => |impl_block| if (associated_entry.associated_index < impl_block.associated_consts.len)
            impl_block.associated_consts[associated_entry.associated_index]
        else
            return error.NotAConst,
        .trait_type => {
            entry.state = .complete;
            entry.failed = true;
            return error.MissingConstExpr;
        },
        else => {
            entry.state = .complete;
            entry.failed = true;
            return error.NotAConst;
        },
    };

    const expr = binding.const_item.expr orelse {
        entry.state = .complete;
        entry.failed = true;
        const err = binding.const_item.lower_error orelse error.MissingConstExpr;
        try reportAssociatedConstEvalError(active, signature.item, binding.name, err);
        return err;
    };

    const value = AssociatedConstResult{
        .associated_const_id = associated_const_id,
        .value = const_eval.evalExprWithAssociated(active, item_entry.module_id, expr, resolveConstIdentifier, resolveAssociatedConstIdentifier, checkedSignature) catch |err| {
            try reportAssociatedConstEvalError(active, signature.item, binding.name, err);
            return err;
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn reflectionById(active: *session.Session, reflection_id: session.ReflectionId) !ReflectionMetadata {
    var entry = &active.caches.reflections[reflection_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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

pub fn moduleBoundaryApiMetadata(
    active: *session.Session,
    module_id: session.ModuleId,
) !ModuleBoundaryApiResult {
    var entry = &active.caches.module_boundary_apis[module_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.module_boundary_apis, module_id.index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var all = std.array_list.Managed(BoundaryApiMetadata).init(active.allocator);
    errdefer all.deinit();

    for (active.semantic_index.items.items, 0..) |item_entry, item_index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const signature = checkedSignature(active, .{ .index = item_index }) catch |err| switch (err) {
            error.CachedFailure => continue,
            else => return err,
        };
        if (!signature.exported or signature.boundary_kind != .api) continue;
        const function = switch (signature.facts) {
            .function => |function| function,
            else => continue,
        };
        try all.append(.{
            .item_id = signature.item_id,
            .name = signature.item.name,
            .is_suspend = function.is_suspend,
            .parameters = function.parameters,
            .return_type = function.return_type,
            .export_name = function.export_name,
        });
    }

    const value = ModuleBoundaryApiResult{
        .module_id = module_id,
        .apis = try all.toOwnedSlice(),
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

pub fn collectModuleBoundaryApiMetadata(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]BoundaryApiMetadata {
    const result = try moduleBoundaryApiMetadata(active, module_id);
    return allocator.dupe(BoundaryApiMetadata, result.apis);
}

fn duplicateMetadataSlice(allocator: Allocator, metadata: []const reflect.ItemMetadata) ![]reflect.ItemMetadata {
    return allocator.dupe(reflect.ItemMetadata, metadata);
}

pub fn finalizeSemanticChecks(active: *session.Session) !void {
    for (active.semantic_index.modules.items, 0..) |_, module_index| {
        _ = try moduleSignatureDiagnostics(active, .{ .index = module_index });
    }

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
            error.ConstIndexOutOfRange,
            error.NegativeArrayLength,
            error.InvalidConversion,
            error.UnknownConst,
            error.AmbiguousAssociatedConst,
            error.NotAConst,
            error.MissingConstExpr,
            => {},
            else => return err,
        };
    }

    for (active.semantic_index.associated_consts.items, 0..) |associated_entry, index| {
        const item = active.item(associated_entry.item_id);
        if (item.kind != .impl_block) continue;
        _ = associatedConstById(active, .{ .index = index }) catch |err| switch (err) {
            error.CachedFailure,
            error.QueryCycle,
            error.UnsupportedConstExpr,
            error.ConstOverflow,
            error.DivideByZero,
            error.InvalidRemainder,
            error.InvalidShiftCount,
            error.ConstIndexOutOfRange,
            error.NegativeArrayLength,
            error.InvalidConversion,
            error.UnknownConst,
            error.AmbiguousAssociatedConst,
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
        _ = try ownershipByBody(active, body_id);
        _ = try borrowByBody(active, body_id);
        _ = try lifetimesByBody(active, body_id);
        _ = try regionsByBody(active, body_id);
        _ = try domainStateByBody(active, body_id);
        _ = try sendByBody(active, body_id);
        if (active.pipeline.diagnostics.hasErrors()) return;
    }

    if (active.pipeline.diagnostics.hasErrors()) return;

    for (active.pipeline.modules.items, 0..) |*module_pipeline, pipeline_module_index| {
        if (module_pipeline.mir != null) continue;

        const module_id = moduleIdForPipelineIndex(active, pipeline_module_index) orelse return error.MissingSemanticModule;
        var checked_signatures = std.array_list.Managed(CheckedSignature).init(active.allocator);
        defer checked_signatures.deinit();
        for (active.semantic_index.items.items, 0..) |item_entry, item_index| {
            if (item_entry.module_id.index != module_id.index) continue;
            try checked_signatures.append(try checkedSignature(active, .{ .index = item_index }));
        }

        var checked_bodies = std.array_list.Managed(CheckedBody).init(active.allocator);
        defer checked_bodies.deinit();
        for (active.semantic_index.bodies.items, 0..) |body_entry, body_index| {
            if (body_entry.module_id.index != module_id.index) continue;
            try checked_bodies.append(try checkedBody(active, .{ .index = body_index }));
        }
        const module = active.module(module_id);
        const mir_imports = try buildMirImportInputs(active.allocator, module.imports.items);
        defer deinitMirImportInputs(active.allocator, mir_imports);
        module_pipeline.mir = try mir.lowerModuleFromCheckedFacts(active.allocator, .{
            .file_id = module.file_id,
            .module_path = module.module_path,
            .imports = mir_imports,
        }, checked_signatures.items, checked_bodies.items);
        try appendExecutableMethodMirItems(
            active.allocator,
            active,
            module_id,
            &module_pipeline.mir.?,
            &active.pipeline.diagnostics,
        );
        for (active.semantic_index.bodies.items, 0..) |body_entry, body_index| {
            if (body_entry.module_id.index != module_id.index) continue;
            if (active.caches.bodies[body_index].value) |*cached_body| {
                cached_body.owned_function = null;
            }
        }
    }
}

fn moduleIdForPipelineIndex(active: *const session.Session, pipeline_module_index: usize) ?session.ModuleId {
    for (active.semantic_index.modules.items, 0..) |module_entry, index| {
        if (module_entry.pipeline_index == pipeline_module_index) return .{ .index = index };
    }
    return null;
}

fn buildMirImportInputs(allocator: Allocator, imports: []const typed.ImportedBinding) ![]mir.ImportedBinding {
    const cloned = try allocator.alloc(mir.ImportedBinding, imports.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |binding| binding.deinit(allocator);
        allocator.free(cloned);
    }

    for (imports, 0..) |binding, index| {
        cloned[index] = try duplicateMirImportInput(allocator, binding);
        initialized += 1;
    }
    return cloned;
}

fn deinitMirImportInputs(allocator: Allocator, imports: []mir.ImportedBinding) void {
    for (imports) |binding| binding.deinit(allocator);
    allocator.free(imports);
}

fn duplicateMirImportInput(allocator: Allocator, binding: typed.ImportedBinding) !mir.ImportedBinding {
    var cloned = mir.ImportedBinding{
        .local_name = binding.local_name,
        .target_name = binding.target_name,
        .target_symbol = binding.target_symbol,
        .category = binding.category,
        .const_type = binding.const_type,
        .function_return_type = binding.function_return_type,
        .function_is_suspend = binding.function_is_suspend,
    };
    errdefer cloned.deinit(allocator);

    cloned.function_generic_params = if (binding.function_generic_params.len != 0)
        try allocator.dupe(typed.GenericParam, binding.function_generic_params)
    else
        &.{};
    cloned.function_where_predicates = if (binding.function_where_predicates.len != 0)
        try allocator.dupe(typed.WherePredicate, binding.function_where_predicates)
    else
        &.{};
    cloned.function_parameter_types = if (binding.function_parameter_types) |values|
        try allocator.dupe(types.TypeRef, values)
    else
        null;
    cloned.function_parameter_type_names = if (binding.function_parameter_type_names) |values|
        try allocator.dupe([]const u8, values)
    else
        null;
    cloned.function_parameter_modes = if (binding.function_parameter_modes) |values|
        try allocator.dupe(typed.ParameterMode, values)
    else
        null;
    cloned.struct_fields = if (binding.struct_fields) |fields|
        try allocator.dupe(typed.StructField, fields)
    else
        null;
    cloned.enum_variants = if (binding.enum_variants) |variants|
        try duplicateMirEnumVariants(allocator, variants)
    else
        null;
    cloned.trait_methods = if (binding.trait_methods) |methods|
        try duplicateMirTraitMethods(allocator, methods)
    else
        null;

    return cloned;
}

fn duplicateMirEnumVariants(allocator: Allocator, variants: []typed.EnumVariant) ![]typed.EnumVariant {
    const cloned = try allocator.alloc(typed.EnumVariant, variants.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*variant| variant.deinit(allocator);
        allocator.free(cloned);
    }

    for (variants, 0..) |variant, index| {
        cloned[index] = try duplicateMirEnumVariant(allocator, variant);
        initialized += 1;
    }
    return cloned;
}

fn duplicateMirEnumVariant(allocator: Allocator, variant: typed.EnumVariant) !typed.EnumVariant {
    var cloned = typed.EnumVariant{
        .name = variant.name,
        .payload = .none,
        .discriminant = variant.discriminant,
    };
    errdefer cloned.deinit(allocator);

    cloned.payload = switch (variant.payload) {
        .none => .none,
        .tuple_fields => |tuple_fields| blk: {
            const fields = try allocator.dupe(typed.TupleField, tuple_fields);
            break :blk .{ .tuple_fields = fields };
        },
        .named_fields => |named_fields| blk: {
            const fields = try allocator.dupe(typed.StructField, named_fields);
            break :blk .{ .named_fields = fields };
        },
    };
    return cloned;
}

fn duplicateMirTraitMethods(allocator: Allocator, methods: []typed.TraitMethod) ![]typed.TraitMethod {
    const cloned = try allocator.alloc(typed.TraitMethod, methods.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*method| method.deinit(allocator);
        allocator.free(cloned);
    }

    for (methods, 0..) |method, index| {
        cloned[index] = try duplicateMirTraitMethod(allocator, method);
        initialized += 1;
    }
    return cloned;
}

fn duplicateMirTraitMethod(allocator: Allocator, method: typed.TraitMethod) !typed.TraitMethod {
    var cloned = typed.TraitMethod{
        .name = method.name,
        .is_suspend = method.is_suspend,
        .has_default_body = method.has_default_body,
    };
    errdefer cloned.deinit(allocator);

    cloned.generic_params = if (method.generic_params.len != 0)
        try allocator.dupe(typed.GenericParam, method.generic_params)
    else
        &.{};
    cloned.where_predicates = if (method.where_predicates.len != 0)
        try allocator.dupe(typed.WherePredicate, method.where_predicates)
    else
        &.{};
    cloned.syntax = if (method.syntax) |syntax| try syntax.clone(allocator) else null;
    return cloned;
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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    const local_summary = try local_const_checks.analyzeBody(
        active,
        body,
        &active.pipeline.diagnostics,
        resolveConstIdentifier,
        resolveAssociatedConstIdentifier,
        checkedSignature,
    );
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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    const statement_summary = try statement_checks.analyzeBody(active.allocator, body, &active.pipeline.diagnostics);
    const value = StatementResult{
        .body_id = body_id,
        .summary = .{
            .checked_statement_count = statement_summary.checked_statement_count,
            .prepared_issue_count = statement_summary.prepared_issue_count,
        },
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn expressionsByBody(active: *session.Session, body_id: session.BodyId) !ExpressionResult {
    var entry = &active.caches.expressions[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    const expression_result = try expression_checks.analyzeBody(active, active.allocator, body, &active.pipeline.diagnostics);
    const value = ExpressionResult{
        .body_id = body_id,
        .summary = .{
            .checked_expression_count = expression_result.summary.checked_expression_count,
            .prepared_issue_count = expression_result.summary.prepared_issue_count,
            .checked_conversion_count = expression_result.summary.checked_conversion_count,
            .rejected_conversion_count = expression_result.summary.rejected_conversion_count,
        },
        .conversion_facts = expression_result.conversion_facts,
    };
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn callablesByBody(active: *session.Session, body_id: session.BodyId) !CallableResult {
    var entry = &active.caches.callables[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    const pattern_summary = try pattern_checks.analyzeBody(active, body, &active.pipeline.diagnostics, satisfiesTrait, checkedSignature, constById, resolveAssociatedConstIdentifier);
    const value = PatternResult{
        .body_id = body_id,
        .summary = .{
            .checked_subject_pattern_count = pattern_summary.checked_subject_pattern_count,
            .irrefutable_subject_pattern_count = pattern_summary.irrefutable_subject_pattern_count,
            .rejected_unreachable_pattern_count = pattern_summary.rejected_unreachable_pattern_count,
            .rejected_non_exhaustive_pattern_count = pattern_summary.rejected_non_exhaustive_pattern_count,
            .rejected_structural_pattern_count = pattern_summary.rejected_structural_pattern_count,
            .checked_constant_pattern_count = pattern_summary.checked_constant_pattern_count,
            .rejected_constant_pattern_count = pattern_summary.rejected_constant_pattern_count,
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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
        .summary = try borrow.validateCheckedBody(
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

pub fn lifetimesByBody(active: *session.Session, body_id: session.BodyId) !LifetimeResult {
    var entry = &active.caches.lifetimes[body_id.index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

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

fn resolveAssociatedConstIdentifier(
    active: *session.Session,
    module_id: session.ModuleId,
    owner_name: []const u8,
    const_name: []const u8,
) !const_ir.Value {
    const associated_const_id = try findAssociatedConstIdInModule(active, module_id, owner_name, const_name);
    return (try associatedConstById(active, associated_const_id)).value;
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

fn findAssociatedConstIdInModule(
    active: *session.Session,
    module_id: session.ModuleId,
    owner_name: []const u8,
    const_name: []const u8,
) !session.AssociatedConstId {
    var found: ?session.AssociatedConstId = null;
    const owner_base = baseTypeName(owner_name);
    for (active.semantic_index.associated_consts.items, 0..) |associated_entry, index| {
        const item_entry = active.semantic_index.itemEntry(associated_entry.item_id);
        if (item_entry.module_id.index != module_id.index) continue;
        const signature = checkedSignature(active, associated_entry.item_id) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => continue,
            else => return err,
        };
        const impl_block = switch (signature.facts) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        if (!std.mem.eql(u8, baseTypeName(impl_block.target_type), owner_base)) continue;
        if (associated_entry.associated_index >= impl_block.associated_consts.len) continue;
        const binding = impl_block.associated_consts[associated_entry.associated_index];
        if (!std.mem.eql(u8, binding.name, const_name)) continue;
        if (found != null) return error.AmbiguousAssociatedConst;
        found = .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |imported| {
        if (!std.mem.eql(u8, imported.local_name, owner_base)) continue;
        for (active.semantic_index.associated_consts.items, 0..) |associated_entry, index| {
            const signature = checkedSignature(active, associated_entry.item_id) catch |err| switch (err) {
                error.CachedFailure, error.QueryCycle => continue,
                else => return err,
            };
            const impl_block = switch (signature.facts) {
                .impl_block => |impl_block| impl_block,
                else => continue,
            };
            if (!std.mem.eql(u8, baseTypeName(impl_block.target_type), owner_base)) continue;
            if (associated_entry.associated_index >= impl_block.associated_consts.len) continue;
            const binding = impl_block.associated_consts[associated_entry.associated_index];
            if (!std.mem.eql(u8, binding.name, const_name)) continue;
            if (found != null) return error.AmbiguousAssociatedConst;
            found = .{ .index = index };
        }
    }

    return found orelse error.UnknownConst;
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
        error.ConstIndexOutOfRange => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.index",
            item.span,
            "const '{s}' indexes outside a compile-time array value",
            .{item.name},
        ),
        error.NegativeArrayLength => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.array_length_negative",
            item.span,
            "const '{s}' uses a negative compile-time array length",
            .{item.name},
        ),
        error.UnknownConst => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.unknown",
            item.span,
            "const '{s}' references an unknown const item",
            .{item.name},
        ),
        error.AmbiguousAssociatedConst => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.associated_ambiguous",
            item.span,
            "const '{s}' references an ambiguous associated const",
            .{item.name},
        ),
        error.InvalidConversion => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.conversion",
            item.span,
            "const '{s}' uses an invalid compile-time conversion",
            .{item.name},
        ),
        else => {},
    }
}

fn reportAssociatedConstEvalError(active: *session.Session, item: *const typed.Item, associated_name: []const u8, err: anyerror) !void {
    switch (err) {
        error.QueryCycle => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.cycle",
            item.span,
            "associated const '{s}' participates in cyclic const evaluation",
            .{associated_name},
        ),
        error.UnsupportedConstExpr => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.expr",
            item.span,
            "associated const '{s}' uses an unsupported const expression",
            .{associated_name},
        ),
        error.ConstOverflow => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.overflow",
            item.span,
            "associated const '{s}' overflows during compile-time evaluation",
            .{associated_name},
        ),
        error.DivideByZero => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            item.span,
            "associated const '{s}' divides by zero during compile-time evaluation",
            .{associated_name},
        ),
        error.InvalidRemainder => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            item.span,
            "associated const '{s}' uses an invalid remainder operation during compile-time evaluation",
            .{associated_name},
        ),
        error.InvalidShiftCount => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            item.span,
            "associated const '{s}' uses an invalid shift count during compile-time evaluation",
            .{associated_name},
        ),
        error.ConstIndexOutOfRange => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.index",
            item.span,
            "associated const '{s}' indexes outside a compile-time array value",
            .{associated_name},
        ),
        error.NegativeArrayLength => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.array_length_negative",
            item.span,
            "associated const '{s}' uses a negative compile-time array length",
            .{associated_name},
        ),
        error.UnknownConst => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.unknown",
            item.span,
            "associated const '{s}' references an unknown const item",
            .{associated_name},
        ),
        error.AmbiguousAssociatedConst => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.associated_ambiguous",
            item.span,
            "associated const '{s}' references an ambiguous associated const",
            .{associated_name},
        ),
        error.InvalidConversion => try active.pipeline.diagnostics.add(
            .@"error",
            "type.const.conversion",
            item.span,
            "associated const '{s}' uses an invalid compile-time conversion",
            .{associated_name},
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

const QueryStructPrototype = struct {
    name: []const u8,
    symbol_name: []const u8,
    fields: []const typed.StructField,
    owns_fields: bool = false,
};

const QueryEnumPrototype = struct {
    name: []const u8,
    symbol_name: []const u8,
    variants: []const typed.EnumVariant,
    owns_variants: bool = false,
};

const OwnedExecutableMethod = struct {
    target_type: []const u8,
    method_name: []const u8,
    function_name: []const u8,
    symbol_name: []const u8,
    span: source.Span,
    receiver_mode: typed.MethodReceiverMode,
    function: ?*typed.FunctionData,

    fn deinit(self: *OwnedExecutableMethod, allocator: Allocator) void {
        if (self.function) |function| {
            function.deinit(allocator);
            allocator.destroy(function);
        }
        // Checked-body call sites borrow these names directly, so they need
        // session lifetime instead of builder-scope lifetime.
        self.* = undefined;
    }
};

fn buildFunctionForCheckedBody(
    allocator: Allocator,
    source_item: hir.Item,
    signature: query_types.FunctionSignature,
) !*typed.FunctionData {
    const cloned = try allocator.create(typed.FunctionData);
    errdefer allocator.destroy(cloned);
    cloned.* = typed.FunctionData.init(allocator, signature.is_suspend, signature.foreign);
    errdefer cloned.deinit(allocator);

    cloned.generic_params = if (signature.generic_params.len != 0)
        try allocator.dupe(typed.GenericParam, signature.generic_params)
    else
        &.{};
    cloned.where_predicates = if (signature.where_predicates.len != 0)
        try allocator.dupe(typed.WherePredicate, signature.where_predicates)
    else
        &.{};
    for (signature.parameters) |parameter| try cloned.parameters.append(parameter);
    cloned.return_type_name = signature.return_type_name;
    cloned.return_type = signature.return_type;
    if (source_item.block_syntax) |block_syntax| cloned.block_syntax = try block_syntax.clone(allocator);
    cloned.export_name = signature.export_name;
    cloned.abi = signature.abi;
    return cloned;
}

fn duplicateFunctionPrototype(allocator: Allocator, prototype: typed.FunctionPrototype) !typed.FunctionPrototype {
    return .{
        .name = prototype.name,
        .target_name = prototype.target_name,
        .target_symbol = prototype.target_symbol,
        .return_type = prototype.return_type,
        .generic_params = if (prototype.generic_params.len != 0) try allocator.dupe(typed.GenericParam, prototype.generic_params) else &.{},
        .where_predicates = if (prototype.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, prototype.where_predicates) else &.{},
        .is_suspend = prototype.is_suspend,
        .parameter_types = try allocator.dupe(types.TypeRef, prototype.parameter_types),
        .parameter_type_names = try allocator.dupe([]const u8, prototype.parameter_type_names),
        .parameter_modes = try allocator.dupe(typed.ParameterMode, prototype.parameter_modes),
        .unsafe_required = prototype.unsafe_required,
    };
}

fn duplicateMethodPrototype(allocator: Allocator, prototype: typed.MethodPrototype) !typed.MethodPrototype {
    return .{
        .target_type = prototype.target_type,
        .method_name = prototype.method_name,
        .function_name = prototype.function_name,
        .function_symbol = prototype.function_symbol,
        .receiver_mode = prototype.receiver_mode,
        .return_type = prototype.return_type,
        .generic_params = if (prototype.generic_params.len != 0) try allocator.dupe(typed.GenericParam, prototype.generic_params) else &.{},
        .where_predicates = if (prototype.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, prototype.where_predicates) else &.{},
        .is_suspend = prototype.is_suspend,
        .parameter_types = try allocator.dupe(types.TypeRef, prototype.parameter_types),
        .parameter_type_names = try allocator.dupe([]const u8, prototype.parameter_type_names),
        .parameter_modes = try allocator.dupe(typed.ParameterMode, prototype.parameter_modes),
    };
}

fn cloneFunctionPrototypeFromSignature(
    allocator: Allocator,
    base: typed.FunctionPrototype,
    signature: query_types.FunctionSignature,
) !typed.FunctionPrototype {
    const parameter_types = try allocator.alloc(types.TypeRef, signature.parameters.len);
    errdefer allocator.free(parameter_types);
    const parameter_type_names = try allocator.alloc([]const u8, signature.parameters.len);
    errdefer allocator.free(parameter_type_names);
    const parameter_modes = try allocator.alloc(typed.ParameterMode, signature.parameters.len);
    errdefer allocator.free(parameter_modes);
    for (signature.parameters, 0..) |parameter, index| {
        parameter_types[index] = parameter.ty;
        parameter_type_names[index] = parameter.type_name;
        parameter_modes[index] = parameter.mode;
    }

    return .{
        .name = base.name,
        .target_name = base.target_name,
        .target_symbol = base.target_symbol,
        .return_type = signature.return_type,
        .generic_params = if (signature.generic_params.len != 0) try allocator.dupe(typed.GenericParam, signature.generic_params) else &.{},
        .where_predicates = if (signature.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, signature.where_predicates) else &.{},
        .is_suspend = signature.is_suspend,
        .parameter_types = parameter_types,
        .parameter_type_names = parameter_type_names,
        .parameter_modes = parameter_modes,
        .unsafe_required = base.unsafe_required,
    };
}

fn cloneMethodPrototypeFromSignature(
    allocator: Allocator,
    base: typed.MethodPrototype,
    signature: query_types.FunctionSignature,
) !typed.MethodPrototype {
    const parameter_types = try allocator.alloc(types.TypeRef, signature.parameters.len);
    errdefer allocator.free(parameter_types);
    const parameter_type_names = try allocator.alloc([]const u8, signature.parameters.len);
    errdefer allocator.free(parameter_type_names);
    const parameter_modes = try allocator.alloc(typed.ParameterMode, signature.parameters.len);
    errdefer allocator.free(parameter_modes);
    for (signature.parameters, 0..) |parameter, index| {
        parameter_types[index] = parameter.ty;
        parameter_type_names[index] = parameter.type_name;
        parameter_modes[index] = parameter.mode;
    }

    return .{
        .target_type = base.target_type,
        .method_name = base.method_name,
        .function_name = base.function_name,
        .function_symbol = base.function_symbol,
        .receiver_mode = base.receiver_mode,
        .return_type = signature.return_type,
        .generic_params = if (signature.generic_params.len != 0) try allocator.dupe(typed.GenericParam, signature.generic_params) else &.{},
        .where_predicates = if (signature.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, signature.where_predicates) else &.{},
        .is_suspend = signature.is_suspend,
        .parameter_types = parameter_types,
        .parameter_type_names = parameter_type_names,
        .parameter_modes = parameter_modes,
    };
}

fn buildImportedMethodPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    dedupe: bool,
    diagnostics: *diag.Bag,
) anyerror![]const typed.MethodPrototype {
    const module = active.module(module_id);
    var prototypes = std.array_list.Managed(typed.MethodPrototype).init(allocator);
    errdefer {
        for (prototypes.items) |prototype| {
            var owned = prototype;
            owned.deinit(allocator);
        }
        prototypes.deinit();
    }

    for (module.imports.items) |binding| {
        if (binding.category != .type_decl) continue;
        const source_item_id = findItemIdBySymbol(active, binding.target_symbol) orelse continue;
        const source_item_entry = active.semantic_index.itemEntry(source_item_id);
        const source_item = active.item(source_item_id);
        try appendImportedMethodPrototypesForBinding(
            allocator,
            active,
            source_item_entry.module_id,
            source_item,
            binding.local_name,
            dedupe,
            &prototypes,
            diagnostics,
        );
    }

    return try prototypes.toOwnedSlice();
}

fn appendImportedMethodPrototypesForBinding(
    allocator: Allocator,
    active: *session.Session,
    source_module_id: session.ModuleId,
    source_item: *const typed.Item,
    local_type_name: []const u8,
    dedupe: bool,
    prototypes: *std.array_list.Managed(typed.MethodPrototype),
    diagnostics: *diag.Bag,
) anyerror!void {
    const source_type_name = source_item.name;
    if (source_type_name.len == 0) return;
    const source_module = active.module(source_module_id);

    for (source_module.items.items, 0..) |item, item_index| {
        if (item.kind != .impl_block) continue;
        const impl_item_id = findItemIdForModuleItem(active, source_module_id, item_index) orelse continue;
        if (active.caches.signatures[impl_item_id.index].state == .in_progress) continue;
        const checked_impl = try checkedSignature(active, impl_item_id);
        const impl_block = switch (checked_impl.facts) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        if (!std.mem.eql(u8, impl_block.target_type, source_type_name)) continue;

        for (impl_block.methods) |method| {
            if (dedupe and findMethodPrototype(prototypes.items, local_type_name, method.name) != null) continue;
            const imported = (try buildImportedMethodPrototype(
                allocator,
                active,
                source_module_id,
                source_module,
                item.span,
                source_type_name,
                local_type_name,
                impl_block.generic_params,
                method,
                diagnostics,
            )) orelse continue;
            try prototypes.append(imported);
        }

        const trait_name = impl_block.trait_name orelse continue;
        const resolved = try resolveTraitMethods(active, source_module_id, trait_name) orelse continue;
        for (resolved.methods) |trait_method| {
            if (!trait_method.has_default_body) continue;
            if (implContainsMethod(impl_block.methods, trait_method.name)) continue;
            if (dedupe and findMethodPrototype(prototypes.items, local_type_name, trait_method.name) != null) continue;
            const imported = (try buildImportedMethodPrototype(
                allocator,
                active,
                source_module_id,
                source_module,
                item.span,
                source_type_name,
                local_type_name,
                impl_block.generic_params,
                trait_method,
                diagnostics,
            )) orelse continue;
            try prototypes.append(imported);
        }
    }
}

fn buildImportedMethodPrototype(
    allocator: Allocator,
    active: *session.Session,
    source_module_id: session.ModuleId,
    source_module: *const typed.Module,
    span: source.Span,
    source_type_name: []const u8,
    local_type_name: []const u8,
    inherited_generic_params: []const typed.GenericParam,
    method: typed.TraitMethod,
    diagnostics: *diag.Bag,
) !?typed.MethodPrototype {
    const parsed = (try body_syntax_bridge.parseExecutableMethodFromTraitMethod(
        allocator,
        source_type_name,
        inherited_generic_params,
        method,
        diagnostics,
    )) orelse return null;
    var function = parsed.function;
    defer function.deinit(allocator);

    try resolveExecutableMethodFunction(
        allocator,
        active,
        source_module_id,
        source_module,
        span,
        source_type_name,
        &function,
        diagnostics,
    );

    const rendered_function_name = try std.fmt.allocPrint(allocator, "{s}__{s}", .{
        source_type_name,
        parsed.method_name,
    });
    defer allocator.free(rendered_function_name);
    const function_name_id = try active.internName(rendered_function_name);
    const function_name = active.internedName(function_name_id) orelse return error.InvalidInternedName;

    const rendered_symbol_name = try symbolNameForSyntheticName(
        allocator,
        source_module.symbol_prefix,
        source_module.module_path,
        function_name,
    );
    defer allocator.free(rendered_symbol_name);
    const symbol_name_id = try active.internName(rendered_symbol_name);
    const symbol_name = active.internedName(symbol_name_id) orelse return error.InvalidInternedName;

    const parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
    errdefer allocator.free(parameter_types);
    const parameter_type_names = try allocator.alloc([]const u8, function.parameters.items.len);
    errdefer allocator.free(parameter_type_names);
    const parameter_modes = try allocator.alloc(typed.ParameterMode, function.parameters.items.len);
    errdefer allocator.free(parameter_modes);
    for (function.parameters.items, 0..) |parameter, index| {
        parameter_types[index] = remapImportedMethodType(parameter.ty, source_type_name, local_type_name);
        parameter_type_names[index] = remapImportedMethodTypeName(parameter.type_name, source_type_name, local_type_name);
        parameter_modes[index] = parameter.mode;
    }

    return .{
        .target_type = local_type_name,
        .method_name = parsed.method_name,
        .function_name = function_name,
        .function_symbol = symbol_name,
        .receiver_mode = switch (parsed.receiver_mode) {
            .take => .take,
            .read => .read,
            .edit => .edit,
            .owned => unreachable,
        },
        .return_type = remapImportedMethodType(function.return_type, source_type_name, local_type_name),
        .generic_params = if (function.generic_params.len != 0) try allocator.dupe(typed.GenericParam, function.generic_params) else &.{},
        .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, function.where_predicates) else &.{},
        .is_suspend = function.is_suspend,
        .parameter_types = parameter_types,
        .parameter_type_names = parameter_type_names,
        .parameter_modes = parameter_modes,
    };
}

fn remapImportedMethodType(ty: types.TypeRef, source_type_name: []const u8, local_type_name: []const u8) types.TypeRef {
    return switch (ty) {
        .named => |name| if (std.mem.eql(u8, name, source_type_name)) .{ .named = local_type_name } else ty,
        else => ty,
    };
}

fn remapImportedMethodTypeName(type_name: []const u8, source_type_name: []const u8, local_type_name: []const u8) []const u8 {
    return if (std.mem.eql(u8, type_name, source_type_name)) local_type_name else type_name;
}

fn buildDeclaredExecutableMethods(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    diagnostics: *diag.Bag,
) ![]OwnedExecutableMethod {
    const module = active.module(module_id);
    var declared = std.array_list.Managed(OwnedExecutableMethod).init(allocator);
    errdefer {
        for (declared.items) |*method| method.deinit(allocator);
        declared.deinit();
    }

    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .impl_block) continue;
        const impl_item_id = findItemIdForModuleItem(active, module_id, item_index) orelse continue;
        const checked_impl = try checkedSignature(active, impl_item_id);
        const impl_block = switch (checked_impl.facts) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };

        for (impl_block.methods) |method| {
            if (findOwnedExecutableMethod(declared.items, impl_block.target_type, method.name) != null) continue;

            const parsed = (try body_syntax_bridge.parseExecutableMethodFromTraitMethod(
                allocator,
                impl_block.target_type,
                impl_block.generic_params,
                method,
                diagnostics,
            )) orelse continue;

            const function = try allocator.create(typed.FunctionData);
            errdefer allocator.destroy(function);
            function.* = parsed.function;
            errdefer function.deinit(allocator);

            try resolveExecutableMethodFunction(
                allocator,
                active,
                module_id,
                module,
                item.span,
                impl_block.target_type,
                function,
                diagnostics,
            );

            const rendered_function_name = try std.fmt.allocPrint(allocator, "{s}__{s}", .{
                impl_block.target_type,
                parsed.method_name,
            });
            defer allocator.free(rendered_function_name);
            const function_name_id = try active.internName(rendered_function_name);
            const function_name = active.internedName(function_name_id) orelse return error.InvalidInternedName;

            const rendered_symbol_name = try symbolNameForSyntheticName(
                allocator,
                module.symbol_prefix,
                module.module_path,
                function_name,
            );
            defer allocator.free(rendered_symbol_name);
            const symbol_name_id = try active.internName(rendered_symbol_name);
            const symbol_name = active.internedName(symbol_name_id) orelse return error.InvalidInternedName;

            try declared.append(.{
                .target_type = impl_block.target_type,
                .method_name = parsed.method_name,
                .function_name = function_name,
                .symbol_name = symbol_name,
                .span = item.span,
                .receiver_mode = switch (parsed.receiver_mode) {
                    .take => .take,
                    .read => .read,
                    .edit => .edit,
                    .owned => unreachable,
                },
                .function = function,
            });
        }
    }

    return try declared.toOwnedSlice();
}

fn buildSynthesizedDefaultMethods(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    imported_method_prototypes: []const typed.MethodPrototype,
    diagnostics: *diag.Bag,
) ![]OwnedExecutableMethod {
    const module = active.module(module_id);
    var synthesized = std.array_list.Managed(OwnedExecutableMethod).init(allocator);
    errdefer {
        for (synthesized.items) |*method| method.deinit(allocator);
        synthesized.deinit();
    }

    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .impl_block) continue;
        const impl_item_id = findItemIdForModuleItem(active, module_id, item_index) orelse continue;
        const checked_impl = try checkedSignature(active, impl_item_id);
        const impl_block = switch (checked_impl.facts) {
            .impl_block => |impl_block| impl_block,
            else => continue,
        };
        const trait_name = impl_block.trait_name orelse continue;
        const resolved = try resolveTraitMethods(active, module_id, trait_name) orelse continue;
        for (resolved.methods) |trait_method| {
            if (!trait_method.has_default_body) continue;
            if (implContainsMethod(impl_block.methods, trait_method.name)) continue;
            if (findMethodPrototype(imported_method_prototypes, impl_block.target_type, trait_method.name) != null) continue;
            if (findOwnedExecutableMethod(synthesized.items, impl_block.target_type, trait_method.name) != null) continue;

            const parsed = (try body_syntax_bridge.parseExecutableMethodFromTraitMethod(
                allocator,
                impl_block.target_type,
                impl_block.generic_params,
                trait_method,
                diagnostics,
            )) orelse continue;

            const function = try allocator.create(typed.FunctionData);
            errdefer allocator.destroy(function);
            function.* = parsed.function;
            errdefer function.deinit(allocator);

            try resolveExecutableMethodFunction(
                allocator,
                active,
                module_id,
                module,
                item.span,
                impl_block.target_type,
                function,
                diagnostics,
            );

            const rendered_function_name = try std.fmt.allocPrint(allocator, "{s}__{s}", .{
                impl_block.target_type,
                parsed.method_name,
            });
            defer allocator.free(rendered_function_name);
            const function_name_id = try active.internName(rendered_function_name);
            const function_name = active.internedName(function_name_id) orelse return error.InvalidInternedName;

            const rendered_symbol_name = try symbolNameForSyntheticName(
                allocator,
                module.symbol_prefix,
                module.module_path,
                function_name,
            );
            defer allocator.free(rendered_symbol_name);
            const symbol_name_id = try active.internName(rendered_symbol_name);
            const symbol_name = active.internedName(symbol_name_id) orelse return error.InvalidInternedName;

            try synthesized.append(.{
                .target_type = impl_block.target_type,
                .method_name = parsed.method_name,
                .function_name = function_name,
                .symbol_name = symbol_name,
                .span = item.span,
                .receiver_mode = switch (parsed.receiver_mode) {
                    .take => .take,
                    .read => .read,
                    .edit => .edit,
                    .owned => unreachable,
                },
                .function = function,
            });
        }
    }

    return try synthesized.toOwnedSlice();
}

fn deinitSynthesizedDefaultMethods(allocator: Allocator, methods: []OwnedExecutableMethod) void {
    deinitOwnedExecutableMethods(allocator, methods);
}

fn deinitOwnedExecutableMethods(allocator: Allocator, methods: []OwnedExecutableMethod) void {
    for (methods) |*method| {
        method.deinit(allocator);
    }
    if (methods.len != 0) allocator.free(methods);
}

fn findOwnedExecutableMethod(
    methods: []const OwnedExecutableMethod,
    target_type: []const u8,
    method_name: []const u8,
) ?OwnedExecutableMethod {
    for (methods) |method| {
        if (!std.mem.eql(u8, method.target_type, target_type)) continue;
        if (!std.mem.eql(u8, method.method_name, method_name)) continue;
        return method;
    }
    return null;
}

fn implContainsMethod(methods: []const typed.TraitMethod, method_name: []const u8) bool {
    for (methods) |method| {
        if (std.mem.eql(u8, method.name, method_name)) return true;
    }
    return false;
}

fn resolveExecutableMethodFunction(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    target_type: []const u8,
    function: *typed.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = function.generic_params,
        .allow_self = true,
        .self_type_name = target_type,
    };

    for (function.parameters.items) |*parameter| {
        parameter.ty = try resolveValueTypeWithContext(parameter.type_name, context, span, diagnostics);
    }
    function.return_type = try resolveValueTypeWithContext(function.return_type_name, context, span, diagnostics);
    try validateWherePredicates(active, module_id, module, function.where_predicates, context, span, diagnostics);
}

fn methodPrototypeFromOwnedExecutableMethod(
    allocator: Allocator,
    method: OwnedExecutableMethod,
) !typed.MethodPrototype {
    const function = method.function orelse return error.InvalidMirLowering;
    const parameter_types = try allocator.alloc(types.TypeRef, function.parameters.items.len);
    errdefer allocator.free(parameter_types);
    const parameter_type_names = try allocator.alloc([]const u8, function.parameters.items.len);
    errdefer allocator.free(parameter_type_names);
    const parameter_modes = try allocator.alloc(typed.ParameterMode, function.parameters.items.len);
    errdefer allocator.free(parameter_modes);
    for (function.parameters.items, 0..) |parameter, index| {
        parameter_types[index] = parameter.ty;
        parameter_type_names[index] = parameter.type_name;
        parameter_modes[index] = parameter.mode;
    }

    return .{
        .target_type = method.target_type,
        .method_name = method.method_name,
        .function_name = method.function_name,
        .function_symbol = method.symbol_name,
        .receiver_mode = method.receiver_mode,
        .return_type = function.return_type,
        .generic_params = if (function.generic_params.len != 0) try allocator.dupe(typed.GenericParam, function.generic_params) else &.{},
        .where_predicates = if (function.where_predicates.len != 0) try allocator.dupe(typed.WherePredicate, function.where_predicates) else &.{},
        .is_suspend = function.is_suspend,
        .parameter_types = parameter_types,
        .parameter_type_names = parameter_type_names,
        .parameter_modes = parameter_modes,
    };
}

fn deinitFunctionPrototypes(allocator: Allocator, prototypes: []const typed.FunctionPrototype) void {
    for (prototypes) |prototype| {
        var owned = prototype;
        owned.deinit(allocator);
    }
    if (prototypes.len != 0) allocator.free(prototypes);
}

fn deinitMethodPrototypes(allocator: Allocator, prototypes: []const typed.MethodPrototype) void {
    for (prototypes) |prototype| {
        var owned = prototype;
        owned.deinit(allocator);
    }
    if (prototypes.len != 0) allocator.free(prototypes);
}

fn buildResolvedFunctionPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]const typed.FunctionPrototype {
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const module_pipeline = &active.pipeline.modules.items[module_entry.pipeline_index];
    if (module_pipeline.prototypes.items.len == 0) return &.{};

    const prototypes = try allocator.alloc(typed.FunctionPrototype, module_pipeline.prototypes.items.len);
    var initialized: usize = 0;
    errdefer {
        for (prototypes[0..initialized]) |prototype| {
            var owned = prototype;
            owned.deinit(allocator);
        }
        allocator.free(prototypes);
    }

    for (module_pipeline.prototypes.items, 0..) |prototype, index| {
        if (findItemIdBySymbol(active, prototype.target_symbol)) |item_id| {
            const checked = try checkedSignature(active, item_id);
            switch (checked.facts) {
                .function => |function| prototypes[index] = try cloneFunctionPrototypeFromSignature(allocator, prototype, function),
                else => prototypes[index] = try duplicateFunctionPrototype(allocator, prototype),
            }
        } else {
            prototypes[index] = try duplicateFunctionPrototype(allocator, prototype);
        }
        initialized += 1;
    }

    return prototypes;
}

fn buildResolvedMethodPrototypes(
    allocator: Allocator,
    imported_method_prototypes: []const typed.MethodPrototype,
    local_methods: []const OwnedExecutableMethod,
    synthesized_default_methods: []const OwnedExecutableMethod,
) ![]const typed.MethodPrototype {
    const total_count = imported_method_prototypes.len + local_methods.len + synthesized_default_methods.len;
    if (total_count == 0) return &.{};

    const prototypes = try allocator.alloc(typed.MethodPrototype, total_count);
    var initialized: usize = 0;
    errdefer {
        for (prototypes[0..initialized]) |prototype| {
            var owned = prototype;
            owned.deinit(allocator);
        }
        allocator.free(prototypes);
    }

    for (imported_method_prototypes, 0..) |prototype, index| {
        prototypes[index] = try duplicateMethodPrototype(allocator, prototype);
        initialized += 1;
    }

    for (local_methods, 0..) |method, local_index| {
        prototypes[imported_method_prototypes.len + local_index] = try methodPrototypeFromOwnedExecutableMethod(allocator, method);
        initialized += 1;
    }

    for (synthesized_default_methods, 0..) |method, synth_index| {
        prototypes[imported_method_prototypes.len + local_methods.len + synth_index] = try methodPrototypeFromOwnedExecutableMethod(allocator, method);
        initialized += 1;
    }

    return prototypes;
}

fn buildResolvedStructPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]const typed.StructPrototype {
    const module = active.module(module_id);
    var count: usize = 0;
    for (module.items.items) |item| {
        if (item.kind == .struct_type) count += 1;
    }
    for (module.imports.items) |binding| {
        if (binding.struct_fields != null) count += 1;
    }
    if (count == 0) return &.{};

    const prototypes = try allocator.alloc(typed.StructPrototype, count);
    var index: usize = 0;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .struct_type) continue;
        const item_id = findItemIdForModuleItem(active, module_id, item_index) orelse return error.MissingSemanticModule;
        const checked = try checkedSignature(active, item_id);
        switch (checked.facts) {
            .struct_type => |struct_type| {
                prototypes[index] = .{
                    .name = item.name,
                    .symbol_name = item.symbol_name,
                    .fields = struct_type.fields,
                };
                index += 1;
            },
            else => return error.InvalidMirLowering,
        }
    }
    for (module.imports.items) |binding| {
        const fields = binding.struct_fields orelse continue;
        prototypes[index] = .{
            .name = binding.local_name,
            .symbol_name = binding.target_symbol,
            .fields = fields,
        };
        index += 1;
    }
    return prototypes;
}

fn buildResolvedEnumPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]const typed.EnumPrototype {
    const module = active.module(module_id);
    var count: usize = 0;
    for (module.items.items) |item| {
        if (item.kind == .enum_type) count += 1;
    }
    for (module.imports.items) |binding| {
        if (binding.enum_variants != null) count += 1;
    }
    if (count == 0) return &.{};

    const prototypes = try allocator.alloc(typed.EnumPrototype, count);
    var index: usize = 0;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .enum_type) continue;
        const item_id = findItemIdForModuleItem(active, module_id, item_index) orelse return error.MissingSemanticModule;
        const checked = try checkedSignature(active, item_id);
        switch (checked.facts) {
            .enum_type => |enum_type| {
                prototypes[index] = .{
                    .name = item.name,
                    .symbol_name = item.symbol_name,
                    .variants = enum_type.variants,
                };
                index += 1;
            },
            else => return error.InvalidMirLowering,
        }
    }
    for (module.imports.items) |binding| {
        const variants = binding.enum_variants orelse continue;
        prototypes[index] = .{
            .name = binding.local_name,
            .symbol_name = binding.target_symbol,
            .variants = variants,
        };
        index += 1;
    }
    return prototypes;
}

fn seedBodyGlobalScope(
    active: *session.Session,
    module_id: session.ModuleId,
    scope: *body_parse.Scope,
) !void {
    const module = active.module(module_id);
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .const_item or item.name.len == 0) continue;
        const item_id = findItemIdForModuleItem(active, module_id, item_index) orelse continue;
        const checked = try checkedSignature(active, item_id);
        switch (checked.facts) {
            .const_item => |const_item| try scope.putConst(item.name, const_item.type_ref),
            else => {},
        }
    }
    for (module.imports.items) |binding| {
        if (binding.const_type) |ty| try scope.putConst(binding.local_name, ty);
    }
}

fn buildModuleConstBindings(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
) ![]const query_types.ModuleConstBinding {
    const module = active.module(module_id);
    var count: usize = 0;
    for (module.items.items) |item| {
        if (item.kind == .const_item and item.name.len != 0) count += 1;
    }
    for (module.imports.items) |binding| {
        if (binding.const_type != null) count += 1;
    }
    if (count == 0) return &.{};

    const bindings = try allocator.alloc(query_types.ModuleConstBinding, count);
    errdefer allocator.free(bindings);

    var index: usize = 0;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .const_item or item.name.len == 0) continue;
        const item_id = findItemIdForModuleItem(active, module_id, item_index) orelse return error.MissingSemanticModule;
        const checked = try checkedSignature(active, item_id);
        const const_item = switch (checked.facts) {
            .const_item => |const_item| const_item,
            else => return error.InvalidMirLowering,
        };
        bindings[index] = .{
            .name = item.name,
            .ty = const_item.type_ref,
        };
        index += 1;
    }
    for (module.imports.items) |binding| {
        const ty = binding.const_type orelse continue;
        bindings[index] = .{
            .name = binding.local_name,
            .ty = ty,
        };
        index += 1;
    }

    return bindings[0..index];
}

fn appendOwnedExecutableMethodMirBatch(
    allocator: Allocator,
    mir_module: *mir.Module,
    methods: []OwnedExecutableMethod,
    function_prototypes: []const typed.FunctionPrototype,
    method_prototypes: []const typed.MethodPrototype,
    global_scope: *body_parse.Scope,
    struct_prototypes: []const typed.StructPrototype,
    enum_prototypes: []const typed.EnumPrototype,
    diagnostics: *diag.Bag,
) !void {
    for (methods) |*method| {
        const function = method.function orelse continue;
        if (!function.foreign and function.block_syntax != null) {
            var temp_item = typed.Item{
                .name = method.function_name,
                .symbol_name = method.symbol_name,
                .category = .value,
                .kind = .function,
                .visibility = .private,
                .attributes = &.{},
                .span = method.span,
                .has_body = function.block_syntax != null,
                .is_synthetic = true,
                .is_reflectable = false,
                .is_boundary_api = false,
                .is_unsafe = false,
                .is_domain_root = false,
                .is_domain_context = false,
                .payload = .none,
            };
            try body_parse.parseFunctionBody(
                allocator,
                &temp_item,
                function,
                function_prototypes,
                method_prototypes,
                global_scope,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
            );
        }

        var mir_item = try mir.lowerTypedFunctionItem(
            allocator,
            method.function_name,
            method.symbol_name,
            method.span,
            function,
            false,
        );
        errdefer mir_item.deinit(allocator);
        try mir_module.items.append(mir_item);
        try mir_module.appendRetainedCheckedFunction(function);
        method.function = null;
    }
}

fn appendExecutableMethodMirItems(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    mir_module: *mir.Module,
    diagnostics: *diag.Bag,
) !void {
    const imported_method_prototypes = try buildImportedMethodPrototypes(allocator, active, module_id, true, diagnostics);
    defer deinitMethodPrototypes(allocator, imported_method_prototypes);
    const local_methods = try buildDeclaredExecutableMethods(allocator, active, module_id, diagnostics);
    defer deinitOwnedExecutableMethods(allocator, local_methods);
    const synthesized_default_methods = try buildSynthesizedDefaultMethods(
        allocator,
        active,
        module_id,
        imported_method_prototypes,
        diagnostics,
    );
    defer deinitSynthesizedDefaultMethods(allocator, synthesized_default_methods);
    if (imported_method_prototypes.len == 0 and local_methods.len == 0 and synthesized_default_methods.len == 0) return;

    var global_scope = body_parse.Scope.init(allocator);
    defer global_scope.deinit();
    try seedBodyGlobalScope(active, module_id, &global_scope);

    const function_prototypes = try buildResolvedFunctionPrototypes(allocator, active, module_id);
    defer deinitFunctionPrototypes(allocator, function_prototypes);
    const method_prototypes = try buildResolvedMethodPrototypes(
        allocator,
        imported_method_prototypes,
        local_methods,
        synthesized_default_methods,
    );
    defer deinitMethodPrototypes(allocator, method_prototypes);
    const struct_prototypes = try buildResolvedStructPrototypes(allocator, active, module_id);
    defer if (struct_prototypes.len != 0) allocator.free(struct_prototypes);
    const enum_prototypes = try buildResolvedEnumPrototypes(allocator, active, module_id);
    defer if (enum_prototypes.len != 0) allocator.free(enum_prototypes);

    try appendOwnedExecutableMethodMirBatch(
        allocator,
        mir_module,
        local_methods,
        function_prototypes,
        method_prototypes,
        &global_scope,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
    );
    try appendOwnedExecutableMethodMirBatch(
        allocator,
        mir_module,
        synthesized_default_methods,
        function_prototypes,
        method_prototypes,
        &global_scope,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
    );
}

const ConstExprScope = struct {
    allocator: Allocator,
    names: std.array_list.Managed([]const u8),
    types_list: std.array_list.Managed(types.TypeRef),
    mutable_list: std.array_list.Managed(bool),

    fn init(allocator: Allocator) ConstExprScope {
        return .{
            .allocator = allocator,
            .names = std.array_list.Managed([]const u8).init(allocator),
            .types_list = std.array_list.Managed(types.TypeRef).init(allocator),
            .mutable_list = std.array_list.Managed(bool).init(allocator),
        };
    }

    fn deinit(self: *ConstExprScope) void {
        self.names.deinit();
        self.types_list.deinit();
        self.mutable_list.deinit();
    }

    fn putConst(self: *ConstExprScope, name: []const u8, ty: types.TypeRef) !void {
        try self.names.append(name);
        try self.types_list.append(ty);
        try self.mutable_list.append(false);
    }

    pub fn get(self: *const ConstExprScope, name: []const u8) ?types.TypeRef {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.types_list.items[index];
        }
        return null;
    }

    pub fn isMutable(self: *const ConstExprScope, name: []const u8) bool {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.mutable_list.items[index];
        }
        return false;
    }

    pub fn getOrigin(self: *const ConstExprScope, name: []const u8) ?type_support.BoundaryType {
        _ = self;
        _ = name;
        return null;
    }
};

fn buildConstRequiredExprSites(
    active: *session.Session,
    module_id: session.ModuleId,
    item: *const typed.Item,
    facts: query_types.SignatureFacts,
    diagnostics: *diag.Bag,
) ![]const query_types.ConstRequiredExprSite {
    const module = active.module(module_id);
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const module_pipeline = &active.pipeline.modules.items[module_entry.pipeline_index];

    var scope = ConstExprScope.init(active.allocator);
    defer scope.deinit();
    try seedConstExprScope(active, module_id, &scope, module);

    const struct_prototypes = try buildStructPrototypes(active.allocator, active, module_id, module);
    defer deinitQueryStructPrototypes(active.allocator, struct_prototypes);
    const enum_prototypes = try buildEnumPrototypes(active.allocator, active, module_id, module);
    defer deinitQueryEnumPrototypes(active.allocator, enum_prototypes);
    const imported_method_prototypes = try buildImportedMethodPrototypes(active.allocator, active, module_id, true, diagnostics);
    defer deinitMethodPrototypes(active.allocator, imported_method_prototypes);

    var sites = std.array_list.Managed(query_types.ConstRequiredExprSite).init(active.allocator);
    errdefer {
        for (sites.items) |*site| site.deinit(active.allocator);
        sites.deinit();
    }

    switch (facts) {
        .function => |function| {
            for (function.parameters) |parameter| {
                try collectTypeConstRequiredExprSites(
                    active.allocator,
                    &sites,
                    parameter.type_name,
                    &scope,
                    module_pipeline.prototypes.items,
                    imported_method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    item.span,
                    diagnostics,
                );
            }
            try collectTypeConstRequiredExprSites(
                active.allocator,
                &sites,
                function.return_type_name,
                &scope,
                module_pipeline.prototypes.items,
                imported_method_prototypes,
                struct_prototypes,
                enum_prototypes,
                item.span,
                diagnostics,
            );
        },
        .const_item => |const_item| try collectTypeConstRequiredExprSites(
            active.allocator,
            &sites,
            const_item.type_name,
            &scope,
            module_pipeline.prototypes.items,
            imported_method_prototypes,
            struct_prototypes,
            enum_prototypes,
            item.span,
            diagnostics,
        ),
        .struct_type => |struct_type| for (struct_type.fields) |field| {
            try collectTypeConstRequiredExprSites(
                active.allocator,
                &sites,
                field.type_name,
                &scope,
                module_pipeline.prototypes.items,
                imported_method_prototypes,
                struct_prototypes,
                enum_prototypes,
                item.span,
                diagnostics,
            );
        },
        .union_type => |union_type| for (union_type.fields) |field| {
            try collectTypeConstRequiredExprSites(
                active.allocator,
                &sites,
                field.type_name,
                &scope,
                module_pipeline.prototypes.items,
                imported_method_prototypes,
                struct_prototypes,
                enum_prototypes,
                item.span,
                diagnostics,
            );
        },
        .enum_type => |enum_type| {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| for (fields) |field| {
                        try collectTypeConstRequiredExprSites(
                            active.allocator,
                            &sites,
                            field.type_name,
                            &scope,
                            module_pipeline.prototypes.items,
                            imported_method_prototypes,
                            struct_prototypes,
                            enum_prototypes,
                            item.span,
                            diagnostics,
                        );
                    },
                    .named_fields => |fields| for (fields) |field| {
                        try collectTypeConstRequiredExprSites(
                            active.allocator,
                            &sites,
                            field.type_name,
                            &scope,
                            module_pipeline.prototypes.items,
                            imported_method_prototypes,
                            struct_prototypes,
                            enum_prototypes,
                            item.span,
                            diagnostics,
                        );
                    },
                }
            }

            const discriminant_type = enumDiscriminantExpectedType(item.attributes);
            for (enum_type.variants) |variant| {
                const discriminant = variant.discriminant orelse continue;
                if (std.mem.trim(u8, discriminant, " \t").len == 0) continue;
                try appendConstRequiredExprSite(
                    active.allocator,
                    &sites,
                    .enum_discriminant,
                    discriminant,
                    variant.name,
                    discriminant_type,
                    &scope,
                    module_pipeline.prototypes.items,
                    imported_method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    item.span,
                    diagnostics,
                );
            }
        },
        .impl_block => |impl_block| {
            try collectTypeConstRequiredExprSites(
                active.allocator,
                &sites,
                impl_block.target_type,
                &scope,
                module_pipeline.prototypes.items,
                imported_method_prototypes,
                struct_prototypes,
                enum_prototypes,
                item.span,
                diagnostics,
            );
            for (impl_block.associated_types) |binding| {
                try collectTypeConstRequiredExprSites(
                    active.allocator,
                    &sites,
                    binding.value_type_name,
                    &scope,
                    module_pipeline.prototypes.items,
                    imported_method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    item.span,
                    diagnostics,
                );
            }
            for (impl_block.associated_consts) |binding| {
                try collectTypeConstRequiredExprSites(
                    active.allocator,
                    &sites,
                    binding.const_item.type_name,
                    &scope,
                    module_pipeline.prototypes.items,
                    imported_method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    item.span,
                    diagnostics,
                );
            }
        },
        .trait_type => |trait_type| {
            for (trait_type.associated_consts) |associated_const| {
                try collectTypeConstRequiredExprSites(
                    active.allocator,
                    &sites,
                    associated_const.type_name,
                    &scope,
                    module_pipeline.prototypes.items,
                    imported_method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    item.span,
                    diagnostics,
                );
            }
            for (trait_type.methods) |method| {
                const syntax = method.syntax orelse continue;
                for (syntax.signature.parameters) |parameter| {
                    if (parameter.ty) |ty| {
                        try collectTypeConstRequiredExprSites(
                            active.allocator,
                            &sites,
                            ty.text,
                            &scope,
                            module_pipeline.prototypes.items,
                            imported_method_prototypes,
                            struct_prototypes,
                            enum_prototypes,
                            item.span,
                            diagnostics,
                        );
                    }
                }
                if (syntax.signature.return_type) |return_type| {
                    try collectTypeConstRequiredExprSites(
                        active.allocator,
                        &sites,
                        return_type.text,
                        &scope,
                        module_pipeline.prototypes.items,
                        imported_method_prototypes,
                        struct_prototypes,
                        enum_prototypes,
                        item.span,
                        diagnostics,
                    );
                }
            }
        },
        .opaque_type, .none => {},
    }

    return sites.toOwnedSlice();
}

fn seedConstExprScope(active: *session.Session, module_id: session.ModuleId, scope: *ConstExprScope, module: *const typed.Module) !void {
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const source_items = active.pipeline.modules.items[module_entry.pipeline_index].hir.items.items;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .const_item or item.name.len == 0) continue;
        const source_item = source_items[item_index];
        var diagnostics = diag.Bag.init(active.allocator);
        defer diagnostics.deinit();
        var const_item = switch (source_item.syntax) {
            .const_item => |signature| try item_syntax_bridge.parseConstDataFromSyntax(active.allocator, signature, source_item.span, &diagnostics),
            else => continue,
        };
        defer const_item.deinit(active.allocator);
        try scope.putConst(item.name, const_item.type_ref);
    }
    for (module.imports.items) |binding| {
        if (binding.const_type) |ty| try scope.putConst(binding.local_name, ty);
    }
}

fn buildStructPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
) ![]const QueryStructPrototype {
    var count: usize = 0;
    for (module.items.items) |item| {
        if (item.kind == .struct_type) count += 1;
    }
    for (module.imports.items) |binding| {
        if (binding.struct_fields != null) count += 1;
    }
    if (count == 0) return &.{};

    const prototypes = try allocator.alloc(QueryStructPrototype, count);
    errdefer allocator.free(prototypes);
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const source_items = active.pipeline.modules.items[module_entry.pipeline_index].hir.items.items;
    var index: usize = 0;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .struct_type) continue;
        const source_item = source_items[item_index];
        var diagnostics = diag.Bag.init(allocator);
        defer diagnostics.deinit();
        const fields = switch (source_item.body_syntax) {
            .struct_fields => |fields| try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, source_item.name, source_item.span, &diagnostics),
            .none => try allocator.alloc(typed.StructField, 0),
            else => continue,
        };
        prototypes[index] = .{
            .name = item.name,
            .symbol_name = item.symbol_name,
            .fields = fields,
            .owns_fields = true,
        };
        index += 1;
    }
    for (module.imports.items) |binding| {
        const fields = binding.struct_fields orelse continue;
        prototypes[index] = .{
            .name = binding.local_name,
            .symbol_name = binding.target_symbol,
            .fields = fields,
        };
        index += 1;
    }
    return prototypes;
}

fn buildEnumPrototypes(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
) ![]const QueryEnumPrototype {
    var count: usize = 0;
    for (module.items.items) |item| {
        if (item.kind == .enum_type) count += 1;
    }
    for (module.imports.items) |binding| {
        if (binding.enum_variants != null) count += 1;
    }
    if (count == 0) return &.{};

    const prototypes = try allocator.alloc(QueryEnumPrototype, count);
    errdefer allocator.free(prototypes);
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const source_items = active.pipeline.modules.items[module_entry.pipeline_index].hir.items.items;
    var index: usize = 0;
    for (module.items.items, 0..) |item, item_index| {
        if (item.kind != .enum_type) continue;
        const source_item = source_items[item_index];
        var diagnostics = diag.Bag.init(allocator);
        defer diagnostics.deinit();
        const variants = switch (source_item.body_syntax) {
            .enum_variants => |variants| try body_syntax_bridge.parseEnumVariantsFromSyntax(allocator, variants, source_item.name, source_item.span, &diagnostics),
            .none => try allocator.alloc(typed.EnumVariant, 0),
            else => continue,
        };
        prototypes[index] = .{
            .name = item.name,
            .symbol_name = item.symbol_name,
            .variants = variants,
            .owns_variants = true,
        };
        index += 1;
    }
    for (module.imports.items) |binding| {
        const variants = binding.enum_variants orelse continue;
        prototypes[index] = .{
            .name = binding.local_name,
            .symbol_name = binding.target_symbol,
            .variants = variants,
        };
        index += 1;
    }
    return prototypes;
}

fn deinitQueryStructPrototypes(allocator: Allocator, prototypes: []const QueryStructPrototype) void {
    for (prototypes) |prototype| {
        if (prototype.owns_fields and prototype.fields.len != 0) allocator.free(prototype.fields);
    }
    if (prototypes.len != 0) allocator.free(prototypes);
}

fn deinitQueryEnumPrototypes(allocator: Allocator, prototypes: []const QueryEnumPrototype) void {
    for (prototypes) |prototype| {
        if (!prototype.owns_variants) continue;
        for (prototype.variants) |variant| {
            var owned = variant;
            owned.deinit(allocator);
        }
        if (prototype.variants.len != 0) allocator.free(prototype.variants);
    }
    if (prototypes.len != 0) allocator.free(prototypes);
}

fn collectTypeConstRequiredExprSites(
    allocator: Allocator,
    sites: *std.array_list.Managed(query_types.ConstRequiredExprSite),
    raw_type_name: []const u8,
    scope: *ConstExprScope,
    prototypes: []const typed.FunctionPrototype,
    method_prototypes: []const typed.MethodPrototype,
    struct_prototypes: []const QueryStructPrototype,
    enum_prototypes: []const QueryEnumPrototype,
    span: source.Span,
    diagnostics: *diag.Bag,
) anyerror!void {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t");
    if (trimmed.len == 0) return;

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse return;
        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return collectTypeConstRequiredExprSites(allocator, sites, rest["read ".len..], scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
        if (std.mem.startsWith(u8, rest, "edit ")) return collectTypeConstRequiredExprSites(allocator, sites, rest["edit ".len..], scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return collectTypeConstRequiredExprSites(allocator, sites, trimmed["read ".len..], scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
    if (std.mem.startsWith(u8, trimmed, "edit ")) return collectTypeConstRequiredExprSites(allocator, sites, trimmed["edit ".len..], scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse return;
        const element_type = std.mem.trim(u8, inner[0..separator], " \t");
        const length_expr = std.mem.trim(u8, inner[separator + 1 ..], " \t");
        if (element_type.len != 0) {
            try collectTypeConstRequiredExprSites(allocator, sites, element_type, scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
        }
        if (length_expr.len != 0) {
            try appendConstRequiredExprSite(allocator, sites, .array_length, length_expr, "", types.TypeRef.fromBuiltin(.index), scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse return;
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) return;
        const args = try splitTopLevelCommaParts(allocator, trimmed[open_index + 1 .. close_index]);
        defer allocator.free(args);
        for (args) |arg| try collectTypeConstRequiredExprSites(allocator, sites, arg, scope, prototypes, method_prototypes, struct_prototypes, enum_prototypes, span, diagnostics);
    }
}

fn appendConstRequiredExprSite(
    allocator: Allocator,
    sites: *std.array_list.Managed(query_types.ConstRequiredExprSite),
    kind: query_types.ConstRequiredExprKind,
    source_text: []const u8,
    owner_name: []const u8,
    expected_type: types.TypeRef,
    scope: *ConstExprScope,
    prototypes: []const typed.FunctionPrototype,
    method_prototypes: []const typed.MethodPrototype,
    struct_prototypes: []const QueryStructPrototype,
    enum_prototypes: []const QueryEnumPrototype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    var site = query_types.ConstRequiredExprSite{
        .kind = kind,
        .source = source_text,
        .owner_name = owner_name,
    };
    errdefer site.deinit(allocator);

    const syntax_expr = try body_syntax_lower.lowerStandaloneExprSyntax(allocator, .{
        .text = source_text,
        .span = span,
    });
    defer {
        syntax_expr.deinit(allocator);
        allocator.destroy(syntax_expr);
    }

    const parsed = expression_parse.parseExpressionSyntax(
        allocator,
        syntax_expr,
        expected_type,
        scope,
        &.{},
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        span,
        false,
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            site.lower_error = err;
            try sites.append(site);
            return;
        },
    };
    defer {
        parsed.deinit(allocator);
        allocator.destroy(parsed);
    }

    site.expr = const_ir.lowerExpr(allocator, parsed) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            site.lower_error = err;
            break :blk null;
        },
    };
    try sites.append(site);
}

fn enumDiscriminantExpectedType(attributes: []const ast.Attribute) types.TypeRef {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "repr")) continue;
        const open_index = std.mem.indexOfScalar(u8, attribute.raw, '[') orelse return types.TypeRef.fromBuiltin(.index);
        const close_index = std.mem.lastIndexOfScalar(u8, attribute.raw, ']') orelse return types.TypeRef.fromBuiltin(.index);
        if (close_index <= open_index) return types.TypeRef.fromBuiltin(.index);

        var parts = std.mem.splitScalar(u8, attribute.raw[open_index + 1 .. close_index], ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            const builtin = types.Builtin.fromName(trimmed);
            if (builtin.isInteger()) return types.TypeRef.fromBuiltin(builtin);
        }
    }
    return types.TypeRef.fromBuiltin(.index);
}

const TypeResolutionContext = struct {
    type_scope: *const NameSet,
    generic_params: []const typed.GenericParam = &.{},
    allow_self: bool = false,
    self_type_name: ?[]const u8 = null,
};

const NameSet = struct {
    allocator: Allocator,
    names: std.array_list.Managed([]const u8),

    fn init(allocator: Allocator) NameSet {
        return .{
            .allocator = allocator,
            .names = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *NameSet) void {
        self.names.deinit();
    }

    fn put(self: *NameSet, name: []const u8) !void {
        if (self.contains(name)) return;
        try self.names.append(name);
    }

    fn contains(self: *const NameSet, name: []const u8) bool {
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }
};

fn seedTypeScope(type_scope: *NameSet, module: *const typed.Module) !void {
    for (module.items.items) |item| {
        if (item.category == .type_decl or item.category == .trait_decl) {
            if (item.name.len != 0) try type_scope.put(item.name);
        }
    }
    for (module.imports.items) |binding| {
        if (binding.category == .type_decl or binding.category == .trait_decl) {
            try type_scope.put(binding.local_name);
        }
    }
}

fn isLifetimeName(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '\'') return false;
    const body = raw[1..];
    if (std.mem.eql(u8, body, "static")) return true;
    if (!(std.ascii.isAlphabetic(body[0]) or body[0] == '_')) return false;
    for (body[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isBuiltinLifetime(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "'static");
}

fn genericParamExists(generic_params: []const typed.GenericParam, name: []const u8, kind: typed.GenericParamKind) bool {
    for (generic_params) |param| {
        if (param.kind != kind) continue;
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn validateLifetimeReference(
    name: []const u8,
    generic_params: []const typed.GenericParam,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    if (!isLifetimeName(name)) {
        try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed lifetime name '{s}'", .{name});
        return;
    }
    if (isBuiltinLifetime(name) or genericParamExists(generic_params, name, .lifetime_param)) return;
    try diagnostics.add(.@"error", "type.lifetime.unknown", span, "unknown lifetime name '{s}'", .{name});
}

fn mergeGenericParams(
    allocator: Allocator,
    inherited: []const typed.GenericParam,
    local: []const typed.GenericParam,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]typed.GenericParam {
    var combined = std.array_list.Managed(typed.GenericParam).init(allocator);
    errdefer combined.deinit();

    for (inherited) |param| try combined.append(param);
    for (local) |param| {
        var duplicate = false;
        for (combined.items) |existing| {
            if (std.mem.eql(u8, existing.name, param.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.generic.param_duplicate", span, "duplicate generic or lifetime parameter '{s}'", .{param.name});
            continue;
        }
        try combined.append(param);
    }

    return combined.toOwnedSlice();
}

fn validateSimpleTypeName(name: []const u8, context: TypeResolutionContext, span: source.Span, diagnostics: *diag.Bag) !void {
    if (name.len == 0) {
        try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type name", .{});
        return;
    }
    if (types.Builtin.fromName(name) != .unsupported) return;
    if (std.mem.eql(u8, name, "Option") or std.mem.eql(u8, name, "Result") or std.mem.eql(u8, name, "ConvertError")) return;
    if (context.allow_self and std.mem.eql(u8, name, "Self")) return;
    if (genericParamExists(context.generic_params, name, .type_param)) return;
    if (context.type_scope.contains(name)) return;
    try diagnostics.add(.@"error", "type.name.unknown_type", span, "unknown type name '{s}'", .{name});
}

fn validateTypeExpression(
    raw: []const u8,
    context: TypeResolutionContext,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) {
        try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type name", .{});
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed retained-borrow syntax '{s}'", .{trimmed});
            return;
        };
        const lifetime_name = std.mem.trim(u8, trimmed["hold[".len..close_index], " \t");
        try validateLifetimeReference(lifetime_name, context.generic_params, span, diagnostics);

        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return validateTypeExpression(rest["read ".len..], context, span, diagnostics);
        if (std.mem.startsWith(u8, rest, "edit ")) return validateTypeExpression(rest["edit ".len..], context, span, diagnostics);
        if (std.mem.startsWith(u8, rest, "take ")) {
            try diagnostics.add(.@"error", "type.lifetime.hold_take", span, "retained borrows do not support 'hold[...] take T'", .{});
            return;
        }
        try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed retained-borrow syntax '{s}'", .{trimmed});
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return validateTypeExpression(trimmed["read ".len..], context, span, diagnostics);
    if (std.mem.startsWith(u8, trimmed, "edit ")) return validateTypeExpression(trimmed["edit ".len..], context, span, diagnostics);

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.array.syntax", span, "malformed fixed array type '{s}'", .{trimmed});
            return;
        };
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) {
            try diagnostics.add(.@"error", "type.array.syntax", span, "malformed fixed array type '{s}'", .{trimmed});
            return;
        }
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse {
            try diagnostics.add(.@"error", "type.array.syntax", span, "fixed array type '{s}' requires '[T; N]'", .{trimmed});
            return;
        };
        const element_type = std.mem.trim(u8, inner[0..separator], " \t");
        const length_expr = std.mem.trim(u8, inner[separator + 1 ..], " \t");
        if (element_type.len == 0 or length_expr.len == 0) {
            try diagnostics.add(.@"error", "type.array.syntax", span, "fixed array type '{s}' requires '[T; N]'", .{trimmed});
            return;
        }
        try validateTypeExpression(element_type, context, span, diagnostics);
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
            return;
        };
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) {
            try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
            return;
        }
        const base_name = std.mem.trim(u8, trimmed[0..open_index], " \t");
        try validateSimpleTypeName(base_name, context, span, diagnostics);
        const args = try splitTopLevelCommaParts(context.type_scope.allocator, trimmed[open_index + 1 .. close_index]);
        defer context.type_scope.allocator.free(args);
        for (args) |arg| {
            if (arg.len == 0) {
                try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
                continue;
            }
            if (isLifetimeName(arg)) {
                try validateLifetimeReference(arg, context.generic_params, span, diagnostics);
            } else {
                try validateTypeExpression(arg, context, span, diagnostics);
            }
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        var parts = std.mem.splitScalar(u8, trimmed, '.');
        var part_index: usize = 0;
        while (parts.next()) |part| : (part_index += 1) {
            if (part_index == 0) {
                try validateSimpleTypeName(part, context, span, diagnostics);
            } else if (!isPlainIdentifier(part)) {
                try diagnostics.add(.@"error", "type.name.syntax", span, "malformed associated type reference '{s}'", .{trimmed});
            }
        }
        return;
    }

    try validateSimpleTypeName(trimmed, context, span, diagnostics);
}

fn resolveValueTypeWithContext(
    type_name: []const u8,
    context: TypeResolutionContext,
    span: source.Span,
    diagnostics: *diag.Bag,
) !types.TypeRef {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    try validateTypeExpression(trimmed, context, span, diagnostics);

    const builtin = types.Builtin.fromName(trimmed);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    if (context.self_type_name) |self_type_name| {
        if (std.mem.eql(u8, trimmed, "Self")) return .{ .named = self_type_name };
    }
    return .{ .named = trimmed };
}

fn duplicateTypeRefIfOwned(allocator: Allocator, value: types.TypeRef) !types.TypeRef {
    return switch (value) {
        .named => |name| .{ .named = try allocator.dupe(u8, name) },
        else => value,
    };
}

fn validateWherePredicates(
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    predicates: []const typed.WherePredicate,
    context: TypeResolutionContext,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| try validateTypeExpression(bound.contract_name, context, span, diagnostics),
            .projection_equality => |projection| {
                try validateTypeExpression(projection.value_type_name, context, span, diagnostics);
                if (!projectionSubjectHasAssociatedType(active, module_id, module, predicates, projection.subject_name, projection.associated_name)) {
                    try diagnostics.add(.@"error", "type.where.associated", span, "invalid associated-output reference '{s}.{s}'", .{
                        projection.subject_name,
                        projection.associated_name,
                    });
                }
            },
            .lifetime_outlives => |outlives| {
                try validateLifetimeReference(outlives.longer_name, context.generic_params, span, diagnostics);
                try validateLifetimeReference(outlives.shorter_name, context.generic_params, span, diagnostics);
            },
            .type_outlives => |outlives| {
                try validateSimpleTypeName(outlives.type_name, context, span, diagnostics);
                try validateLifetimeReference(outlives.lifetime_name, context.generic_params, span, diagnostics);
            },
        }
    }
}

fn traitHasAssociatedType(active: *session.Session, module_id: session.ModuleId, module: *const typed.Module, trait_name: []const u8, associated_name: []const u8) bool {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.kind != .trait_type or !std.mem.eql(u8, item.name, trait_name)) continue;
        return sourceTraitHasAssociatedType(active, .{ .index = index }, associated_name);
    }
    for (module.imports.items) |binding| {
        if (binding.category != .trait_decl or !std.mem.eql(u8, binding.local_name, trait_name)) continue;
        const item_id = findItemIdBySymbol(active, binding.target_symbol) orelse return false;
        return sourceTraitHasAssociatedType(active, item_id, associated_name);
    }
    return false;
}

fn sourceTraitHasAssociatedType(active: *session.Session, item_id: session.ItemId, associated_name: []const u8) bool {
    const entry = active.semantic_index.itemEntry(item_id);
    const hir_items = active.pipeline.modules.items[entry.pipeline_module_index].hir.items.items;
    if (entry.item_index >= hir_items.len) return false;
    const source_item = hir_items[entry.item_index];
    const body = switch (source_item.body_syntax) {
        .trait_body => |body| body,
        else => return false,
    };
    for (body.associated_types) |associated_type| {
        const name = associated_type.name orelse continue;
        if (std.mem.eql(u8, name.text, associated_name)) return true;
    }
    return false;
}

fn projectionSubjectHasAssociatedType(
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    predicates: []const typed.WherePredicate,
    subject_name: []const u8,
    associated_name: []const u8,
) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| {
                if (!std.mem.eql(u8, bound.subject_name, subject_name)) continue;
                if (traitHasAssociatedType(active, module_id, module, baseTypeName(bound.contract_name), associated_name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn parseParameterMode(
    mode: ?ast.SpanText,
    span: source.Span,
    diagnostics: *diag.Bag,
) !typed.ParameterMode {
    const raw = if (mode) |value| std.mem.trim(u8, value.text, " \t") else return .owned;
    if (std.mem.eql(u8, raw, "take")) return .take;
    if (std.mem.eql(u8, raw, "read")) return .read;
    if (std.mem.eql(u8, raw, "edit")) return .edit;
    try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter mode '{s}'", .{raw});
    return .owned;
}

fn parseMethodReceiverFromSyntax(
    target_type: []const u8,
    parameter: ast.ParameterSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !?typed.Parameter {
    const name = parameter.name orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
        return null;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, name.text, " \t"), "self")) {
        try diagnostics.add(.@"error", "type.method.receiver", span, "inherent methods require an explicit self receiver", .{});
        return null;
    }

    const mode = try parseParameterMode(parameter.mode, span, diagnostics);
    const type_name = if (parameter.ty) |ty| std.mem.trim(u8, ty.text, " \t") else "";
    if (type_name.len == 0) {
        return switch (mode) {
            .take, .read, .edit => .{
                .name = "self",
                .mode = mode,
                .type_name = target_type,
                .ty = .{ .named = target_type },
            },
            .owned => {
                try diagnostics.add(.@"error", "type.method.receiver", span, "unsupported method receiver form", .{});
                return null;
            },
        };
    }

    if (mode == .take and std.mem.startsWith(u8, type_name, "hold[") and
        (std.mem.indexOf(u8, type_name, " read Self") != null or std.mem.indexOf(u8, type_name, " edit Self") != null))
    {
        return .{
            .name = "self",
            .mode = .take,
            .type_name = type_name,
            .ty = types.TypeRef.fromBuiltin(types.Builtin.fromName(type_name)),
        };
    }

    try diagnostics.add(.@"error", "type.method.receiver", span, "unsupported method receiver form", .{});
    return null;
}

fn parseOrdinaryParameterFromSyntax(
    parameter: ast.ParameterSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !?typed.Parameter {
    const name = parameter.name orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
        return null;
    };
    const ty = parameter.ty orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{name.text});
        return null;
    };

    const type_name = std.mem.trim(u8, ty.text, " \t");
    return .{
        .name = std.mem.trim(u8, name.text, " \t"),
        .mode = try parseParameterMode(parameter.mode, span, diagnostics),
        .type_name = type_name,
        .ty = types.TypeRef.fromBuiltin(types.Builtin.fromName(type_name)),
    };
}

fn validateTraitMethodSignature(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    method: *const typed.TraitMethod,
    trait_generic_params: []const typed.GenericParam,
    span: source.Span,
    type_scope: *const NameSet,
    diagnostics: *diag.Bag,
) !void {
    const generic_params = try mergeGenericParams(allocator, trait_generic_params, method.generic_params, span, diagnostics);
    defer if (generic_params.len != 0) allocator.free(generic_params);

    const context = TypeResolutionContext{
        .type_scope = type_scope,
        .generic_params = generic_params,
        .allow_self = true,
        .self_type_name = "Self",
    };

    if (method.syntax) |method_syntax| {
        var param_index: usize = 0;
        if (method_syntax.signature.parameters.len != 0) {
            const first_parameter = method_syntax.signature.parameters[0];
            if (first_parameter.name) |name| {
                if (std.mem.eql(u8, std.mem.trim(u8, name.text, " \t"), "self")) {
                    const receiver = try parseMethodReceiverFromSyntax("Self", first_parameter, span, diagnostics) orelse return;
                    try validateTypeExpression(receiver.type_name, context, span, diagnostics);
                    param_index = 1;
                }
            }
        }

        while (param_index < method_syntax.signature.parameters.len) : (param_index += 1) {
            const parameter = try parseOrdinaryParameterFromSyntax(method_syntax.signature.parameters[param_index], span, diagnostics) orelse continue;
            try validateTypeExpression(parameter.type_name, context, span, diagnostics);
        }

        if (method_syntax.signature.return_type) |return_type| {
            const return_raw = std.mem.trim(u8, return_type.text, " \t");
            if (return_raw.len != 0) try validateTypeExpression(return_raw, context, span, diagnostics);
        }
        try validateWherePredicates(active, module_id, module, method.where_predicates, context, span, diagnostics);
    }
}

fn validateTraitSignature(
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    trait_type: *const typed.TraitData,
    diagnostics: *diag.Bag,
) !void {
    var type_scope = NameSet.init(diagnostics.allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = trait_type.generic_params,
        .allow_self = true,
        .self_type_name = "Self",
    };
    try validateWherePredicates(active, module_id, module, trait_type.where_predicates, context, span, diagnostics);
    for (trait_type.associated_consts) |associated_const| {
        try validateTypeExpression(associated_const.type_name, context, span, diagnostics);
    }
    for (trait_type.methods) |*method| {
        try validateTraitMethodSignature(diagnostics.allocator, active, module_id, module, method, trait_type.generic_params, span, &type_scope, diagnostics);
    }
}

fn validateImplBlock(
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    impl_block: *const typed.ImplData,
    type_scope: *const NameSet,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    const context = TypeResolutionContext{
        .type_scope = type_scope,
        .generic_params = impl_block.generic_params,
    };
    try validateTypeExpression(impl_block.target_type, context, span, diagnostics);
    if (impl_block.trait_name) |trait_name| {
        try validateTypeExpression(trait_name, context, span, diagnostics);
    } else if (impl_block.associated_types.len != 0) {
        try diagnostics.add(.@"error", "type.impl.associated_inherent", span, "inherent impls cannot bind associated types", .{});
    }
    for (impl_block.associated_types) |binding| {
        try validateTypeExpression(binding.value_type_name, context, span, diagnostics);
    }
    for (impl_block.associated_consts) |binding| {
        try validateTypeExpression(binding.const_data.type_name, context, span, diagnostics);
    }
    try validateWherePredicates(active, module_id, module, impl_block.where_predicates, context, span, diagnostics);
}

fn selfTypeNameForFunction(module: *const typed.Module, symbol_name: []const u8) ?[]const u8 {
    for (module.methods.items) |method| {
        if (std.mem.eql(u8, method.function_symbol, symbol_name)) return method.target_type;
    }
    return null;
}

fn functionSignatureForItem(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    item: *const typed.Item,
    function: *const typed.FunctionData,
    diagnostics: *diag.Bag,
) !query_types.FunctionSignature {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = function.generic_params,
        .allow_self = selfTypeNameForFunction(module, item.symbol_name) != null,
        .self_type_name = selfTypeNameForFunction(module, item.symbol_name),
    };

    const parameters = try allocator.alloc(typed.Parameter, function.parameters.items.len);
    errdefer allocator.free(parameters);
    for (function.parameters.items, 0..) |parameter, index| {
        parameters[index] = parameter;
        parameters[index].ty = try resolveValueTypeWithContext(parameter.type_name, context, item.span, diagnostics);
    }
    const return_type = try resolveValueTypeWithContext(function.return_type_name, context, item.span, diagnostics);
    try validateWherePredicates(active, module_id, module, function.where_predicates, context, item.span, diagnostics);

    return .{
        .is_suspend = function.is_suspend,
        .foreign = function.foreign,
        .generic_params = function.generic_params,
        .where_predicates = function.where_predicates,
        .parameters = parameters,
        .return_type_name = function.return_type_name,
        .return_type = return_type,
        .export_name = function.export_name,
        .abi = function.abi,
    };
}

fn structSignatureForItem(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    struct_type: *const typed.StructData,
    diagnostics: *diag.Bag,
) !query_types.StructSignature {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = struct_type.generic_params,
    };
    try validateWherePredicates(active, module_id, module, struct_type.where_predicates, context, span, diagnostics);

    const fields = try allocator.alloc(typed.StructField, struct_type.fields.len);
    errdefer allocator.free(fields);
    for (struct_type.fields, 0..) |field, index| {
        fields[index] = field;
        fields[index].ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
    }

    return .{
        .generic_params = struct_type.generic_params,
        .where_predicates = struct_type.where_predicates,
        .fields = fields,
    };
}

fn unionSignatureForItem(
    allocator: Allocator,
    module: *const typed.Module,
    span: source.Span,
    union_type: *const typed.UnionData,
    diagnostics: *diag.Bag,
) !query_types.UnionSignature {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
    };
    const fields = try allocator.alloc(typed.StructField, union_type.fields.len);
    errdefer allocator.free(fields);
    for (union_type.fields, 0..) |field, index| {
        fields[index] = field;
        fields[index].ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
    }
    return .{ .fields = fields };
}

fn enumSignatureForItem(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    enum_type: *const typed.EnumData,
    attributes: []const ast.Attribute,
    diagnostics: *diag.Bag,
) !query_types.EnumSignature {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);
    const imported_method_prototypes = try buildImportedMethodPrototypes(allocator, active, module_id, true, diagnostics);
    defer deinitMethodPrototypes(allocator, imported_method_prototypes);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = enum_type.generic_params,
    };
    try validateWherePredicates(active, module_id, module, enum_type.where_predicates, context, span, diagnostics);

    const variants = try allocator.alloc(typed.EnumVariant, enum_type.variants.len);
    var initialized: usize = 0;
    errdefer {
        for (variants[0..initialized]) |*variant| variant.deinit(allocator);
        allocator.free(variants);
    }
    for (enum_type.variants, 0..) |variant, index| {
        variants[index] = .{
            .name = variant.name,
            .payload = .none,
            .discriminant = variant.discriminant,
        };
        initialized += 1;
        switch (variant.payload) {
            .none => {
                if (variant.discriminant) |discriminant| {
                    var scope = ConstExprScope.init(allocator);
                    defer scope.deinit();
                    try seedConstExprScope(active, module_id, &scope, module);
                    var sites = std.array_list.Managed(query_types.ConstRequiredExprSite).init(allocator);
                    defer {
                        for (sites.items) |*site| site.deinit(allocator);
                        sites.deinit();
                    }
                    try appendConstRequiredExprSite(
                        allocator,
                        &sites,
                        .enum_discriminant,
                        discriminant,
                        variant.name,
                        enumDiscriminantExpectedType(attributes),
                        &scope,
                        &.{},
                        imported_method_prototypes,
                        &.{},
                        &.{},
                        span,
                        diagnostics,
                    );
                }
            },
            .tuple_fields => |tuple_fields| {
                const lowered = try allocator.alloc(typed.TupleField, tuple_fields.len);
                for (tuple_fields, 0..) |field, field_index| {
                    lowered[field_index] = field;
                    lowered[field_index].ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
                }
                variants[index].payload = .{ .tuple_fields = lowered };
            },
            .named_fields => |named_fields| {
                const lowered = try allocator.alloc(typed.StructField, named_fields.len);
                for (named_fields, 0..) |field, field_index| {
                    lowered[field_index] = field;
                    lowered[field_index].ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
                }
                variants[index].payload = .{ .named_fields = lowered };
            },
        }
    }

    return .{
        .generic_params = enum_type.generic_params,
        .where_predicates = enum_type.where_predicates,
        .variants = variants,
    };
}

fn buildCheckedSignatureFacts(
    active: *session.Session,
    module_id: session.ModuleId,
    item: *const typed.Item,
    source_item: ?hir.Item,
    diagnostics: *diag.Bag,
) !query_types.SignatureFacts {
    const syntax_item = source_item orelse return .none;
    const module_entry = active.semantic_index.moduleEntry(module_id);
    const module = active.module(module_id);
    const prototypes = active.pipeline.modules.items[module_entry.pipeline_index].prototypes.items;
    return switch (item.kind) {
        .function, .suspend_function, .foreign_function => .{ .function = try functionSignatureFromSyntax(active.allocator, active, module_id, module, item, syntax_item, diagnostics) },
        .const_item => .{ .const_item = try constSignatureFromSyntax(active, active.allocator, module_id, module, prototypes, item.span, syntax_item, &.{}, &.{}, diagnostics) },
        .struct_type => .{ .struct_type = try structSignatureFromSyntax(active.allocator, active, module_id, module, item.span, syntax_item, diagnostics) },
        .union_type => .{ .union_type = try unionSignatureFromSyntax(active.allocator, module, item.span, syntax_item, diagnostics) },
        .enum_type => .{ .enum_type = try enumSignatureFromSyntax(active, active.allocator, module_id, module, item.span, syntax_item, item.attributes, diagnostics) },
        .opaque_type => .{ .opaque_type = try opaqueSignatureFromSyntax(active.allocator, item.span, syntax_item, diagnostics) },
        .trait_type => .{ .trait_type = try traitSignatureFromSyntax(active.allocator, active, module_id, module, item.span, syntax_item, diagnostics) },
        .impl_block => .{ .impl_block = try implSignatureFromSyntax(active, active.allocator, module_id, module, prototypes, item.span, syntax_item, diagnostics) },
        else => .none,
    };
}

fn functionSignatureFromSyntax(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    item: *const typed.Item,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.FunctionSignature {
    const signature = switch (source_item.syntax) {
        .function => |signature| signature,
        else => return error.InvalidParse,
    };

    var function = typed.FunctionData.init(allocator, source_item.kind == .suspend_function, source_item.kind == .foreign_function);
    errdefer function.deinit(allocator);
    try item_syntax_bridge.fillFunctionDataFromSyntax(allocator, &function, signature, source_item.span, diagnostics);
    function.export_name = parseExportName(source_item.attributes);
    function.abi = source_item.foreign_abi;

    if (source_item.kind == .foreign_function and function.export_name != null) {
        try diagnostics.add(.@"error", "type.foreign.export", source_item.span, "foreign declarations do not combine with #export in stage0", .{});
    }

    const result = try functionSignatureForItem(allocator, active, module_id, module, item, &function, diagnostics);
    function.generic_params = &.{};
    function.where_predicates = &.{};
    function.deinit(allocator);
    return result;
}

fn constSignatureFromSyntax(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    prototypes: []const typed.FunctionPrototype,
    span: source.Span,
    source_item: hir.Item,
    generic_params: []const typed.GenericParam,
    associated_types: []const typed.TraitAssociatedTypeBinding,
    diagnostics: *diag.Bag,
) !query_types.ConstSignature {
    const signature = switch (source_item.syntax) {
        .const_item => |signature| signature,
        else => return error.InvalidParse,
    };
    var const_item = try item_syntax_bridge.parseConstDataFromSyntax(allocator, signature, span, diagnostics);
    defer const_item.deinit(allocator);
    return constSignatureForItem(active, allocator, module_id, module, prototypes, span, &const_item, generic_params, associated_types, diagnostics);
}

fn namedDeclDataFromSyntax(
    allocator: Allocator,
    source_item: hir.Item,
    allow_self: bool,
    diagnostics: *diag.Bag,
) !item_syntax_bridge.NamedDeclData {
    return switch (source_item.syntax) {
        .named_decl => |signature| item_syntax_bridge.parseNamedDeclData(allocator, signature, allow_self, source_item.span, diagnostics),
        else => error.InvalidParse,
    };
}

fn structSignatureFromSyntax(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.StructSignature {
    var header = try namedDeclDataFromSyntax(allocator, source_item, false, diagnostics);
    errdefer header.deinit(allocator);
    const fields = switch (source_item.body_syntax) {
        .struct_fields => |fields| try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, source_item.name, source_item.span, diagnostics),
        .none => try allocator.alloc(typed.StructField, 0),
        else => return error.InvalidParse,
    };
    errdefer allocator.free(fields);

    var struct_type = typed.StructData{
        .generic_params = header.generic_params,
        .where_predicates = header.where_predicates,
        .fields = fields,
    };
    const result = try structSignatureForItem(allocator, active, module_id, module, span, &struct_type, diagnostics);
    header.generic_params = &.{};
    header.where_predicates = &.{};
    struct_type.generic_params = &.{};
    struct_type.where_predicates = &.{};
    struct_type.deinit(allocator);
    return result;
}

fn unionSignatureFromSyntax(
    allocator: Allocator,
    module: *const typed.Module,
    span: source.Span,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.UnionSignature {
    const fields = switch (source_item.body_syntax) {
        .union_fields => |fields| try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, source_item.name, source_item.span, diagnostics),
        .none => try allocator.alloc(typed.StructField, 0),
        else => return error.InvalidParse,
    };
    var union_type = typed.UnionData{ .fields = fields };
    defer union_type.deinit(allocator);
    return unionSignatureForItem(allocator, module, span, &union_type, diagnostics);
}

fn enumSignatureFromSyntax(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    source_item: hir.Item,
    attributes: []const ast.Attribute,
    diagnostics: *diag.Bag,
) !query_types.EnumSignature {
    var header = try namedDeclDataFromSyntax(allocator, source_item, false, diagnostics);
    errdefer header.deinit(allocator);
    const variants = switch (source_item.body_syntax) {
        .enum_variants => |variants| try body_syntax_bridge.parseEnumVariantsFromSyntax(allocator, variants, source_item.name, source_item.span, diagnostics),
        .none => try allocator.alloc(typed.EnumVariant, 0),
        else => return error.InvalidParse,
    };
    errdefer {
        for (variants) |*variant| variant.deinit(allocator);
        allocator.free(variants);
    }

    var enum_type = typed.EnumData{
        .generic_params = header.generic_params,
        .where_predicates = header.where_predicates,
        .variants = variants,
    };
    const result = try enumSignatureForItem(active, allocator, module_id, module, span, &enum_type, attributes, diagnostics);
    header.generic_params = &.{};
    header.where_predicates = &.{};
    enum_type.generic_params = &.{};
    enum_type.where_predicates = &.{};
    enum_type.deinit(allocator);
    return result;
}

fn opaqueSignatureFromSyntax(
    allocator: Allocator,
    span: source.Span,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.OpaqueTypeSignature {
    _ = span;
    var header = try namedDeclDataFromSyntax(allocator, source_item, false, diagnostics);
    errdefer header.deinit(allocator);
    const result = query_types.OpaqueTypeSignature{
        .generic_params = header.generic_params,
        .where_predicates = header.where_predicates,
    };
    header.generic_params = &.{};
    header.where_predicates = &.{};
    return result;
}

fn traitSignatureFromSyntax(
    allocator: Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    module: *const typed.Module,
    span: source.Span,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.TraitSignature {
    var header = try namedDeclDataFromSyntax(allocator, source_item, true, diagnostics);
    errdefer header.deinit(allocator);
    var parsed_body = switch (source_item.body_syntax) {
        .trait_body => |body| try body_syntax_bridge.parseTraitBodyFromSyntax(allocator, header.generic_params, body, source_item.name, source_item.span, diagnostics),
        .none => body_syntax_bridge.ParsedTraitBody{
            .methods = try allocator.alloc(typed.TraitMethod, 0),
            .associated_types = try allocator.alloc(typed.TraitAssociatedType, 0),
            .associated_consts = try allocator.alloc(typed.TraitAssociatedConst, 0),
        },
        else => return error.InvalidParse,
    };
    errdefer parsed_body.deinit(allocator);

    var trait_type = typed.TraitData{
        .generic_params = header.generic_params,
        .where_predicates = header.where_predicates,
        .methods = parsed_body.methods,
        .associated_types = parsed_body.associated_types,
        .associated_consts = parsed_body.associated_consts,
    };
    try validateTraitSignature(active, module_id, module, span, &trait_type, diagnostics);

    const result = query_types.TraitSignature{
        .generic_params = trait_type.generic_params,
        .where_predicates = trait_type.where_predicates,
        .methods = trait_type.methods,
        .associated_types = trait_type.associated_types,
        .associated_consts = trait_type.associated_consts,
    };
    header.generic_params = &.{};
    header.where_predicates = &.{};
    parsed_body.methods = &.{};
    parsed_body.associated_types = &.{};
    parsed_body.associated_consts = &.{};
    return result;
}

fn implHeaderDataFromSyntax(
    allocator: Allocator,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !item_syntax_bridge.ImplHeaderData {
    return switch (source_item.syntax) {
        .impl_block => |signature| item_syntax_bridge.parseImplHeaderData(allocator, signature, source_item.span, diagnostics),
        else => error.InvalidParse,
    };
}

fn implSignatureFromSyntax(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    prototypes: []const typed.FunctionPrototype,
    span: source.Span,
    source_item: hir.Item,
    diagnostics: *diag.Bag,
) !query_types.ImplSignature {
    var header = try implHeaderDataFromSyntax(allocator, source_item, diagnostics);
    errdefer header.deinit(allocator);

    const body = switch (source_item.body_syntax) {
        .impl_body => |body| body,
        .none => ast.ImplBodySyntax{},
        else => return error.InvalidParse,
    };

    const associated_types = try body_syntax_bridge.parseImplAssociatedTypesFromSyntax(allocator, body.associated_types, span, diagnostics);
    errdefer allocator.free(associated_types);
    const associated_const_bindings = try body_syntax_bridge.parseImplAssociatedConstsFromSyntax(allocator, body.associated_consts, span, diagnostics);
    errdefer {
        for (associated_const_bindings) |*binding| binding.deinit(allocator);
        allocator.free(associated_const_bindings);
    }
    const methods = try body_syntax_bridge.parseImplMethodsFromSyntax(allocator, header.generic_params, body, span, diagnostics);
    errdefer {
        for (methods) |*method| method.deinit(allocator);
        allocator.free(methods);
    }

    var impl_block = typed.ImplData{
        .generic_params = header.generic_params,
        .where_predicates = header.where_predicates,
        .target_type = header.target_type,
        .trait_name = header.trait_name,
        .associated_types = associated_types,
        .associated_consts = associated_const_bindings,
        .methods = methods,
    };
    const result = try implSignatureForItem(active, allocator, module_id, module, prototypes, span, &impl_block, diagnostics);

    header.generic_params = &.{};
    header.where_predicates = &.{};
    impl_block.generic_params = &.{};
    impl_block.where_predicates = &.{};
    impl_block.associated_types = &.{};
    impl_block.methods = &.{};
    for (impl_block.associated_consts) |*binding| binding.deinit(allocator);
    allocator.free(impl_block.associated_consts);
    impl_block.associated_consts = &.{};
    return result;
}

fn implSignatureForItem(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    prototypes: []const typed.FunctionPrototype,
    span: source.Span,
    impl_block: *const typed.ImplData,
    diagnostics: *diag.Bag,
) !query_types.ImplSignature {
    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);
    try validateImplBlock(active, module_id, module, impl_block, &type_scope, span, diagnostics);

    const associated_consts = try allocator.alloc(query_types.AssociatedConstBindingSignature, impl_block.associated_consts.len);
    var initialized: usize = 0;
    errdefer {
        for (associated_consts[0..initialized]) |binding| {
            if (binding.const_item.expr) |expr| const_ir.destroyExpr(allocator, expr);
        }
        allocator.free(associated_consts);
    }
    for (impl_block.associated_consts, 0..) |binding, index| {
        associated_consts[index] = .{
            .name = binding.name,
            .const_item = try constSignatureForItem(
                active,
                allocator,
                module_id,
                module,
                prototypes,
                span,
                &binding.const_data,
                impl_block.generic_params,
                impl_block.associated_types,
                diagnostics,
            ),
        };
        initialized += 1;
    }
    return .{
        .generic_params = impl_block.generic_params,
        .where_predicates = impl_block.where_predicates,
        .target_type = impl_block.target_type,
        .trait_name = impl_block.trait_name,
        .associated_types = impl_block.associated_types,
        .associated_consts = associated_consts,
        .methods = impl_block.methods,
    };
}

fn constSignatureForItem(
    active: *session.Session,
    allocator: Allocator,
    module_id: session.ModuleId,
    module: *const typed.Module,
    prototypes: []const typed.FunctionPrototype,
    span: source.Span,
    const_item: *const typed.ConstData,
    generic_params: []const typed.GenericParam,
    associated_types: []const typed.TraitAssociatedTypeBinding,
    diagnostics: *diag.Bag,
) !query_types.ConstSignature {
    _ = associated_types;
    var lowered: ?*const const_ir.Expr = null;
    var lower_error: ?anyerror = null;

    var type_scope = NameSet.init(allocator);
    defer type_scope.deinit();
    try seedTypeScope(&type_scope, module);

    const context = TypeResolutionContext{
        .type_scope = &type_scope,
        .generic_params = generic_params,
    };
    const resolved_type_ref = try resolveValueTypeWithContext(const_item.type_name, context, span, diagnostics);

    var initializer_type_ref: types.TypeRef = .unsupported;
    if (const_item.initializer_syntax) |initializer_syntax| {
        var scope = ConstExprScope.init(allocator);
        defer scope.deinit();
        try seedConstExprScope(active, module_id, &scope, module);
        const imported_method_prototypes = try buildImportedMethodPrototypes(allocator, active, module_id, true, diagnostics);
        defer deinitMethodPrototypes(allocator, imported_method_prototypes);

        const struct_prototypes = try buildStructPrototypes(allocator, active, module_id, module);
        defer deinitQueryStructPrototypes(allocator, struct_prototypes);
        const enum_prototypes = try buildEnumPrototypes(allocator, active, module_id, module);
        defer deinitQueryEnumPrototypes(allocator, enum_prototypes);

        const parsed = expression_parse.parseExpressionSyntax(
            allocator,
            initializer_syntax,
            resolved_type_ref,
            &scope,
            &.{},
            prototypes,
            imported_method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            span,
            false,
            false,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                lower_error = err;
                return .{
                    .type_name = const_item.type_name,
                    .ty = switch (resolved_type_ref) {
                        .builtin => |builtin| builtin,
                        else => .unsupported,
                    },
                    .type_ref = resolved_type_ref,
                    .initializer_type_ref = .unsupported,
                    .initializer_source = const_item.initializer_source,
                    .expr = null,
                    .lower_error = lower_error,
                };
            },
        };
        defer {
            parsed.deinit(allocator);
            allocator.destroy(parsed);
        }

        initializer_type_ref = try duplicateTypeRefIfOwned(allocator, parsed.ty);
        lowered = const_ir.lowerExpr(allocator, parsed) catch |err| switch (err) {
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
        .ty = switch (resolved_type_ref) {
            .builtin => |builtin| builtin,
            else => .unsupported,
        },
        .type_ref = resolved_type_ref,
        .initializer_type_ref = initializer_type_ref,
        .initializer_source = const_item.initializer_source,
        .expr = lowered,
        .lower_error = lower_error,
    };
}
