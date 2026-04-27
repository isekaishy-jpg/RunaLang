const std = @import("std");
const callable_types = @import("callable_types.zig");
const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const raw_pointer = @import("../raw_pointer/root.zig");
const session = @import("../session/root.zig");
const typed = @import("../typed/root.zig");
const boundary_checks = @import("boundary_checks.zig");
const type_support = @import("type_support.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");

const baseTypeName = typed_text.baseTypeName;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const parseBoundaryType = type_support.parseBoundaryType;
const parseCallableTypeName = callable_types.parseCallableTypeName;

pub const SignatureResolver = *const fn (active: *session.Session, item_id: session.ItemId) anyerror!query_types.CheckedSignature;

fn markCycleFailure(entry: anytype) void {
    entry.value = null;
    entry.failed = true;
    entry.state = .complete;
}

fn satisfiesTrait(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !query_types.TraitGoalResult {
    return satisfiesTraitWithResolver(active, module_id, self_type_name, trait_name, where_predicates, cachedSignatureResolver);
}

pub fn satisfiesTraitWithResolver(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    where_predicates: []const typed.WherePredicate,
    signature_resolver: SignatureResolver,
) !query_types.TraitGoalResult {
    const key = try traitGoalKeyFromNames(active, module_id, self_type_name, trait_name, where_predicates);
    return satisfiesTraitKeyWithResolver(active, key, where_predicates, signature_resolver);
}

pub fn traitGoalKeyFromNames(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !query_types.TraitGoalKey {
    const trimmed_self = std.mem.trim(u8, self_type_name, " \t");
    return .{
        .module_id = module_id,
        .trait_head = try canonicalTraitHead(active, module_id, trait_name),
        .self_head = try canonicalTypeHead(active, module_id, trimmed_self, where_predicates),
        .self_type_symbol = try active.internName(trimmed_self),
        .where_env_symbol = try canonicalWhereEnvironment(active, where_predicates),
    };
}

pub fn satisfiesTraitKeyWithResolver(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    where_predicates: []const typed.WherePredicate,
    signature_resolver: SignatureResolver,
) !query_types.TraitGoalResult {
    const goal_index = try findOrCreateGoal(active, key, where_predicates);
    var entry = &active.caches.trait_goals.items[goal_index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        try reportTraitCycle(active, key);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.trait_goal, goal_index)) {
        entry.state = .complete;
        entry.failed = true;
        try reportTraitCycle(active, key);
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    const value = try solveGoal(active, key, signature_resolver);
    entry = &active.caches.trait_goals.items[goal_index];
    entry.value = value;
    entry.state = .complete;
    return value;
}

pub fn typeNameIsSend(active: *session.Session, module_id: session.ModuleId, raw_type_name: []const u8) bool {
    return typeNameIsSendInEnvironment(active, module_id, raw_type_name, &.{});
}

pub fn typeNameIsSendInEnvironment(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) bool {
    const result = satisfiesTrait(active, module_id, raw_type_name, "Send", where_predicates) catch return false;
    return result.satisfied;
}

pub fn typeNameIsEqInEnvironment(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) bool {
    const result = satisfiesTrait(active, module_id, raw_type_name, "Eq", where_predicates) catch return false;
    return result.satisfied;
}

pub fn typeNameIsHashInEnvironment(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) bool {
    const result = satisfiesTrait(active, module_id, raw_type_name, "Hash", where_predicates) catch return false;
    return result.satisfied;
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
    return associatedTypeEqualsWithResolver(active, module_id, self_type_name, trait_name, associated_name, value_type_name, where_predicates, cachedSignatureResolver);
}

pub fn associatedTypeEqualsWithResolver(
    active: *session.Session,
    module_id: session.ModuleId,
    self_type_name: []const u8,
    trait_name: []const u8,
    associated_name: []const u8,
    value_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
    signature_resolver: SignatureResolver,
) !bool {
    const key = try traitGoalKeyFromNames(active, module_id, self_type_name, trait_name, where_predicates);
    return associatedTypeEqualsKeyWithResolver(active, key, associated_name, value_type_name, where_predicates, signature_resolver);
}

pub fn associatedTypeEqualsKeyWithResolver(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    associated_name: []const u8,
    value_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
    signature_resolver: SignatureResolver,
) !bool {
    const self_type_name = keySelfTypeName(active, key);
    const projection = typed.ProjectionEqualityPredicate{
        .subject_name = std.mem.trim(u8, self_type_name, " \t"),
        .associated_name = std.mem.trim(u8, associated_name, " \t"),
        .value_type_name = std.mem.trim(u8, value_type_name, " \t"),
    };
    if (whereEnvironmentHasProjection(where_predicates, projection)) return true;
    _ = try findOrCreateGoal(active, key, where_predicates);

    const impl_signature = (try findSelectedImplSignature(active, key, signature_resolver)) orelse return false;
    var arena = std.heap.ArenaAllocator.init(active.allocator);
    defer arena.deinit();
    var substitutions = std.array_list.Managed(TypeSubstitution).init(arena.allocator());
    try collectTypeSubstitutions(arena.allocator(), impl_signature, self_type_name, &substitutions);
    for (impl_signature.associated_types) |binding| {
        if (!std.mem.eql(u8, binding.name, projection.associated_name)) continue;
        const substituted = try substituteTypeName(arena.allocator(), binding.value_type_name, substitutions.items);
        return typeNamesEqual(substituted, projection.value_type_name);
    }
    return false;
}

pub fn validateImplContracts(active: *session.Session, diagnostics: *diag.Bag) !void {
    return validateImplContractsWithResolver(active, diagnostics, cachedSignatureResolver);
}

pub fn validateImplContractsWithResolver(
    active: *session.Session,
    diagnostics: *diag.Bag,
    signature_resolver: SignatureResolver,
) !void {
    for (active.semantic_index.impls.items) |impl_entry| {
        const checked = signature_resolver(active, impl_entry.item_id) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => continue,
            else => return err,
        };
        const impl_signature = switch (checked.facts) {
            .impl_block => |impl_signature| impl_signature,
            else => continue,
        };
        const trait_name = impl_signature.trait_name orelse {
            if (impl_signature.associated_types.len != 0) {
                try diagnostics.add(
                    .@"error",
                    "type.impl.associated_inherent",
                    checked.item.span,
                    "inherent impls cannot bind associated types",
                    .{},
                );
            }
            continue;
        };
        if (std.mem.eql(u8, baseTypeName(trait_name), "Send")) continue;

        const trait_signature = (try traitSignatureByName(active, checked.module_id, trait_name, signature_resolver)) orelse continue;
        for (impl_signature.associated_types) |binding| {
            if (!traitHasAssociatedType(trait_signature, binding.name)) {
                try diagnostics.add(
                    .@"error",
                    "type.impl.associated_unknown",
                    checked.item.span,
                    "trait '{s}' has no associated type '{s}'",
                    .{ baseTypeName(trait_name), binding.name },
                );
            }
        }
        for (impl_signature.associated_consts) |binding| {
            if (!traitHasAssociatedConst(trait_signature, binding.name)) {
                try diagnostics.add(
                    .@"error",
                    "type.impl.associated_const_unknown",
                    checked.item.span,
                    "trait '{s}' has no associated const '{s}'",
                    .{ baseTypeName(trait_name), binding.name },
                );
            }
        }
        for (trait_signature.associated_types) |required| {
            if (!implBindsAssociatedType(impl_signature.associated_types, required.name)) {
                try diagnostics.add(
                    .@"error",
                    "type.impl.associated_missing",
                    checked.item.span,
                    "trait impl for '{s}' is missing associated type '{s}'",
                    .{ impl_signature.target_type, required.name },
                );
            }
        }
        for (trait_signature.associated_consts) |required| {
            if (!implBindsAssociatedConst(impl_signature.associated_consts, required.name)) {
                try diagnostics.add(
                    .@"error",
                    "type.impl.associated_const_missing",
                    checked.item.span,
                    "trait impl for '{s}' is missing associated const '{s}'",
                    .{ impl_signature.target_type, required.name },
                );
            }
        }

        _ = satisfiesTraitWithResolver(
            active,
            checked.module_id,
            impl_signature.target_type,
            trait_name,
            impl_signature.where_predicates,
            signature_resolver,
        ) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => {},
            else => return err,
        };
    }
}

fn solveGoal(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    signature_resolver: SignatureResolver,
) !query_types.TraitGoalResult {
    switch (key.trait_head) {
        .builtin_send => return .{
            .key = key,
            .satisfied = whereEnvironmentSatisfies(active, key) or
                solveBuiltinSend(active, key.module_id, keySelfTypeName(active, key), signature_resolver),
        },
        .builtin_eq => {
            if (whereEnvironmentSatisfies(active, key) or solveBuiltinEq(active, key.module_id, keySelfTypeName(active, key), signature_resolver)) {
                return .{ .key = key, .satisfied = true };
            }
        },
        .builtin_hash => {
            if (whereEnvironmentSatisfies(active, key) or solveBuiltinHash(active, key.module_id, keySelfTypeName(active, key), signature_resolver)) {
                return .{ .key = key, .satisfied = true };
            }
        },
        .opaque_name => return .{ .key = key, .satisfied = whereEnvironmentSatisfies(active, key) },
        .trait_item => {},
    }

    if (whereEnvironmentSatisfies(active, key)) {
        return .{ .key = key, .satisfied = true };
    }

    const candidates = try implCandidates(active, key, signature_resolver);
    for (candidates) |impl_id| {
        const impl_entry = active.semantic_index.implEntry(impl_id);
        const impl_signature = (try findSelectedImplSignatureAt(active, key, impl_entry, signature_resolver)) orelse continue;

        const trait_signature = traitSignatureByHead(active, key.trait_head, signature_resolver) catch null;
        return .{
            .key = key,
            .satisfied = true,
            .impl_id = impl_id,
            .inherited_default_method_count = if (trait_signature) |signature|
                inheritedDefaultMethodCount(signature.methods, impl_signature.methods)
            else
                0,
        };
    }

    return .{ .key = key, .satisfied = false };
}

fn findSelectedImplSignature(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    signature_resolver: SignatureResolver,
) !?query_types.ImplSignature {
    const candidates = try implCandidates(active, key, signature_resolver);
    for (candidates) |impl_id| {
        const impl_entry = active.semantic_index.implEntry(impl_id);
        if (try findSelectedImplSignatureAt(active, key, impl_entry, signature_resolver)) |impl_signature| return impl_signature;
    }
    return null;
}

fn implIndex(
    active: *session.Session,
    signature_resolver: SignatureResolver,
) !query_types.ImplIndexResult {
    var entry = &active.caches.impl_index;
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.impl_index, 0)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var entries = std.array_list.Managed(query_types.ImplIndexEntry).init(active.allocator);
    defer entries.deinit();

    for (active.semantic_index.impls.items, 0..) |impl_entry, index| {
        const checked = signature_resolver(active, impl_entry.item_id) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => continue,
            else => return err,
        };
        const impl_signature = switch (checked.facts) {
            .impl_block => |impl_signature| impl_signature,
            else => continue,
        };
        const impl_trait_name = impl_signature.trait_name orelse continue;
        try entries.append(.{
            .module_id = checked.module_id,
            .trait_head = try canonicalTraitHead(active, checked.module_id, impl_trait_name),
            .self_head = try canonicalTypeHead(active, checked.module_id, impl_signature.target_type, impl_signature.where_predicates),
            .impl_id = .{ .index = index },
        });
    }

    const value = query_types.ImplIndexResult{
        .entries = try entries.toOwnedSlice(),
    };
    entry = &active.caches.impl_index;
    entry.value = value;
    entry.state = .complete;
    return value;
}

fn implCandidates(
    active: *session.Session,
    goal_key: query_types.TraitGoalKey,
    signature_resolver: SignatureResolver,
) ![]const session.ImplId {
    const key = query_types.ImplLookupKey{
        .module_id = goal_key.module_id,
        .trait_head = goal_key.trait_head,
        .self_head = goal_key.self_head,
    };
    const lookup_index = try findOrCreateImplLookup(active, key);
    var entry = &active.caches.impl_lookups.items[lookup_index];
    if (entry.state == .complete) return if (entry.failed) error.CachedFailure else entry.value.?.impl_ids;
    if (entry.state == .in_progress) {
        markCycleFailure(entry);
        return error.QueryCycle;
    }

    entry.state = .in_progress;
    if (!try active.pushActiveQuery(.impl_lookup, lookup_index)) {
        entry.state = .complete;
        entry.failed = true;
        return error.QueryCycle;
    }
    defer active.popActiveQuery();
    errdefer {
        entry.state = .complete;
        entry.failed = true;
    }

    var candidates = std.array_list.Managed(session.ImplId).init(active.allocator);
    defer candidates.deinit();

    const indexed = try implIndex(active, signature_resolver);
    for (indexed.entries) |candidate| {
        if (!traitHeadsEqual(candidate.trait_head, key.trait_head)) continue;
        if (!implIndexSelfHeadCouldMatch(candidate.self_head, key.self_head)) continue;

        const impl_entry = active.semantic_index.implEntry(candidate.impl_id);
        const checked = signature_resolver(active, impl_entry.item_id) catch |err| switch (err) {
            error.CachedFailure, error.QueryCycle => continue,
            else => return err,
        };
        const impl_signature = switch (checked.facts) {
            .impl_block => |impl_signature| impl_signature,
            else => continue,
        };
        if (!try implTargetMatchesGoal(active, checked.module_id, impl_signature, goal_key)) continue;
        try candidates.append(candidate.impl_id);
    }

    const value = query_types.ImplLookupResult{
        .key = key,
        .impl_ids = try candidates.toOwnedSlice(),
    };
    entry = &active.caches.impl_lookups.items[lookup_index];
    entry.value = value;
    entry.state = .complete;
    return value.impl_ids;
}

fn findSelectedImplSignatureAt(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    impl_entry: anytype,
    signature_resolver: SignatureResolver,
) !?query_types.ImplSignature {
    const checked = signature_resolver(active, impl_entry.item_id) catch |err| switch (err) {
        error.CachedFailure, error.QueryCycle => return null,
        else => return err,
    };
    const impl_signature = switch (checked.facts) {
        .impl_block => |impl_signature| impl_signature,
        else => return null,
    };
    const impl_trait_name = impl_signature.trait_name orelse return null;
    if (!traitHeadsEqual(try canonicalTraitHead(active, checked.module_id, impl_trait_name), key.trait_head)) return null;
    if (!try implTargetMatchesGoal(active, checked.module_id, impl_signature, key)) return null;
    if (!implWherePredicatesSatisfied(active, checked.module_id, impl_signature, key, signature_resolver)) return null;
    return impl_signature;
}

fn implIndexSelfHeadCouldMatch(
    candidate: query_types.CanonicalTypeHead,
    goal: query_types.CanonicalTypeHead,
) bool {
    if (typeHeadsEqual(candidate, goal)) return true;
    return switch (candidate) {
        .generic_param, .opaque_name => true,
        .builtin, .item => switch (goal) {
            .opaque_name => true,
            .builtin, .item, .generic_param => false,
        },
    };
}

fn implTargetMatchesGoal(
    active: *session.Session,
    module_id: session.ModuleId,
    impl_signature: query_types.ImplSignature,
    key: query_types.TraitGoalKey,
) !bool {
    const impl_self_head = try canonicalTypeHead(active, module_id, impl_signature.target_type, impl_signature.where_predicates);
    if (!typeHeadsEqual(impl_self_head, key.self_head) and implTargetGenericName(impl_signature) == null) return false;

    var arena = std.heap.ArenaAllocator.init(active.allocator);
    defer arena.deinit();
    var substitutions = std.array_list.Managed(TypeSubstitution).init(arena.allocator());
    return matchTypePattern(
        arena.allocator(),
        impl_signature.target_type,
        keySelfTypeName(active, key),
        impl_signature.generic_params,
        &substitutions,
    );
}

fn implWherePredicatesSatisfied(
    active: *session.Session,
    module_id: session.ModuleId,
    impl_signature: query_types.ImplSignature,
    caller_key: query_types.TraitGoalKey,
    signature_resolver: SignatureResolver,
) bool {
    const caller_predicates = wherePredicatesForKey(active, caller_key) orelse &.{};
    const concrete_self = keySelfTypeName(active, caller_key);
    var arena = std.heap.ArenaAllocator.init(active.allocator);
    defer arena.deinit();
    var substitutions = std.array_list.Managed(TypeSubstitution).init(arena.allocator());
    collectTypeSubstitutions(arena.allocator(), impl_signature, concrete_self, &substitutions) catch return false;
    for (impl_signature.where_predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| {
                const subject_name = substituteTypeName(arena.allocator(), bound.subject_name, substitutions.items) catch return false;
                if (whereEnvironmentHasBound(caller_predicates, subject_name, bound.contract_name)) continue;
                if (boundPredicateMatchesGoal(active, module_id, .{
                    .subject_name = subject_name,
                    .contract_name = bound.contract_name,
                }, caller_predicates, caller_key)) {
                    reportTraitCycle(active, caller_key) catch {};
                    return false;
                }
                const result = satisfiesTraitWithResolver(
                    active,
                    module_id,
                    subject_name,
                    bound.contract_name,
                    caller_predicates,
                    signature_resolver,
                ) catch return false;
                if (!result.satisfied) return false;
            },
            .projection_equality => |projection| {
                const substituted = typed.ProjectionEqualityPredicate{
                    .subject_name = substituteTypeName(arena.allocator(), projection.subject_name, substitutions.items) catch return false,
                    .associated_name = projection.associated_name,
                    .value_type_name = substituteTypeName(arena.allocator(), projection.value_type_name, substitutions.items) catch return false,
                };
                if (!whereEnvironmentHasProjection(caller_predicates, substituted)) return false;
            },
            .lifetime_outlives, .type_outlives => {},
        }
    }
    return true;
}

fn implTargetGenericName(impl_signature: query_types.ImplSignature) ?[]const u8 {
    const target = baseTypeName(impl_signature.target_type);
    if (target.len == 0) return null;
    for (impl_signature.generic_params) |param| {
        if (param.kind != .type_param) continue;
        if (std.mem.eql(u8, param.name, target)) return target;
    }
    return null;
}

const TypeSubstitution = struct {
    param_name: []const u8,
    value_name: []const u8,
};

fn collectTypeSubstitutions(
    allocator: std.mem.Allocator,
    impl_signature: query_types.ImplSignature,
    concrete_self: []const u8,
    substitutions: *std.array_list.Managed(TypeSubstitution),
) !void {
    _ = try matchTypePattern(
        allocator,
        impl_signature.target_type,
        concrete_self,
        impl_signature.generic_params,
        substitutions,
    );
}

fn matchTypePattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    concrete: []const u8,
    generic_params: []const typed.GenericParam,
    substitutions: *std.array_list.Managed(TypeSubstitution),
) !bool {
    const pattern_trimmed = std.mem.trim(u8, pattern, " \t");
    const concrete_trimmed = std.mem.trim(u8, concrete, " \t");
    if (genericTypeParamExists(generic_params, pattern_trimmed)) {
        return putSubstitution(substitutions, pattern_trimmed, concrete_trimmed);
    }

    const pattern_args = try typeApplicationArgs(allocator, pattern_trimmed);
    const concrete_args = try typeApplicationArgs(allocator, concrete_trimmed);
    if (pattern_args) |p_args| {
        const c_args = concrete_args orelse return false;
        if (!std.mem.eql(u8, baseTypeName(pattern_trimmed), baseTypeName(concrete_trimmed))) return false;
        if (p_args.len != c_args.len) return false;
        for (p_args, c_args) |pattern_arg, concrete_arg| {
            if (!try matchTypePattern(allocator, pattern_arg, concrete_arg, generic_params, substitutions)) return false;
        }
        return true;
    }

    if (concrete_args != null) return false;
    return typeNamesEqual(pattern_trimmed, concrete_trimmed);
}

fn putSubstitution(
    substitutions: *std.array_list.Managed(TypeSubstitution),
    param_name: []const u8,
    value_name: []const u8,
) !bool {
    for (substitutions.items) |existing| {
        if (!std.mem.eql(u8, existing.param_name, param_name)) continue;
        return typeNamesEqual(existing.value_name, value_name);
    }
    try substitutions.append(.{
        .param_name = param_name,
        .value_name = value_name,
    });
    return true;
}

fn substituteTypeName(
    allocator: std.mem.Allocator,
    raw_name: []const u8,
    substitutions: []const TypeSubstitution,
) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_name, " \t");
    if (substitutionFor(substitutions, trimmed)) |value| return value;

    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot_index| {
        if (substitutionFor(substitutions, trimmed[0..dot_index])) |value| {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ value, trimmed[dot_index..] });
        }
    }

    const args = (try typeApplicationArgs(allocator, trimmed)) orelse return raw_name;
    var changed = false;
    var rendered_args = std.array_list.Managed([]const u8).init(allocator);
    for (args) |arg| {
        const substituted = try substituteTypeName(allocator, arg, substitutions);
        if (!typeNamesEqual(substituted, arg)) changed = true;
        try rendered_args.append(substituted);
    }
    if (!changed) return raw_name;

    var rendered = std.array_list.Managed(u8).init(allocator);
    try rendered.appendSlice(baseTypeName(trimmed));
    try rendered.append('[');
    for (rendered_args.items, 0..) |arg, index| {
        if (index != 0) try rendered.appendSlice(", ");
        try rendered.appendSlice(arg);
    }
    try rendered.append(']');
    return rendered.toOwnedSlice();
}

fn substitutionFor(substitutions: []const TypeSubstitution, name: []const u8) ?[]const u8 {
    for (substitutions) |substitution| {
        if (std.mem.eql(u8, substitution.param_name, std.mem.trim(u8, name, " \t"))) return substitution.value_name;
    }
    return null;
}

fn typeApplicationArgs(allocator: std.mem.Allocator, raw_name: []const u8) !?[][]const u8 {
    const open_index = std.mem.indexOfScalar(u8, raw_name, '[') orelse return null;
    const close_index = findMatchingDelimiter(raw_name, open_index, '[', ']') orelse return null;
    if (std.mem.trim(u8, raw_name[close_index + 1 ..], " \t").len != 0) return null;
    return try typed_text.splitTopLevelCommaParts(allocator, raw_name[open_index + 1 .. close_index]);
}

fn genericTypeParamExists(generic_params: []const typed.GenericParam, name: []const u8) bool {
    for (generic_params) |param| {
        if (param.kind == .type_param and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn typeNamesEqual(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, lhs, " \t"), std.mem.trim(u8, rhs, " \t"));
}

fn whereEnvironmentSatisfies(active: *session.Session, key: query_types.TraitGoalKey) bool {
    const predicates = wherePredicatesForKey(active, key) orelse return false;
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| {
                if (!typeHeadsEqual(canonicalTypeHead(active, key.module_id, bound.subject_name, predicates) catch return false, key.self_head)) continue;
                if (traitHeadsEqual(canonicalTraitHead(active, key.module_id, bound.contract_name) catch return false, key.trait_head)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn boundPredicateMatchesGoal(
    active: *session.Session,
    module_id: session.ModuleId,
    bound: typed.BoundPredicate,
    predicates: []const typed.WherePredicate,
    key: query_types.TraitGoalKey,
) bool {
    const trait_head = canonicalTraitHead(active, module_id, bound.contract_name) catch return false;
    if (!traitHeadsEqual(trait_head, key.trait_head)) return false;
    const self_head = canonicalTypeHead(active, module_id, bound.subject_name, predicates) catch return false;
    if (!typeHeadsEqual(self_head, key.self_head)) return false;
    return std.mem.eql(u8, std.mem.trim(u8, bound.subject_name, " \t"), keySelfTypeName(active, key));
}

fn solveBuiltinSend(active: *session.Session, module_id: session.ModuleId, raw_type_name: []const u8, signature_resolver: SignatureResolver) bool {
    var visiting = std.array_list.Managed([]const u8).init(active.allocator);
    defer visiting.deinit();
    return solveBuiltinSendInner(active, module_id, raw_type_name, &visiting, signature_resolver);
}

fn solveBuiltinSendInner(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    visiting: *std.array_list.Managed([]const u8),
    signature_resolver: SignatureResolver,
) bool {
    const boundary = parseBoundaryType(raw_type_name);
    if (boundary.kind != .value) return false;

    const trimmed = std.mem.trim(u8, boundary.inner_type_name, " \t");
    if (trimmed.len == 0) return false;
    if ((parseCallableTypeName(trimmed, active.allocator) catch null) != null) return true;

    if (std.mem.startsWith(u8, trimmed, "(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[1 .. trimmed.len - 1];
        const parts = typed_text.splitTopLevelCommaParts(active.allocator, inner) catch return false;
        defer active.allocator.free(parts);
        for (parts) |part| {
            if (!solveBuiltinSendInner(active, module_id, part, visiting, signature_resolver)) return false;
        }
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse return false;
        if (close_index + 1 != trimmed.len) return false;
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse return false;
        return solveBuiltinSendInner(active, module_id, std.mem.trim(u8, inner[0..separator], " \t"), visiting, signature_resolver);
    }

    if (isKnownStandardSendFamily(active, module_id, trimmed, visiting, signature_resolver)) return true;

    const base_name = baseTypeName(trimmed);
    const builtin = types.Builtin.fromName(base_name);
    if (builtin != .unsupported) return true;
    if (types.CAbiAlias.fromName(base_name)) |alias| return alias != .c_void;
    if (std.mem.eql(u8, base_name, "Char") or std.mem.eql(u8, base_name, "IndexRange")) return true;
    if (std.mem.eql(u8, base_name, "Task")) return false;

    for (visiting.items) |existing| {
        if (std.mem.eql(u8, existing, base_name)) return true;
    }
    visiting.append(base_name) catch return false;
    defer _ = visiting.pop();

    const item_id = resolveItemByName(active, module_id, base_name) orelse return false;
    const item = active.item(item_id);
    if (boundary_checks.kindForItem(item) == .capability) return false;
    const checked = signature_resolver(active, item_id) catch return false;

    return switch (checked.facts) {
        .struct_type => |struct_type| blk: {
            for (struct_type.fields) |field| {
                if (!solveBuiltinSendInner(active, module_id, field.type_name, visiting, signature_resolver)) break :blk false;
            }
            break :blk true;
        },
        .enum_type => |enum_type| blk: {
            for (enum_type.variants) |variant| {
                switch (variant.payload) {
                    .none => {},
                    .tuple_fields => |fields| for (fields) |field| {
                        if (!solveBuiltinSendInner(active, module_id, field.type_name, visiting, signature_resolver)) break :blk false;
                    },
                    .named_fields => |fields| for (fields) |field| {
                        if (!solveBuiltinSendInner(active, module_id, field.type_name, visiting, signature_resolver)) break :blk false;
                    },
                }
            }
            break :blk true;
        },
        .type_alias => |alias| solveBuiltinSendInner(active, checked.module_id, alias.target_type_name, visiting, signature_resolver),
        .opaque_type, .union_type, .function, .const_item, .trait_type, .impl_block, .none => false,
    };
}

fn solveBuiltinEq(active: *session.Session, module_id: session.ModuleId, raw_type_name: []const u8, signature_resolver: SignatureResolver) bool {
    var visiting = std.array_list.Managed([]const u8).init(active.allocator);
    defer visiting.deinit();
    return solveBuiltinEqHashInner(active, module_id, raw_type_name, .eq, &visiting, signature_resolver);
}

fn solveBuiltinHash(active: *session.Session, module_id: session.ModuleId, raw_type_name: []const u8, signature_resolver: SignatureResolver) bool {
    var visiting = std.array_list.Managed([]const u8).init(active.allocator);
    defer visiting.deinit();
    return solveBuiltinEqHashInner(active, module_id, raw_type_name, .hash, &visiting, signature_resolver);
}

const EqHashContract = enum {
    eq,
    hash,
};

fn solveBuiltinEqHashInner(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    contract: EqHashContract,
    visiting: *std.array_list.Managed([]const u8),
    signature_resolver: SignatureResolver,
) bool {
    const boundary = parseBoundaryType(raw_type_name);
    if (boundary.kind != .value) return false;

    const trimmed = std.mem.trim(u8, boundary.inner_type_name, " \t");
    if (trimmed.len == 0) return false;
    if ((parseCallableTypeName(trimmed, active.allocator) catch null) != null) return true;
    if (raw_pointer.parse(trimmed) != null) return true;

    if (std.mem.startsWith(u8, trimmed, "(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[1 .. trimmed.len - 1];
        const parts = typed_text.splitTopLevelCommaParts(active.allocator, inner) catch return false;
        defer active.allocator.free(parts);
        for (parts) |part| {
            if (!solveBuiltinEqHashInner(active, module_id, part, contract, visiting, signature_resolver)) return false;
        }
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse return false;
        if (close_index + 1 != trimmed.len) return false;
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse return false;
        return solveBuiltinEqHashInner(active, module_id, std.mem.trim(u8, inner[0..separator], " \t"), contract, visiting, signature_resolver);
    }

    if (isKnownStandardEqHashFamily(active, module_id, trimmed, contract, visiting, signature_resolver)) return true;

    const base_name = baseTypeName(trimmed);
    const builtin = types.Builtin.fromName(base_name);
    if (builtinEqHashSatisfies(builtin)) return true;
    if (types.CAbiAlias.fromName(base_name)) |alias| return alias != .c_void;
    if (std.mem.eql(u8, base_name, "Char") or
        std.mem.eql(u8, base_name, "IndexRange") or
        std.mem.eql(u8, base_name, "Bytes"))
    {
        return true;
    }

    for (visiting.items) |existing| {
        if (std.mem.eql(u8, existing, base_name)) return false;
    }
    visiting.append(base_name) catch return false;
    defer _ = visiting.pop();

    const item_id = resolveItemByName(active, module_id, base_name) orelse return false;
    const checked = signature_resolver(active, item_id) catch return false;
    return switch (checked.facts) {
        .type_alias => |alias| solveBuiltinEqHashInner(active, checked.module_id, alias.target_type_name, contract, visiting, signature_resolver),
        else => false,
    };
}

fn builtinEqHashSatisfies(builtin: types.Builtin) bool {
    return switch (builtin) {
        .unit, .bool, .i32, .u32, .index, .isize, .str => true,
        .unsupported => false,
    };
}

fn isKnownStandardEqHashFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    contract: EqHashContract,
    visiting: *std.array_list.Managed([]const u8),
    signature_resolver: SignatureResolver,
) bool {
    const base_name = baseTypeName(raw_type_name);
    const open_index = std.mem.indexOfScalar(u8, raw_type_name, '[') orelse return false;
    const close_index = findMatchingDelimiter(raw_type_name, open_index, '[', ']') orelse return false;
    if (close_index + 1 != raw_type_name.len) return false;
    const parts = typed_text.splitTopLevelCommaParts(active.allocator, raw_type_name[open_index + 1 .. close_index]) catch return false;
    defer active.allocator.free(parts);

    if (std.mem.eql(u8, base_name, "Option")) {
        return parts.len == 1 and solveBuiltinEqHashInner(active, module_id, parts[0], contract, visiting, signature_resolver);
    }
    if (std.mem.eql(u8, base_name, "Result")) {
        return parts.len == 2 and
            solveBuiltinEqHashInner(active, module_id, parts[0], contract, visiting, signature_resolver) and
            solveBuiltinEqHashInner(active, module_id, parts[1], contract, visiting, signature_resolver);
    }
    return false;
}

fn isKnownStandardSendFamily(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    visiting: *std.array_list.Managed([]const u8),
    signature_resolver: SignatureResolver,
) bool {
    const base_name = baseTypeName(raw_type_name);
    if (std.mem.eql(u8, base_name, "Str") or
        std.mem.eql(u8, base_name, "Bytes") or
        std.mem.eql(u8, base_name, "ByteBuffer") or
        std.mem.eql(u8, base_name, "Utf16") or
        std.mem.eql(u8, base_name, "Utf16Buffer"))
    {
        return true;
    }

    const open_index = std.mem.indexOfScalar(u8, raw_type_name, '[') orelse return false;
    const close_index = findMatchingDelimiter(raw_type_name, open_index, '[', ']') orelse return false;
    if (close_index + 1 != raw_type_name.len) return false;
    const parts = typed_text.splitTopLevelCommaParts(active.allocator, raw_type_name[open_index + 1 .. close_index]) catch return false;
    defer active.allocator.free(parts);

    if (std.mem.eql(u8, base_name, "Option") or std.mem.eql(u8, base_name, "List")) {
        return parts.len == 1 and solveBuiltinSendInner(active, module_id, parts[0], visiting, signature_resolver);
    }
    if (std.mem.eql(u8, base_name, "Result") or std.mem.eql(u8, base_name, "Map")) {
        return parts.len == 2 and
            solveBuiltinSendInner(active, module_id, parts[0], visiting, signature_resolver) and
            solveBuiltinSendInner(active, module_id, parts[1], visiting, signature_resolver);
    }
    return false;
}

fn canonicalWhereEnvironment(active: *session.Session, predicates: []const typed.WherePredicate) !@import("../intern/root.zig").SymbolId {
    if (predicates.len == 0) return active.internName("");

    var rendered = std.array_list.Managed([]const u8).init(active.allocator);
    defer {
        for (rendered.items) |item| active.allocator.free(item);
        rendered.deinit();
    }

    for (predicates) |predicate| {
        const text = switch (predicate) {
            .bound => |bound| try std.fmt.allocPrint(
                active.allocator,
                "B:{s}:{s}",
                .{ std.mem.trim(u8, bound.subject_name, " \t"), baseTypeName(bound.contract_name) },
            ),
            .projection_equality => |projection| try std.fmt.allocPrint(
                active.allocator,
                "P:{s}.{s}={s}",
                .{
                    std.mem.trim(u8, projection.subject_name, " \t"),
                    std.mem.trim(u8, projection.associated_name, " \t"),
                    std.mem.trim(u8, projection.value_type_name, " \t"),
                },
            ),
            .lifetime_outlives => |outlives| try std.fmt.allocPrint(
                active.allocator,
                "L:{s}:{s}",
                .{
                    std.mem.trim(u8, outlives.longer_name, " \t"),
                    std.mem.trim(u8, outlives.shorter_name, " \t"),
                },
            ),
            .type_outlives => |outlives| try std.fmt.allocPrint(
                active.allocator,
                "O:{s}:{s}",
                .{
                    std.mem.trim(u8, outlives.type_name, " \t"),
                    std.mem.trim(u8, outlives.lifetime_name, " \t"),
                },
            ),
        };
        try rendered.append(text);
    }

    std.mem.sort([]const u8, rendered.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var joined = std.array_list.Managed(u8).init(active.allocator);
    defer joined.deinit();
    for (rendered.items, 0..) |item, index| {
        if (index != 0) try joined.append(';');
        try joined.appendSlice(item);
    }

    return active.internName(joined.items);
}

fn keySelfTypeName(active: *const session.Session, key: query_types.TraitGoalKey) []const u8 {
    return active.internedName(key.self_type_symbol) orelse "";
}

fn wherePredicatesForKey(active: *const session.Session, key: query_types.TraitGoalKey) ?[]const typed.WherePredicate {
    for (active.caches.trait_goals.items) |entry| {
        if (goalKeysEqual(entry.key, key)) return entry.where_predicates;
    }
    return null;
}

fn reportTraitCycle(active: *session.Session, key: query_types.TraitGoalKey) !void {
    try active.pipeline.diagnostics.add(
        .@"error",
        "type.trait.cycle",
        null,
        "trait query cycle while solving '{s}: {s}'",
        .{ keySelfTypeName(active, key), traitHeadLabel(active, key.trait_head) },
    );
}

fn traitHeadLabel(active: *const session.Session, head: query_types.CanonicalTraitHead) []const u8 {
    return switch (head) {
        .builtin_send => "Send",
        .builtin_eq => "Eq",
        .builtin_hash => "Hash",
        .trait_item => |trait_id| blk: {
            const trait_entry = active.semantic_index.traitEntry(trait_id);
            break :blk active.item(trait_entry.item_id).name;
        },
        .opaque_name => |name| active.internedName(name) orelse "<opaque>",
    };
}

fn findOrCreateGoal(
    active: *session.Session,
    key: query_types.TraitGoalKey,
    where_predicates: []const typed.WherePredicate,
) !usize {
    for (active.caches.trait_goals.items, 0..) |*entry, index| {
        if (goalKeysEqual(entry.key, key)) {
            if (entry.where_predicates.len == 0 and where_predicates.len != 0) {
                entry.where_predicates = where_predicates;
            }
            return index;
        }
    }
    try active.caches.trait_goals.append(.{
        .key = key,
        .where_predicates = where_predicates,
    });
    return active.caches.trait_goals.items.len - 1;
}

fn findOrCreateImplLookup(active: *session.Session, key: query_types.ImplLookupKey) !usize {
    for (active.caches.impl_lookups.items, 0..) |entry, index| {
        if (implLookupKeysEqual(entry.key, key)) return index;
    }
    try active.caches.impl_lookups.append(.{ .key = key });
    return active.caches.impl_lookups.items.len - 1;
}

pub fn canonicalTraitHead(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_trait_name: []const u8,
) !query_types.CanonicalTraitHead {
    const name = baseTypeName(raw_trait_name);
    if (std.mem.eql(u8, name, "Send")) return .builtin_send;
    if (std.mem.eql(u8, name, "Eq")) return .builtin_eq;
    if (std.mem.eql(u8, name, "Hash")) return .builtin_hash;
    if (findTraitIdByName(active, module_id, name)) |trait_id| return .{ .trait_item = trait_id };
    return .{ .opaque_name = try active.internName(name) };
}

pub fn canonicalTypeHead(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
    where_predicates: []const typed.WherePredicate,
) !query_types.CanonicalTypeHead {
    const name = baseTypeName(raw_type_name);
    const builtin = types.Builtin.fromName(name);
    if (builtin != .unsupported) return .{ .builtin = builtin };
    if (whereEnvironmentMentionsSubject(where_predicates, name)) return .{ .generic_param = try active.internName(name) };
    if (resolveItemByName(active, module_id, name)) |item_id| return .{ .item = item_id };
    return .{ .opaque_name = try active.internName(name) };
}

fn findTraitIdByName(active: *session.Session, module_id: session.ModuleId, name: []const u8) ?session.TraitId {
    const item_id = resolveItemByName(active, module_id, name) orelse return null;
    const entry = active.semantic_index.itemEntry(item_id);
    return entry.trait_id;
}

fn traitSignatureByName(
    active: *session.Session,
    module_id: session.ModuleId,
    raw_trait_name: []const u8,
    signature_resolver: SignatureResolver,
) !?query_types.TraitSignature {
    return traitSignatureByHead(active, try canonicalTraitHead(active, module_id, raw_trait_name), signature_resolver);
}

fn traitSignatureByHead(
    active: *session.Session,
    head: query_types.CanonicalTraitHead,
    signature_resolver: SignatureResolver,
) !?query_types.TraitSignature {
    return switch (head) {
        .trait_item => |trait_id| blk: {
            const trait_entry = active.semantic_index.traitEntry(trait_id);
            const checked = signature_resolver(active, trait_entry.item_id) catch |err| switch (err) {
                error.CachedFailure, error.QueryCycle => break :blk null,
                else => return err,
            };
            break :blk switch (checked.facts) {
                .trait_type => |signature| signature,
                else => null,
            };
        },
        .builtin_send, .builtin_eq, .builtin_hash, .opaque_name => null,
    };
}

fn resolveItemByName(active: *session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.kind == .use_decl or item.kind == .module_decl) continue;
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        for (active.semantic_index.items.items, 0..) |_, index| {
            const item = active.item(.{ .index = index });
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return .{ .index = index };
        }
    }

    return null;
}

fn inheritedDefaultMethodCount(trait_methods: []const typed.TraitMethod, impl_methods: []const typed.TraitMethod) usize {
    var count: usize = 0;
    for (trait_methods) |method| {
        if (!method.has_default_body) continue;
        if (implContainsMethod(impl_methods, method.name)) continue;
        count += 1;
    }
    return count;
}

fn implContainsMethod(methods: []const typed.TraitMethod, method_name: []const u8) bool {
    for (methods) |method| {
        if (std.mem.eql(u8, method.name, method_name)) return true;
    }
    return false;
}

fn traitHasAssociatedType(signature: query_types.TraitSignature, name: []const u8) bool {
    for (signature.associated_types) |associated_type| {
        if (std.mem.eql(u8, associated_type.name, name)) return true;
    }
    return false;
}

fn traitHasAssociatedConst(signature: query_types.TraitSignature, name: []const u8) bool {
    for (signature.associated_consts) |associated_const| {
        if (std.mem.eql(u8, associated_const.name, name)) return true;
    }
    return false;
}

fn implBindsAssociatedType(bindings: []const typed.TraitAssociatedTypeBinding, name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn implBindsAssociatedConst(bindings: []const query_types.AssociatedConstBindingSignature, name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn whereEnvironmentMentionsSubject(predicates: []const typed.WherePredicate, subject_name: []const u8) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| if (std.mem.eql(u8, bound.subject_name, subject_name)) return true,
            .projection_equality => |projection| if (std.mem.eql(u8, projection.subject_name, subject_name)) return true,
            .type_outlives => |outlives| if (std.mem.eql(u8, outlives.type_name, subject_name)) return true,
            .lifetime_outlives => {},
        }
    }
    return false;
}

fn whereEnvironmentHasBound(predicates: []const typed.WherePredicate, subject_name: []const u8, contract_name: []const u8) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| {
                if (std.mem.eql(u8, bound.subject_name, subject_name) and
                    std.mem.eql(u8, baseTypeName(bound.contract_name), baseTypeName(contract_name))) return true;
            },
            else => {},
        }
    }
    return false;
}

fn whereEnvironmentHasProjection(predicates: []const typed.WherePredicate, projection: typed.ProjectionEqualityPredicate) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .projection_equality => |existing| {
                if (std.mem.eql(u8, existing.subject_name, projection.subject_name) and
                    std.mem.eql(u8, existing.associated_name, projection.associated_name) and
                    std.mem.eql(u8, existing.value_type_name, projection.value_type_name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn goalKeysEqual(lhs: query_types.TraitGoalKey, rhs: query_types.TraitGoalKey) bool {
    return lhs.module_id.index == rhs.module_id.index and
        traitHeadsEqual(lhs.trait_head, rhs.trait_head) and
        typeHeadsEqual(lhs.self_head, rhs.self_head) and
        lhs.self_type_symbol == rhs.self_type_symbol and
        lhs.where_env_symbol == rhs.where_env_symbol;
}

fn implLookupKeysEqual(lhs: query_types.ImplLookupKey, rhs: query_types.ImplLookupKey) bool {
    return lhs.module_id.index == rhs.module_id.index and
        traitHeadsEqual(lhs.trait_head, rhs.trait_head) and
        typeHeadsEqual(lhs.self_head, rhs.self_head);
}

fn cachedSignatureResolver(active: *session.Session, item_id: session.ItemId) anyerror!query_types.CheckedSignature {
    _ = active;
    _ = item_id;
    return error.MissingCheckedSignature;
}

pub fn traitHeadsEqual(lhs: query_types.CanonicalTraitHead, rhs: query_types.CanonicalTraitHead) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .builtin_send => true,
        .builtin_eq => true,
        .builtin_hash => true,
        .trait_item => |trait_id| trait_id.index == rhs.trait_item.index,
        .opaque_name => |name| name == rhs.opaque_name,
    };
}

pub fn typeHeadsEqual(lhs: query_types.CanonicalTypeHead, rhs: query_types.CanonicalTypeHead) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .builtin => |builtin| builtin == rhs.builtin,
        .item => |item_id| item_id.index == rhs.item.index,
        .generic_param => |name| name == rhs.generic_param,
        .opaque_name => |name| name == rhs.opaque_name,
    };
}
