const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const standard_families = @import("standard_families.zig");
const typed_expr = @import("../typed/expr.zig");
const signatures = @import("signatures.zig");
const typed_statement = @import("../typed/statement.zig");
const typed_text = @import("text.zig");
const tuple_types = @import("tuple_types.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const Expr = typed_expr.Expr;
const Statement = typed_statement.Statement;
const WherePredicate = signatures.WherePredicate;
const cloneExprForTyped = typed_expr.cloneExpr;
const isPlainIdentifier = typed_text.isPlainIdentifier;

pub const SubjectPattern = struct {
    condition: *Expr,
    bindings: []Statement.SelectBinding,
    irrefutable: bool,
    diagnostics: []Statement.PatternDiagnostic = &.{},

    pub fn deinit(self: SubjectPattern, allocator: Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        for (self.bindings) |binding| binding.deinit(allocator);
        allocator.free(self.bindings);
        for (self.diagnostics) |pattern_diagnostic| pattern_diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
    }
};

const PatternDiagnosticCollector = struct {
    allocator: Allocator,
    items: array_list.Managed(Statement.PatternDiagnostic),

    fn init(allocator: Allocator) PatternDiagnosticCollector {
        return .{
            .allocator = allocator,
            .items = array_list.Managed(Statement.PatternDiagnostic).init(allocator),
        };
    }

    fn deinit(self: *PatternDiagnosticCollector) void {
        for (self.items.items) |item| item.deinit(self.allocator);
        self.items.deinit();
    }

    fn add(
        self: *PatternDiagnosticCollector,
        severity: diag.Severity,
        code: []const u8,
        span: ?source.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        _ = severity;
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.items.append(.{
            .code = code,
            .message = message,
            .span = span orelse .{ .file_id = 0, .start = 0, .end = 0 },
        });
    }

    fn toOwnedSlice(self: *PatternDiagnosticCollector) ![]Statement.PatternDiagnostic {
        const result = try self.items.toOwnedSlice();
        self.items = array_list.Managed(Statement.PatternDiagnostic).init(self.allocator);
        return result;
    }
};

const BindingNameSet = struct {
    allocator: Allocator,
    names: array_list.Managed([]const u8),

    fn init(allocator: Allocator) BindingNameSet {
        return .{
            .allocator = allocator,
            .names = array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *BindingNameSet) void {
        self.names.deinit();
    }

    fn put(self: *BindingNameSet, name: []const u8) !void {
        if (self.contains(name)) return;
        try self.names.append(name);
    }

    fn contains(self: *const BindingNameSet, name: []const u8) bool {
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }
};

pub fn parseSubjectPatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    pattern_syntax: *const ast.BodyPatternSyntax,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!SubjectPattern {
    var binding_names = BindingNameSet.init(allocator);
    defer binding_names.deinit();
    var pattern_diagnostics = PatternDiagnosticCollector.init(allocator);
    defer pattern_diagnostics.deinit();
    var result = try parseSubjectPatternSyntaxRecursive(
        parseExpressionSyntaxFn,
        allocator,
        pattern_syntax,
        subject,
        current_symbol_prefix,
        scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        suspend_context,
        unsafe_context,
        &pattern_diagnostics,
        &binding_names,
    );
    result.diagnostics = try pattern_diagnostics.toOwnedSlice();
    return result;
}

fn parseSubjectPatternSyntaxRecursive(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    pattern_syntax: *const ast.BodyPatternSyntax,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
    pattern_diagnostics: *PatternDiagnosticCollector,
    binding_names: *BindingNameSet,
) anyerror!SubjectPattern {
    switch (pattern_syntax.node) {
        .wildcard => return .{
            .condition = try makeBoolExpr(allocator, true),
            .bindings = try allocator.alloc(Statement.SelectBinding, 0),
            .irrefutable = true,
        },
        .binding => |binding| {
            if (std.mem.eql(u8, binding.text, "true") or std.mem.eql(u8, binding.text, "false") or
                (@hasDecl(@TypeOf(scope.*), "isConst") and scope.isConst(binding.text)))
            {
                return parseLiteralPatternSyntax(
                    parseExpressionSyntaxFn,
                    allocator,
                    pattern_syntax,
                    subject,
                    scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    suspend_context,
                    unsafe_context,
                );
            }
            if (binding_names.contains(binding.text)) {
                try pattern_diagnostics.add(.@"error", "type.pattern.binding_duplicate", pattern_syntax.span, "duplicate binding name '{s}' within one pattern", .{binding.text});
                return try makeInvalidSubjectPattern(allocator);
            }
            try binding_names.put(binding.text);

            const bindings = try allocator.alloc(Statement.SelectBinding, 1);
            bindings[0] = .{
                .name = binding.text,
                .ty = subject.ty,
                .expr = try cloneExprForTyped(allocator, subject),
            };
            return .{
                .condition = try makeBoolExpr(allocator, true),
                .bindings = bindings,
                .irrefutable = true,
            };
        },
        .integer, .string => {
            return parseLiteralPatternSyntax(
                parseExpressionSyntaxFn,
                allocator,
                pattern_syntax,
                subject,
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                suspend_context,
                unsafe_context,
            );
        },
        .struct_pattern => |aggregate| {
            return try parseStructPatternSyntax(
                parseExpressionSyntaxFn,
                allocator,
                pattern_syntax.span,
                aggregate,
                subject,
                current_symbol_prefix,
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                suspend_context,
                unsafe_context,
                pattern_diagnostics,
                binding_names,
            );
        },
        .variant_pattern => |aggregate| {
            return try parseEnumVariantPatternSyntax(
                parseExpressionSyntaxFn,
                allocator,
                pattern_syntax.span,
                aggregate,
                subject,
                current_symbol_prefix,
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                suspend_context,
                unsafe_context,
                pattern_diagnostics,
                binding_names,
            );
        },
        .tuple => |items| return try parseTuplePatternSyntax(
            parseExpressionSyntaxFn,
            allocator,
            pattern_syntax.span,
            items,
            subject,
            current_symbol_prefix,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            suspend_context,
            unsafe_context,
            pattern_diagnostics,
            binding_names,
        ),
        .@"error" => {
            try pattern_diagnostics.add(.@"error", "type.pattern.syntax", pattern_syntax.span, "unsupported subject pattern syntax", .{});
            return try makeInvalidSubjectPattern(allocator);
        },
    }
}

fn parseTuplePatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    span: source.Span,
    items: []const *ast.BodyPatternSyntax,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
    pattern_diagnostics: *PatternDiagnosticCollector,
    binding_names: *BindingNameSet,
) anyerror!SubjectPattern {
    const subject_type_name = switch (subject.ty) {
        .named => |name| name,
        else => {
            try pattern_diagnostics.add(.@"error", "type.pattern.tuple_subject", span, "tuple subject patterns require a tuple-typed subject", .{});
            return try makeInvalidSubjectPattern(allocator);
        },
    };
    const parts = (try tuple_types.splitTypeParts(allocator, subject_type_name)) orelse {
        try pattern_diagnostics.add(.@"error", "type.pattern.tuple_subject", span, "tuple subject patterns require a tuple-typed subject", .{});
        return try makeInvalidSubjectPattern(allocator);
    };
    defer allocator.free(parts);
    if (!tuple_types.validTupleParts(parts)) {
        try pattern_diagnostics.add(.@"error", "type.pattern.tuple_subject", span, "tuple subject patterns require a tuple-typed subject", .{});
        return try makeInvalidSubjectPattern(allocator);
    }
    if (items.len != parts.len) {
        try pattern_diagnostics.add(.@"error", "type.pattern.tuple_arity", span, "tuple pattern has wrong arity", .{});
        return try makeInvalidSubjectPattern(allocator);
    }

    var condition = try makeBoolExpr(allocator, true);
    errdefer {
        condition.deinit(allocator);
        allocator.destroy(condition);
    }
    var bindings = array_list.Managed(Statement.SelectBinding).init(allocator);
    errdefer {
        for (bindings.items) |binding| binding.deinit(allocator);
        bindings.deinit();
    }

    var irrefutable = true;
    for (items, parts, 0..) |item_pattern, part, index| {
        const field_subject = try makeFieldExpr(allocator, subject, tuple_types.shallowTypeRefFromName(part), tuplePayloadFieldName(index));
        defer {
            field_subject.deinit(allocator);
            allocator.destroy(field_subject);
        }

        var subpattern = try parseSubjectPatternSyntaxRecursive(
            parseExpressionSyntaxFn,
            allocator,
            item_pattern,
            field_subject,
            current_symbol_prefix,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            suspend_context,
            unsafe_context,
            pattern_diagnostics,
            binding_names,
        );

        condition = try makeBoolAndExpr(allocator, condition, subpattern.condition);
        for (subpattern.bindings) |binding| try bindings.append(binding);
        allocator.free(subpattern.bindings);
        subpattern.bindings = &.{};
        irrefutable = irrefutable and subpattern.irrefutable;
    }

    return .{
        .condition = condition,
        .bindings = try bindings.toOwnedSlice(),
        .irrefutable = irrefutable,
    };
}

fn parseLiteralPatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    pattern_syntax: *const ast.BodyPatternSyntax,
    subject: *Expr,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!SubjectPattern {
    const expr_syntax = switch (pattern_syntax.node) {
        .binding => |binding| ast.BodyExprSyntax{
            .span = pattern_syntax.span,
            .node = .{ .name = binding },
        },
        .integer => |value| ast.BodyExprSyntax{
            .span = pattern_syntax.span,
            .node = .{ .integer = value },
        },
        .string => |value| ast.BodyExprSyntax{
            .span = pattern_syntax.span,
            .node = .{ .string = value },
        },
        else => unreachable,
    };
    const empty_where_predicates: []const WherePredicate = &.{};
    const pattern_expr = try parseExpressionSyntaxFn(
        allocator,
        &expr_syntax,
        subject.ty,
        scope,
        empty_where_predicates,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        pattern_syntax.span,
        suspend_context,
        unsafe_context,
    );
    const condition = try allocator.create(Expr);
    condition.* = .{
        .ty = types.TypeRef.fromBuiltin(.bool),
        .node = .{ .binary = .{
            .op = .eq,
            .lhs = try cloneExprForTyped(allocator, subject),
            .rhs = pattern_expr,
        } },
    };
    return .{
        .condition = condition,
        .bindings = try allocator.alloc(Statement.SelectBinding, 0),
        .irrefutable = false,
    };
}

fn parseStructPatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    span: source.Span,
    aggregate: ast.BodyPatternSyntax.Aggregate,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
    pattern_diagnostics: *PatternDiagnosticCollector,
    binding_names: *BindingNameSet,
) anyerror!SubjectPattern {
    const subject_struct_name = switch (subject.ty) {
        .named => |name| name,
        else => {
            try pattern_diagnostics.add(.@"error", "type.pattern.struct_subject", span, "struct patterns require a struct-typed subject", .{});
            return try makeInvalidSubjectPattern(allocator);
        },
    };
    if (!std.mem.eql(u8, subject_struct_name, aggregate.name.text)) {
        try pattern_diagnostics.add(.@"error", "type.pattern.struct_subject", span, "struct pattern '{s}' does not match subject type '{s}'", .{
            aggregate.name.text,
            subject_struct_name,
        });
        return try makeInvalidSubjectPattern(allocator);
    }

    const prototype = findStructPrototype(struct_prototypes, aggregate.name.text) orelse {
        try pattern_diagnostics.add(.@"error", "type.pattern.struct_unknown", span, "unknown struct pattern type '{s}'", .{aggregate.name.text});
        return try makeInvalidSubjectPattern(allocator);
    };

    switch (aggregate.payload) {
        .tuple => {
            try pattern_diagnostics.add(.@"error", "type.pattern.struct_payload", span, "struct subject patterns require exact named-field patterns", .{});
            return try makeInvalidSubjectPattern(allocator);
        },
        .none, .fields => {},
    }

    const fields = switch (aggregate.payload) {
        .fields => |fields| fields,
        .none => &.{},
        else => unreachable,
    };

    var seen = try allocator.alloc(bool, prototype.fields.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var bindings = array_list.Managed(Statement.SelectBinding).init(allocator);
    errdefer {
        for (bindings.items) |binding| binding.deinit(allocator);
        bindings.deinit();
    }

    var condition = try makeBoolExpr(allocator, true);
    errdefer {
        condition.deinit(allocator);
        allocator.destroy(condition);
    }

    var had_error = false;
    var irrefutable = true;

    for (fields) |field_pattern| {
        const field_index = findFieldIndex(prototype.fields, field_pattern.name.text) orelse {
            try pattern_diagnostics.add(.@"error", "type.pattern.struct_field_unknown", span, "unknown field '{s}' in exact struct pattern '{s}'", .{
                field_pattern.name.text,
                prototype.name,
            });
            had_error = true;
            continue;
        };
        if (seen[field_index]) {
            try pattern_diagnostics.add(.@"error", "type.pattern.struct_field_duplicate", span, "duplicate field '{s}' in exact struct pattern '{s}'", .{
                field_pattern.name.text,
                prototype.name,
            });
            had_error = true;
            continue;
        }
        seen[field_index] = true;

        const field = prototype.fields[field_index];
        if (!fieldVisibleFromCurrentModule(prototype.symbol_name, current_symbol_prefix, field.visibility)) {
            try pattern_diagnostics.add(.@"error", "type.pattern.field_visibility", span, "field '{s}' in exact pattern '{s}' is not visible here", .{
                field.name,
                prototype.name,
            });
            had_error = true;
        }
        const field_subject = try makeFieldExpr(allocator, subject, field.ty, field.name);
        defer {
            field_subject.deinit(allocator);
            allocator.destroy(field_subject);
        }

        var subpattern = try parseSubjectPatternSyntaxRecursive(
            parseExpressionSyntaxFn,
            allocator,
            field_pattern.pattern,
            field_subject,
            current_symbol_prefix,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            suspend_context,
            unsafe_context,
            pattern_diagnostics,
            binding_names,
        );

        condition = try makeBoolAndExpr(allocator, condition, subpattern.condition);
        for (subpattern.bindings) |binding| try bindings.append(binding);
        allocator.free(subpattern.bindings);
        subpattern.bindings = &.{};
        irrefutable = irrefutable and subpattern.irrefutable;
    }

    for (prototype.fields, 0..) |field, index| {
        if (seen[index]) continue;
        try pattern_diagnostics.add(.@"error", "type.pattern.struct_field_missing", span, "missing field '{s}' in exact struct pattern '{s}'", .{
            field.name,
            prototype.name,
        });
        had_error = true;
    }

    if (had_error) {
        return .{
            .condition = condition,
            .bindings = try bindings.toOwnedSlice(),
            .irrefutable = false,
        };
    }

    return .{
        .condition = condition,
        .bindings = try bindings.toOwnedSlice(),
        .irrefutable = irrefutable,
    };
}

fn parseEnumVariantPatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    span: source.Span,
    aggregate: ast.BodyPatternSyntax.Aggregate,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    suspend_context: bool,
    unsafe_context: bool,
    pattern_diagnostics: *PatternDiagnosticCollector,
    binding_names: *BindingNameSet,
) anyerror!SubjectPattern {
    const split = splitVariantPath(aggregate.name.text) orelse {
        try pattern_diagnostics.add(.@"error", "type.pattern.enum_syntax", span, "malformed enum variant pattern '{s}'", .{aggregate.name.text});
        return try makeInvalidSubjectPattern(allocator);
    };
    if (standard_families.familyFromName(split.enum_name) != null) {
        return parseStandardEnumVariantSubjectPatternSyntax(
            parseExpressionSyntaxFn,
            allocator,
            aggregate,
            split,
            subject,
            current_symbol_prefix,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            span,
            suspend_context,
            unsafe_context,
            pattern_diagnostics,
            binding_names,
        );
    }
    switch (subject.ty) {
        .named => |subject_name| {
            if (!std.mem.eql(u8, subject_name, split.enum_name)) {
                try pattern_diagnostics.add(.@"error", "type.pattern.enum_subject", span, "enum variant pattern '{s}' does not match subject type '{s}'", .{
                    aggregate.name.text,
                    subject_name,
                });
                return try makeInvalidSubjectPattern(allocator);
            }
        },
        else => {
            try pattern_diagnostics.add(.@"error", "type.pattern.enum_subject", span, "enum variant patterns require an enum-typed subject", .{});
            return try makeInvalidSubjectPattern(allocator);
        },
    }

    const prototype = findEnumPrototype(enum_prototypes, split.enum_name) orelse {
        try pattern_diagnostics.add(.@"error", "type.pattern.enum_unknown", span, "unknown enum pattern type '{s}'", .{split.enum_name});
        return try makeInvalidSubjectPattern(allocator);
    };
    const variant = findEnumVariant(prototype, split.variant_name) orelse {
        try pattern_diagnostics.add(.@"error", "type.pattern.enum_variant_unknown", span, "unknown variant '{s}' on enum '{s}'", .{
            split.variant_name,
            prototype.name,
        });
        return try makeInvalidSubjectPattern(allocator);
    };

    const subject_tag = try makeFieldExpr(allocator, subject, types.TypeRef.fromBuiltin(.i32), "tag");
    const tag_condition = try makeEqExpr(allocator, subject_tag, try makeEnumTagExpr(allocator, prototype, variant.name));

    switch (variant.payload) {
        .none => {
            switch (aggregate.payload) {
                .none => {},
                else => {
                    tag_condition.deinit(allocator);
                    allocator.destroy(tag_condition);
                    try pattern_diagnostics.add(.@"error", "type.pattern.enum_payload_missing", span, "unit variant '{s}.{s}' does not take payload patterns", .{
                        prototype.name,
                        variant.name,
                    });
                    return try makeInvalidSubjectPattern(allocator);
                },
            }
            return .{
                .condition = tag_condition,
                .bindings = try allocator.alloc(Statement.SelectBinding, 0),
                .irrefutable = false,
            };
        },
        .tuple_fields => |tuple_fields| {
            const payload_items = switch (aggregate.payload) {
                .tuple => |items| items,
                else => {
                    tag_condition.deinit(allocator);
                    allocator.destroy(tag_condition);
                    try pattern_diagnostics.add(.@"error", "type.pattern.enum_payload_required", span, "payload variant '{s}.{s}' requires tuple payload patterns", .{
                        prototype.name,
                        variant.name,
                    });
                    return try makeInvalidSubjectPattern(allocator);
                },
            };

            if (payload_items.len != tuple_fields.len) {
                tag_condition.deinit(allocator);
                allocator.destroy(tag_condition);
                try pattern_diagnostics.add(.@"error", "type.pattern.enum_tuple_arity", span, "tuple payload pattern for '{s}.{s}' has wrong arity", .{
                    prototype.name,
                    variant.name,
                });
                return try makeInvalidSubjectPattern(allocator);
            }

            var condition = tag_condition;
            var bindings = array_list.Managed(Statement.SelectBinding).init(allocator);
            errdefer {
                condition.deinit(allocator);
                allocator.destroy(condition);
                for (bindings.items) |binding| binding.deinit(allocator);
                bindings.deinit();
            }

            for (payload_items, tuple_fields, 0..) |item_pattern, tuple_field, index| {
                const field_subject = try makeEnumPayloadFieldExpr(allocator, subject, variant.name, tuplePayloadFieldName(index), tuple_field.ty);
                defer {
                    field_subject.deinit(allocator);
                    allocator.destroy(field_subject);
                }

                var subpattern = try parseSubjectPatternSyntaxRecursive(
                    parseExpressionSyntaxFn,
                    allocator,
                    item_pattern,
                    field_subject,
                    current_symbol_prefix,
                    scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    suspend_context,
                    unsafe_context,
                    pattern_diagnostics,
                    binding_names,
                );

                condition = try makeBoolAndExpr(allocator, condition, subpattern.condition);
                for (subpattern.bindings) |binding| try bindings.append(binding);
                allocator.free(subpattern.bindings);
                subpattern.bindings = &.{};
            }

            return .{
                .condition = condition,
                .bindings = try bindings.toOwnedSlice(),
                .irrefutable = false,
            };
        },
        .named_fields => |named_fields| {
            const payload_fields = switch (aggregate.payload) {
                .fields => |fields| fields,
                else => {
                    tag_condition.deinit(allocator);
                    allocator.destroy(tag_condition);
                    try pattern_diagnostics.add(.@"error", "type.pattern.enum_payload_required", span, "payload variant '{s}.{s}' requires named payload patterns", .{
                        prototype.name,
                        variant.name,
                    });
                    return try makeInvalidSubjectPattern(allocator);
                },
            };

            var seen = try allocator.alloc(bool, named_fields.len);
            defer allocator.free(seen);
            @memset(seen, false);

            var condition = tag_condition;
            var bindings = array_list.Managed(Statement.SelectBinding).init(allocator);
            errdefer {
                condition.deinit(allocator);
                allocator.destroy(condition);
                for (bindings.items) |binding| binding.deinit(allocator);
                bindings.deinit();
            }

            var had_error = false;
            for (payload_fields) |field_pattern| {
                const field_index = findFieldIndex(named_fields, field_pattern.name.text) orelse {
                    try pattern_diagnostics.add(.@"error", "type.pattern.enum_field_unknown", span, "unknown payload field '{s}' in variant '{s}.{s}'", .{
                        field_pattern.name.text,
                        prototype.name,
                        variant.name,
                    });
                    had_error = true;
                    continue;
                };
                if (seen[field_index]) {
                    try pattern_diagnostics.add(.@"error", "type.pattern.enum_field_duplicate", span, "duplicate payload field '{s}' in variant '{s}.{s}'", .{
                        field_pattern.name.text,
                        prototype.name,
                        variant.name,
                    });
                    had_error = true;
                    continue;
                }
                seen[field_index] = true;

                const field = named_fields[field_index];
                if (!fieldVisibleFromCurrentModule(prototype.symbol_name, current_symbol_prefix, field.visibility)) {
                    try pattern_diagnostics.add(.@"error", "type.pattern.field_visibility", span, "payload field '{s}' in variant '{s}.{s}' is not visible here", .{
                        field.name,
                        prototype.name,
                        variant.name,
                    });
                    had_error = true;
                }
                const field_subject = try makeEnumPayloadFieldExpr(allocator, subject, variant.name, field.name, field.ty);
                defer {
                    field_subject.deinit(allocator);
                    allocator.destroy(field_subject);
                }

                var subpattern = try parseSubjectPatternSyntaxRecursive(
                    parseExpressionSyntaxFn,
                    allocator,
                    field_pattern.pattern,
                    field_subject,
                    current_symbol_prefix,
                    scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    suspend_context,
                    unsafe_context,
                    pattern_diagnostics,
                    binding_names,
                );

                condition = try makeBoolAndExpr(allocator, condition, subpattern.condition);
                for (subpattern.bindings) |binding| try bindings.append(binding);
                allocator.free(subpattern.bindings);
                subpattern.bindings = &.{};
            }

            for (named_fields, 0..) |field, index| {
                if (seen[index]) continue;
                try pattern_diagnostics.add(.@"error", "type.pattern.enum_field_missing", span, "missing payload field '{s}' in variant '{s}.{s}'", .{
                    field.name,
                    prototype.name,
                    variant.name,
                });
                had_error = true;
            }

            if (had_error) {
                return .{
                    .condition = condition,
                    .bindings = try bindings.toOwnedSlice(),
                    .irrefutable = false,
                };
            }

            return .{
                .condition = condition,
                .bindings = try bindings.toOwnedSlice(),
                .irrefutable = false,
            };
        },
    }
}

fn parseStandardEnumVariantSubjectPatternSyntax(
    comptime parseExpressionSyntaxFn: anytype,
    allocator: Allocator,
    aggregate: ast.BodyPatternSyntax.Aggregate,
    split: VariantPath,
    subject: *Expr,
    current_symbol_prefix: []const u8,
    scope: anytype,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
    pattern_diagnostics: *PatternDiagnosticCollector,
    binding_names: *BindingNameSet,
) anyerror!SubjectPattern {
    const maybe_variant = try standard_families.variantForSubject(allocator, subject.ty, split.enum_name, split.variant_name);
    const variant = maybe_variant orelse {
        switch (subject.ty) {
            .named => |subject_name| try pattern_diagnostics.add(.@"error", "type.pattern.enum_subject", span, "standard enum variant pattern '{s}' does not match subject type '{s}'", .{
                aggregate.name.text,
                subject_name,
            }),
            else => try pattern_diagnostics.add(.@"error", "type.pattern.enum_subject", span, "standard enum variant patterns require an enum-typed subject", .{}),
        }
        return try makeInvalidSubjectPattern(allocator);
    };

    const subject_tag = try makeFieldExpr(allocator, subject, types.TypeRef.fromBuiltin(.i32), "tag");
    const tag_condition = try makeEqExpr(allocator, subject_tag, try makeEnumTagExprRaw(allocator, variant.concrete_type_name, variant.family_name, variant.variant_name));

    const payload_type_name = variant.payload_type_name orelse {
        switch (aggregate.payload) {
            .none => {},
            else => {
                tag_condition.deinit(allocator);
                allocator.destroy(tag_condition);
                try pattern_diagnostics.add(.@"error", "type.pattern.enum_payload_missing", span, "unit variant '{s}.{s}' does not take payload patterns", .{
                    variant.family_name,
                    variant.variant_name,
                });
                return try makeInvalidSubjectPattern(allocator);
            },
        }
        return .{
            .condition = tag_condition,
            .bindings = try allocator.alloc(Statement.SelectBinding, 0),
            .irrefutable = false,
        };
    };

    const payload_items = switch (aggregate.payload) {
        .tuple => |items| items,
        else => {
            tag_condition.deinit(allocator);
            allocator.destroy(tag_condition);
            try pattern_diagnostics.add(.@"error", "type.pattern.enum_payload_required", span, "payload variant '{s}.{s}' requires tuple payload patterns", .{
                variant.family_name,
                variant.variant_name,
            });
            return try makeInvalidSubjectPattern(allocator);
        },
    };

    if (payload_items.len != 1) {
        tag_condition.deinit(allocator);
        allocator.destroy(tag_condition);
        try pattern_diagnostics.add(.@"error", "type.pattern.enum_tuple_arity", span, "tuple payload pattern for '{s}.{s}' has wrong arity", .{
            variant.family_name,
            variant.variant_name,
        });
        return try makeInvalidSubjectPattern(allocator);
    }

    var condition = tag_condition;
    errdefer {
        condition.deinit(allocator);
        allocator.destroy(condition);
    }

    const field_subject = try makeEnumPayloadFieldExpr(
        allocator,
        subject,
        variant.variant_name,
        variant.payload_field_name.?,
        standard_families.typeRefFromName(payload_type_name),
    );
    defer {
        field_subject.deinit(allocator);
        allocator.destroy(field_subject);
    }

    var subpattern = try parseSubjectPatternSyntaxRecursive(
        parseExpressionSyntaxFn,
        allocator,
        payload_items[0],
        field_subject,
        current_symbol_prefix,
        scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        suspend_context,
        unsafe_context,
        pattern_diagnostics,
        binding_names,
    );

    condition = try makeBoolAndExpr(allocator, condition, subpattern.condition);
    const bindings = subpattern.bindings;
    subpattern.bindings = &.{};

    return .{
        .condition = condition,
        .bindings = bindings,
        .irrefutable = false,
    };
}

fn makeBoolAndExpr(allocator: Allocator, lhs: *Expr, rhs: *Expr) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = types.TypeRef.fromBuiltin(.bool),
        .node = .{ .binary = .{
            .op = .bool_and,
            .lhs = lhs,
            .rhs = rhs,
        } },
    };
    return expr;
}

fn makeEqExpr(allocator: Allocator, lhs: *Expr, rhs: *Expr) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = types.TypeRef.fromBuiltin(.bool),
        .node = .{ .binary = .{
            .op = .eq,
            .lhs = lhs,
            .rhs = rhs,
        } },
    };
    return expr;
}

fn makeFieldExpr(allocator: Allocator, base: *const Expr, ty: types.TypeRef, field_name: []const u8) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = ty,
        .node = .{ .field = .{
            .base = try cloneExprForTyped(allocator, base),
            .field_name = field_name,
        } },
    };
    return expr;
}

fn makeEnumPayloadFieldExpr(
    allocator: Allocator,
    subject: *const Expr,
    variant_name: []const u8,
    field_name: []const u8,
    field_ty: types.TypeRef,
) !*Expr {
    const payload_expr = try makeFieldExpr(allocator, subject, .unsupported, "payload");
    defer {
        payload_expr.deinit(allocator);
        allocator.destroy(payload_expr);
    }

    const variant_expr = try makeFieldExpr(allocator, payload_expr, .unsupported, variant_name);
    defer {
        variant_expr.deinit(allocator);
        allocator.destroy(variant_expr);
    }

    return makeFieldExpr(allocator, variant_expr, field_ty, field_name);
}

fn makeEnumTagExprRaw(allocator: Allocator, enum_name: []const u8, enum_symbol: []const u8, variant_name: []const u8) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = types.TypeRef.fromBuiltin(.i32),
        .node = .{ .enum_tag = .{
            .enum_name = enum_name,
            .enum_symbol = enum_symbol,
            .variant_name = variant_name,
        } },
    };
    return expr;
}

fn makeEnumTagExpr(allocator: Allocator, prototype: anytype, variant_name: []const u8) !*Expr {
    return makeEnumTagExprRaw(allocator, prototype.name, prototype.symbol_name, variant_name);
}

fn makeInvalidSubjectPattern(allocator: Allocator) !SubjectPattern {
    return .{
        .condition = try makeBoolExpr(allocator, false),
        .bindings = try allocator.alloc(Statement.SelectBinding, 0),
        .irrefutable = false,
    };
}

fn makeBoolExpr(allocator: Allocator, value: bool) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = types.TypeRef.fromBuiltin(.bool),
        .node = .{ .bool_lit = value },
    };
    return expr;
}

fn tuplePayloadFieldName(index: usize) []const u8 {
    return switch (index) {
        0 => "_0",
        1 => "_1",
        2 => "_2",
        3 => "_3",
        4 => "_4",
        5 => "_5",
        6 => "_6",
        7 => "_7",
        8 => "_8",
        9 => "_9",
        else => "_overflow",
    };
}

fn findStructPrototype(struct_prototypes: anytype, name: []const u8) ?std.meta.Child(@TypeOf(struct_prototypes)) {
    for (struct_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype;
    }
    return null;
}

fn findEnumPrototype(enum_prototypes: anytype, name: []const u8) ?std.meta.Child(@TypeOf(enum_prototypes)) {
    for (enum_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype;
    }
    return null;
}

fn findEnumVariant(prototype: anytype, name: []const u8) ?std.meta.Child(@TypeOf(prototype.variants)) {
    for (prototype.variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

fn findFieldIndex(fields: anytype, name: []const u8) ?usize {
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, name)) return index;
    }
    return null;
}

fn fieldVisibleFromCurrentModule(type_symbol_name: []const u8, current_symbol_prefix: []const u8, visibility: ast.Visibility) bool {
    if (current_symbol_prefix.len == 0) {
        if (std.mem.indexOf(u8, type_symbol_name, "__") == null) return true;
    } else if (std.mem.startsWith(u8, type_symbol_name, current_symbol_prefix)) {
        return true;
    }
    return switch (visibility) {
        .pub_item, .pub_package => true,
        .private => false,
    };
}

const VariantPath = struct {
    enum_name: []const u8,
    variant_name: []const u8,
};

fn splitVariantPath(raw: []const u8) ?VariantPath {
    const dot_index = std.mem.lastIndexOfScalar(u8, raw, '.') orelse return null;
    const enum_name = std.mem.trim(u8, raw[0..dot_index], " \t");
    const variant_name = std.mem.trim(u8, raw[dot_index + 1 ..], " \t");
    if (!isPlainIdentifier(enum_name) or !isPlainIdentifier(variant_name)) return null;
    return .{
        .enum_name = enum_name,
        .variant_name = variant_name,
    };
}
