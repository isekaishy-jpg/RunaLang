const ast = @import("../ast/root.zig");
const body_scope = @import("body_scope.zig");
const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const typed = @import("../typed/root.zig");
const typed_text = @import("text.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const ScopeStack = body_scope.ScopeStack;
const returnTypeStructurallyCompatible = type_support.returnTypeStructurallyCompatible;

pub const Summary = struct {
    checked_statement_count: usize = 0,
    prepared_issue_count: usize = 0,
};

pub fn analyzeBody(allocator: Allocator, body: query_types.CheckedBody, diagnostics: *diag.Bag) !Summary {
    var summary = Summary{
        .checked_statement_count = body.summary.statement_count,
    };

    const block_syntax = body.function.block_syntax orelse return summary;
    var scope = ScopeStack.init(allocator);
    defer scope.deinit();
    try scope.push();
    defer scope.pop();
    try body_scope.seedModuleConsts(&scope, body);
    try body_scope.seedParameters(&scope, body.parameters);
    try analyzeBlock(&scope, &block_syntax.structured, &body.function.body, body, diagnostics, &summary, 0);

    if (!body.function.return_type.eql(types.TypeRef.fromBuiltin(.unit)) and !blockDefinitelyReturns(&body.function.body)) {
        try emit(
            diagnostics,
            &summary,
            "type.return.missing",
            body.item.span,
            "non-Unit function '{s}' must end with an explicit return",
            .{body.item.name},
        );
    }

    return summary;
}

fn analyzeBlock(
    scope: *ScopeStack,
    syntax_block: *const ast.BodyBlockSyntax,
    typed_block: *const typed.Block,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
    loop_depth: usize,
) anyerror!void {
    if (syntax_block.statements.len != typed_block.statements.items.len) return error.InvalidBodySync;

    for (syntax_block.statements, typed_block.statements.items) |syntax_statement, typed_statement| {
        try analyzeStatement(scope, syntax_statement, typed_statement, body, diagnostics, summary, loop_depth);
    }
}

fn analyzeStatement(
    scope: *ScopeStack,
    syntax_statement: ast.BodyStatementSyntax,
    typed_statement: typed.Statement,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
    loop_depth: usize,
) anyerror!void {
    switch (syntax_statement) {
        .placeholder => |line| {
            const text = std.mem.trim(u8, line.text, " \t");
            if (std.mem.eql(u8, text, "...")) return;
            if (std.mem.eql(u8, text, "#unsafe:") or
                std.mem.eql(u8, text, "select:") or
                (std.mem.startsWith(u8, text, "select ") and std.mem.endsWith(u8, text, ":")) or
                std.mem.eql(u8, text, "repeat:") or
                std.mem.eql(u8, text, "repeat") or
                std.mem.startsWith(u8, text, "repeat "))
            {
                try emit(diagnostics, summary, "type.statement.block", line.span, "statement form '{s}' requires its own indented body", .{text});
                return;
            }
            if (text.len != 0) {
                try emit(diagnostics, summary, "type.stage0.statement", line.span, "stage0 does not yet implement statement form '{s}'", .{text});
            }
        },
        .let_decl => |binding| {
            const lowered = switch (typed_statement) {
                .let_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            if (binding.declared_type != null and !lowered.expr.ty.isUnsupported() and !lowered.ty.isUnsupported() and !lowered.expr.ty.eql(lowered.ty)) {
                try emit(
                    diagnostics,
                    summary,
                    "type.binding.mismatch",
                    binding.name.span,
                    "local binding '{s}' initializer type does not match declared type",
                    .{std.mem.trim(u8, binding.name.text, " \t")},
                );
            }
            try scope.put(lowered.name, lowered.ty, true);
        },
        .const_decl => |binding| {
            const lowered = switch (typed_statement) {
                .const_decl => |value| value,
                else => return error.InvalidBodySync,
            };
            if (binding.declared_type == null) {
                try emit(
                    diagnostics,
                    summary,
                    "type.const.type",
                    binding.name.span,
                    "local const '{s}' requires an explicit const-safe type",
                    .{std.mem.trim(u8, binding.name.text, " \t")},
                );
            } else if (!lowered.expr.ty.isUnsupported() and !lowered.ty.isUnsupported() and !lowered.expr.ty.eql(lowered.ty)) {
                try emit(
                    diagnostics,
                    summary,
                    "type.binding.mismatch",
                    binding.name.span,
                    "local binding '{s}' initializer type does not match declared type",
                    .{std.mem.trim(u8, binding.name.text, " \t")},
                );
            }
            try scope.put(lowered.name, lowered.ty, false);
        },
        .assign_stmt => |assign| {
            const target = try resolveAssignmentTarget(scope, body, assign.target, diagnostics, summary);
            const lowered = switch (typed_statement) {
                .assign_stmt => |value| value,
                .placeholder => null,
                else => return error.InvalidBodySync,
            };
            if (target == null or lowered == null) return;

            if (lowered.?.op) |op| {
                const lhs_builtin = switch (target.?.ty) {
                    .builtin => |builtin| builtin,
                    else => .unsupported,
                };
                const rhs_builtin = switch (lowered.?.expr.ty) {
                    .builtin => |builtin| builtin,
                    else => .unsupported,
                };
                const result_type = compoundAssignmentResult(op, lhs_builtin, rhs_builtin);
                if (result_type == .unsupported and !target.?.ty.isUnsupported() and !lowered.?.expr.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.assign.compound", assign.target.span, "compound assignment requires matching numeric operands in stage0", .{});
                } else if (result_type != .unsupported and !target.?.ty.eql(types.TypeRef.fromBuiltin(result_type))) {
                    try emit(diagnostics, summary, "type.assign.compound", assign.target.span, "compound assignment result must match the target type", .{});
                }
            } else if (!target.?.ty.isUnsupported() and !lowered.?.expr.ty.isUnsupported() and !target.?.ty.eql(lowered.?.expr.ty)) {
                try emit(
                    diagnostics,
                    summary,
                    "type.assign.mismatch",
                    assign.target.span,
                    "assignment target '{s}' does not match the right-hand type",
                    .{target.?.rendered_name},
                );
            }
        },
        .select_stmt => |select_syntax| {
            const lowered = switch (typed_statement) {
                .select_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            var lowered_arm_index: usize = 0;
            var valid_arm_count: usize = 0;

            for (select_syntax.arms) |arm_syntax| {
                if (select_syntax.subject != null) {
                    switch (arm_syntax.head) {
                        .guard => {
                            try emit(diagnostics, summary, "type.select.arm", armHeadSpan(arm_syntax.head), "unsupported select arm head in subject select", .{});
                            continue;
                        },
                        .pattern => {},
                    }
                } else {
                    switch (arm_syntax.head) {
                        .pattern => {
                            try emit(diagnostics, summary, "type.select.arm", armHeadSpan(arm_syntax.head), "malformed guarded select arm", .{});
                            continue;
                        },
                        .guard => {},
                    }
                }

                if (lowered_arm_index >= lowered.arms.len) return error.InvalidBodySync;
                valid_arm_count += 1;
                const lowered_arm = lowered.arms[lowered_arm_index];
                lowered_arm_index += 1;

                if (select_syntax.subject == null and !lowered_arm.condition.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !lowered_arm.condition.ty.isUnsupported()) {
                    try emit(diagnostics, summary, "type.select.guard", armHeadSpan(arm_syntax.head), "guarded select conditions must be Bool", .{});
                }

                try scope.push();
                defer scope.pop();
                if (select_syntax.subject != null) {
                    for (lowered_arm.bindings) |binding_site| {
                        try scope.put(binding_site.name, binding_site.ty, true);
                    }
                }
                try analyzeBlock(scope, arm_syntax.body, lowered_arm.body, body, diagnostics, summary, loop_depth);
            }

            if (valid_arm_count == 0) {
                try emit(diagnostics, summary, "type.select.empty", selectStatementSpan(select_syntax), "select requires at least one when arm", .{});
            }

            if (select_syntax.else_body) |else_body| {
                const lowered_else = lowered.else_body orelse return error.InvalidBodySync;
                try scope.push();
                defer scope.pop();
                try analyzeBlock(scope, else_body, lowered_else, body, diagnostics, summary, loop_depth);
            }
        },
        .repeat_stmt => |repeat_syntax| {
            const lowered = switch (typed_statement) {
                .loop_stmt => |value| value,
                .placeholder => null,
                else => return error.InvalidBodySync,
            };

            switch (repeat_syntax.header) {
                .infinite => {},
                .while_condition => {
                    if (lowered) |loop_data| {
                        const condition = loop_data.condition orelse return error.InvalidBodySync;
                        if (!condition.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !condition.ty.isUnsupported()) {
                            try emit(diagnostics, summary, "type.repeat.cond", repeatHeaderSpan(repeat_syntax.header), "repeat while condition must be Bool", .{});
                        }
                    }
                },
                .iteration => |iteration| {
                    switch (iteration.binding.node) {
                        .wildcard => {},
                        .binding => |binding_name| {
                            const name = std.mem.trim(u8, binding_name.text, " \t");
                            if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
                                try emit(diagnostics, summary, "type.repeat.pattern", iteration.binding.span, "repeat iteration requires an irrefutable binding pattern", .{});
                            }
                        },
                        .tuple => {
                            try emit(diagnostics, summary, "type.repeat.pattern.tuple", iteration.binding.span, "repeat tuple binding patterns require tuple iteration item types", .{});
                        },
                        else => {
                            try emit(diagnostics, summary, "type.repeat.pattern", iteration.binding.span, "repeat iteration requires an irrefutable binding pattern", .{});
                        },
                    }
                },
                .invalid => |invalid| {
                    try emit(diagnostics, summary, "type.repeat.syntax", invalid.span, "malformed repeat statement '{s}'", .{invalid.text});
                },
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
                try analyzeBlock(scope, repeat_syntax.body, loop_data.body, body, diagnostics, summary, loop_depth + 1);
            }
        },
        .unsafe_block => |unsafe_body| {
            const lowered = switch (typed_statement) {
                .unsafe_block => |value| value,
                else => return error.InvalidBodySync,
            };
            try scope.push();
            defer scope.pop();
            try analyzeBlock(scope, unsafe_body, lowered, body, diagnostics, summary, loop_depth);
        },
        .defer_stmt => switch (typed_statement) {
            .defer_stmt => {},
            else => return error.InvalidBodySync,
        },
        .break_stmt => {
            if (loop_depth == 0) {
                try emit(diagnostics, summary, "type.repeat.break", body.item.span, "break is only valid inside repeat", .{});
            }
        },
        .continue_stmt => {
            if (loop_depth == 0) {
                try emit(diagnostics, summary, "type.repeat.continue", body.item.span, "continue is only valid inside repeat", .{});
            }
        },
        .return_stmt => |return_syntax| {
            const lowered = switch (typed_statement) {
                .return_stmt => |value| value,
                else => return error.InvalidBodySync,
            };
            if (return_syntax) |_| {
                const expr = lowered orelse return error.InvalidBodySync;
                if (!body.function.return_type.isUnsupported() and !expr.ty.isUnsupported() and
                    !returnTypeStructurallyCompatible(expr.ty, body.function.return_type))
                {
                    try emit(diagnostics, summary, "type.return.mismatch", body.item.span, "return type mismatch in function '{s}'", .{body.item.name});
                }
            } else if (!body.function.return_type.eql(types.TypeRef.fromBuiltin(.unit))) {
                try emit(
                    diagnostics,
                    summary,
                    "type.return.missing_value",
                    body.item.span,
                    "non-Unit function '{s}' must return a value",
                    .{body.item.name},
                );
            }
        },
        .expr_stmt => switch (typed_statement) {
            .expr_stmt => {},
            else => return error.InvalidBodySync,
        },
    }
}

const ResolvedAssignmentTarget = struct {
    rendered_name: []const u8,
    ty: types.TypeRef,
};

fn resolveAssignmentTarget(
    scope: *const ScopeStack,
    body: query_types.CheckedBody,
    target: *const ast.BodyExprSyntax,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !?ResolvedAssignmentTarget {
    switch (target.node) {
        .name => |name| {
            const name_text = std.mem.trim(u8, name.text, " \t");
            if (!typed_text.isPlainIdentifier(name_text)) {
                try emit(diagnostics, summary, "type.assign.target", target.span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }

            const target_type = scope.get(name_text) orelse {
                try emit(diagnostics, summary, "type.assign.unknown", target.span, "assignment target '{s}' is not a known local name", .{name_text});
                return null;
            };
            if (!scope.isMutable(name_text)) {
                try emit(diagnostics, summary, "type.assign.immutable", target.span, "assignment target '{s}' is not mutable in stage0", .{name_text});
                return null;
            }

            return .{
                .rendered_name = name_text,
                .ty = target_type,
            };
        },
        .field => |field| {
            const base_name = switch (field.base.node) {
                .name => |name| std.mem.trim(u8, name.text, " \t"),
                else => {
                    try emit(diagnostics, summary, "type.assign.target", target.span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                    return null;
                },
            };
            const field_name = std.mem.trim(u8, field.field_name.text, " \t");
            if (!typed_text.isPlainIdentifier(base_name) or !typed_text.isPlainIdentifier(field_name)) {
                try emit(diagnostics, summary, "type.assign.target", target.span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }

            const base_type = scope.get(base_name) orelse {
                try emit(diagnostics, summary, "type.assign.unknown", target.span, "assignment target '{s}' is not a known local name", .{base_name});
                return null;
            };
            if (!scope.isMutable(base_name)) {
                try emit(diagnostics, summary, "type.assign.immutable", target.span, "assignment target '{s}' is not mutable in stage0", .{base_name});
                return null;
            }

            const struct_name = switch (base_type) {
                .named => |name| name,
                else => {
                    try emit(diagnostics, summary, "type.assign.target", target.span, "field assignment requires a struct-typed base expression", .{});
                    return null;
                },
            };
            const fields = findStructFields(body, struct_name) orelse {
                try emit(diagnostics, summary, "type.assign.target", target.span, "stage0 field assignment supports only locally declared struct types", .{});
                return null;
            };
            for (fields) |field_proto| {
                if (!std.mem.eql(u8, field_proto.name, field_name)) continue;
                return .{
                    .rendered_name = field_name,
                    .ty = field_proto.ty,
                };
            }

            try emit(diagnostics, summary, "type.field.unknown", target.span, "unknown field '{s}' on struct '{s}'", .{
                field_name,
                struct_name,
            });
            return null;
        },
        else => {
            try emit(diagnostics, summary, "type.assign.target", target.span, "stage0 assignment supports only plain locals or one struct field projection", .{});
            return null;
        },
    }
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

fn blockDefinitelyReturns(block: *const typed.Block) bool {
    if (block.statements.items.len == 0) return false;
    return statementDefinitelyReturns(block.statements.items[block.statements.items.len - 1]);
}

fn statementDefinitelyReturns(statement: typed.Statement) bool {
    return switch (statement) {
        .return_stmt => true,
        .select_stmt => |select_data| selectDefinitelyReturns(select_data),
        .unsafe_block => |unsafe_body| blockDefinitelyReturns(unsafe_body),
        else => false,
    };
}

fn selectDefinitelyReturns(select_data: *const typed.Statement.SelectData) bool {
    var covered = false;
    for (select_data.arms) |arm| {
        if (!blockDefinitelyReturns(arm.body)) return false;
        if (isDefinitelyTrueExpr(arm.condition)) {
            covered = true;
            break;
        }
    }

    if (covered) return true;
    if (select_data.else_body) |else_body| return blockDefinitelyReturns(else_body);
    return false;
}

fn isDefinitelyTrueExpr(expr: *const typed.Expr) bool {
    return switch (expr.node) {
        .bool_lit => |value| value,
        else => false,
    };
}

fn compoundAssignmentResult(op: typed.BinaryOp, lhs: types.Builtin, rhs: types.Builtin) types.Builtin {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => if (lhs == rhs and lhs.isNumeric()) lhs else .unsupported,
        .bit_and, .bit_xor, .bit_or => if (lhs == rhs and lhs.isInteger()) lhs else .unsupported,
        .shl, .shr => if (lhs.isInteger() and rhs == .index) lhs else .unsupported,
        else => .unsupported,
    };
}

fn emit(
    diagnostics: *diag.Bag,
    summary: *Summary,
    code: []const u8,
    span: ?@import("../source/root.zig").Span,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try diagnostics.add(.@"error", code, span, fmt, args);
    summary.prepared_issue_count += 1;
}

fn armHeadSpan(head: ast.BodyStatementSyntax.SelectHead) @import("../source/root.zig").Span {
    return switch (head) {
        .guard => |expr| expr.span,
        .pattern => |pattern| pattern.span,
    };
}

fn selectStatementSpan(select_syntax: *const ast.BodyStatementSyntax.SelectStmt) ?@import("../source/root.zig").Span {
    if (select_syntax.subject) |subject| return subject.span;
    if (select_syntax.arms.len != 0) return armHeadSpan(select_syntax.arms[0].head);
    return null;
}

fn repeatHeaderSpan(header: ast.BodyStatementSyntax.RepeatHeader) ?@import("../source/root.zig").Span {
    return switch (header) {
        .infinite => null,
        .while_condition => |expr| expr.span,
        .iteration => |iteration| iteration.binding.span,
        .invalid => |invalid| invalid.span,
    };
}
