const std = @import("std");
const const_ir = @import("const_ir.zig");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const standard_families = @import("standard_families.zig");
const typed = @import("../typed/root.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");
const checked_body = @import("checked_body.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
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

const ConstResolver = *const fn (active: *session.Session, const_id: session.ConstId) anyerror!query_types.ConstResult;
const AssociatedConstResolver = *const fn (active: *session.Session, module_id: session.ModuleId, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value;

pub fn analyzeBody(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    trait_resolver: anytype,
    signature_resolver: anytype,
    const_resolver: ConstResolver,
    associated_const_resolver: AssociatedConstResolver,
) !Summary {
    var summary = Summary{
        .checked_subject_pattern_count = body.subject_pattern_sites.len,
        .irrefutable_subject_pattern_count = body.summary.irrefutable_subject_pattern_count,
        .rejected_unreachable_pattern_count = body.unreachable_pattern_sites.len,
        .rejected_structural_pattern_count = body.pattern_diagnostic_sites.len,
        .checked_repeat_iteration_count = body.repeat_iteration_sites.len,
    };

    for (body.unreachable_pattern_sites) |_| {
        try diagnostics.add(
            .@"error",
            "type.select.unreachable",
            body.item.span,
            "later subject-select arms are unreachable after an earlier irrefutable arm",
            .{},
        );
    }
    for (body.pattern_diagnostic_sites) |site| {
        try diagnostics.add(
            .@"error",
            site.code,
            body.item.span,
            "{s}",
            .{site.message},
        );
    }
    for (body.statement_sites) |statement| {
        if (statement.kind != .select_stmt or statement.select_subject == null) continue;
        try validateConstantPatterns(active, body, statement, diagnostics, const_resolver, associated_const_resolver, &summary);
    }
    for (body.statement_sites) |statement| {
        if (statement.kind != .select_stmt or statement.select_subject == null) continue;
        if (try subjectSelectExhaustive(active, body, statement, signature_resolver)) continue;
        summary.rejected_non_exhaustive_pattern_count += 1;
        try diagnostics.add(
            .@"error",
            "type.select.non_exhaustive",
            body.item.span,
            "subject select in '{s}' is not exhaustive",
            .{body.item.name},
        );
    }
    for (body.repeat_iteration_sites) |site| {
        if (try repeatIterableSatisfied(active, body, site, trait_resolver)) continue;
        summary.rejected_repeat_iterable_count += 1;
        try diagnostics.add(
            .@"error",
            "type.repeat.iterable",
            body.item.span,
            "type '{s}' does not satisfy repeat iteration",
            .{typeRefLabel(site.iterable_type)},
        );
    }

    return summary;
}

fn subjectSelectExhaustive(
    active: *session.Session,
    body: query_types.CheckedBody,
    statement: checked_body.StatementSite,
    signature_resolver: anytype,
) !bool {
    if (statement.select_else_block_id != null) return true;
    if (statementHasPatternDiagnostics(body, statement.index)) return true;
    for (statement.select_arms) |arm| {
        if (arm.pattern_irrefutable) return true;
    }

    const subject = statement.select_subject orelse return true;
    return switch (subject.ty) {
        .builtin => |builtin| switch (builtin) {
            .bool => boolSubjectSelectExhaustive(statement),
            else => false,
        },
        .named => |name| try enumSubjectSelectExhaustive(active, body.module_id, statement, name, signature_resolver),
        .unsupported => true,
    };
}

fn statementHasPatternDiagnostics(body: query_types.CheckedBody, statement_index: usize) bool {
    for (body.pattern_diagnostic_sites) |site| {
        if (site.statement_index == statement_index) return true;
    }
    return false;
}

fn validateConstantPatterns(
    active: *session.Session,
    body: query_types.CheckedBody,
    statement: checked_body.StatementSite,
    diagnostics: *diag.Bag,
    const_resolver: ConstResolver,
    associated_const_resolver: AssociatedConstResolver,
    summary: *Summary,
) !void {
    const subject_temp_name = statement.select_subject_temp_name orelse return;
    for (statement.select_arms) |arm| {
        const pattern_expr = equalityPatternExpr(arm.condition, subject_temp_name) orelse continue;
        switch (pattern_expr.node) {
            .bool_lit, .integer, .string, .enum_tag => continue,
            .identifier => |name| {
                if (findConstIdInModule(active, body.module_id, name) == null) continue;
            },
            else => {},
        }
        summary.checked_constant_pattern_count += 1;
        const lowered = arm.constant_pattern_expr orelse {
            const err = arm.constant_pattern_lower_error orelse error.UnsupportedConstExpr;
            summary.rejected_constant_pattern_count += 1;
            try reportConstantPatternError(diagnostics, body.item.span, err);
            continue;
        };
        var value = const_ir.evalExpr(active.allocator, PatternConstContext{
            .active = active,
            .module_id = body.module_id,
            .const_resolver = const_resolver,
            .associated_const_resolver = associated_const_resolver,
        }, lowered, resolvePatternConstIdentifier) catch |err| {
            summary.rejected_constant_pattern_count += 1;
            try reportConstantPatternError(diagnostics, body.item.span, err);
            continue;
        };
        const_ir.deinitValue(active.allocator, &value);
    }
}

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

const PatternConstContext = struct {
    active: *session.Session,
    module_id: session.ModuleId,
    const_resolver: ConstResolver,
    associated_const_resolver: AssociatedConstResolver,

    pub fn resolveAssociatedConst(self: PatternConstContext, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value {
        return self.associated_const_resolver(self.active, self.module_id, owner_name, const_name);
    }
};

fn resolvePatternConstIdentifier(context: PatternConstContext, name: []const u8) anyerror!const_ir.Value {
    const const_id = findConstIdInModule(context.active, context.module_id, name) orelse return error.UnknownConst;
    return (try context.const_resolver(context.active, const_id)).value;
}

fn findConstIdInModule(active: *session.Session, module_id: session.ModuleId, name: []const u8) ?session.ConstId {
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
        for (active.semantic_index.consts.items, 0..) |const_entry, index| {
            const item = active.item(const_entry.item_id);
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return .{ .index = index };
        }
    }
    return null;
}

fn reportConstantPatternError(diagnostics: *diag.Bag, span: ?source.Span, err: anyerror) !void {
    const code: []const u8 = switch (err) {
        error.QueryCycle => "type.pattern.const_cycle",
        error.UnknownConst => "type.pattern.const_unknown",
        error.AmbiguousAssociatedConst => "type.pattern.const_associated_ambiguous",
        error.ConstOverflow => "type.pattern.const_overflow",
        error.DivideByZero => "type.pattern.const_divide_by_zero",
        error.InvalidRemainder => "type.pattern.const_invalid_remainder",
        error.InvalidShiftCount => "type.pattern.const_invalid_shift",
        error.ConstIndexOutOfRange => "type.pattern.const_index",
        error.InvalidConversion => "type.pattern.const_conversion",
        else => "type.pattern.const_expr",
    };
    try diagnostics.add(
        .@"error",
        code,
        span,
        "constant pattern is not a valid const expression",
        .{},
    );
}

fn boolSubjectSelectExhaustive(statement: checked_body.StatementSite) bool {
    const subject_temp_name = statement.select_subject_temp_name orelse return false;
    var saw_true = false;
    var saw_false = false;
    for (statement.select_arms) |arm| {
        const value = boolPatternValue(arm.condition, subject_temp_name) orelse continue;
        if (value) {
            saw_true = true;
        } else {
            saw_false = true;
        }
    }
    return saw_true and saw_false;
}

fn boolPatternValue(expr: *const typed.Expr, subject_temp_name: []const u8) ?bool {
    return switch (expr.node) {
        .binary => |binary| {
            if (binary.op != .eq) return null;
            if (isSubjectTemp(binary.lhs, subject_temp_name)) {
                return switch (binary.rhs.node) {
                    .bool_lit => |value| value,
                    else => null,
                };
            }
            if (isSubjectTemp(binary.rhs, subject_temp_name)) {
                return switch (binary.lhs.node) {
                    .bool_lit => |value| value,
                    else => null,
                };
            }
            return null;
        },
        else => null,
    };
}

fn enumSubjectSelectExhaustive(
    active: *session.Session,
    module_id: session.ModuleId,
    statement: checked_body.StatementSite,
    raw_type_name: []const u8,
    signature_resolver: anytype,
) !bool {
    const enum_name = typed_text.baseTypeName(raw_type_name);
    const subject_temp_name = statement.select_subject_temp_name orelse return false;
    if (try standard_families.exhaustiveVariantNames(active.allocator, raw_type_name)) |variants| {
        return standardSubjectSelectExhaustive(statement, subject_temp_name, raw_type_name, variants);
    }
    const item_id = resolveTypeItemId(active, module_id, enum_name) orelse return false;
    const signature = try signature_resolver(active, item_id);
    const enum_signature = switch (signature.facts) {
        .enum_type => |enum_type| enum_type,
        else => return false,
    };

    for (enum_signature.variants) |variant| {
        var covered = false;
        for (statement.select_arms) |arm| {
            const covered_variant = enumPatternVariant(arm.condition, subject_temp_name, enum_name) orelse continue;
            if (!std.mem.eql(u8, covered_variant, variant.name)) continue;
            covered = true;
            break;
        }
        if (!covered) return false;
    }
    return true;
}

fn standardSubjectSelectExhaustive(
    statement: checked_body.StatementSite,
    subject_temp_name: []const u8,
    raw_type_name: []const u8,
    variants: []const []const u8,
) bool {
    for (variants) |variant| {
        var covered = false;
        for (statement.select_arms) |arm| {
            const covered_variant = enumPatternVariant(arm.condition, subject_temp_name, raw_type_name) orelse continue;
            if (!std.mem.eql(u8, covered_variant, variant)) continue;
            covered = true;
            break;
        }
        if (!covered) return false;
    }
    return true;
}

fn enumPatternVariant(expr: *const typed.Expr, subject_temp_name: []const u8, enum_name: []const u8) ?[]const u8 {
    return switch (expr.node) {
        .binary => |binary| switch (binary.op) {
            .eq => enumEqPatternVariant(binary.lhs, binary.rhs, subject_temp_name, enum_name) orelse
                enumEqPatternVariant(binary.rhs, binary.lhs, subject_temp_name, enum_name),
            .bool_and => enumPatternVariant(binary.lhs, subject_temp_name, enum_name) orelse
                enumPatternVariant(binary.rhs, subject_temp_name, enum_name),
            else => null,
        },
        else => null,
    };
}

fn enumEqPatternVariant(lhs: *const typed.Expr, rhs: *const typed.Expr, subject_temp_name: []const u8, enum_name: []const u8) ?[]const u8 {
    if (!isSubjectTag(lhs, subject_temp_name)) return null;
    return switch (rhs.node) {
        .enum_tag => |tag| if (std.mem.eql(u8, tag.enum_name, enum_name)) tag.variant_name else null,
        else => null,
    };
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

fn repeatIterableSatisfied(
    active: *session.Session,
    body: query_types.CheckedBody,
    site: checked_body.RepeatIterationSite,
    trait_resolver: anytype,
) !bool {
    const type_name = switch (site.iterable_type) {
        .named => |name| name,
        else => return false,
    };
    const result = trait_resolver(active, body.module_id, type_name, "Iterable", body.function.where_predicates) catch return false;
    return result.satisfied;
}

fn typeRefLabel(ty: types.TypeRef) []const u8 {
    return switch (ty) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| name,
        .unsupported => "Unsupported",
    };
}

fn resolveTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    if (findLocalTypeItemId(active, module_id, name)) |item_id| return item_id;

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        return findItemIdBySymbol(active, binding.target_symbol);
    }

    return null;
}

fn findLocalTypeItemId(active: *const session.Session, module_id: session.ModuleId, name: []const u8) ?session.ItemId {
    for (active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (std.mem.eql(u8, item.name, name)) return .{ .index = index };
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
