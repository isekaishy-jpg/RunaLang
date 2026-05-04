const std = @import("std");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const base_signatures = @import("../signature_types.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const Allocator = std.mem.Allocator;

pub const GenericParamKind = base_signatures.GenericParamKind;
pub const GenericParam = base_signatures.GenericParam;
pub const BoundPredicate = base_signatures.BoundPredicate;
pub const ProjectionEqualityPredicate = base_signatures.ProjectionEqualityPredicate;
pub const LifetimeOutlivesPredicate = base_signatures.LifetimeOutlivesPredicate;
pub const TypeOutlivesPredicate = base_signatures.TypeOutlivesPredicate;
pub const WherePredicate = base_signatures.WherePredicate;
pub const cloneWherePredicates = base_signatures.cloneWherePredicates;
pub const deinitWherePredicates = base_signatures.deinitWherePredicates;

pub fn isLifetimeName(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '\'') return false;
    const body = raw[1..];
    if (std.mem.eql(u8, body, "static")) return true;
    if (!(std.ascii.isAlphabetic(body[0]) or body[0] == '_')) return false;
    for (body[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

pub fn isBuiltinLifetime(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "'static");
}

pub fn lowerGenericParams(
    allocator: Allocator,
    generic_params: ?ast.GenericParamListSyntax,
    diagnostics: *diag.Bag,
) ![]GenericParam {
    const syntax = generic_params orelse return allocator.alloc(GenericParam, 0);

    if (syntax.invalid_kind) |invalid_kind| switch (invalid_kind) {
        .empty_list => try diagnostics.add(.@"error", "type.generic.param", syntax.span, "generic and lifetime parameter lists may not be empty", .{}),
        .malformed_entry => try diagnostics.add(.@"error", "type.generic.param", syntax.span, "malformed mixed generic and lifetime parameter list", .{}),
    };

    var lowered = std.array_list.Managed(GenericParam).init(allocator);
    errdefer lowered.deinit();

    for (syntax.params) |param| {
        const lowered_param = switch (param.kind) {
            .lifetime_param => blk: {
                if (!isLifetimeName(param.name)) {
                    try diagnostics.add(.@"error", "type.generic.param", param.span, "malformed mixed generic and lifetime parameter list", .{});
                    continue;
                }
                if (isBuiltinLifetime(param.name)) {
                    try diagnostics.add(.@"error", "type.lifetime.param", param.span, "lifetime parameter list may not declare builtin lifetime '{s}'", .{param.name});
                    continue;
                }
                break :blk GenericParam{ .name = param.name, .kind = .lifetime_param };
            },
            .type_param => blk: {
                if (!isPlainIdentifier(param.name)) {
                    try diagnostics.add(.@"error", "type.generic.param", param.span, "malformed mixed generic and lifetime parameter list", .{});
                    continue;
                }
                break :blk GenericParam{ .name = param.name, .kind = .type_param };
            },
        };

        var duplicate = false;
        for (lowered.items) |existing| {
            if (std.mem.eql(u8, existing.name, lowered_param.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.generic.param_duplicate", param.span, "duplicate generic or lifetime parameter '{s}'", .{lowered_param.name});
            continue;
        }

        try lowered.append(lowered_param);
    }

    return lowered.toOwnedSlice();
}

pub fn mergeGenericParams(
    allocator: Allocator,
    inherited: []const GenericParam,
    local: []const GenericParam,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]GenericParam {
    var combined = std.array_list.Managed(GenericParam).init(allocator);
    errdefer combined.deinit();

    for (inherited) |param| {
        try combined.append(param);
    }
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

pub fn genericParamExists(generic_params: []const GenericParam, name: []const u8, kind: GenericParamKind) bool {
    for (generic_params) |param| {
        if (param.kind != kind) continue;
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

pub fn validateLifetimeReference(name: []const u8, generic_params: []const GenericParam, span: source.Span, diagnostics: *diag.Bag) !void {
    if (!isLifetimeName(name)) {
        try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed lifetime name '{s}'", .{name});
        return;
    }
    if (isBuiltinLifetime(name) or genericParamExists(generic_params, name, .lifetime_param)) return;
    try diagnostics.add(.@"error", "type.lifetime.unknown", span, "unknown lifetime name '{s}'", .{name});
}

pub fn lowerWherePredicates(
    allocator: Allocator,
    clauses: []const ast.WhereClauseSyntax,
    generic_params: []const GenericParam,
    allow_self: bool,
    diagnostics: *diag.Bag,
) ![]WherePredicate {
    var predicates = std.array_list.Managed(WherePredicate).init(allocator);
    errdefer {
        for (predicates.items) |*predicate| predicate.deinit(allocator);
        predicates.deinit();
    }

    for (clauses) |clause| {
        if (clause.invalid_kind == .empty_clause) {
            try diagnostics.add(.@"error", "type.where.syntax", clause.span, "where clauses require at least one predicate", .{});
        }

        for (clause.predicates) |predicate| {
            switch (predicate) {
                .bound => |bound| {
                    if (bound.subject_name.len == 0 or type_syntax_support.containsInvalid(bound.contract_type)) {
                        try diagnostics.add(.@"error", "type.where.syntax", bound.span, "malformed where predicate", .{});
                        continue;
                    }
                    if ((!allow_self or !std.mem.eql(u8, bound.subject_name, "Self")) and !genericParamExists(generic_params, bound.subject_name, .type_param)) {
                        try diagnostics.add(.@"error", "type.where.unknown_name", bound.span, "unknown constrained name '{s}'", .{bound.subject_name});
                        continue;
                    }
                    try predicates.append(.{ .bound = .{
                        .subject_name = bound.subject_name,
                        .contract_type_syntax = try bound.contract_type.clone(allocator),
                    } });
                },
                .projection_equality => |projection| {
                    const rendered_value_type = try type_syntax_support.render(allocator, projection.value_type);
                    defer allocator.free(rendered_value_type);
                    if ((!allow_self or !std.mem.eql(u8, projection.subject_name, "Self")) and !genericParamExists(generic_params, projection.subject_name, .type_param)) {
                        try diagnostics.add(.@"error", "type.where.projection", projection.span, "malformed projection equality predicate '{s}.{s} = {s}'", .{
                            projection.subject_name,
                            projection.associated_name,
                            rendered_value_type,
                        });
                        continue;
                    }
                    if (!isPlainIdentifier(projection.associated_name) or type_syntax_support.containsInvalid(projection.value_type)) {
                        try diagnostics.add(.@"error", "type.where.projection", projection.span, "malformed projection equality predicate '{s}.{s} = {s}'", .{
                            projection.subject_name,
                            projection.associated_name,
                            rendered_value_type,
                        });
                        continue;
                    }
                    try predicates.append(.{ .projection_equality = .{
                        .subject_name = projection.subject_name,
                        .associated_name = projection.associated_name,
                        .value_type_syntax = try projection.value_type.clone(allocator),
                    } });
                },
                .lifetime_outlives => |outlives| try predicates.append(.{ .lifetime_outlives = .{
                    .longer_name = outlives.longer_name,
                    .shorter_name = outlives.shorter_name,
                } }),
                .type_outlives => |outlives| {
                    if ((!allow_self or !std.mem.eql(u8, outlives.type_name, "Self")) and !genericParamExists(generic_params, outlives.type_name, .type_param)) {
                        try diagnostics.add(.@"error", "type.where.unknown_name", outlives.span, "unknown constrained name '{s}'", .{outlives.type_name});
                        continue;
                    }
                    try predicates.append(.{ .type_outlives = .{
                        .type_name = outlives.type_name,
                        .lifetime_name = outlives.lifetime_name,
                    } });
                },
                .invalid => |invalid| {
                    if (std.mem.indexOfScalar(u8, invalid.text, '=')) |_| {
                        try diagnostics.add(.@"error", "type.where.projection", invalid.span, "malformed projection equality predicate '{s}'", .{invalid.text});
                    } else {
                        try diagnostics.add(.@"error", "type.where.syntax", invalid.span, "malformed where predicate '{s}'", .{invalid.text});
                    }
                },
            }
        }
    }

    return predicates.toOwnedSlice();
}

fn isPlainIdentifier(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (!(std.ascii.isAlphabetic(raw[0]) or raw[0] == '_')) return false;
    for (raw[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}
