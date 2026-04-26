const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const callable_types = @import("callable_types.zig");
const typed_decls = @import("declarations.zig");
const typed_expr = @import("expr.zig");
const signatures = @import("signatures.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed_text = @import("text.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const BinaryOp = typed_expr.BinaryOp;
const Expr = typed_expr.Expr;
const ParameterMode = typed_decls.ParameterMode;
const GenericParam = signatures.GenericParam;
const WherePredicate = signatures.WherePredicate;
const baseTypeName = typed_text.baseTypeName;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const BoundaryType = type_support.BoundaryType;
const boundaryAccessCompatible = type_support.boundaryAccessCompatible;
const boundaryInnerTypeCompatible = type_support.boundaryInnerTypeCompatible;
const callArgumentTypeCompatible = type_support.callArgumentTypeCompatible;
const findEnumPrototype = type_support.findEnumPrototype;
const findEnumVariant = type_support.findEnumVariant;
const findMethodPrototype = type_support.findMethodPrototype;
const findPrototype = type_support.findPrototype;
const findStructPrototype = type_support.findStructPrototype;
const inferExprBoundaryTypeInScope = type_support.inferExprBoundaryTypeInScope;
const parseBoundaryType = type_support.parseBoundaryType;
const makeCallableTypeName = callable_types.makeCallableTypeName;
const makeCallableInputTypeName = callable_types.makeCallableInputTypeName;
const parseCallableTypeName = callable_types.parseCallableTypeName;
const shallowTypeRefFromName = callable_types.shallowTypeRefFromName;

fn validateBorrowArguments(
    self: anytype,
    parameter_modes: []const ParameterMode,
    args: []const *Expr,
    callee_name: []const u8,
) !void {
    for (args, 0..) |arg, index| {
        const mode = if (index < parameter_modes.len) parameter_modes[index] else ParameterMode.owned;
        switch (mode) {
            .owned, .take => {},
            .read => try validateBorrowArgumentExpr(self, arg, false, callee_name, index + 1),
            .edit => try validateBorrowArgumentExpr(self, arg, true, callee_name, index + 1),
        }
    }
}

fn validateBorrowArgumentExpr(
    self: anytype,
    expr: *const Expr,
    require_mutable: bool,
    callee_name: []const u8,
    arg_index: usize,
) !void {
    switch (expr.node) {
        .identifier => |name| {
            if (self.scope.get(name) == null) {
                try self.diagnostics.add(.@"error", "type.call.borrow_arg", self.span, "borrow argument {d} to '{s}' must come from a local place in stage0", .{
                    arg_index,
                    callee_name,
                });
                return;
            }
            if (require_mutable and !self.scope.isMutable(name)) {
                try self.diagnostics.add(.@"error", "type.call.borrow_mut", self.span, "edit borrow argument {d} to '{s}' requires a mutable local place in stage0", .{
                    arg_index,
                    callee_name,
                });
            }
        },
        .field => |field| switch (field.base.node) {
            .identifier => |base_name| {
                if (self.scope.get(base_name) == null) {
                    try self.diagnostics.add(.@"error", "type.call.borrow_arg", self.span, "borrow argument {d} to '{s}' must come from a local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                    return;
                }
                if (require_mutable and !self.scope.isMutable(base_name)) {
                    try self.diagnostics.add(.@"error", "type.call.borrow_mut", self.span, "edit borrow argument {d} to '{s}' requires a mutable local place in stage0", .{
                        arg_index,
                        callee_name,
                    });
                }
            },
            else => try self.diagnostics.add(.@"error", "type.call.borrow_arg", self.span, "borrow argument {d} to '{s}' must be a plain local or one field projection in stage0", .{
                arg_index,
                callee_name,
            }),
        },
        else => try self.diagnostics.add(.@"error", "type.call.borrow_arg", self.span, "borrow argument {d} to '{s}' must be a plain local or one field projection in stage0", .{
            arg_index,
            callee_name,
        }),
    }
}

const LifetimeBinding = struct {
    formal_name: []const u8,
    actual_name: []const u8,
};

fn validateRetainedCallArguments(
    self: anytype,
    parameter_type_names: []const []const u8,
    generic_params: []const GenericParam,
    where_predicates: []const WherePredicate,
    args: []const *Expr,
    callee_name: []const u8,
) !void {
    var lifetime_bindings = array_list.Managed(LifetimeBinding).init(self.allocator);
    defer lifetime_bindings.deinit();

    for (args, 0..) |arg, index| {
        if (index >= parameter_type_names.len) break;
        const expected = parseBoundaryType(parameter_type_names[index]);
        if (expected.kind != .retained_read and expected.kind != .retained_edit) continue;

        const actual = inferExprBoundaryTypeInScope(self.scope, arg);
        switch (actual.kind) {
            .retained_read, .retained_edit => {},
            .ephemeral_read, .ephemeral_edit => {
                try self.diagnostics.add(.@"error", "lifetime.call.ephemeral_source", self.span, "retained argument {d} to '{s}' is derived only from an ephemeral borrow", .{
                    index + 1,
                    callee_name,
                });
                continue;
            },
            .value => {
                try self.diagnostics.add(.@"error", "lifetime.call.retained_source", self.span, "retained argument {d} to '{s}' must be a retained borrow value", .{
                    index + 1,
                    callee_name,
                });
                continue;
            },
        }

        if (!boundaryAccessCompatible(actual, expected)) {
            try self.diagnostics.add(.@"error", "lifetime.call.mode", self.span, "retained argument {d} to '{s}' does not match the required borrow mode", .{
                index + 1,
                callee_name,
            });
            continue;
        }

        if (!boundaryInnerTypeCompatible(actual.inner_type_name, expected.inner_type_name, generic_params, true)) {
            continue;
        }

        const expected_lifetime = expected.lifetime_name orelse continue;
        const actual_lifetime = actual.lifetime_name orelse continue;
        if (std.mem.eql(u8, expected_lifetime, "'static")) {
            if (!lifetimeOutlivesInContext(self.current_where_predicates, actual_lifetime, "'static")) {
                try self.diagnostics.add(.@"error", "lifetime.call.outlives", self.span, "retained argument {d} to '{s}' does not satisfy required outlives relation", .{
                    index + 1,
                    callee_name,
                });
            }
            continue;
        }

        if (findLifetimeBinding(lifetime_bindings.items, expected_lifetime)) |existing| {
            if (!std.mem.eql(u8, existing, actual_lifetime)) {
                try self.diagnostics.add(.@"error", "lifetime.call.bind", self.span, "call to '{s}' would require incompatible lifetime bindings for '{s}'", .{
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
                if (!lifetimeOutlivesInContext(self.current_where_predicates, longer_name, shorter_name)) {
                    try self.diagnostics.add(.@"error", "lifetime.call.outlives", self.span, "call to '{s}' does not satisfy required outlives relation '{s}: {s}'", .{
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
    self: anytype,
    field_type_names: []const []const u8,
    args: []const *Expr,
    container_name: []const u8,
) !void {
    for (args, 0..) |arg, index| {
        if (index >= field_type_names.len) break;
        const expected = parseBoundaryType(field_type_names[index]);
        if (expected.kind != .retained_read and expected.kind != .retained_edit) continue;

        const actual = inferExprBoundaryTypeInScope(self.scope, arg);
        switch (actual.kind) {
            .retained_read, .retained_edit => {},
            .ephemeral_read, .ephemeral_edit => {
                try self.diagnostics.add(.@"error", "lifetime.store.ephemeral_source", self.span, "stored retained field {d} for '{s}' is derived only from an ephemeral borrow", .{
                    index + 1,
                    container_name,
                });
                continue;
            },
            .value => {
                try self.diagnostics.add(.@"error", "lifetime.store.retained_source", self.span, "stored retained field {d} for '{s}' must be a retained borrow value", .{
                    index + 1,
                    container_name,
                });
                continue;
            },
        }

        if (!boundaryAccessCompatible(actual, expected)) {
            try self.diagnostics.add(.@"error", "lifetime.store.mode", self.span, "stored retained field {d} for '{s}' does not match the required borrow mode", .{
                index + 1,
                container_name,
            });
        }
    }
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

fn lifetimeOutlivesInContext(where_predicates: []const WherePredicate, longer_name: []const u8, shorter_name: []const u8) bool {
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

fn hasBorrowingParameters(parameter_modes: []const ParameterMode) bool {
    for (parameter_modes) |mode| if (mode == .read or mode == .edit) return true;
    return false;
}

fn ExprParser(
    comptime ScopeType: type,
    comptime FunctionPrototypeSlice: type,
    comptime MethodPrototypeSlice: type,
    comptime StructPrototypeSlice: type,
    comptime EnumPrototypeSlice: type,
) type {
    return struct {
        allocator: Allocator,
        diagnostics: *diag.Bag,
        scope: ScopeType,
        current_where_predicates: []const WherePredicate,
        prototypes: FunctionPrototypeSlice,
        method_prototypes: MethodPrototypeSlice,
        struct_prototypes: StructPrototypeSlice,
        enum_prototypes: EnumPrototypeSlice,
        span: source.Span,
        tokens: []ExprToken,
        index: usize = 0,
        expected_type: types.TypeRef,
        suspend_context: bool,
        unsafe_context: bool,

        fn parse(self: *@This()) anyerror!*Expr {
            const expr = try self.parseConversion();
            return self.finalizeBareFunctionValue(expr);
        }

        fn parseConversion(self: *@This()) anyerror!*Expr {
            var expr = try self.parseLogicalOr();
            while (self.peekIsIdentifier("as")) {
                _ = self.advance();
                const target = try self.parseConversionTarget();
                if (target.mode == .explicit_checked) {
                    const result_type_name = try std.fmt.allocPrint(self.allocator, "Result[{s}, ConvertError]", .{target.target_type_name});
                    errdefer self.allocator.free(result_type_name);
                    const converted = try self.makeExpr(.{ .named = result_type_name }, .{ .conversion = .{
                        .operand = expr,
                        .mode = target.mode,
                        .target_type = target.target_type,
                        .target_type_name = target.target_type_name,
                    } });
                    converted.owned_type_name = result_type_name;
                    expr = converted;
                    continue;
                }
                expr = try self.makeExpr(target.target_type, .{ .conversion = .{
                    .operand = expr,
                    .mode = target.mode,
                    .target_type = target.target_type,
                    .target_type_name = target.target_type_name,
                } });
            }
            return expr;
        }

        const ConversionTarget = struct {
            mode: typed_expr.ConversionMode,
            target_type: types.TypeRef,
            target_type_name: []const u8,
        };

        fn parseConversionTarget(self: *@This()) anyerror!ConversionTarget {
            var mode = typed_expr.ConversionMode.explicit_infallible;
            var target_token = self.advance();

            if (target_token.kind == .identifier and std.mem.eql(u8, target_token.lexeme, "may")) {
                mode = .explicit_checked;
                if (self.peek().kind != .l_bracket) {
                    try self.diagnostics.add(.@"error", "type.expr.conversion.syntax", self.span, "checked conversion requires may[Target]", .{});
                    return .{
                        .mode = mode,
                        .target_type = .unsupported,
                        .target_type_name = "Unsupported",
                    };
                }
                _ = self.advance();
                target_token = self.advance();
                if (self.peek().kind == .r_bracket) {
                    _ = self.advance();
                } else {
                    try self.diagnostics.add(.@"error", "type.expr.conversion.syntax", self.span, "checked conversion target must close with ']'", .{});
                }
            }

            if (target_token.kind != .identifier) {
                try self.diagnostics.add(.@"error", "type.expr.conversion.syntax", self.span, "conversion target must be a type name", .{});
                return .{
                    .mode = mode,
                    .target_type = .unsupported,
                    .target_type_name = "Unsupported",
                };
            }

            const target_type = shallowTypeRefFromName(target_token.lexeme);
            return .{
                .mode = mode,
                .target_type = target_type,
                .target_type_name = target_type.displayName(),
            };
        }

        fn parseLogicalOr(self: *@This()) anyerror!*Expr {
            var expr = try self.parseLogicalAnd();
            while (true) {
                if (self.peek().kind != .pipe_pipe) return expr;
                _ = self.advance();
                const rhs = try self.parseLogicalAnd();
                if (!expr.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !expr.ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.bool_or", self.span, "|| requires Bool operands", .{});
                }
                if (!rhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !rhs.ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.bool_or", self.span, "|| requires Bool operands", .{});
                }
                expr = try self.makeBinary(.bool_or, expr, rhs, types.TypeRef.fromBuiltin(.bool));
            }
        }

        fn parseLogicalAnd(self: *@This()) anyerror!*Expr {
            var expr = try self.parseBitwise();
            while (true) {
                if (self.peek().kind != .amp_amp) return expr;
                _ = self.advance();
                const rhs = try self.parseBitwise();
                if (!expr.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !expr.ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.bool_and", self.span, "&& requires Bool operands", .{});
                }
                if (!rhs.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !rhs.ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.bool_and", self.span, "&& requires Bool operands", .{});
                }
                expr = try self.makeBinary(.bool_and, expr, rhs, types.TypeRef.fromBuiltin(.bool));
            }
        }

        fn parseBitwise(self: *@This()) anyerror!*Expr {
            var expr = try self.parseEquality();
            while (true) {
                const op = switch (self.peek().kind) {
                    .amp => BinaryOp.bit_and,
                    .caret => BinaryOp.bit_xor,
                    .pipe => BinaryOp.bit_or,
                    else => return expr,
                };
                _ = self.advance();
                const rhs = try self.parseEquality();
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                const result_ty = if (lhs_ty.eql(rhs_ty) and lhs_ty.isInteger()) lhs_ty else types.TypeRef.unsupported;
                if (result_ty.isUnsupported() and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.bitwise", self.span, "bitwise operators require matching integer operands", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, result_ty);
            }
        }

        fn parseEquality(self: *@This()) anyerror!*Expr {
            var expr = try self.parseOrdering();
            while (true) {
                const op = switch (self.peek().kind) {
                    .eq_eq => BinaryOp.eq,
                    .bang_eq => BinaryOp.ne,
                    else => return expr,
                };
                _ = self.advance();
                const rhs = try self.parseOrdering();
                const comparison_chain = isComparisonExpr(expr);
                if (comparison_chain) {
                    try self.diagnostics.add(.@"error", "type.expr.compare_chain", self.span, "comparison chaining requires explicit grouping", .{});
                }
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                if (!comparison_chain and !lhs_ty.eql(rhs_ty) and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.compare", self.span, "comparison operands must have matching types", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, types.TypeRef.fromBuiltin(.bool));
            }
        }

        fn parseOrdering(self: *@This()) anyerror!*Expr {
            var expr = try self.parseShift();
            while (true) {
                const op = switch (self.peek().kind) {
                    .lt => BinaryOp.lt,
                    .lte => BinaryOp.lte,
                    .gt => BinaryOp.gt,
                    .gte => BinaryOp.gte,
                    else => return expr,
                };
                _ = self.advance();
                const rhs = try self.parseShift();
                const comparison_chain = isComparisonExpr(expr);
                if (comparison_chain) {
                    try self.diagnostics.add(.@"error", "type.expr.compare_chain", self.span, "comparison chaining requires explicit grouping", .{});
                }
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                if (!comparison_chain and !lhs_ty.eql(rhs_ty) and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.compare", self.span, "comparison operands must have matching types", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, types.TypeRef.fromBuiltin(.bool));
            }
        }

        fn parseShift(self: *@This()) anyerror!*Expr {
            var expr = try self.parseAdditive();
            while (true) {
                const op = switch (self.peek().kind) {
                    .lt_lt => BinaryOp.shl,
                    .gt_gt => BinaryOp.shr,
                    else => return expr,
                };
                _ = self.advance();
                const previous_expected = self.expected_type;
                self.expected_type = types.TypeRef.fromBuiltin(.index);
                const rhs = try self.parseAdditive();
                self.expected_type = previous_expected;
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                const result_ty = if (lhs_ty.isInteger() and rhs_ty.eql(types.TypeRef.fromBuiltin(.index))) lhs_ty else types.TypeRef.unsupported;
                if (result_ty.isUnsupported() and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.shift", self.span, "shift operators require an integer left operand and Index shift count", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, result_ty);
            }
        }

        fn parseAdditive(self: *@This()) anyerror!*Expr {
            var expr = try self.parseMultiplicative();
            while (true) {
                const op = switch (self.peek().kind) {
                    .plus => BinaryOp.add,
                    .minus => BinaryOp.sub,
                    else => return expr,
                };
                _ = self.advance();
                const rhs = try self.parseMultiplicative();
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                const result_ty = if (lhs_ty.eql(rhs_ty) and lhs_ty.isNumeric()) lhs_ty else types.TypeRef.unsupported;
                if (result_ty.isUnsupported() and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.additive", self.span, "additive operators require matching numeric operands", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, result_ty);
            }
        }

        fn parseMultiplicative(self: *@This()) anyerror!*Expr {
            var expr = try self.parseUnary();
            while (true) {
                const op = switch (self.peek().kind) {
                    .star => BinaryOp.mul,
                    .slash => BinaryOp.div,
                    .percent => BinaryOp.mod,
                    else => return expr,
                };
                _ = self.advance();
                const rhs = try self.parseUnary();
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                const result_ty = if (lhs_ty.eql(rhs_ty) and lhs_ty.isNumeric()) lhs_ty else types.TypeRef.unsupported;
                if (result_ty.isUnsupported() and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.multiplicative", self.span, "multiplicative operators require matching numeric operands", .{});
                }
                expr = try self.makeBinary(op, expr, rhs, result_ty);
            }
        }

        fn parsePostfix(self: *@This()) anyerror!*Expr {
            var expr = try self.parsePrimary();
            while (true) {
                if (self.peek().kind == .colon_colon) {
                    expr = try self.parseInvocation(expr);
                    continue;
                }
                if (self.peek().kind == .dot) {
                    expr = try self.parseFieldProjection(expr);
                    continue;
                }
                if (self.peek().kind == .l_bracket) {
                    expr = try self.parseKeyedAccess(expr);
                    continue;
                }
                return expr;
            }
        }

        fn parseUnary(self: *@This()) anyerror!*Expr {
            return switch (self.peek().kind) {
                .bang => blk: {
                    _ = self.advance();
                    const operand = try self.parseUnary();
                    if (!operand.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !operand.ty.isUnsupported()) {
                        try self.diagnostics.add(.@"error", "type.expr.unary_not", self.span, "unary ! requires Bool", .{});
                    }
                    break :blk try self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .unary = .{
                        .op = .bool_not,
                        .operand = operand,
                    } });
                },
                .minus => blk: {
                    _ = self.advance();
                    const operand = try self.parseUnary();
                    if (!operand.ty.eql(types.TypeRef.fromBuiltin(.i32)) and !operand.ty.isUnsupported()) {
                        try self.diagnostics.add(.@"error", "type.expr.unary_neg", self.span, "unary - requires I32 in stage0", .{});
                    }
                    break :blk try self.makeExpr(if (operand.ty.isUnsupported()) .unsupported else types.TypeRef.fromBuiltin(.i32), .{ .unary = .{
                        .op = .negate,
                        .operand = operand,
                    } });
                },
                .tilde => blk: {
                    _ = self.advance();
                    const operand = try self.parseUnary();
                    if (!operand.ty.isInteger() and !operand.ty.isUnsupported()) {
                        try self.diagnostics.add(.@"error", "type.expr.unary_bit_not", self.span, "unary ~ requires an integer operand", .{});
                    }
                    break :blk try self.makeExpr(if (operand.ty.isUnsupported()) .unsupported else operand.ty, .{ .unary = .{
                        .op = .bit_not,
                        .operand = operand,
                    } });
                },
                else => self.parsePostfix(),
            };
        }

        fn parsePrimary(self: *@This()) anyerror!*Expr {
            const token = self.advance();
            switch (token.kind) {
                .integer => {
                    const value = std.fmt.parseInt(i64, token.lexeme, 10) catch 0;
                    const integer_type = if (self.expected_type.isNumeric()) self.expected_type else types.TypeRef.fromBuiltin(.i32);
                    return self.makeExpr(integer_type, .{ .integer = value });
                },
                .string => return self.makeExpr(types.TypeRef.fromBuiltin(.str), .{ .string = token.lexeme }),
                .identifier => {
                    if (std.mem.eql(u8, token.lexeme, "true")) return self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .bool_lit = true });
                    if (std.mem.eql(u8, token.lexeme, "false")) return self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .bool_lit = false });

                    const value_type = self.scope.get(token.lexeme) orelse .unsupported;
                    if (value_type.isUnsupported() and
                        findPrototype(self.prototypes, token.lexeme) == null and
                        findStructPrototype(self.struct_prototypes, token.lexeme) == null and
                        findEnumPrototype(self.enum_prototypes, token.lexeme) == null)
                    {
                        try self.diagnostics.add(.@"error", "type.name.unknown", self.span, "unknown name '{s}'", .{token.lexeme});
                    }
                    return self.makeExpr(value_type, .{ .identifier = token.lexeme });
                },
                .l_paren => {
                    if (self.parenSequenceHasTopLevelComma()) {
                        return self.parseTupleExpression();
                    }
                    const expr = try self.parse();
                    if (self.peek().kind == .r_paren) {
                        _ = self.advance();
                    } else {
                        try self.diagnostics.add(.@"error", "parse.expr.grouping", self.span, "unterminated parenthesized expression", .{});
                    }
                    return expr;
                },
                .l_bracket => return self.parseArrayLiteral(),
                else => {
                    try self.diagnostics.add(.@"error", "parse.expr.primary", self.span, "unsupported expression form in stage0", .{});
                    return makeUnsupportedExpr(self.allocator);
                },
            }
        }

        fn parseInvocation(self: *@This(), callee_expr: *Expr) anyerror!*Expr {
            _ = self.advance();

            var method_target: ?Expr.MethodTarget = null;
            const callee_name = switch (callee_expr.node) {
                .identifier => |name| name,
                .method_target => |target| blk: {
                    method_target = target;
                    break :blk "";
                },
                else => blk: {
                    if (callee_expr.node == .enum_constructor_target) break :blk "";
                    try self.diagnostics.add(.@"error", "type.call.target", self.span, "stage0 only supports direct function invocation targets", .{});
                    break :blk "";
                },
            };

            const enum_constructor_target = switch (callee_expr.node) {
                .enum_constructor_target => |value| value,
                else => null,
            };

            const prototype = findPrototype(self.prototypes, callee_name);
            const struct_prototype = findStructPrototype(self.struct_prototypes, callee_name);
            const callable = switch (callee_expr.ty) {
                .named => |type_name| try parseCallableTypeName(type_name, self.allocator),
                else => null,
            };

            var args = array_list.Managed(*Expr).init(self.allocator);
            defer args.deinit();

            if (self.peek().kind != .colon_colon) {
                while (true) {
                    const arg = try self.parseInvocationArg();
                    try args.append(arg);
                    if (self.peek().kind == .comma) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
            }

            if (args.items.len > 5) {
                try self.diagnostics.add(.@"error", "type.call.arity_cap", self.span, "stage0 enforces the v1 maximum of five top-level invocation args", .{});
            }

            if (self.peek().kind != .colon_colon) {
                try self.diagnostics.add(.@"error", "type.call.syntax", self.span, "invocation must end the argument slot with ':: call'", .{});
                return self.makeExpr(.unsupported, .{ .call = .{
                    .callee = callee_name,
                    .args = try args.toOwnedSlice(),
                } });
            }
            _ = self.advance();

            const qualifier = self.advance();
            const is_call = qualifier.kind == .identifier and std.mem.eql(u8, qualifier.lexeme, "call");
            const is_method = qualifier.kind == .identifier and std.mem.eql(u8, qualifier.lexeme, "method");
            if (!is_call and !is_method) {
                try self.diagnostics.add(.@"error", "type.call.qualifier", self.span, "stage0 supports only ':: call' and ':: method' invocation qualifiers", .{});
            }

            if (method_target) |target| {
                if (!is_method) {
                    callee_expr.deinit(self.allocator);
                    self.allocator.destroy(callee_expr);
                    try self.diagnostics.add(.@"error", "type.method.qualifier", self.span, "method targets must use ':: method'", .{});
                    return self.makeExpr(.unsupported, .{ .call = .{
                        .callee = "",
                        .args = try args.toOwnedSlice(),
                    } });
                }

                const prototype_method = findMethodPrototype(self.method_prototypes, target.target_type, target.method_name) orelse {
                    callee_expr.deinit(self.allocator);
                    self.allocator.destroy(callee_expr);
                    try self.diagnostics.add(.@"error", "type.method.unknown", self.span, "unknown inherent method '{s}' on type '{s}'", .{
                        target.method_name,
                        target.target_type,
                    });
                    return self.makeExpr(.unsupported, .{ .call = .{
                        .callee = "",
                        .args = try args.toOwnedSlice(),
                    } });
                };

                const combined_args = try self.allocator.alloc(*Expr, args.items.len + 1);
                combined_args[0] = target.base;
                for (args.items, 0..) |arg, index| combined_args[index + 1] = arg;

                if (prototype_method.parameter_types.len != combined_args.len) {
                    try self.diagnostics.add(.@"error", "type.method.arity", self.span, "method call to '{s}.{s}' has wrong arity", .{
                        target.target_type,
                        target.method_name,
                    });
                } else {
                    for (combined_args, prototype_method.parameter_types, 0..) |arg, expected, index| {
                        const expected_type_name = if (index < prototype_method.parameter_type_names.len) prototype_method.parameter_type_names[index] else expected.displayName();
                        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
                            !callArgumentTypeCompatible(arg.ty, expected, expected_type_name, prototype_method.generic_params, true))
                        {
                            try self.diagnostics.add(.@"error", "type.method.arg", self.span, "method call to '{s}.{s}' argument {d} has wrong type", .{
                                target.target_type,
                                target.method_name,
                                index + 1,
                            });
                        }
                    }
                    try validateBorrowArguments(self, prototype_method.parameter_modes, combined_args, prototype_method.function_name);
                    try validateRetainedCallArguments(
                        self,
                        prototype_method.parameter_type_names,
                        prototype_method.generic_params,
                        prototype_method.where_predicates,
                        combined_args,
                        prototype_method.function_name,
                    );
                }
                if (prototype_method.is_suspend and !self.suspend_context) {
                    try self.diagnostics.add(.@"error", "type.method.suspend_context", self.span, "call to suspend method '{s}.{s}' requires suspend context or an explicit runtime adapter", .{
                        target.target_type,
                        target.method_name,
                    });
                }
                if (prototype_method.is_suspend and hasBorrowingParameters(prototype_method.parameter_modes)) {
                    try self.diagnostics.add(.@"error", "type.method.suspend_borrow", self.span, "stage0 does not yet permit suspend method calls that borrow self or arguments", .{});
                }

                self.allocator.destroy(callee_expr);
                return self.makeExpr(prototype_method.return_type, .{ .call = .{
                    .callee = prototype_method.function_name,
                    .args = combined_args,
                } });
            }

            callee_expr.deinit(self.allocator);
            self.allocator.destroy(callee_expr);

            if (enum_constructor_target) |target| {
                const prototype_enum = findEnumPrototype(self.enum_prototypes, target.enum_name) orelse {
                    try self.diagnostics.add(.@"error", "type.enum.variant_unknown", self.span, "unknown enum '{s}' in constructor target", .{target.enum_name});
                    return self.makeExpr(.unsupported, .{ .identifier = target.variant_name });
                };
                const variant = findEnumVariant(prototype_enum, target.variant_name) orelse {
                    try self.diagnostics.add(.@"error", "type.enum.variant_unknown", self.span, "unknown variant '{s}' on enum '{s}'", .{
                        target.variant_name,
                        target.enum_name,
                    });
                    return self.makeExpr(.unsupported, .{ .identifier = target.variant_name });
                };

                return switch (variant.payload) {
                    .tuple_fields => |tuple_fields| blk: {
                        if (tuple_fields.len != args.items.len) {
                            try self.diagnostics.add(.@"error", "type.enum.ctor.arity", self.span, "constructor call to '{s}.{s}' has wrong arity", .{
                                target.enum_name,
                                target.variant_name,
                            });
                        } else {
                            for (args.items, tuple_fields, 0..) |arg, field, field_index| {
                                if (!arg.ty.isUnsupported() and !field.ty.isUnsupported() and
                                    !callArgumentTypeCompatible(arg.ty, field.ty, field.type_name, &.{}, false))
                                {
                                    try self.diagnostics.add(.@"error", "type.enum.ctor.arg", self.span, "constructor call to '{s}.{s}' argument {d} has wrong type", .{
                                        target.enum_name,
                                        target.variant_name,
                                        field_index + 1,
                                    });
                                }
                            }
                            const field_type_names = try self.allocator.alloc([]const u8, tuple_fields.len);
                            defer self.allocator.free(field_type_names);
                            for (tuple_fields, 0..) |field, field_index| field_type_names[field_index] = field.type_name;
                            try validateRetainedStorageArguments(self, field_type_names, args.items, target.enum_name);
                        }
                        break :blk self.makeExpr(.{ .named = target.enum_name }, .{ .enum_construct = .{
                            .enum_name = target.enum_name,
                            .enum_symbol = target.enum_symbol,
                            .variant_name = target.variant_name,
                            .args = try args.toOwnedSlice(),
                        } });
                    },
                    .named_fields => blk: {
                        const named_fields = switch (variant.payload) {
                            .named_fields => |fields| fields,
                            else => unreachable,
                        };
                        if (named_fields.len != args.items.len) {
                            try self.diagnostics.add(.@"error", "type.enum.ctor.arity", self.span, "constructor call to '{s}.{s}' has wrong arity", .{
                                target.enum_name,
                                target.variant_name,
                            });
                        } else {
                            for (args.items, named_fields, 0..) |arg, field, field_index| {
                                if (!arg.ty.isUnsupported() and !field.ty.isUnsupported() and
                                    !callArgumentTypeCompatible(arg.ty, field.ty, field.type_name, &.{}, false))
                                {
                                    try self.diagnostics.add(.@"error", "type.enum.ctor.arg", self.span, "constructor call to '{s}.{s}' field {d} has wrong type", .{
                                        target.enum_name,
                                        target.variant_name,
                                        field_index + 1,
                                    });
                                }
                            }
                            const field_type_names = try self.allocator.alloc([]const u8, named_fields.len);
                            defer self.allocator.free(field_type_names);
                            for (named_fields, 0..) |field, field_index| field_type_names[field_index] = field.type_name;
                            try validateRetainedStorageArguments(self, field_type_names, args.items, target.enum_name);
                        }
                        break :blk self.makeExpr(.{ .named = target.enum_name }, .{ .enum_construct = .{
                            .enum_name = target.enum_name,
                            .enum_symbol = target.enum_symbol,
                            .variant_name = target.variant_name,
                            .args = try args.toOwnedSlice(),
                        } });
                    },
                    .none => blk: {
                        if (args.items.len != 0) {
                            try self.diagnostics.add(.@"error", "type.enum.ctor.arity", self.span, "unit variant '{s}.{s}' does not take constructor args", .{
                                target.enum_name,
                                target.variant_name,
                            });
                        }
                        break :blk makeEnumVariantExpr(self.allocator, prototype_enum, target.variant_name);
                    },
                };
            }

            if (struct_prototype) |value| {
                if (value.fields.len != args.items.len) {
                    try self.diagnostics.add(.@"error", "type.ctor.arity", self.span, "constructor call to '{s}' has wrong arity", .{callee_name});
                } else {
                    for (args.items, value.fields, 0..) |arg, field, field_index| {
                        if (!arg.ty.isUnsupported() and !field.ty.isUnsupported() and
                            !callArgumentTypeCompatible(arg.ty, field.ty, field.type_name, &.{}, false))
                        {
                            try self.diagnostics.add(.@"error", "type.ctor.arg", self.span, "constructor call to '{s}' field {d} has wrong type", .{
                                callee_name,
                                field_index + 1,
                            });
                        }
                    }
                    const field_type_names = try self.allocator.alloc([]const u8, value.fields.len);
                    defer self.allocator.free(field_type_names);
                    for (value.fields, 0..) |field, field_index| field_type_names[field_index] = field.type_name;
                    try validateRetainedStorageArguments(self, field_type_names, args.items, callee_name);
                }
                return self.makeExpr(.{ .named = value.name }, .{ .constructor = .{
                    .type_name = value.name,
                    .type_symbol = value.symbol_name,
                    .args = try args.toOwnedSlice(),
                } });
            } else if (prototype) |value| {
                const return_type = value.return_type;
                if (value.unsafe_required and !self.unsafe_context) {
                    try self.diagnostics.add(.@"error", "type.call.unsafe", self.span, "call to unsafe function '{s}' requires #unsafe context", .{callee_name});
                }
                if (value.is_suspend and !self.suspend_context) {
                    try self.diagnostics.add(.@"error", "type.call.suspend_context", self.span, "call to suspend function '{s}' requires suspend context or an explicit runtime adapter", .{callee_name});
                }
                if (value.is_suspend and hasBorrowingParameters(value.parameter_modes)) {
                    try self.diagnostics.add(.@"error", "type.call.suspend_borrow", self.span, "stage0 does not yet permit suspend calls that borrow arguments", .{});
                }
                if (value.parameter_types.len != args.items.len) {
                    try self.diagnostics.add(.@"error", "type.call.arity", self.span, "call to '{s}' has wrong arity", .{callee_name});
                } else {
                    for (args.items, value.parameter_types, 0..) |arg, expected, index| {
                        const expected_type_name = if (index < value.parameter_type_names.len) value.parameter_type_names[index] else expected.displayName();
                        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
                            !callArgumentTypeCompatible(arg.ty, expected, expected_type_name, value.generic_params, false))
                        {
                            try self.diagnostics.add(.@"error", "type.call.arg", self.span, "call to '{s}' argument {d} has wrong type", .{
                                callee_name,
                                index + 1,
                            });
                        }
                    }
                    try validateBorrowArguments(self, value.parameter_modes, args.items, callee_name);
                    try validateRetainedCallArguments(
                        self,
                        value.parameter_type_names,
                        value.generic_params,
                        value.where_predicates,
                        args.items,
                        callee_name,
                    );
                }
                return self.makeExpr(return_type, .{ .call = .{
                    .callee = callee_name,
                    .args = try args.toOwnedSlice(),
                } });
            } else if (callable) |value| {
                if (!is_call) {
                    try self.diagnostics.add(.@"error", "type.call.qualifier", self.span, "callable values must use ':: call'", .{});
                }

                return self.makeExpr(shallowTypeRefFromName(value.output_type_name), .{ .call = .{
                    .callee = callee_name,
                    .args = try args.toOwnedSlice(),
                } });
            } else {
                if (self.scope.get(callee_name) == null) {
                    try self.diagnostics.add(.@"error", "type.call.unknown", self.span, "unknown function '{s}'", .{callee_name});
                }
                return self.makeExpr(.unsupported, .{ .call = .{
                    .callee = callee_name,
                    .args = try args.toOwnedSlice(),
                } });
            }
        }

        fn parseFieldProjection(self: *@This(), base_expr: *Expr) anyerror!*Expr {
            _ = self.advance();
            const field_token = self.advance();
            if (field_token.kind == .integer) {
                base_expr.deinit(self.allocator);
                self.allocator.destroy(base_expr);
                try self.diagnostics.add(.@"error", "type.expr.tuple_projection.stage0", self.span, "stage0 does not yet implement tuple projection", .{});
                return makeUnsupportedExpr(self.allocator);
            }
            if (field_token.kind != .identifier) {
                base_expr.deinit(self.allocator);
                self.allocator.destroy(base_expr);
                try self.diagnostics.add(.@"error", "type.field.syntax", self.span, "field projection requires a field name after '.'", .{});
                return makeUnsupportedExpr(self.allocator);
            }

            switch (base_expr.node) {
                .identifier => |base_name| {
                    if (findEnumPrototype(self.enum_prototypes, base_name)) |prototype| {
                        const variant = findEnumVariant(prototype, field_token.lexeme) orelse {
                            if (!self.expected_type.isUnsupported()) {
                                return self.makeExpr(self.expected_type, .{ .field = .{
                                    .base = base_expr,
                                    .field_name = field_token.lexeme,
                                } });
                            }
                            base_expr.deinit(self.allocator);
                            self.allocator.destroy(base_expr);
                            try self.diagnostics.add(.@"error", "type.enum.variant_unknown", self.span, "unknown variant '{s}' on enum '{s}'", .{
                                field_token.lexeme,
                                prototype.name,
                            });
                            return self.makeExpr(.unsupported, .{ .identifier = field_token.lexeme });
                        };

                        switch (variant.payload) {
                            .none => {
                                base_expr.deinit(self.allocator);
                                self.allocator.destroy(base_expr);
                                return self.makeExpr(.{ .named = prototype.name }, .{ .enum_variant = .{
                                    .enum_name = prototype.name,
                                    .enum_symbol = prototype.symbol_name,
                                    .variant_name = variant.name,
                                } });
                            },
                            else => {
                                if (self.peek().kind != .colon_colon) {
                                    base_expr.deinit(self.allocator);
                                    self.allocator.destroy(base_expr);
                                    try self.diagnostics.add(.@"error", "type.enum.variant_payload.invoke", self.span, "payload enum variants require immediate constructor invocation with ':: call'", .{});
                                    return self.makeExpr(.unsupported, .{ .identifier = field_token.lexeme });
                                }
                                base_expr.deinit(self.allocator);
                                self.allocator.destroy(base_expr);
                                return self.makeExpr(.unsupported, .{ .enum_constructor_target = .{
                                    .enum_name = prototype.name,
                                    .enum_symbol = prototype.symbol_name,
                                    .variant_name = variant.name,
                                } });
                            },
                        }
                    }
                    if (findStructPrototype(self.struct_prototypes, base_name) != null) {
                        return self.makeExpr(self.expected_type, .{ .field = .{
                            .base = base_expr,
                            .field_name = field_token.lexeme,
                        } });
                    }
                },
                else => {},
            }

            const target_type_name = switch (base_expr.ty) {
                .named => |name| parseBoundaryType(name).inner_type_name,
                else => blk: {
                    try self.diagnostics.add(.@"error", "type.field.base", self.span, "field projection requires a struct-typed base expression", .{});
                    break :blk "";
                },
            };
            const struct_name = baseTypeName(target_type_name);

            if (findStructPrototype(self.struct_prototypes, struct_name)) |prototype| {
                for (prototype.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_token.lexeme)) {
                        return self.makeExpr(field.ty, .{ .field = .{
                            .base = base_expr,
                            .field_name = field.name,
                        } });
                    }
                }
                if (self.peek().kind == .colon_colon) {
                    return self.makeExpr(.unsupported, .{ .method_target = .{
                        .base = base_expr,
                        .target_type = target_type_name,
                        .method_name = field_token.lexeme,
                    } });
                }
                try self.diagnostics.add(.@"error", "type.field.unknown", self.span, "unknown field '{s}' on struct '{s}'", .{
                    field_token.lexeme,
                    struct_name,
                });
                return self.makeExpr(.unsupported, .{ .field = .{
                    .base = base_expr,
                    .field_name = field_token.lexeme,
                } });
            }

            if (self.peek().kind == .colon_colon) {
                return self.makeExpr(.unsupported, .{ .method_target = .{
                    .base = base_expr,
                    .target_type = target_type_name,
                    .method_name = field_token.lexeme,
                } });
            }

            try self.diagnostics.add(.@"error", "type.field.struct_unsupported", self.span, "stage0 field projection supports only locally declared struct types", .{});
            return self.makeExpr(.unsupported, .{ .field = .{
                .base = base_expr,
                .field_name = field_token.lexeme,
            } });
        }

        fn parseKeyedAccess(self: *@This(), base_expr: *Expr) anyerror!*Expr {
            _ = self.advance();
            const previous_expected = self.expected_type;
            self.expected_type = types.TypeRef.fromBuiltin(.index);
            const index_expr = try self.parseConversion();
            self.expected_type = previous_expected;
            if (self.peek().kind == .r_bracket) {
                _ = self.advance();
            } else {
                try self.diagnostics.add(.@"error", "parse.expr.keyed_access", self.span, "unterminated keyed access expression", .{});
            }
            if (!index_expr.ty.eql(types.TypeRef.fromBuiltin(.index)) and !index_expr.ty.isUnsupported()) {
                try self.diagnostics.add(.@"error", "type.expr.keyed_access.index", self.span, "keyed access requires an Index expression", .{});
            }
            const element_type = fixedArrayElementType(base_expr.ty) orelse blk: {
                if (!base_expr.ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.keyed_access.base", self.span, "keyed access requires a fixed array expression", .{});
                }
                break :blk types.TypeRef.unsupported;
            };
            return self.makeExpr(element_type, .{ .index = .{
                .base = base_expr,
                .index = index_expr,
            } });
        }

        fn parseTupleExpression(self: *@This()) anyerror!*Expr {
            try self.skipDelimitedTokens(.l_paren, .r_paren, "parse.expr.tuple", "unterminated tuple expression");
            try self.diagnostics.add(.@"error", "type.expr.tuple.stage0", self.span, "stage0 does not yet implement tuple expressions", .{});
            return makeUnsupportedExpr(self.allocator);
        }

        fn parseArrayLiteral(self: *@This()) anyerror!*Expr {
            const array_type = self.expected_type;
            const element_type = fixedArrayElementType(array_type) orelse types.TypeRef.unsupported;
            if (self.peek().kind == .r_bracket) {
                _ = self.advance();
                if (element_type.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.array.type", self.span, "array literal requires a fixed array contextual type", .{});
                }
                const items = try self.allocator.alloc(*Expr, 0);
                return self.makeExpr(if (element_type.isUnsupported()) .unsupported else array_type, .{ .array = .{ .items = items } });
            }

            const previous_expected = self.expected_type;
            self.expected_type = element_type;
            const first = try self.parseConversion();
            self.expected_type = previous_expected;
            if (self.peek().kind == .semicolon) {
                _ = self.advance();
                self.expected_type = types.TypeRef.fromBuiltin(.index);
                const length = try self.parseConversion();
                self.expected_type = previous_expected;
                if (self.peek().kind == .r_bracket) {
                    _ = self.advance();
                } else {
                    try self.diagnostics.add(.@"error", "parse.expr.array", self.span, "unterminated array literal", .{});
                }
                const result_type = if (element_type.isUnsupported()) types.TypeRef.unsupported else array_type;
                if (result_type.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.array.type", self.span, "array repetition requires a fixed array contextual type", .{});
                }
                return self.makeExpr(result_type, .{ .array_repeat = .{
                    .value = first,
                    .length = length,
                } });
            }

            var items = array_list.Managed(*Expr).init(self.allocator);
            defer items.deinit();
            try items.append(first);

            while (self.peek().kind == .comma) {
                _ = self.advance();
                if (self.peek().kind == .r_bracket) break;
                self.expected_type = element_type;
                const item = try self.parseConversion();
                self.expected_type = previous_expected;
                try items.append(item);
            }
            if (self.peek().kind == .r_bracket) {
                _ = self.advance();
            } else {
                try self.diagnostics.add(.@"error", "parse.expr.array", self.span, "unterminated array literal", .{});
            }
            const result_type = if (element_type.isUnsupported()) types.TypeRef.unsupported else array_type;
            if (result_type.isUnsupported()) {
                try self.diagnostics.add(.@"error", "type.expr.array.type", self.span, "array literal requires a fixed array contextual type", .{});
            }
            return self.makeExpr(result_type, .{ .array = .{ .items = try items.toOwnedSlice() } });
        }

        fn parenSequenceHasTopLevelComma(self: *const @This()) bool {
            var paren_depth: usize = 0;
            var bracket_depth: usize = 0;
            var scan = self.index;
            while (scan < self.tokens.len) : (scan += 1) {
                switch (self.tokens[scan].kind) {
                    .l_paren => paren_depth += 1,
                    .r_paren => {
                        if (paren_depth == 0 and bracket_depth == 0) return false;
                        if (paren_depth > 0) paren_depth -= 1;
                    },
                    .l_bracket => bracket_depth += 1,
                    .r_bracket => {
                        if (bracket_depth > 0) bracket_depth -= 1;
                    },
                    .comma => {
                        if (paren_depth == 0 and bracket_depth == 0) return true;
                    },
                    .eof => return false,
                    else => {},
                }
            }
            return false;
        }

        fn skipDelimitedTokens(
            self: *@This(),
            comptime open_kind: ExprTokenKind,
            comptime close_kind: ExprTokenKind,
            syntax_code: []const u8,
            comptime syntax_message: []const u8,
        ) anyerror!void {
            var depth: usize = 1;
            while (depth > 0) {
                const token = self.peek();
                if (token.kind == .eof) {
                    try self.diagnostics.add(.@"error", syntax_code, self.span, syntax_message, .{});
                    return;
                }
                _ = self.advance();
                switch (token.kind) {
                    open_kind => depth += 1,
                    close_kind => depth -= 1,
                    else => {},
                }
            }
        }

        fn makeBinary(self: *@This(), op: BinaryOp, lhs: *Expr, rhs: *Expr, ty: types.TypeRef) anyerror!*Expr {
            return self.makeExpr(ty, .{ .binary = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }

        fn parseInvocationArg(self: *@This()) anyerror!*Expr {
            const start = self.index;
            var end = start;
            var paren_depth: usize = 0;
            var bracket_depth: usize = 0;
            while (end < self.tokens.len) : (end += 1) {
                const token = self.tokens[end];
                switch (token.kind) {
                    .l_paren => paren_depth += 1,
                    .r_paren => {
                        if (paren_depth > 0) paren_depth -= 1;
                    },
                    .l_bracket => bracket_depth += 1,
                    .r_bracket => {
                        if (bracket_depth > 0) bracket_depth -= 1;
                    },
                    .comma => if (paren_depth == 0 and bracket_depth == 0) break,
                    .colon_colon => if (paren_depth == 0 and bracket_depth == 0 and end + 1 < self.tokens.len and self.tokens[end + 1].kind == .identifier and (std.mem.eql(u8, self.tokens[end + 1].lexeme, "call") or std.mem.eql(u8, self.tokens[end + 1].lexeme, "method"))) break,
                    .eof => break,
                    else => {},
                }
            }

            const sub_token_count = end - start + 1;
            var sub_tokens = try self.allocator.alloc(ExprToken, sub_token_count);
            defer self.allocator.free(sub_tokens);
            if (end > start) @memcpy(sub_tokens[0 .. end - start], self.tokens[start..end]);
            sub_tokens[sub_token_count - 1] = .{ .kind = .eof, .lexeme = "" };

            var sub_parser = @This(){
                .allocator = self.allocator,
                .diagnostics = self.diagnostics,
                .scope = self.scope,
                .current_where_predicates = self.current_where_predicates,
                .prototypes = self.prototypes,
                .method_prototypes = self.method_prototypes,
                .struct_prototypes = self.struct_prototypes,
                .enum_prototypes = self.enum_prototypes,
                .span = self.span,
                .tokens = sub_tokens,
                .expected_type = .unsupported,
                .suspend_context = self.suspend_context,
                .unsafe_context = self.unsafe_context,
            };
            self.index = end;
            return sub_parser.parse();
        }

        fn finalizeBareFunctionValue(self: *@This(), expr: *Expr) anyerror!*Expr {
            const name = switch (expr.node) {
                .identifier => |value| value,
                else => return expr,
            };
            if (self.scope.get(name) != null) return expr;

            const prototype = findPrototype(self.prototypes, name) orelse return expr;
            if (prototype.generic_params.len != 0) {
                return expr;
            }
            if (!usesOwnedPackedCallableInput(prototype.parameter_modes)) {
                return expr;
            }
            const input_type_name = try makeCallableInputTypeName(self.allocator, prototype.parameter_type_names);
            defer self.allocator.free(input_type_name);
            const callable_type_name = try makeCallableTypeName(
                self.allocator,
                prototype.is_suspend,
                input_type_name,
                prototype.return_type.displayName(),
            );
            expr.owned_type_name = @constCast(callable_type_name);
            expr.ty = .{ .named = callable_type_name };
            return expr;
        }

        fn makeExpr(self: *@This(), ty: types.TypeRef, node: Expr.Node) anyerror!*Expr {
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .ty = ty,
                .node = node,
            };
            return expr;
        }

        fn peek(self: *const @This()) ExprToken {
            return self.tokens[self.index];
        }

        fn advance(self: *@This()) ExprToken {
            const token = self.tokens[self.index];
            if (self.index + 1 < self.tokens.len) self.index += 1;
            return token;
        }

        fn peekIsIdentifier(self: *const @This(), expected: []const u8) bool {
            const token = self.peek();
            return token.kind == .identifier and std.mem.eql(u8, token.lexeme, expected);
        }
    };
}

fn makeEnumVariantExpr(allocator: Allocator, prototype: anytype, variant_name: []const u8) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = .{ .named = prototype.name },
        .node = .{ .enum_variant = .{
            .enum_name = prototype.name,
            .enum_symbol = prototype.symbol_name,
            .variant_name = variant_name,
        } },
    };
    return expr;
}

fn makeUnsupportedExpr(allocator: Allocator) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = .unsupported,
        .node = .{ .identifier = "" },
    };
    return expr;
}

fn isComparisonExpr(expr: *const Expr) bool {
    return switch (expr.node) {
        .binary => |binary| switch (binary.op) {
            .eq, .ne, .lt, .lte, .gt, .gte => true,
            else => false,
        },
        else => false,
    };
}

fn usesOwnedPackedCallableInput(parameter_modes: []const ParameterMode) bool {
    for (parameter_modes) |mode| {
        if (mode != .owned and mode != .take) return false;
    }
    return true;
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

const ExprTokenKind = enum {
    identifier,
    integer,
    string,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    dot,
    plus,
    minus,
    star,
    slash,
    percent,
    tilde,
    amp,
    pipe,
    caret,
    eq_eq,
    bang_eq,
    bang,
    lt,
    lte,
    gt,
    gte,
    lt_lt,
    gt_gt,
    amp_amp,
    pipe_pipe,
    colon_colon,
    eof,
};

const ExprToken = struct {
    kind: ExprTokenKind,
    lexeme: []const u8,
};

pub fn parseExpressionText(
    allocator: Allocator,
    text: []const u8,
    expected_type: types.TypeRef,
    scope: anytype,
    current_where_predicates: []const WherePredicate,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!*Expr {
    var tokens = array_list.Managed(ExprToken).init(allocator);
    defer tokens.deinit();
    try appendRawExprTokens(&tokens, text);
    try tokens.append(.{ .kind = .eof, .lexeme = "" });

    const Parser = ExprParser(
        @TypeOf(scope),
        @TypeOf(prototypes),
        @TypeOf(method_prototypes),
        @TypeOf(struct_prototypes),
        @TypeOf(enum_prototypes),
    );
    var parser = Parser{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .scope = scope,
        .current_where_predicates = current_where_predicates,
        .prototypes = prototypes,
        .method_prototypes = method_prototypes,
        .struct_prototypes = struct_prototypes,
        .enum_prototypes = enum_prototypes,
        .span = span,
        .tokens = tokens.items,
        .expected_type = expected_type,
        .suspend_context = suspend_context,
        .unsafe_context = unsafe_context,
    };
    return parser.parse();
}

pub fn parseExpressionSyntax(
    allocator: Allocator,
    syntax_expr: *const ast.BodyExprSyntax,
    expected_type: types.TypeRef,
    scope: anytype,
    current_where_predicates: []const WherePredicate,
    prototypes: anytype,
    method_prototypes: anytype,
    struct_prototypes: anytype,
    enum_prototypes: anytype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!*Expr {
    if (syntaxExprHasError(syntax_expr)) {
        try diagnostics.add(.@"error", "type.expr.syntax", span, "malformed expression syntax in stage0", .{});
        return makeUnsupportedExpr(allocator);
    }

    var tokens = array_list.Managed(ExprToken).init(allocator);
    defer tokens.deinit();
    try appendExprTokens(&tokens, syntax_expr);
    try tokens.append(.{ .kind = .eof, .lexeme = "" });

    const Parser = ExprParser(
        @TypeOf(scope),
        @TypeOf(prototypes),
        @TypeOf(method_prototypes),
        @TypeOf(struct_prototypes),
        @TypeOf(enum_prototypes),
    );
    var parser = Parser{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .scope = scope,
        .current_where_predicates = current_where_predicates,
        .prototypes = prototypes,
        .method_prototypes = method_prototypes,
        .struct_prototypes = struct_prototypes,
        .enum_prototypes = enum_prototypes,
        .span = syntax_expr.span,
        .tokens = tokens.items,
        .expected_type = expected_type,
        .suspend_context = suspend_context,
        .unsafe_context = unsafe_context or syntax_expr.force_unsafe,
    };
    return parser.parse();
}

fn syntaxExprHasError(expr: *const ast.BodyExprSyntax) bool {
    return switch (expr.node) {
        .@"error" => true,
        .name, .integer, .string => false,
        .group => |group| syntaxExprHasError(group),
        .tuple => |items| exprSliceHasError(items),
        .array => |items| exprSliceHasError(items),
        .array_repeat => |array_repeat| syntaxExprHasError(array_repeat.value) or syntaxExprHasError(array_repeat.length),
        .unary => |unary| syntaxExprHasError(unary.operand),
        .binary => |binary| syntaxExprHasError(binary.lhs) or syntaxExprHasError(binary.rhs),
        .field => |field| syntaxExprHasError(field.base),
        .index => |index| syntaxExprHasError(index.base) or syntaxExprHasError(index.index),
        .call => |call| syntaxExprHasError(call.callee) or exprSliceHasError(call.args),
        .method_call => |call| syntaxExprHasError(call.callee) or exprSliceHasError(call.args),
    };
}

fn exprSliceHasError(items: []const *ast.BodyExprSyntax) bool {
    for (items) |item| {
        if (syntaxExprHasError(item)) return true;
    }
    return false;
}

fn appendExprTokens(tokens: *array_list.Managed(ExprToken), expr: *const ast.BodyExprSyntax) anyerror!void {
    switch (expr.node) {
        .@"error" => return,
        .name => |value| try tokens.append(.{ .kind = .identifier, .lexeme = value.text }),
        .integer => |value| try tokens.append(.{ .kind = .integer, .lexeme = value.text }),
        .string => |value| try tokens.append(.{ .kind = .string, .lexeme = stringTokenLexeme(value.text) }),
        .group => |group| {
            try tokens.append(.{ .kind = .l_paren, .lexeme = "(" });
            try appendExprTokens(tokens, group);
            try tokens.append(.{ .kind = .r_paren, .lexeme = ")" });
        },
        .tuple => |items| {
            try tokens.append(.{ .kind = .l_paren, .lexeme = "(" });
            for (items, 0..) |item, index| {
                if (index != 0) try tokens.append(.{ .kind = .comma, .lexeme = "," });
                try appendExprTokens(tokens, item);
            }
            if (items.len == 1) try tokens.append(.{ .kind = .comma, .lexeme = "," });
            try tokens.append(.{ .kind = .r_paren, .lexeme = ")" });
        },
        .array => |items| {
            try tokens.append(.{ .kind = .l_bracket, .lexeme = "[" });
            for (items, 0..) |item, index| {
                if (index != 0) try tokens.append(.{ .kind = .comma, .lexeme = "," });
                try appendExprTokens(tokens, item);
            }
            try tokens.append(.{ .kind = .r_bracket, .lexeme = "]" });
        },
        .array_repeat => |array_repeat| {
            try tokens.append(.{ .kind = .l_bracket, .lexeme = "[" });
            try appendExprTokens(tokens, array_repeat.value);
            try tokens.append(.{ .kind = .semicolon, .lexeme = ";" });
            try appendExprTokens(tokens, array_repeat.length);
            try tokens.append(.{ .kind = .r_bracket, .lexeme = "]" });
        },
        .unary => |unary| {
            try tokens.append(.{
                .kind = unaryOperatorTokenKind(unary.operator.text),
                .lexeme = unary.operator.text,
            });
            try appendExprTokens(tokens, unary.operand);
        },
        .binary => |binary| {
            try appendExprTokens(tokens, binary.lhs);
            try tokens.append(.{
                .kind = binaryOperatorTokenKind(binary.operator.text),
                .lexeme = binary.operator.text,
            });
            try appendExprTokens(tokens, binary.rhs);
        },
        .field => |field| {
            try appendExprTokens(tokens, field.base);
            try tokens.append(.{ .kind = .dot, .lexeme = "." });
            try tokens.append(.{
                .kind = fieldTokenKind(field.field_name.text),
                .lexeme = field.field_name.text,
            });
        },
        .index => |index| {
            try appendExprTokens(tokens, index.base);
            try tokens.append(.{ .kind = .l_bracket, .lexeme = "[" });
            try appendExprTokens(tokens, index.index);
            try tokens.append(.{ .kind = .r_bracket, .lexeme = "]" });
        },
        .call => |call| {
            try appendExprTokens(tokens, call.callee);
            try appendPhraseInvocation(tokens, call.args, "call");
        },
        .method_call => |call| {
            try appendExprTokens(tokens, call.callee);
            try appendPhraseInvocation(tokens, call.args, "method");
        },
    }
}

fn appendPhraseInvocation(
    tokens: *array_list.Managed(ExprToken),
    args: []const *ast.BodyExprSyntax,
    qualifier: []const u8,
) anyerror!void {
    try tokens.append(.{ .kind = .colon_colon, .lexeme = "::" });
    for (args, 0..) |arg, index| {
        if (index != 0) try tokens.append(.{ .kind = .comma, .lexeme = "," });
        try appendExprTokens(tokens, arg);
    }
    try tokens.append(.{ .kind = .colon_colon, .lexeme = "::" });
    try tokens.append(.{ .kind = .identifier, .lexeme = qualifier });
}

fn stringTokenLexeme(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

fn unaryOperatorTokenKind(raw: []const u8) ExprTokenKind {
    if (std.mem.eql(u8, raw, "!")) return .bang;
    if (std.mem.eql(u8, raw, "-")) return .minus;
    if (std.mem.eql(u8, raw, "~")) return .tilde;
    return .identifier;
}

fn binaryOperatorTokenKind(raw: []const u8) ExprTokenKind {
    if (std.mem.eql(u8, raw, "+")) return .plus;
    if (std.mem.eql(u8, raw, "-")) return .minus;
    if (std.mem.eql(u8, raw, "*")) return .star;
    if (std.mem.eql(u8, raw, "/")) return .slash;
    if (std.mem.eql(u8, raw, "%")) return .percent;
    if (std.mem.eql(u8, raw, "<<")) return .lt_lt;
    if (std.mem.eql(u8, raw, ">>")) return .gt_gt;
    if (std.mem.eql(u8, raw, "<")) return .lt;
    if (std.mem.eql(u8, raw, "<=")) return .lte;
    if (std.mem.eql(u8, raw, ">")) return .gt;
    if (std.mem.eql(u8, raw, ">=")) return .gte;
    if (std.mem.eql(u8, raw, "==")) return .eq_eq;
    if (std.mem.eql(u8, raw, "!=")) return .bang_eq;
    if (std.mem.eql(u8, raw, "&")) return .amp;
    if (std.mem.eql(u8, raw, "^")) return .caret;
    if (std.mem.eql(u8, raw, "|")) return .pipe;
    if (std.mem.eql(u8, raw, "&&")) return .amp_amp;
    if (std.mem.eql(u8, raw, "||")) return .pipe_pipe;
    return .identifier;
}

fn fieldTokenKind(raw: []const u8) ExprTokenKind {
    if (raw.len != 0 and raw[0] >= '0' and raw[0] <= '9') return .integer;
    return .identifier;
}

fn appendRawExprTokens(tokens: *array_list.Managed(ExprToken), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (std.ascii.isWhitespace(byte)) {
            index += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(byte) or byte == '_') {
            const start = index;
            index += 1;
            while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_' or text[index] == '\'')) : (index += 1) {}
            try tokens.append(.{ .kind = .identifier, .lexeme = text[start..index] });
            continue;
        }
        if (std.ascii.isDigit(byte)) {
            const start = index;
            index += 1;
            while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_')) : (index += 1) {}
            try tokens.append(.{ .kind = .integer, .lexeme = text[start..index] });
            continue;
        }
        if (byte == '"') {
            const start = index + 1;
            index += 1;
            while (index < text.len and text[index] != '"') : (index += 1) {
                if (text[index] == '\\' and index + 1 < text.len) index += 1;
            }
            const end = index;
            if (index < text.len) index += 1;
            try tokens.append(.{ .kind = .string, .lexeme = text[start..end] });
            continue;
        }

        if (index + 1 < text.len) {
            const two = text[index .. index + 2];
            const kind: ?ExprTokenKind = if (std.mem.eql(u8, two, "=="))
                .eq_eq
            else if (std.mem.eql(u8, two, "!="))
                .bang_eq
            else if (std.mem.eql(u8, two, "<="))
                .lte
            else if (std.mem.eql(u8, two, ">="))
                .gte
            else if (std.mem.eql(u8, two, "<<"))
                .lt_lt
            else if (std.mem.eql(u8, two, ">>"))
                .gt_gt
            else if (std.mem.eql(u8, two, "&&"))
                .amp_amp
            else if (std.mem.eql(u8, two, "||"))
                .pipe_pipe
            else if (std.mem.eql(u8, two, "::"))
                .colon_colon
            else
                null;
            if (kind) |token_kind| {
                try tokens.append(.{ .kind = token_kind, .lexeme = two });
                index += 2;
                continue;
            }
        }

        const kind: ExprTokenKind = switch (byte) {
            '(' => .l_paren,
            ')' => .r_paren,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ',' => .comma,
            ';' => .semicolon,
            '.' => .dot,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '~' => .tilde,
            '&' => .amp,
            '|' => .pipe,
            '^' => .caret,
            '!' => .bang,
            '<' => .lt,
            '>' => .gt,
            else => .identifier,
        };
        try tokens.append(.{ .kind = kind, .lexeme = text[index .. index + 1] });
        index += 1;
    }
}
