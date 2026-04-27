const ast = @import("../ast/root.zig");
const body_scope = @import("body_scope.zig");
const conversions = @import("conversions.zig");
const diag = @import("../diag/root.zig");
const dynamic_library = @import("../runtime/dynamic_library/root.zig");
const foreign_callable_types = @import("foreign_callable_types.zig");
const raw_pointer = @import("../raw_pointer/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const typed_text = @import("text.zig");
const type_support = @import("type_support.zig");
const tuple_types = @import("tuple_types.zig");
const types = @import("../types/root.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const ScopeStack = body_scope.ScopeStack;
const boundaryAccessCompatible = type_support.boundaryAccessCompatible;
const boundaryInnerTypeCompatible = type_support.boundaryInnerTypeCompatible;
const callArgumentTypeCompatible = type_support.callArgumentTypeCompatible;
const cVariadicArgumentTypeSupported = type_support.cVariadicArgumentTypeSupported;
const cVariadicCallArityValid = type_support.cVariadicCallArityValid;
const cVariadicFixedParameterCount = type_support.cVariadicFixedParameterCount;
const cVariadicTailIndex = type_support.cVariadicTailIndex;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findMethodPrototype = type_support.findMethodPrototype;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const inferExprBoundaryTypeInScope = type_support.inferExprBoundaryTypeInScope;
const parseBoundaryType = type_support.parseBoundaryType;

pub const Summary = struct {
    checked_expression_count: usize = 0,
    prepared_issue_count: usize = 0,
    checked_conversion_count: usize = 0,
    rejected_conversion_count: usize = 0,
};

pub const Result = struct {
    summary: Summary,
    conversion_facts: []const query_types.CheckedConversionFact,
};

pub fn analyzeBody(
    active: *session.Session,
    allocator: Allocator,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
) !Result {
    var summary = Summary{
        .checked_expression_count = body.expression_sites.len,
    };

    if (body.function.block_syntax) |block_syntax| {
        var scope = ScopeStack.init(allocator);
        defer scope.deinit();
        try scope.push();
        defer scope.pop();
        try body_scope.seedModuleConsts(&scope, body);
        try body_scope.seedParameters(&scope, body.parameters);
        try analyzeBlock(active, &scope, body, &block_syntax.structured, &body.function.body, diagnostics, &summary, false);

        var dynamic_state = DynamicLibraryState.init(allocator);
        defer dynamic_state.deinit();
        try analyzeKnownDynamicLibraryInvalidation(&dynamic_state, &block_syntax.structured, &body.function.body, diagnostics, &summary);
    }

    var conversion_facts = std.array_list.Managed(query_types.CheckedConversionFact).init(allocator);
    errdefer conversion_facts.deinit();

    for (body.expression_sites) |site| {
        if (site.kind != .conversion) continue;
        const mode = queryConversionMode(site.conversion_mode orelse continue);
        const status = conversionStatus(mode, site.source_type, site.target_type);
        const diagnostic_code: ?[]const u8 = if (status == .rejected)
            "type.expr.conversion"
        else
            null;
        try conversion_facts.append(.{
            .expression_id = site.id,
            .mode = mode,
            .source_type = site.source_type,
            .target_type = site.target_type,
            .result_type = site.ty,
            .status = status,
            .diagnostic_code = diagnostic_code,
        });
        summary.checked_conversion_count += 1;
        if (status == .rejected) {
            summary.rejected_conversion_count += 1;
            try diagnostics.add(
                .@"error",
                diagnostic_code.?,
                body.item.span,
                "conversion from '{s}' to '{s}' is not valid in this conversion mode",
                .{ site.source_type.displayName(), site.target_type.displayName() },
            );
        }
    }

    return .{
        .summary = summary,
        .conversion_facts = try conversion_facts.toOwnedSlice(),
    };
}

fn analyzeBlock(
    active: *session.Session,
    scope: *ScopeStack,
    body: query_types.CheckedBody,
    syntax_block: *const ast.BodyBlockSyntax,
    typed_block: *const typed.Block,
    diagnostics: *diag.Bag,
    summary: *Summary,
    unsafe_context: bool,
) anyerror!void {
    if (syntax_block.statements.len != typed_block.statements.items.len) return error.InvalidBodySync;

    for (syntax_block.statements, typed_block.statements.items) |syntax_statement, typed_statement| {
        try analyzeStatement(active, scope, body, syntax_statement, typed_statement, diagnostics, summary, unsafe_context);
    }
}

fn analyzeStatement(
    active: *session.Session,
    scope: *ScopeStack,
    body: query_types.CheckedBody,
    syntax_statement: ast.BodyStatementSyntax,
    typed_statement: typed.Statement,
    diagnostics: *diag.Bag,
    summary: *Summary,
    unsafe_context: bool,
) anyerror!void {
    switch (syntax_statement) {
        .placeholder, .break_stmt, .continue_stmt => {},
        .let_decl => |binding| {
            const lowered = switch (typed_statement) {
                .let_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            try analyzeExpr(active, scope, body, binding.expr, lowered.expr, diagnostics, summary, unsafe_context);
            try scope.putWithOrigin(lowered.name, lowered.ty, true, inferExprBoundaryTypeInScope(scope, lowered.expr));
        },
        .const_decl => |binding| {
            const lowered = switch (typed_statement) {
                .const_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            try analyzeExpr(active, scope, body, binding.expr, lowered.expr, diagnostics, summary, unsafe_context);
            try scope.putWithOrigin(lowered.name, lowered.ty, false, inferExprBoundaryTypeInScope(scope, lowered.expr));
        },
        .assign_stmt => |assign| switch (typed_statement) {
            .assign_stmt => |lowered| {
                try analyzeExpr(active, scope, body, assign.expr, lowered.expr, diagnostics, summary, unsafe_context);
                if (assign.op == null and assign.target.node == .name) {
                    const name = std.mem.trim(u8, assign.target.node.name.text, " \t");
                    scope.updateOrigin(name, inferExprBoundaryTypeInScope(scope, lowered.expr));
                }
            },
            .placeholder => {},
            else => return error.InvalidBodySync,
        },
        .select_stmt => |select_syntax| {
            const lowered = switch (typed_statement) {
                .select_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            if (select_syntax.subject) |subject_syntax| {
                const subject = lowered.subject orelse return error.InvalidBodySync;
                try analyzeExpr(active, scope, body, subject_syntax, subject, diagnostics, summary, unsafe_context);
            }

            var lowered_arm_index: usize = 0;
            for (select_syntax.arms) |arm_syntax| {
                if (select_syntax.subject != null and arm_syntax.head == .guard) continue;
                if (select_syntax.subject == null and arm_syntax.head == .pattern) continue;
                if (lowered_arm_index >= lowered.arms.len) return error.InvalidBodySync;

                const lowered_arm = lowered.arms[lowered_arm_index];
                lowered_arm_index += 1;

                if (select_syntax.subject == null) {
                    const guard_syntax = arm_syntax.head.guard;
                    try analyzeExpr(active, scope, body, guard_syntax, lowered_arm.condition, diagnostics, summary, unsafe_context);
                }

                try scope.push();
                defer scope.pop();
                if (select_syntax.subject != null) {
                    for (lowered_arm.bindings) |binding_site| {
                        try scope.put(binding_site.name, binding_site.ty, true);
                    }
                }
                try analyzeBlock(active, scope, body, arm_syntax.body, lowered_arm.body, diagnostics, summary, unsafe_context);
            }

            if (select_syntax.else_body) |else_body| {
                const lowered_else = lowered.else_body orelse return error.InvalidBodySync;
                try scope.push();
                defer scope.pop();
                try analyzeBlock(active, scope, body, else_body, lowered_else, diagnostics, summary, unsafe_context);
            }
        },
        .repeat_stmt => |repeat_syntax| {
            const lowered = switch (typed_statement) {
                .loop_stmt => |value| value,
                .placeholder => null,
                else => return error.InvalidBodySync,
            };

            switch (repeat_syntax.header) {
                .while_condition => |condition_syntax| {
                    const condition = lowered orelse return;
                    const typed_condition = condition.condition orelse return error.InvalidBodySync;
                    try analyzeExpr(active, scope, body, condition_syntax, typed_condition, diagnostics, summary, unsafe_context);
                },
                .iteration => {},
                .infinite, .invalid => {},
            }

            if (lowered) |loop_data| {
                try scope.push();
                defer scope.pop();
                if (repeat_syntax.header == .iteration) {
                    const iteration = repeat_syntax.header.iteration;
                    if (iteration.binding.node == .binding) {
                        const name = std.mem.trim(u8, iteration.binding.node.binding.text, " \t");
                        if (!std.mem.eql(u8, name, "true") and !std.mem.eql(u8, name, "false")) {
                            try scope.put(name, loop_data.iteration_type orelse .unsupported, false);
                        }
                    }
                }
                try analyzeBlock(active, scope, body, repeat_syntax.body, loop_data.body, diagnostics, summary, unsafe_context);
            }
        },
        .unsafe_block => |unsafe_body| {
            const lowered = switch (typed_statement) {
                .unsafe_block => |value| value,
                else => return error.InvalidBodySync,
            };
            try scope.push();
            defer scope.pop();
            try analyzeBlock(active, scope, body, unsafe_body, lowered, diagnostics, summary, true);
        },
        .defer_stmt => |expr_syntax| {
            const expr = switch (typed_statement) {
                .defer_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            try analyzeExpr(active, scope, body, expr_syntax, expr, diagnostics, summary, unsafe_context);
        },
        .return_stmt => |expr_syntax| {
            const lowered = switch (typed_statement) {
                .return_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            if (expr_syntax) |value| {
                const expr = lowered orelse return error.InvalidBodySync;
                try analyzeExpr(active, scope, body, value, expr, diagnostics, summary, unsafe_context);
            }
        },
        .expr_stmt => |expr_syntax| {
            const expr = switch (typed_statement) {
                .expr_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            try analyzeExpr(active, scope, body, expr_syntax, expr, diagnostics, summary, unsafe_context);
        },
    }
}

fn analyzeExpr(
    active: *session.Session,
    scope: *ScopeStack,
    body: query_types.CheckedBody,
    syntax_expr: *const ast.BodyExprSyntax,
    typed_expr: ?*const typed.Expr,
    diagnostics: *diag.Bag,
    summary: *Summary,
    unsafe_context: bool,
) anyerror!void {
    const effective_unsafe = unsafe_context or syntax_expr.force_unsafe;

    switch (syntax_expr.node) {
        .@"error", .integer, .string => {},
        .name => |name| {
            const text = std.mem.trim(u8, name.text, " \t");
            if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return;
            if (std.mem.eql(u8, text, "await")) return;
            const expr = typed_expr orelse return;
            if (expr.ty.isUnsupported() and !scope.contains(text) and !moduleHasNamedBinding(body, text)) {
                try emit(diagnostics, summary, "type.name.unknown", syntax_expr.span, "unknown name '{s}'", .{text});
            }
        },
        .group => |group| try analyzeExpr(active, scope, body, group, typed_expr, diagnostics, summary, effective_unsafe),
        .tuple => |items| {
            const typed_items = if (typed_expr) |expr| switch (expr.node) {
                .tuple => |tuple| tuple.items,
                else => &[_]*typed.Expr{},
            } else &[_]*typed.Expr{};
            if (items.len < 2) {
                try emit(diagnostics, summary, "type.tuple.arity", syntax_expr.span, "tuple expressions must have at least two elements", .{});
            }
            for (items, 0..) |item, index| {
                const item_typed = if (index < typed_items.len) typed_items[index] else null;
                try analyzeExpr(active, scope, body, item, item_typed, diagnostics, summary, effective_unsafe);
            }
        },
        .array => |items| {
            const typed_items = switch (typed_expr orelse return) {
                else => blk: {
                    break :blk switch (typed_expr.?.node) {
                        .array => |array| array.items,
                        else => &[_]*typed.Expr{},
                    };
                },
            };
            var index: usize = 0;
            while (index < items.len) : (index += 1) {
                const item_typed = if (index < typed_items.len) typed_items[index] else null;
                try analyzeExpr(active, scope, body, items[index], item_typed, diagnostics, summary, effective_unsafe);
            }
            if (typed_expr == null or fixedArrayElementType(typed_expr.?.ty) == null) {
                try emit(diagnostics, summary, "type.expr.array.type", syntax_expr.span, "array literal requires a fixed array contextual type", .{});
            }
        },
        .array_repeat => |array_repeat| {
            const typed_value = if (typed_expr) |expr| switch (expr.node) {
                .array_repeat => |repeat_expr| repeat_expr.value,
                else => null,
            } else null;
            const typed_length = if (typed_expr) |expr| switch (expr.node) {
                .array_repeat => |repeat_expr| repeat_expr.length,
                else => null,
            } else null;
            try analyzeExpr(active, scope, body, array_repeat.value, typed_value, diagnostics, summary, effective_unsafe);
            try analyzeExpr(active, scope, body, array_repeat.length, typed_length, diagnostics, summary, effective_unsafe);
            if (typed_expr == null or fixedArrayElementType(typed_expr.?.ty) == null) {
                try emit(diagnostics, summary, "type.expr.array.type", syntax_expr.span, "array repetition requires a fixed array contextual type", .{});
            }
        },
        .raw_pointer => |raw_pointer_expr| {
            const place_typed = if (typed_expr) |expr| switch (expr.node) {
                .call => |call| if (call.args.len == 1 and raw_pointer.isLeafCallee(call.callee)) call.args[0] else null,
                else => null,
            } else null;
            try analyzeExpr(active, scope, body, raw_pointer_expr.place, place_typed, diagnostics, summary, effective_unsafe);
            if (!effective_unsafe) {
                try emit(diagnostics, summary, "type.raw_pointer.formation.unsafe", syntax_expr.span, "raw pointer formation requires #unsafe", .{});
            }
        },
        .field => |field| {
            const base_typed = typedFieldBase(typed_expr);
            try analyzeExpr(active, scope, body, field.base, base_typed, diagnostics, summary, effective_unsafe);

            const field_name = std.mem.trim(u8, field.field_name.text, " \t");
            if (tuple_types.projectionIndex(field_name)) |projection_index| {
                const base_expr = base_typed orelse return;
                const tuple_name = switch (base_expr.ty) {
                    .named => |name| name,
                    else => {
                        if (!base_expr.ty.isUnsupported()) {
                            try emit(diagnostics, summary, "type.tuple.projection", syntax_expr.span, "tuple projection requires a tuple-typed base expression", .{});
                        }
                        return;
                    },
                };
                if ((try tuple_types.projectionElementType(diagnostics.allocator, tuple_name, projection_index)) == null) {
                    try emit(diagnostics, summary, "type.tuple.projection", syntax_expr.span, "invalid tuple projection '.{s}'", .{field_name});
                }
                return;
            }

            const expr = typed_expr orelse return;
            switch (expr.node) {
                .enum_variant, .enum_tag, .enum_constructor_target, .method_target => return,
                else => {},
            }

            const base_expr = base_typed orelse return;
            const target_type_name = switch (base_expr.ty) {
                .named => |name| parseBoundaryType(name).inner_type_name,
                else => {
                    if (!base_expr.ty.isUnsupported()) {
                        try emit(diagnostics, summary, "type.field.base", syntax_expr.span, "field projection requires a struct-typed base expression", .{});
                    }
                    return;
                },
            };
            const struct_name = typed_text.baseTypeName(target_type_name);
            const fields = findStructFields(body, struct_name) orelse {
                try emit(diagnostics, summary, "type.field.struct_unsupported", syntax_expr.span, "stage0 field projection supports only locally declared struct types", .{});
                return;
            };
            for (fields) |field_proto| {
                if (std.mem.eql(u8, field_proto.name, field_name)) return;
            }
            try emit(diagnostics, summary, "type.field.unknown", syntax_expr.span, "unknown field '{s}' on struct '{s}'", .{
                field_name,
                struct_name,
            });
        },
        .index => |index_syntax| {
            const base_typed = if (typed_expr) |expr| switch (expr.node) {
                .index => |index_expr| index_expr.base,
                else => null,
            } else null;
            const index_typed = if (typed_expr) |expr| switch (expr.node) {
                .index => |index_expr| index_expr.index,
                else => null,
            } else null;
            try analyzeExpr(active, scope, body, index_syntax.base, base_typed, diagnostics, summary, effective_unsafe);
            try analyzeExpr(active, scope, body, index_syntax.index, index_typed, diagnostics, summary, effective_unsafe);

            if (index_typed) |value| {
                if (!value.ty.eql(types.TypeRef.fromBuiltin(.index)) and !value.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.keyed_access.index", syntax_expr.span, "keyed access requires an Index expression", .{});
                }
            }
            if (base_typed) |value| {
                if (fixedArrayElementType(value.ty) == null and !value.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.keyed_access.base", syntax_expr.span, "keyed access requires a fixed array expression", .{});
                }
            }
        },
        .unary => |unary| {
            const operand_typed = if (typed_expr) |expr| switch (expr.node) {
                .unary => |lowered| lowered.operand,
                else => null,
            } else null;
            try analyzeExpr(active, scope, body, unary.operand, operand_typed, diagnostics, summary, effective_unsafe);

            const operand = operand_typed orelse return;
            const operator = std.mem.trim(u8, unary.operator.text, " \t");
            if (std.mem.eql(u8, operator, "!")) {
                if (!operand.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !operand.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.unary_not", syntax_expr.span, "unary ! requires Bool", .{});
                }
            } else if (std.mem.eql(u8, operator, "-")) {
                if (!operand.ty.eql(types.TypeRef.fromBuiltin(.i32)) and !operand.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.unary_neg", syntax_expr.span, "unary - requires I32 in stage0", .{});
                }
            } else if (std.mem.eql(u8, operator, "~")) {
                if (!operand.ty.isInteger() and !operand.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.unary_bit_not", syntax_expr.span, "unary ~ requires an integer operand", .{});
                }
            }
        },
        .binary => |binary| {
            const operator = std.mem.trim(u8, binary.operator.text, " \t");
            if (std.mem.eql(u8, operator, "as")) {
                const operand_typed = if (typed_expr) |expr| switch (expr.node) {
                    .conversion => |conversion| conversion.operand,
                    else => null,
                } else null;
                try analyzeExpr(active, scope, body, binary.lhs, operand_typed, diagnostics, summary, effective_unsafe);
                return;
            }

            const lhs_typed = if (typed_expr) |expr| switch (expr.node) {
                .binary => |lowered| lowered.lhs,
                else => null,
            } else null;
            const rhs_typed = if (typed_expr) |expr| switch (expr.node) {
                .binary => |lowered| lowered.rhs,
                else => null,
            } else null;
            try analyzeExpr(active, scope, body, binary.lhs, lhs_typed, diagnostics, summary, effective_unsafe);
            try analyzeExpr(active, scope, body, binary.rhs, rhs_typed, diagnostics, summary, effective_unsafe);

            const lhs = lhs_typed orelse return;
            const rhs = rhs_typed orelse return;
            if (std.mem.eql(u8, operator, "||")) {
                if (!lhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !lhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.bool_or", syntax_expr.span, "|| requires Bool operands", .{});
                }
                if (!rhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.bool_or", syntax_expr.span, "|| requires Bool operands", .{});
                }
            } else if (std.mem.eql(u8, operator, "&&")) {
                if (!lhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !lhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.bool_and", syntax_expr.span, "&& requires Bool operands", .{});
                }
                if (!rhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.bool_and", syntax_expr.span, "&& requires Bool operands", .{});
                }
            } else if (std.mem.eql(u8, operator, "&") or std.mem.eql(u8, operator, "^") or std.mem.eql(u8, operator, "|")) {
                if (!(lhs.ty.eql(rhs.ty) and lhs.ty.isInteger()) and !lhs.ty.isUnsupported() and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.bitwise", syntax_expr.span, "bitwise operators require matching integer operands", .{});
                }
            } else if (isComparisonOperator(operator)) {
                if (isComparisonSyntax(binary.lhs)) {
                    try emit(diagnostics, summary, "type.expr.compare_chain", syntax_expr.span, "comparison chaining requires explicit grouping", .{});
                } else if (!comparisonOperandsCompatible(operator, lhs.ty, rhs.ty) and !lhs.ty.isUnsupported() and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.compare", syntax_expr.span, "comparison operands must have matching types", .{});
                }
            } else if (std.mem.eql(u8, operator, "<<") or std.mem.eql(u8, operator, ">>")) {
                if (!(lhs.ty.isInteger() and rhs.ty.eql(types.TypeRef.fromBuiltin(.index))) and !lhs.ty.isUnsupported() and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.shift", syntax_expr.span, "shift operators require an integer left operand and Index shift count", .{});
                }
            } else if (std.mem.eql(u8, operator, "+") or std.mem.eql(u8, operator, "-")) {
                if (!(lhs.ty.eql(rhs.ty) and lhs.ty.isNumeric()) and !lhs.ty.isUnsupported() and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.additive", syntax_expr.span, "additive operators require matching numeric operands", .{});
                }
            } else if (std.mem.eql(u8, operator, "*") or std.mem.eql(u8, operator, "/") or std.mem.eql(u8, operator, "%")) {
                if (!(lhs.ty.eql(rhs.ty) and lhs.ty.isNumeric()) and !lhs.ty.isUnsupported() and !rhs.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.expr.multiplicative", syntax_expr.span, "multiplicative operators require matching numeric operands", .{});
                }
            }
        },
        .call => |call| {
            const typed_args = directCallArgs(typed_expr);
            for (call.args, 0..) |arg_syntax, index| {
                const arg_typed = if (index < typed_args.len) typed_args[index] else null;
                try analyzeExpr(active, scope, body, arg_syntax, arg_typed, diagnostics, summary, effective_unsafe);
            }

            switch (call.callee.node) {
                .name => |callee_name| {
                    const name = std.mem.trim(u8, callee_name.text, " \t");
                    if (try resolveDirectFunction(active, body, name)) |resolved| {
                        try validateDirectCall(scope, body, name, call.callee.span, resolved, typed_args, effective_unsafe, diagnostics, summary);
                        return;
                    }
                    if (dynamic_library.isPublicCallee(name)) {
                        try validateDynamicLibraryCall(name, typed_expr, typed_args, effective_unsafe, syntax_expr.span, diagnostics, summary);
                        return;
                    }
                    if (findStructFields(body, name)) |fields| {
                        try validateRetainedStorageArguments(scope, fields, typed_args, name, syntax_expr.span, diagnostics, summary);
                        return;
                    }
                    if (scope.contains(name)) return;
                    if (!moduleHasNamedBinding(body, name)) {
                        try emit(diagnostics, summary, "type.call.unknown", syntax_expr.span, "unknown function '{s}'", .{name});
                    }
                },
                .field => |field| try analyzeExpr(active, scope, body, field.base, null, diagnostics, summary, effective_unsafe),
                else => {},
            }
        },
        .method_call => |call| {
            const typed_args = directCallArgs(typed_expr);
            if (call.callee.node == .field and typed_args.len != 0) {
                const field = call.callee.node.field;
                const self_typed = typed_args[0];
                try analyzeExpr(active, scope, body, field.base, self_typed, diagnostics, summary, effective_unsafe);
                for (call.args, 0..) |arg_syntax, index| {
                    const arg_typed = if (index + 1 < typed_args.len) typed_args[index + 1] else null;
                    try analyzeExpr(active, scope, body, arg_syntax, arg_typed, diagnostics, summary, effective_unsafe);
                }

                const target_type_name = switch (self_typed.ty) {
                    .named => |name| parseBoundaryType(name).inner_type_name,
                    else => return,
                };
                const method_name = std.mem.trim(u8, field.field_name.text, " \t");
                const prototype = findMethodPrototype(body.method_prototypes, target_type_name, method_name) orelse return;
                try validateMethodCall(scope, body, target_type_name, method_name, prototype, typed_args, syntax_expr.span, diagnostics, summary);
                return;
            }
            if (call.callee.node == .field) {
                const self_typed = if (typed_args.len != 0) typed_args[0] else null;
                try analyzeExpr(active, scope, body, call.callee.node.field.base, self_typed, diagnostics, summary, effective_unsafe);
            }
            for (call.args, 0..) |arg_syntax, index| {
                const arg_typed = if (index + 1 < typed_args.len) typed_args[index + 1] else null;
                try analyzeExpr(active, scope, body, arg_syntax, arg_typed, diagnostics, summary, effective_unsafe);
            }
        },
    }
}

const ResolvedFunction = union(enum) {
    local: struct {
        prototype: *const typed.FunctionPrototype,
    },
    imported: struct {
        binding: *const typed.ImportedBinding,
        unsafe_required: bool,
    },

    fn unsafeRequired(self: ResolvedFunction) bool {
        return switch (self) {
            .local => |local| local.prototype.unsafe_required,
            .imported => |imported| imported.unsafe_required,
        };
    }

    fn isSuspend(self: ResolvedFunction) bool {
        return switch (self) {
            .local => |local| local.prototype.is_suspend,
            .imported => |imported| imported.binding.function_is_suspend,
        };
    }

    fn genericParams(self: ResolvedFunction) []const typed.GenericParam {
        return switch (self) {
            .local => |local| local.prototype.generic_params,
            .imported => |imported| imported.binding.function_generic_params,
        };
    }

    fn parameterCount(self: ResolvedFunction) usize {
        return switch (self) {
            .local => |local| local.prototype.parameter_types.len,
            .imported => |imported| importedParameterTypes(imported.binding).len,
        };
    }

    fn parameterType(self: ResolvedFunction, index: usize) types.TypeRef {
        return switch (self) {
            .local => |local| local.prototype.parameter_types[index],
            .imported => |imported| importedParameterTypes(imported.binding)[index],
        };
    }

    fn parameterTypeName(self: ResolvedFunction, index: usize) []const u8 {
        return switch (self) {
            .local => |local| local.prototype.parameter_type_names[index],
            .imported => |imported| importedParameterTypeNames(imported.binding)[index],
        };
    }

    fn parameterMode(self: ResolvedFunction, index: usize) typed.ParameterMode {
        return switch (self) {
            .local => |local| local.prototype.parameter_modes[index],
            .imported => |imported| importedParameterModes(imported.binding)[index],
        };
    }
};

const DynamicSymbolBinding = struct {
    symbol_name: []const u8,
    library_name: []const u8,
};

const DynamicLibraryState = struct {
    allocator: Allocator,
    symbols: std.array_list.Managed(DynamicSymbolBinding),
    closed_libraries: std.array_list.Managed([]const u8),

    fn init(allocator: Allocator) DynamicLibraryState {
        return .{
            .allocator = allocator,
            .symbols = std.array_list.Managed(DynamicSymbolBinding).init(allocator),
            .closed_libraries = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *DynamicLibraryState) void {
        self.symbols.deinit();
        self.closed_libraries.deinit();
    }

    fn markLookup(self: *DynamicLibraryState, symbol_name: []const u8, library_name: []const u8) !void {
        for (self.symbols.items) |*binding| {
            if (std.mem.eql(u8, binding.symbol_name, symbol_name)) {
                binding.library_name = library_name;
                return;
            }
        }
        try self.symbols.append(.{
            .symbol_name = symbol_name,
            .library_name = library_name,
        });
    }

    fn markClosed(self: *DynamicLibraryState, library_name: []const u8) !void {
        for (self.closed_libraries.items) |closed_library| {
            if (std.mem.eql(u8, closed_library, library_name)) return;
        }
        try self.closed_libraries.append(library_name);
    }

    fn closed(self: *const DynamicLibraryState, library_name: []const u8) bool {
        for (self.closed_libraries.items) |closed_library| {
            if (std.mem.eql(u8, closed_library, library_name)) return true;
        }
        return false;
    }

    fn invalidatedLibrary(self: *const DynamicLibraryState, symbol_name: []const u8) ?[]const u8 {
        for (self.symbols.items) |binding| {
            if (std.mem.eql(u8, binding.symbol_name, symbol_name) and self.closed(binding.library_name)) {
                return binding.library_name;
            }
        }
        return null;
    }

    fn restore(self: *DynamicLibraryState, symbol_count: usize, closed_count: usize) void {
        self.symbols.shrinkRetainingCapacity(symbol_count);
        self.closed_libraries.shrinkRetainingCapacity(closed_count);
    }
};

fn analyzeKnownDynamicLibraryInvalidation(
    state: *DynamicLibraryState,
    syntax_block: *const ast.BodyBlockSyntax,
    typed_block: *const typed.Block,
    diagnostics: *diag.Bag,
    summary: *Summary,
) anyerror!void {
    if (syntax_block.statements.len != typed_block.statements.items.len) return error.InvalidBodySync;
    for (syntax_block.statements, typed_block.statements.items) |syntax_statement, typed_statement| {
        try analyzeDynamicStatement(state, syntax_statement, typed_statement, diagnostics, summary);
    }
}

fn analyzeDynamicStatement(
    state: *DynamicLibraryState,
    syntax_statement: ast.BodyStatementSyntax,
    typed_statement: typed.Statement,
    diagnostics: *diag.Bag,
    summary: *Summary,
) anyerror!void {
    switch (syntax_statement) {
        .placeholder, .break_stmt, .continue_stmt => {},
        .let_decl => |binding| {
            const lowered = switch (typed_statement) {
                .let_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            try diagnoseClosedDynamicExpr(state, lowered.expr, binding.expr.span, diagnostics, summary);
            try trackDynamicLookupBinding(state, lowered.name, lowered.ty, lowered.expr);
        },
        .const_decl => |binding| {
            const lowered = switch (typed_statement) {
                .const_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            try diagnoseClosedDynamicExpr(state, lowered.expr, binding.expr.span, diagnostics, summary);
            try trackDynamicLookupBinding(state, lowered.name, lowered.ty, lowered.expr);
        },
        .assign_stmt => |assign| switch (typed_statement) {
            .assign_stmt => |lowered| try diagnoseClosedDynamicExpr(state, lowered.expr, assign.expr.span, diagnostics, summary),
            .placeholder => {},
            else => return error.InvalidBodySync,
        },
        .select_stmt => |select_syntax| {
            const lowered = switch (typed_statement) {
                .select_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            if (lowered.subject) |subject| try diagnoseClosedDynamicExpr(state, subject, null, diagnostics, summary);

            var lowered_arm_index: usize = 0;
            for (select_syntax.arms) |arm_syntax| {
                if (select_syntax.subject != null and arm_syntax.head == .guard) continue;
                if (select_syntax.subject == null and arm_syntax.head == .pattern) continue;
                if (lowered_arm_index >= lowered.arms.len) return error.InvalidBodySync;
                const lowered_arm = lowered.arms[lowered_arm_index];
                lowered_arm_index += 1;

                if (select_syntax.subject == null) {
                    try diagnoseClosedDynamicExpr(state, lowered_arm.condition, null, diagnostics, summary);
                }
                try analyzeNonPropagatingDynamicBlock(state, arm_syntax.body, lowered_arm.body, diagnostics, summary);
            }

            if (select_syntax.else_body) |else_body| {
                const lowered_else = lowered.else_body orelse return error.InvalidBodySync;
                try analyzeNonPropagatingDynamicBlock(state, else_body, lowered_else, diagnostics, summary);
            }
        },
        .repeat_stmt => |repeat_syntax| {
            const lowered = switch (typed_statement) {
                .loop_stmt => |value| value,
                .placeholder => null,
                else => return error.InvalidBodySync,
            };
            if (lowered) |loop_data| {
                if (loop_data.condition) |condition| {
                    try diagnoseClosedDynamicExpr(state, condition, null, diagnostics, summary);
                }
                try analyzeNonPropagatingDynamicBlock(state, repeat_syntax.body, loop_data.body, diagnostics, summary);
            }
        },
        .unsafe_block => |unsafe_body| {
            const lowered = switch (typed_statement) {
                .unsafe_block => |value| value,
                else => return error.InvalidBodySync,
            };
            try analyzeKnownDynamicLibraryInvalidation(state, unsafe_body, lowered, diagnostics, summary);
        },
        .defer_stmt => |expr_syntax| {
            const expr = switch (typed_statement) {
                .defer_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            try diagnoseClosedDynamicExpr(state, expr, expr_syntax.span, diagnostics, summary);
        },
        .return_stmt => |expr_syntax| {
            const lowered = switch (typed_statement) {
                .return_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            if (lowered) |expr| {
                const span = if (expr_syntax) |syntax| syntax.span else null;
                try diagnoseClosedDynamicExpr(state, expr, span, diagnostics, summary);
            }
        },
        .expr_stmt => |expr_syntax| {
            const expr = switch (typed_statement) {
                .expr_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            try diagnoseClosedDynamicExpr(state, expr, expr_syntax.span, diagnostics, summary);
            if (closedLibraryNameFromExpr(expr)) |library_name| {
                try state.markClosed(library_name);
            }
        },
    }
}

fn analyzeNonPropagatingDynamicBlock(
    state: *DynamicLibraryState,
    syntax_block: *const ast.BodyBlockSyntax,
    typed_block: *const typed.Block,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    const symbol_count = state.symbols.items.len;
    const closed_count = state.closed_libraries.items.len;
    defer state.restore(symbol_count, closed_count);
    try analyzeKnownDynamicLibraryInvalidation(state, syntax_block, typed_block, diagnostics, summary);
}

fn trackDynamicLookupBinding(
    state: *DynamicLibraryState,
    binding_name: []const u8,
    binding_type: types.TypeRef,
    expr: *const typed.Expr,
) !void {
    if (!try dynamicLookupTypeSupported(state.allocator, binding_type)) return;
    const call = switch (expr.node) {
        .call => |value| value,
        else => return,
    };
    if (!std.mem.eql(u8, call.callee, dynamic_library.lookup_callee)) return;
    if (call.args.len < 1) return;
    const library_name = identifierName(call.args[0]) orelse return;
    try state.markLookup(binding_name, library_name);
}

fn diagnoseClosedDynamicExpr(
    state: *const DynamicLibraryState,
    expr: ?*const typed.Expr,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) anyerror!void {
    const value = expr orelse return;
    switch (value.node) {
        .identifier => |name| try diagnoseInvalidatedSymbolUse(state, name, span, diagnostics, summary),
        .call => |call| {
            try diagnoseInvalidatedSymbolUse(state, call.callee, span, diagnostics, summary);
            if (std.mem.eql(u8, call.callee, dynamic_library.lookup_callee) and call.args.len >= 1) {
                if (identifierName(call.args[0])) |library_name| {
                    if (state.closed(library_name)) {
                        try emit(diagnostics, summary, "runtime.dynamic.close.invalidated", span, "dynamic-library symbol lookup uses closed library '{s}'", .{library_name});
                    }
                }
            }
            for (call.args) |arg| try diagnoseClosedDynamicExpr(state, arg, span, diagnostics, summary);
        },
        .enum_construct => |construct| {
            for (construct.args) |arg| try diagnoseClosedDynamicExpr(state, arg, span, diagnostics, summary);
        },
        .constructor => |constructor| {
            for (constructor.args) |arg| try diagnoseClosedDynamicExpr(state, arg, span, diagnostics, summary);
        },
        .method_target => |target| try diagnoseClosedDynamicExpr(state, target.base, span, diagnostics, summary),
        .field => |field| try diagnoseClosedDynamicExpr(state, field.base, span, diagnostics, summary),
        .array => |array| {
            for (array.items) |item| try diagnoseClosedDynamicExpr(state, item, span, diagnostics, summary);
        },
        .array_repeat => |array_repeat| {
            try diagnoseClosedDynamicExpr(state, array_repeat.value, span, diagnostics, summary);
            try diagnoseClosedDynamicExpr(state, array_repeat.length, span, diagnostics, summary);
        },
        .index => |index| {
            try diagnoseClosedDynamicExpr(state, index.base, span, diagnostics, summary);
            try diagnoseClosedDynamicExpr(state, index.index, span, diagnostics, summary);
        },
        .conversion => |conversion| try diagnoseClosedDynamicExpr(state, conversion.operand, span, diagnostics, summary),
        .unary => |unary| try diagnoseClosedDynamicExpr(state, unary.operand, span, diagnostics, summary),
        .binary => |binary| {
            try diagnoseClosedDynamicExpr(state, binary.lhs, span, diagnostics, summary);
            try diagnoseClosedDynamicExpr(state, binary.rhs, span, diagnostics, summary);
        },
        else => {},
    }
}

fn diagnoseInvalidatedSymbolUse(
    state: *const DynamicLibraryState,
    symbol_name: []const u8,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    if (state.invalidatedLibrary(symbol_name)) |library_name| {
        try emit(diagnostics, summary, "runtime.dynamic.close.invalidated", span, "symbol '{s}' was looked up from closed dynamic library '{s}'", .{
            symbol_name,
            library_name,
        });
    }
}

fn closedLibraryNameFromExpr(expr: *const typed.Expr) ?[]const u8 {
    const call = switch (expr.node) {
        .call => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, call.callee, dynamic_library.close_callee)) return null;
    if (call.args.len != 1) return null;
    return identifierName(call.args[0]);
}

fn identifierName(expr: *const typed.Expr) ?[]const u8 {
    return switch (expr.node) {
        .identifier => |name| name,
        else => null,
    };
}

fn validateDynamicLibraryCall(
    callee_name: []const u8,
    typed_expr: ?*const typed.Expr,
    args: []const *typed.Expr,
    unsafe_context: bool,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    if (std.mem.eql(u8, callee_name, dynamic_library.open_name)) {
        if (args.len != 1) {
            try emit(diagnostics, summary, "runtime.dynamic.open.arity", span, "open_library expects exactly one path argument", .{});
            return;
        }
        if (!args[0].ty.isUnsupported() and !args[0].ty.eql(types.TypeRef.fromBuiltin(.str))) {
            try emit(diagnostics, summary, "runtime.dynamic.open.path", span, "open_library path must be Str", .{});
        }
        const result_type = if (typed_expr) |expr| expr.ty else types.TypeRef.unsupported;
        if (!result_type.isNamed(dynamic_library.open_result_type_name) and !result_type.isUnsupported()) {
            try emit(diagnostics, summary, "runtime.dynamic.open.result", span, "open_library returns Result[DynamicLibrary, DynamicLibraryError]", .{});
        }
        return;
    }
    if (std.mem.eql(u8, callee_name, dynamic_library.lookup_name)) {
        if (!unsafe_context) {
            try emit(diagnostics, summary, "runtime.dynamic.lookup.unsafe", span, "dynamic-library symbol lookup requires #unsafe", .{});
        }
        if (args.len != 2) {
            try emit(diagnostics, summary, "runtime.dynamic.lookup.arity", span, "lookup_symbol expects a DynamicLibrary and symbol name", .{});
            return;
        }
        if (!args[0].ty.isUnsupported() and !args[0].ty.isNamed(dynamic_library.type_name)) {
            try emit(diagnostics, summary, "runtime.dynamic.lookup.library", span, "lookup_symbol first argument must be DynamicLibrary", .{});
        }
        if (!args[1].ty.isUnsupported() and !args[1].ty.eql(types.TypeRef.fromBuiltin(.str))) {
            try emit(diagnostics, summary, "runtime.dynamic.lookup.name", span, "lookup_symbol name must be Str", .{});
        }
        const result_type = if (typed_expr) |expr| expr.ty else types.TypeRef.unsupported;
        if (!try dynamicLookupResultTypeSupported(diagnostics.allocator, result_type)) {
            try emit(diagnostics, summary, "runtime.dynamic.lookup.type", span, "lookup_symbol requires contextual type Result[T, SymbolLookupError] where T is a foreign function pointer or raw pointer", .{});
        }
        return;
    }
    if (std.mem.eql(u8, callee_name, dynamic_library.close_name)) {
        if (!unsafe_context) {
            try emit(diagnostics, summary, "runtime.dynamic.close.unsafe", span, "dynamic-library close requires #unsafe", .{});
        }
        if (args.len != 1) {
            try emit(diagnostics, summary, "runtime.dynamic.close.arity", span, "close_library expects exactly one DynamicLibrary argument", .{});
            return;
        }
        if (!args[0].ty.isUnsupported() and !args[0].ty.isNamed(dynamic_library.type_name)) {
            try emit(diagnostics, summary, "runtime.dynamic.close.library", span, "close_library argument must be DynamicLibrary", .{});
        }
        const result_type = if (typed_expr) |expr| expr.ty else types.TypeRef.unsupported;
        if (!result_type.isNamed(dynamic_library.close_result_type_name) and !result_type.isUnsupported()) {
            try emit(diagnostics, summary, "runtime.dynamic.close.result", span, "close_library returns Result[Unit, DynamicLibraryError]", .{});
        }
    }
}

fn dynamicLookupTypeSupported(allocator: Allocator, ty: types.TypeRef) !bool {
    const raw = switch (ty) {
        .named => |name| std.mem.trim(u8, name, " \t\r\n"),
        else => return false,
    };
    if (std.mem.startsWith(u8, raw, "*read ") or std.mem.startsWith(u8, raw, "*edit ")) return true;
    var syntax = try foreign_callable_types.parseSyntax(allocator, raw) orelse return false;
    defer syntax.deinit(allocator);
    return syntax.variadic_tail == null;
}

fn dynamicLookupResultTypeSupported(allocator: Allocator, ty: types.TypeRef) !bool {
    const raw = switch (ty) {
        .named => |name| std.mem.trim(u8, name, " \t\r\n"),
        else => return false,
    };
    if (!std.mem.startsWith(u8, raw, "Result[")) return false;
    const open_index = "Result".len;
    const close_index = findMatchingDelimiter(raw, open_index, '[', ']') orelse return false;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t\r\n").len != 0) return false;
    const args = try typed_text.splitTopLevelCommaParts(allocator, raw[open_index + 1 .. close_index]);
    defer allocator.free(args);
    if (args.len != 2) return false;
    const ok_type = std.mem.trim(u8, args[0], " \t\r\n");
    const err_type = std.mem.trim(u8, args[1], " \t\r\n");
    if (!std.mem.eql(u8, err_type, dynamic_library.lookup_error_type_name)) return false;
    return dynamicLookupTypeSupported(allocator, .{ .named = ok_type });
}

fn comparisonOperandsCompatible(operator: []const u8, lhs: types.TypeRef, rhs: types.TypeRef) bool {
    if (std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "!=")) return equalityComparable(lhs, rhs);
    if (typeIsRawPointer(lhs) or typeIsRawPointer(rhs)) return false;
    return orderingComparable(lhs, rhs);
}

fn equalityComparable(lhs: types.TypeRef, rhs: types.TypeRef) bool {
    if (lhs.eql(rhs)) return typeSupportsBuiltinEquality(lhs);
    const lhs_pointer = switch (lhs) {
        .named => |name| raw_pointer.parse(name) orelse return false,
        else => return false,
    };
    const rhs_pointer = switch (rhs) {
        .named => |name| raw_pointer.parse(name) orelse return false,
        else => return false,
    };
    return std.mem.eql(u8, lhs_pointer.pointee, rhs_pointer.pointee) and
        (lhs_pointer.access == rhs_pointer.access or lhs_pointer.access == .read or rhs_pointer.access == .read);
}

fn orderingComparable(lhs: types.TypeRef, rhs: types.TypeRef) bool {
    return lhs.eql(rhs) and typeSupportsBuiltinOrdering(lhs);
}

fn typeSupportsBuiltinEquality(ty: types.TypeRef) bool {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .unit, .bool, .i32, .u32, .index, .isize => true,
            .str, .unsupported => false,
        },
        .named => |name| blk: {
            if (raw_pointer.parse(name) != null) break :blk true;
            if (foreign_callable_types.startsForeignCallableType(name)) break :blk true;
            if (types.CAbiAlias.fromName(name)) |alias| break :blk alias != .c_void;
            if (std.mem.eql(u8, name, "Char") or std.mem.eql(u8, name, "IndexRange")) break :blk true;
            break :blk false;
        },
        .unsupported => false,
    };
}

fn typeSupportsBuiltinOrdering(ty: types.TypeRef) bool {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .i32, .u32, .index, .isize => true,
            .unit, .bool, .str, .unsupported => false,
        },
        .named => |name| blk: {
            if (types.CAbiAlias.fromName(name)) |alias| break :blk alias != .c_void;
            if (std.mem.eql(u8, name, "Char") or std.mem.eql(u8, name, "IndexRange")) break :blk true;
            break :blk false;
        },
        .unsupported => false,
    };
}

fn typeIsRawPointer(ty: types.TypeRef) bool {
    return switch (ty) {
        .named => |name| raw_pointer.parse(name) != null,
        else => false,
    };
}

fn importedParameterTypes(binding: *const typed.ImportedBinding) []const types.TypeRef {
    return if (binding.function_parameter_types) |value| value else &.{};
}

fn importedParameterTypeNames(binding: *const typed.ImportedBinding) []const []const u8 {
    return if (binding.function_parameter_type_names) |value| value else &.{};
}

fn importedParameterModes(binding: *const typed.ImportedBinding) []const typed.ParameterMode {
    return if (binding.function_parameter_modes) |value| value else &.{};
}

fn resolveDirectFunction(active: *session.Session, body: query_types.CheckedBody, name: []const u8) !?ResolvedFunction {
    for (body.function_prototypes) |*prototype| {
        if (!std.mem.eql(u8, prototype.name, name)) continue;
        return .{ .local = .{ .prototype = prototype } };
    }

    for (body.module.imports.items) |*binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        if (binding.function_return_type == null) continue;
        return .{ .imported = .{
            .binding = binding,
            .unsafe_required = try importedUnsafeRequired(active, binding.target_symbol),
        } };
    }

    return null;
}

fn importedUnsafeRequired(active: *session.Session, target_symbol: []const u8) !bool {
    for (active.semantic_index.items.items, 0..) |_, index| {
        const item = active.item(.{ .index = index });
        if (!std.mem.eql(u8, item.symbol_name, target_symbol)) continue;
        return item.is_unsafe;
    }
    return error.UnknownImportedFunction;
}

fn validateDirectCall(
    scope: *const ScopeStack,
    body: query_types.CheckedBody,
    callee_name: []const u8,
    span: ?source.Span,
    resolved: ResolvedFunction,
    args: []const *typed.Expr,
    unsafe_context: bool,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    if (resolved.unsafeRequired() and !unsafe_context) {
        try emit(diagnostics, summary, "type.call.unsafe", span, "call to unsafe function '{s}' requires #unsafe context", .{callee_name});
    }
    if (resolved.isSuspend() and !body.function.is_suspend) {
        try emit(diagnostics, summary, "type.call.suspend_context", span, "call to suspend function '{s}' requires suspend context or an explicit runtime adapter", .{callee_name});
    }
    if (resolved.isSuspend() and hasBorrowingParameters(resolved)) {
        try emit(diagnostics, summary, "type.call.suspend_borrow", span, "stage0 does not yet permit suspend calls that borrow arguments", .{});
    }

    const parameter_type_names = try resolvedParameterTypeNames(diagnostics.allocator, resolved);
    const free_parameter_type_names = false;
    defer if (free_parameter_type_names and parameter_type_names.len != 0) diagnostics.allocator.free(parameter_type_names);

    if (!cVariadicCallArityValid(args.len, resolved.parameterCount(), parameter_type_names)) {
        try emit(diagnostics, summary, "type.call.arity", span, "call to '{s}' has wrong arity", .{callee_name});
        return;
    }

    const fixed_count = cVariadicFixedParameterCount(resolved.parameterCount(), parameter_type_names);
    for (args[0..@min(args.len, fixed_count)], 0..) |arg, index| {
        const expected = resolved.parameterType(index);
        const expected_name = resolved.parameterTypeName(index);
        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
            !callArgumentTypeCompatible(arg.ty, expected, expected_name, resolved.genericParams(), false))
        {
            try emit(diagnostics, summary, "type.call.arg", span, "call to '{s}' argument {d} has wrong type", .{
                callee_name,
                index + 1,
            });
        }
    }

    if (cVariadicTailIndex(parameter_type_names) != null) {
        for (args[fixed_count..], fixed_count..) |arg, index| {
            if (!arg.ty.isUnsupported() and !cVariadicArgumentTypeSupported(arg.ty)) {
                try emit(diagnostics, summary, "abi.c.variadic.arg", span, "variadic argument {d} to '{s}' is not C ABI-safe", .{
                    index + 1,
                    callee_name,
                });
            }
        }
    }

    try validateBorrowArguments(scope, callee_name, span, resolved, args, diagnostics, summary);
    try validateRetainedCallArguments(
        scope,
        body.function.where_predicates,
        parameter_type_names,
        resolved.genericParams(),
        switch (resolved) {
            .local => |local| local.prototype.where_predicates,
            .imported => |imported| imported.binding.function_where_predicates,
        },
        args,
        callee_name,
        span,
        diagnostics,
        summary,
    );
}

fn validateMethodCall(
    scope: *const ScopeStack,
    body: query_types.CheckedBody,
    target_type_name: []const u8,
    method_name: []const u8,
    prototype: typed.MethodPrototype,
    args: []const *typed.Expr,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    if (prototype.parameter_types.len != args.len) {
        try emit(diagnostics, summary, "type.method.arity", span, "method call to '{s}.{s}' has wrong arity", .{
            target_type_name,
            method_name,
        });
        return;
    }

    for (args, prototype.parameter_types, 0..) |arg, expected, index| {
        const expected_name = if (index < prototype.parameter_type_names.len) prototype.parameter_type_names[index] else expected.displayName();
        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
            !callArgumentTypeCompatible(arg.ty, expected, expected_name, prototype.generic_params, true))
        {
            try emit(diagnostics, summary, "type.method.arg", span, "method call to '{s}.{s}' argument {d} has wrong type", .{
                target_type_name,
                method_name,
                index + 1,
            });
        }
    }

    if (prototype.is_suspend and !body.function.is_suspend) {
        try emit(diagnostics, summary, "type.method.suspend_context", span, "call to suspend method '{s}.{s}' requires suspend context or an explicit runtime adapter", .{
            target_type_name,
            method_name,
        });
    }
    if (prototype.is_suspend and hasBorrowingModeSlice(prototype.parameter_modes)) {
        try emit(diagnostics, summary, "type.method.suspend_borrow", span, "stage0 does not yet permit suspend method calls that borrow self or arguments", .{});
    }

    try validateBorrowArgumentSlice(scope, prototype.function_name, span, prototype.parameter_modes, args, diagnostics, summary);
    try validateRetainedCallArguments(
        scope,
        body.function.where_predicates,
        prototype.parameter_type_names,
        prototype.generic_params,
        prototype.where_predicates,
        args,
        prototype.function_name,
        span,
        diagnostics,
        summary,
    );
}

fn validateBorrowArguments(
    scope: *const ScopeStack,
    callee_name: []const u8,
    span: ?source.Span,
    resolved: ResolvedFunction,
    args: []const *typed.Expr,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (args, 0..) |arg, index| {
        const mode = if (index < resolved.parameterCount()) resolved.parameterMode(index) else typed.ParameterMode.owned;
        switch (mode) {
            .owned, .take => {},
            .read => try validateBorrowArgumentExpr(scope, arg, false, callee_name, index + 1, span, diagnostics, summary),
            .edit => try validateBorrowArgumentExpr(scope, arg, true, callee_name, index + 1, span, diagnostics, summary),
        }
    }
}

fn validateBorrowArgumentSlice(
    scope: *const ScopeStack,
    callee_name: []const u8,
    span: ?source.Span,
    modes: []const typed.ParameterMode,
    args: []const *typed.Expr,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (args, 0..) |arg, index| {
        const mode = if (index < modes.len) modes[index] else .owned;
        switch (mode) {
            .owned, .take => {},
            .read => try validateBorrowArgumentExpr(scope, arg, false, callee_name, index + 1, span, diagnostics, summary),
            .edit => try validateBorrowArgumentExpr(scope, arg, true, callee_name, index + 1, span, diagnostics, summary),
        }
    }
}

fn validateBorrowArgumentExpr(
    scope: *const ScopeStack,
    expr: *const typed.Expr,
    require_mutable: bool,
    callee_name: []const u8,
    arg_index: usize,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    switch (expr.node) {
        .identifier => |name| {
            if (!scope.contains(name)) {
                try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must come from a local place in stage0", .{
                    arg_index,
                    callee_name,
                });
                return;
            }
            if (require_mutable and !scope.isMutable(name)) {
                try emit(diagnostics, summary, "type.call.borrow_mut", span, "edit borrow argument {d} to '{s}' requires a mutable local place in stage0", .{
                    arg_index,
                    callee_name,
                });
            }
        },
        .field => |field| switch (field.base.node) {
            .identifier => |base_name| {
                if (!scope.contains(base_name)) {
                    try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must come from a local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                    return;
                }
                if (require_mutable and !scope.isMutable(base_name)) {
                    try emit(diagnostics, summary, "type.call.borrow_mut", span, "edit borrow argument {d} to '{s}' requires a mutable local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                }
            },
            else => try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must be a plain local or one field projection in stage0", .{
                arg_index,
                callee_name,
            }),
        },
        .index => |index| switch (index.base.node) {
            .identifier => |base_name| {
                if (!scope.contains(base_name)) {
                    try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must come from a local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                    return;
                }
                if (require_mutable and !scope.isMutable(base_name)) {
                    try emit(diagnostics, summary, "type.call.borrow_mut", span, "edit borrow argument {d} to '{s}' requires a mutable local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                }
            },
            else => try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must be a plain local, field, or array element place in stage0", .{
                arg_index,
                callee_name,
            }),
        },
        else => try emit(diagnostics, summary, "type.call.borrow_arg", span, "borrow argument {d} to '{s}' must be a plain local or one field projection in stage0", .{
            arg_index,
            callee_name,
        }),
    }
}

fn hasBorrowingParameters(resolved: ResolvedFunction) bool {
    var index: usize = 0;
    while (index < resolved.parameterCount()) : (index += 1) {
        const mode = resolved.parameterMode(index);
        if (mode == .read or mode == .edit) return true;
    }
    return false;
}

fn hasBorrowingModeSlice(modes: []const typed.ParameterMode) bool {
    for (modes) |mode| if (mode == .read or mode == .edit) return true;
    return false;
}

const LifetimeBinding = struct {
    formal_name: []const u8,
    actual_name: []const u8,
};

fn validateRetainedCallArguments(
    scope: *const ScopeStack,
    current_where_predicates: []const typed.WherePredicate,
    parameter_type_names: []const []const u8,
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
    args: []const *typed.Expr,
    callee_name: []const u8,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    var lifetime_bindings = std.array_list.Managed(LifetimeBinding).init(diagnostics.allocator);
    defer lifetime_bindings.deinit();

    for (args, 0..) |arg, index| {
        if (index >= parameter_type_names.len) break;
        const expected = parseBoundaryType(parameter_type_names[index]);
        if (expected.kind != .retained_read and expected.kind != .retained_edit) continue;

        const actual = inferExprBoundaryTypeInScope(scope, arg);
        switch (actual.kind) {
            .retained_read, .retained_edit => {},
            .ephemeral_read, .ephemeral_edit => {
                try emit(diagnostics, summary, "lifetime.call.ephemeral_source", span, "retained argument {d} to '{s}' is derived only from an ephemeral borrow", .{
                    index + 1,
                    callee_name,
                });
                continue;
            },
            .value => {
                try emit(diagnostics, summary, "lifetime.call.retained_source", span, "retained argument {d} to '{s}' must be a retained borrow value", .{
                    index + 1,
                    callee_name,
                });
                continue;
            },
        }

        if (!boundaryAccessCompatible(actual, expected)) {
            try emit(diagnostics, summary, "lifetime.call.mode", span, "retained argument {d} to '{s}' does not match the required borrow mode", .{
                index + 1,
                callee_name,
            });
            continue;
        }

        if (!boundaryInnerTypeCompatible(actual.inner_type_name, expected.inner_type_name, generic_params, true)) continue;

        const expected_lifetime = expected.lifetime_name orelse continue;
        const actual_lifetime = actual.lifetime_name orelse continue;
        if (std.mem.eql(u8, expected_lifetime, "'static")) {
            if (!lifetimeOutlivesInContext(current_where_predicates, actual_lifetime, "'static")) {
                try emit(diagnostics, summary, "lifetime.call.outlives", span, "retained argument {d} to '{s}' does not satisfy required outlives relation", .{
                    index + 1,
                    callee_name,
                });
            }
            continue;
        }

        if (findLifetimeBinding(lifetime_bindings.items, expected_lifetime)) |existing| {
            if (!std.mem.eql(u8, existing, actual_lifetime)) {
                try emit(diagnostics, summary, "lifetime.call.bind", span, "call to '{s}' would require incompatible lifetime bindings for '{s}'", .{
                    callee_name,
                    expected_lifetime,
                });
            }
            continue;
        }

        try lifetime_bindings.append(.{
            .formal_name = expected_lifetime,
            .actual_name = actual_lifetime,
        });
    }

    for (where_predicates) |predicate| {
        switch (predicate) {
            .lifetime_outlives => |outlives| {
                const longer_name = resolveBoundLifetimeName(lifetime_bindings.items, outlives.longer_name) orelse continue;
                const shorter_name = resolveBoundLifetimeName(lifetime_bindings.items, outlives.shorter_name) orelse continue;
                if (!lifetimeOutlivesInContext(current_where_predicates, longer_name, shorter_name)) {
                    try emit(diagnostics, summary, "lifetime.call.outlives", span, "call to '{s}' does not satisfy required outlives relation '{s}: {s}'", .{
                        callee_name,
                        outlives.longer_name,
                        outlives.shorter_name,
                    });
                }
            },
            else => {},
        }
    }
}

fn validateRetainedStorageArguments(
    scope: *const ScopeStack,
    fields: []const typed.StructField,
    args: []const *typed.Expr,
    container_name: []const u8,
    span: ?source.Span,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (args, 0..) |arg, index| {
        if (index >= fields.len) break;
        const expected = parseBoundaryType(fields[index].type_name);
        if (expected.kind != .retained_read and expected.kind != .retained_edit) continue;

        const actual = inferExprBoundaryTypeInScope(scope, arg);
        switch (actual.kind) {
            .retained_read, .retained_edit => {},
            .ephemeral_read, .ephemeral_edit => {
                try emit(diagnostics, summary, "lifetime.store.ephemeral_source", span, "stored retained field {d} for '{s}' is derived only from an ephemeral borrow", .{
                    index + 1,
                    container_name,
                });
                continue;
            },
            .value => {
                try emit(diagnostics, summary, "lifetime.store.retained_source", span, "stored retained field {d} for '{s}' must be a retained borrow value", .{
                    index + 1,
                    container_name,
                });
                continue;
            },
        }

        if (!boundaryAccessCompatible(actual, expected)) {
            try emit(diagnostics, summary, "lifetime.store.mode", span, "stored retained field {d} for '{s}' does not match the required borrow mode", .{
                index + 1,
                container_name,
            });
        }
    }
}

fn resolvedParameterTypeNames(allocator: std.mem.Allocator, resolved: ResolvedFunction) ![]const []const u8 {
    _ = allocator;
    return switch (resolved) {
        .imported => |imported| importedParameterTypeNames(imported.binding),
        .local => |local| local.prototype.parameter_type_names,
    };
}

fn findLifetimeBinding(bindings: []const LifetimeBinding, formal_name: []const u8) ?[]const u8 {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.formal_name, formal_name)) return binding.actual_name;
    }
    return null;
}

fn resolveBoundLifetimeName(bindings: []const LifetimeBinding, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "'static")) return "'static";
    return findLifetimeBinding(bindings, name);
}

fn lifetimeOutlivesInContext(where_predicates: []const typed.WherePredicate, longer_name: []const u8, shorter_name: []const u8) bool {
    if (std.mem.eql(u8, longer_name, shorter_name)) return true;
    if (std.mem.eql(u8, longer_name, "'static")) return true;
    if (std.mem.eql(u8, shorter_name, "'static")) return false;

    var frontier: usize = 0;
    var queue: [32][]const u8 = undefined;
    var seen: [32][]const u8 = undefined;
    var queue_len: usize = 0;
    var seen_len: usize = 0;
    queue[queue_len] = longer_name;
    queue_len += 1;
    seen[seen_len] = longer_name;
    seen_len += 1;

    while (frontier < queue_len) : (frontier += 1) {
        const current = queue[frontier];
        for (where_predicates) |predicate| {
            switch (predicate) {
                .lifetime_outlives => |outlives| {
                    if (!std.mem.eql(u8, outlives.longer_name, current)) continue;
                    if (std.mem.eql(u8, outlives.shorter_name, shorter_name)) return true;
                    if (seenSliceContains(seen[0..seen_len], outlives.shorter_name)) continue;
                    if (queue_len >= queue.len or seen_len >= seen.len) continue;
                    queue[queue_len] = outlives.shorter_name;
                    queue_len += 1;
                    seen[seen_len] = outlives.shorter_name;
                    seen_len += 1;
                },
                else => {},
            }
        }
    }

    return false;
}

fn seenSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn directCallArgs(expr: ?*const typed.Expr) []const *typed.Expr {
    const value = expr orelse return &.{};
    return switch (value.node) {
        .call => |call| call.args,
        .constructor => |constructor| constructor.args,
        .enum_construct => |construct| construct.args,
        else => &.{},
    };
}

fn typedFieldBase(expr: ?*const typed.Expr) ?*const typed.Expr {
    const value = expr orelse return null;
    return switch (value.node) {
        .field => |field| field.base,
        .method_target => |target| target.base,
        else => null,
    };
}

fn moduleHasNamedBinding(body: query_types.CheckedBody, name: []const u8) bool {
    for (body.module.items.items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    for (body.module.imports.items) |binding| {
        if (std.mem.eql(u8, binding.local_name, name)) return true;
    }
    return false;
}

fn findStructFields(body: query_types.CheckedBody, name: []const u8) ?[]const typed.StructField {
    for (body.struct_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype.fields;
    }
    for (body.module.imports.items) |binding| {
        const fields = binding.struct_fields orelse continue;
        if (std.mem.eql(u8, binding.local_name, name)) return fields;
    }
    return null;
}

fn fixedArrayElementType(ty: types.TypeRef) ?types.TypeRef {
    const raw = switch (ty) {
        .named => |name| std.mem.trim(u8, name, " \t"),
        else => return null,
    };
    if (!std.mem.startsWith(u8, raw, "[")) return null;
    const close_index = findMatchingDelimiter(raw, 0, '[', ']') orelse return null;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t").len != 0) return null;
    const inner = raw[1..close_index];
    const separator = findTopLevelHeaderScalar(inner, ';') orelse return null;
    const element_type = std.mem.trim(u8, inner[0..separator], " \t");
    if (element_type.len == 0) return null;
    const builtin = types.Builtin.fromName(element_type);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = element_type };
}

fn isComparisonOperator(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "==") or
        std.mem.eql(u8, operator, "!=") or
        std.mem.eql(u8, operator, "<") or
        std.mem.eql(u8, operator, "<=") or
        std.mem.eql(u8, operator, ">") or
        std.mem.eql(u8, operator, ">=");
}

fn isComparisonSyntax(expr: *const ast.BodyExprSyntax) bool {
    return switch (expr.node) {
        .binary => |binary| isComparisonOperator(std.mem.trim(u8, binary.operator.text, " \t")),
        else => false,
    };
}

fn isIntegerText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn emit(
    diagnostics: *diag.Bag,
    summary: *Summary,
    code: []const u8,
    span: ?source.Span,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try diagnostics.add(.@"error", code, span, fmt, args);
    summary.prepared_issue_count += 1;
}

fn queryConversionMode(mode: @import("../typed/root.zig").ConversionMode) query_types.ConversionMode {
    return switch (mode) {
        .explicit_infallible => .explicit_infallible,
        .explicit_checked => .explicit_checked,
    };
}

fn conversionStatus(mode: query_types.ConversionMode, source_type: types.TypeRef, target_type: types.TypeRef) query_types.ConversionStatus {
    const shared_mode: conversions.Mode = switch (mode) {
        .implicit => .implicit,
        .explicit_infallible => .explicit_infallible,
        .explicit_checked => .explicit_checked,
    };
    return if (conversions.allowed(shared_mode, source_type, target_type)) .accepted else .rejected;
}
