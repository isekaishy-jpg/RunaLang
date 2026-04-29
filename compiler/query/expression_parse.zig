const std = @import("std");
const array_list = std.array_list;
const c_va_list = @import("../abi/c/va_list.zig");
const ast = @import("../ast/root.zig");
const callable_types = @import("callable_types.zig");
const dynamic_library = @import("../runtime/dynamic_library/root.zig");
const foreign_callable_types = @import("foreign_callable_types.zig");
const raw_pointer = @import("../raw_pointer/root.zig");
const typed_decls = @import("../typed/declarations.zig");
const typed_expr = @import("../typed/expr.zig");
const signatures = @import("signatures.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const standard_families = @import("standard_families.zig");
const typed_text = @import("text.zig");
const type_support = @import("type_support.zig");
const tuple_types = @import("tuple_types.zig");
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
const cVariadicArgumentTypeSupported = type_support.cVariadicArgumentTypeSupported;
const cVariadicCallArityValid = type_support.cVariadicCallArityValid;
const cVariadicFixedParameterCount = type_support.cVariadicFixedParameterCount;
const cVariadicTailIndex = type_support.cVariadicTailIndex;
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
        .index => |index| switch (index.base.node) {
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
            else => try self.diagnostics.add(.@"error", "type.call.borrow_arg", self.span, "borrow argument {d} to '{s}' must be a plain local, field, or array element place in stage0", .{
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

fn validateDirectCallArguments(
    self: anytype,
    callee_name: []const u8,
    args: []const *Expr,
    parameter_types: []const types.TypeRef,
    parameter_type_names: []const []const u8,
    parameter_modes: []const ParameterMode,
    generic_params: []const GenericParam,
    where_predicates: []const WherePredicate,
) !void {
    if (!cVariadicCallArityValid(args.len, parameter_types.len, parameter_type_names)) {
        try self.diagnostics.add(.@"error", "type.call.arity", self.span, "call to '{s}' has wrong arity", .{callee_name});
        return;
    }

    const fixed_count = cVariadicFixedParameterCount(parameter_types.len, parameter_type_names);
    for (args[0..@min(args.len, fixed_count)], 0..) |arg, index| {
        const expected = parameter_types[index];
        const expected_type_name = if (index < parameter_type_names.len) parameter_type_names[index] else expected.displayName();
        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
            !callArgumentTypeCompatible(arg.ty, expected, expected_type_name, generic_params, false))
        {
            try self.diagnostics.add(.@"error", "type.call.arg", self.span, "call to '{s}' argument {d} has wrong type", .{
                callee_name,
                index + 1,
            });
        }
    }

    if (cVariadicTailIndex(parameter_type_names) != null) {
        for (args[fixed_count..], fixed_count..) |arg, index| {
            if (!arg.ty.isUnsupported() and !cVariadicArgumentTypeSupported(arg.ty)) {
                try self.diagnostics.add(.@"error", "abi.c.variadic.arg", self.span, "variadic argument {d} to '{s}' is not C ABI-safe", .{
                    index + 1,
                    callee_name,
                });
            }
        }
    }

    try validateBorrowArguments(self, parameter_modes, args, callee_name);
    try validateRetainedCallArguments(
        self,
        parameter_type_names,
        generic_params,
        where_predicates,
        args,
        callee_name,
    );
}

fn foreignCallablePrototypeCompatible(syntax: foreign_callable_types.Syntax, prototype: anytype) bool {
    if (syntax.variadic_tail != null) return false;
    if (syntax.parameters.len != prototype.parameter_type_names.len) return false;
    for (prototype.parameter_modes) |mode| {
        if (mode != .owned and mode != .take) return false;
    }
    for (syntax.parameters, prototype.parameter_type_names) |expected, actual| {
        if (!std.mem.eql(u8, std.mem.trim(u8, expected, " \t\r\n"), std.mem.trim(u8, actual, " \t\r\n"))) return false;
    }
    return std.mem.eql(u8, std.mem.trim(u8, syntax.return_type, " \t\r\n"), prototype.return_type.displayName());
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
                const previous_expected = self.expected_type;
                if (expr.ty == .named and raw_pointer.parse(expr.ty.named) != null) self.expected_type = expr.ty;
                const rhs = try self.parseOrdering();
                self.expected_type = previous_expected;
                const comparison_chain = isComparisonExpr(expr);
                if (comparison_chain) {
                    try self.diagnostics.add(.@"error", "type.expr.compare_chain", self.span, "comparison chaining requires explicit grouping", .{});
                }
                const lhs_ty = expr.ty;
                const rhs_ty = rhs.ty;
                if (!comparison_chain and !typesEqualityComparable(lhs_ty, rhs_ty) and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
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
                if (!comparison_chain and (typeIsRawPointer(lhs_ty) or typeIsRawPointer(rhs_ty))) {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.ordering", self.span, "raw pointers support equality but not ordering", .{});
                } else if (!comparison_chain and !typesOrderingComparable(lhs_ty, rhs_ty) and !lhs_ty.isUnsupported() and !rhs_ty.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.compare", self.span, "comparison operands must be in a builtin ordered domain", .{});
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
                .amp => self.parseRawPointerFormation(),
                else => self.parsePostfix(),
            };
        }

        fn parseRawPointerFormation(self: *@This()) anyerror!*Expr {
            _ = self.advance();
            const raw_token = self.advance();
            const mode_token = self.advance();
            if (raw_token.kind != .identifier or !std.mem.eql(u8, raw_token.lexeme, "raw") or
                mode_token.kind != .identifier or
                (!std.mem.eql(u8, mode_token.lexeme, "read") and !std.mem.eql(u8, mode_token.lexeme, "edit")))
            {
                try self.diagnostics.add(.@"error", "type.raw_pointer.formation.syntax", self.span, "raw pointer formation requires '&raw read place' or '&raw edit place'", .{});
                return makeUnsupportedExpr(self.allocator);
            }
            if (!self.unsafe_context) {
                try self.diagnostics.add(.@"error", "type.raw_pointer.formation.unsafe", self.span, "raw pointer formation requires #unsafe", .{});
            }

            const place = try self.parsePostfix();
            if (!isAddressablePlace(place)) {
                try self.diagnostics.add(.@"error", "type.raw_pointer.formation.place", self.span, "raw pointer formation requires an addressable local or field place", .{});
            }
            const pointee_name = type_support.typeRefRawName(place.ty);
            const access = if (std.mem.eql(u8, mode_token.lexeme, "read")) raw_pointer.Access.read else .edit;
            const type_name = try raw_pointer.makeTypeName(self.allocator, access, pointee_name);
            const callee = if (access == .read) raw_pointer.address_read_callee else raw_pointer.address_edit_callee;
            const args = try self.allocator.alloc(*Expr, 1);
            args[0] = place;
            const expr = try self.makeExpr(.{ .named = type_name }, .{ .call = .{
                .callee = callee,
                .args = args,
            } });
            expr.owned_type_name = @constCast(type_name);
            return expr;
        }

        fn parsePrimary(self: *@This()) anyerror!*Expr {
            const token = self.advance();
            switch (token.kind) {
                .integer => {
                    const value = std.fmt.parseInt(i64, token.lexeme, 10) catch 0;
                    const integer_type = contextualIntegerLiteralType(self.expected_type);
                    return self.makeExpr(integer_type, .{ .integer = value });
                },
                .string => return self.makeExpr(types.TypeRef.fromBuiltin(.str), .{ .string = token.lexeme }),
                .identifier => {
                    if (std.mem.eql(u8, token.lexeme, "true")) return self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .bool_lit = true });
                    if (std.mem.eql(u8, token.lexeme, "false")) return self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .bool_lit = false });
                    if (std.mem.eql(u8, token.lexeme, "null")) {
                        if (self.expected_type == .named and raw_pointer.parse(self.expected_type.named) != null) {
                            return self.makeExpr(self.expected_type, .{ .identifier = "NULL" });
                        }
                        try self.diagnostics.add(.@"error", "type.raw_pointer.null", self.span, "null is valid only where a raw pointer type is expected", .{});
                        return makeUnsupportedExpr(self.allocator);
                    }
                    if (std.mem.eql(u8, token.lexeme, "await")) {
                        try self.diagnostics.add(.@"error", "type.await.standalone", self.span, "standalone await expressions are not part of v1; use the Task.await method surface", .{});
                        return makeUnsupportedExpr(self.allocator);
                    }

                    const value_type = self.scope.get(token.lexeme) orelse .unsupported;
                    if (value_type.isUnsupported() and
                        !dynamic_library.isPublicCallee(token.lexeme) and
                        standard_families.familyFromName(token.lexeme) == null and
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
            var foreign_callable = switch (callee_expr.ty) {
                .named => |type_name| try foreign_callable_types.parseSyntax(self.allocator, type_name),
                else => null,
            };
            defer if (foreign_callable) |*syntax| syntax.deinit(self.allocator);

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
                if (qualifier.kind == .identifier and std.mem.eql(u8, qualifier.lexeme, "await")) {
                    try self.diagnostics.add(.@"error", "type.await.qualifier", self.span, "await is not an invocation qualifier; use the Task.await method surface", .{});
                } else {
                    try self.diagnostics.add(.@"error", "type.call.qualifier", self.span, "stage0 supports only ':: call' and ':: method' invocation qualifiers", .{});
                }
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

                if (try self.parseStandardFamilyMethodInvocation(callee_expr, target, args.items)) |expr| return expr;
                if (try self.parseCVaListMethodInvocation(callee_expr, target, args.items)) |expr| return expr;
                if (try self.parseRawPointerMethodInvocation(callee_expr, target, args.items)) |expr| return expr;

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
                if (try self.parseStandardEnumConstructorInvocation(target, args.items)) |expr| return expr;

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
            } else if (try self.parseDynamicLibraryInvocation(callee_name, args.items, is_call)) |expr| {
                return expr;
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
                try validateDirectCallArguments(
                    self,
                    callee_name,
                    args.items,
                    value.parameter_types,
                    value.parameter_type_names,
                    value.parameter_modes,
                    value.generic_params,
                    value.where_predicates,
                );
                return self.makeExpr(return_type, .{ .call = .{
                    .callee = callee_name,
                    .args = try args.toOwnedSlice(),
                } });
            } else if (foreign_callable) |syntax| {
                if (!is_call) {
                    try self.diagnostics.add(.@"error", "type.call.qualifier", self.span, "foreign function pointer values must use ':: call'", .{});
                }
                if (!self.unsafe_context) {
                    try self.diagnostics.add(.@"error", "abi.c.fnptr.unsafe", self.span, "calling a foreign function pointer requires #unsafe", .{});
                }
                if (syntax.variadic_tail != null) {
                    try self.diagnostics.add(.@"error", "abi.c.fnptr.variadic", self.span, "variadic foreign function pointer calls are not implemented in stage0", .{});
                }
                if (syntax.parameters.len != args.items.len) {
                    try self.diagnostics.add(.@"error", "abi.c.fnptr.arity", self.span, "foreign function pointer call has wrong arity", .{});
                } else {
                    for (args.items, syntax.parameters, 0..) |arg, expected_type_name, index| {
                        const expected = shallowTypeRefFromName(expected_type_name);
                        if (!arg.ty.isUnsupported() and !expected.isUnsupported() and
                            !callArgumentTypeCompatible(arg.ty, expected, expected_type_name, &.{}, false))
                        {
                            try self.diagnostics.add(.@"error", "abi.c.fnptr.arg", self.span, "foreign function pointer argument {d} has wrong type", .{index + 1});
                        }
                    }
                }

                return self.makeExpr(shallowTypeRefFromName(syntax.return_type), .{ .call = .{
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

        fn parseDynamicLibraryInvocation(
            self: *@This(),
            callee_name: []const u8,
            args: []const *Expr,
            is_call: bool,
        ) anyerror!?*Expr {
            if (!dynamic_library.isPublicCallee(callee_name)) return null;
            if (!is_call) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.qualifier", self.span, "dynamic-library operations must use ':: call'", .{});
            }

            if (std.mem.eql(u8, callee_name, dynamic_library.open_name)) {
                try self.validateDynamicOpenArgs(args);
                return self.makeExpr(.{ .named = dynamic_library.open_result_type_name }, .{ .call = .{
                    .callee = dynamic_library.open_callee,
                    .args = try self.cloneArgSlice(args),
                } });
            }
            if (std.mem.eql(u8, callee_name, dynamic_library.lookup_name)) {
                if (!self.unsafe_context) {
                    try self.diagnostics.add(.@"error", "runtime.dynamic.lookup.unsafe", self.span, "dynamic-library symbol lookup requires #unsafe", .{});
                }
                try self.validateDynamicLookupArgs(args);
                const result_type_name = try self.dynamicLookupResultTypeName();
                const expr = try self.makeExpr(.{ .named = result_type_name }, .{ .call = .{
                    .callee = dynamic_library.lookup_callee,
                    .args = try self.cloneArgSlice(args),
                } });
                expr.owned_type_name = @constCast(result_type_name);
                return expr;
            }
            if (std.mem.eql(u8, callee_name, dynamic_library.close_name)) {
                if (!self.unsafe_context) {
                    try self.diagnostics.add(.@"error", "runtime.dynamic.close.unsafe", self.span, "dynamic-library close requires #unsafe", .{});
                }
                try self.validateDynamicCloseArgs(args);
                return self.makeExpr(.{ .named = dynamic_library.close_result_type_name }, .{ .call = .{
                    .callee = dynamic_library.close_callee,
                    .args = try self.cloneArgSlice(args),
                } });
            }
            return null;
        }

        fn cloneArgSlice(self: *@This(), args: []const *Expr) ![]*Expr {
            const owned = try self.allocator.alloc(*Expr, args.len);
            for (args, 0..) |arg, index| owned[index] = arg;
            return owned;
        }

        fn validateDynamicOpenArgs(self: *@This(), args: []const *Expr) !void {
            if (args.len != 1) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.open.arity", self.span, "open_library expects exactly one path argument", .{});
                return;
            }
            if (!args[0].ty.isUnsupported() and !args[0].ty.eql(types.TypeRef.fromBuiltin(.str))) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.open.path", self.span, "open_library path must be Str", .{});
            }
        }

        fn validateDynamicLookupArgs(self: *@This(), args: []const *Expr) !void {
            if (args.len != 2) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.lookup.arity", self.span, "lookup_symbol expects a DynamicLibrary and symbol name", .{});
                return;
            }
            if (!args[0].ty.isUnsupported() and !args[0].ty.isNamed(dynamic_library.type_name)) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.lookup.library", self.span, "lookup_symbol first argument must be DynamicLibrary", .{});
            }
            if (!args[1].ty.isUnsupported() and !args[1].ty.eql(types.TypeRef.fromBuiltin(.str))) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.lookup.name", self.span, "lookup_symbol name must be Str", .{});
            }
        }

        fn validateDynamicCloseArgs(self: *@This(), args: []const *Expr) !void {
            if (args.len != 1) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.close.arity", self.span, "close_library expects exactly one DynamicLibrary argument", .{});
                return;
            }
            if (!args[0].ty.isUnsupported() and !args[0].ty.isNamed(dynamic_library.type_name)) {
                try self.diagnostics.add(.@"error", "runtime.dynamic.close.library", self.span, "close_library argument must be DynamicLibrary", .{});
            }
        }

        fn dynamicLookupResultTypeName(self: *@This()) ![]const u8 {
            switch (self.expected_type) {
                .named => |name| {
                    if (try dynamicLookupResultOkType(self.allocator, name)) |ok_type| {
                        return try std.fmt.allocPrint(self.allocator, "Result[{s}, {s}]", .{ ok_type, dynamic_library.lookup_error_type_name });
                    }
                },
                else => {},
            }
            try self.diagnostics.add(.@"error", "runtime.dynamic.lookup.type", self.span, "lookup_symbol requires contextual type Result[T, SymbolLookupError] where T is a foreign function pointer or raw pointer", .{});
            return try self.allocator.dupe(u8, "Result[Unsupported, SymbolLookupError]");
        }

        fn parseStandardFamilyMethodInvocation(
            self: *@This(),
            callee_expr: *Expr,
            target: Expr.MethodTarget,
            explicit_args: []const *Expr,
        ) anyerror!?*Expr {
            const variant_name = standard_families.helperVariant(target.target_type, target.method_name) orelse return null;
            if (explicit_args.len != 0) {
                try self.diagnostics.add(.@"error", "type.standard.helper_arity", self.span, "standard helper '{s}.{s}' does not take explicit arguments", .{
                    baseTypeName(target.target_type),
                    target.method_name,
                });
            }

            const tag_expr = try self.makeExpr(types.TypeRef.fromBuiltin(.i32), .{ .field = .{
                .base = target.base,
                .field_name = "tag",
            } });
            const variant_expr = try self.makeExpr(types.TypeRef.fromBuiltin(.i32), .{ .enum_tag = .{
                .enum_name = target.target_type,
                .enum_symbol = baseTypeName(target.target_type),
                .variant_name = variant_name,
            } });

            self.allocator.destroy(callee_expr);
            return self.makeExpr(types.TypeRef.fromBuiltin(.bool), .{ .binary = .{
                .op = .eq,
                .lhs = tag_expr,
                .rhs = variant_expr,
            } });
        }

        fn parseStandardEnumConstructorInvocation(
            self: *@This(),
            target: Expr.EnumVariantValue,
            args: []const *Expr,
        ) anyerror!?*Expr {
            const maybe_variant = try standard_families.variantForConcrete(self.allocator, target.enum_name, target.enum_symbol, target.variant_name);
            const variant = maybe_variant orelse return null;
            const payload_type_name = variant.payload_type_name orelse {
                if (args.len != 0) {
                    try self.diagnostics.add(.@"error", "type.enum.ctor.arity", self.span, "unit variant '{s}.{s}' does not take constructor args", .{
                        variant.family_name,
                        variant.variant_name,
                    });
                    return self.makeExpr(.{ .named = variant.concrete_type_name }, .{ .enum_construct = .{
                        .enum_name = variant.concrete_type_name,
                        .enum_symbol = variant.family_name,
                        .variant_name = variant.variant_name,
                        .args = try self.allocator.dupe(*Expr, args),
                    } });
                }
                return self.makeExpr(.{ .named = variant.concrete_type_name }, .{ .enum_variant = .{
                    .enum_name = variant.concrete_type_name,
                    .enum_symbol = variant.family_name,
                    .variant_name = variant.variant_name,
                } });
            };
            const expected = standard_families.typeRefFromName(payload_type_name);
            const unit_payload = expected.eql(types.TypeRef.fromBuiltin(.unit));
            const arity_ok = if (unit_payload) args.len == 0 or args.len == 1 else args.len == 1;
            if (!arity_ok) {
                try self.diagnostics.add(.@"error", "type.enum.ctor.arity", self.span, "constructor call to '{s}.{s}' has wrong arity", .{
                    variant.family_name,
                    variant.variant_name,
                });
            } else if (args.len == 1 and !args[0].ty.isUnsupported() and !expected.isUnsupported() and
                !callArgumentTypeCompatible(args[0].ty, expected, payload_type_name, &.{}, false))
            {
                try self.diagnostics.add(.@"error", "type.enum.ctor.arg", self.span, "constructor call to '{s}.{s}' argument 1 has wrong type", .{
                    variant.family_name,
                    variant.variant_name,
                });
            }
            return self.makeExpr(.{ .named = variant.concrete_type_name }, .{ .enum_construct = .{
                .enum_name = variant.concrete_type_name,
                .enum_symbol = variant.family_name,
                .variant_name = variant.variant_name,
                .args = try self.allocator.dupe(*Expr, args),
            } });
        }

        fn parseCVaListMethodInvocation(
            self: *@This(),
            callee_expr: *Expr,
            target: Expr.MethodTarget,
            explicit_args: []const *Expr,
        ) anyerror!?*Expr {
            if (!c_va_list.isTypeName(target.target_type)) return null;

            if (!self.unsafe_context) {
                try self.diagnostics.add(.@"error", "abi.c.valist.unsafe", self.span, "CVaList operations require #unsafe", .{});
            }
            if (explicit_args.len != 0) {
                try self.diagnostics.add(.@"error", "abi.c.valist.arity", self.span, "CVaList operation '{s}' does not take explicit arguments", .{target.method_name});
            }

            const Operation = struct {
                result_type: types.TypeRef,
                callee: []const u8,
            };
            const operation: Operation = if (std.mem.eql(u8, target.method_name, "copy")) .{
                .result_type = .{ .named = c_va_list.type_name },
                .callee = c_va_list.copy_callee,
            } else if (std.mem.eql(u8, target.method_name, "finish")) .{
                .result_type = types.TypeRef.fromBuiltin(.unit),
                .callee = c_va_list.finish_callee,
            } else if (std.mem.eql(u8, target.method_name, "next")) blk: {
                const type_arg = target.type_arg_name orelse {
                    try self.diagnostics.add(.@"error", "abi.c.valist.next_type", self.span, "CVaList.next requires a type argument", .{});
                    break :blk .{
                        .result_type = types.TypeRef.unsupported,
                        .callee = c_va_list.next_callee,
                    };
                };
                if (!c_va_list.variadicValueTypeNameSupported(type_arg)) {
                    try self.diagnostics.add(.@"error", "abi.c.valist.next_type", self.span, "CVaList.next type '{s}' is not C ABI-safe after promotion", .{type_arg});
                }
                break :blk .{
                    .result_type = shallowTypeRefFromName(type_arg),
                    .callee = c_va_list.next_callee,
                };
            } else return null;

            if (!std.mem.eql(u8, target.method_name, "next") and target.type_arg_name != null) {
                try self.diagnostics.add(.@"error", "abi.c.valist.type_arg", self.span, "only CVaList.next accepts a type argument", .{});
            }

            const combined_args = try self.allocator.alloc(*Expr, 1 + explicit_args.len);
            combined_args[0] = target.base;
            for (explicit_args, 0..) |arg, index| combined_args[index + 1] = arg;

            self.allocator.destroy(callee_expr);
            return self.makeExpr(operation.result_type, .{ .call = .{
                .callee = operation.callee,
                .args = combined_args,
            } });
        }

        fn parseRawPointerMethodInvocation(
            self: *@This(),
            callee_expr: *Expr,
            target: Expr.MethodTarget,
            explicit_args: []const *Expr,
        ) anyerror!?*Expr {
            const pointer = raw_pointer.parse(target.target_type) orelse return null;
            const method_name = target.method_name;
            const unsafe_required = !std.mem.eql(u8, method_name, "is_null");
            if (unsafe_required and !self.unsafe_context) {
                try self.diagnostics.add(.@"error", "type.raw_pointer.operation.unsafe", self.span, "raw-pointer operation '{s}' requires #unsafe", .{method_name});
            }

            const Operation = struct {
                result_type: types.TypeRef,
                callee: []const u8,
                expected_args: usize,
            };
            const operation: Operation = if (std.mem.eql(u8, method_name, "is_null")) .{
                .result_type = types.TypeRef.fromBuiltin(.bool),
                .callee = raw_pointer.is_null_callee,
                .expected_args = 0,
            } else if (std.mem.eql(u8, method_name, "cast")) blk: {
                const target_type = target.type_arg_name orelse {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.cast.type", self.span, "raw-pointer cast requires a target type", .{});
                    break :blk .{
                        .result_type = types.TypeRef.unsupported,
                        .callee = raw_pointer.cast_callee,
                        .expected_args = 0,
                    };
                };
                const type_name = try raw_pointer.makeTypeName(self.allocator, pointer.access, target_type);
                break :blk .{
                    .result_type = .{ .named = type_name },
                    .callee = raw_pointer.cast_callee,
                    .expected_args = 0,
                };
            } else if (std.mem.eql(u8, method_name, "offset")) .{
                .result_type = .{ .named = target.target_type },
                .callee = raw_pointer.offset_callee,
                .expected_args = 1,
            } else if (std.mem.eql(u8, method_name, "load")) blk: {
                if (!raw_pointer.isMemorySafePointeeName(pointer.pointee)) {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.load.pointee", self.span, "raw-pointer load requires a raw-memory-safe pointee type", .{});
                }
                break :blk .{
                    .result_type = shallowTypeRefFromName(pointer.pointee),
                    .callee = raw_pointer.load_callee,
                    .expected_args = 0,
                };
            } else if (std.mem.eql(u8, method_name, "store")) blk: {
                if (pointer.access != .edit) {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.store.access", self.span, "raw-pointer store requires *edit T", .{});
                }
                if (!raw_pointer.isMemorySafePointeeName(pointer.pointee)) {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.store.pointee", self.span, "raw-pointer store requires a raw-memory-safe pointee type", .{});
                }
                break :blk .{
                    .result_type = types.TypeRef.fromBuiltin(.unit),
                    .callee = raw_pointer.store_callee,
                    .expected_args = 1,
                };
            } else return null;

            if (!std.mem.eql(u8, method_name, "cast") and target.type_arg_name != null) {
                try self.diagnostics.add(.@"error", "type.raw_pointer.type_arg", self.span, "only raw-pointer cast accepts a type argument", .{});
            }
            if (explicit_args.len != operation.expected_args) {
                try self.diagnostics.add(.@"error", "type.raw_pointer.arity", self.span, "raw-pointer operation '{s}' has wrong arity", .{method_name});
            }
            if (std.mem.eql(u8, method_name, "offset") and explicit_args.len == 1 and
                !explicit_args[0].ty.isUnsupported() and !explicit_args[0].ty.eql(types.TypeRef.fromBuiltin(.isize)))
            {
                if (explicit_args[0].node == .integer and explicit_args[0].ty.eql(types.TypeRef.fromBuiltin(.i32))) {
                    explicit_args[0].ty = types.TypeRef.fromBuiltin(.isize);
                } else {
                    try self.diagnostics.add(.@"error", "type.raw_pointer.offset.count", self.span, "raw-pointer offset count must be ISize", .{});
                }
            }
            if (std.mem.eql(u8, method_name, "store") and explicit_args.len == 1 and
                !explicit_args[0].ty.isUnsupported() and !callArgumentTypeCompatible(explicit_args[0].ty, shallowTypeRefFromName(pointer.pointee), pointer.pointee, &.{}, false))
            {
                try self.diagnostics.add(.@"error", "type.raw_pointer.store.value", self.span, "raw-pointer store value has the wrong type", .{});
            }

            const combined_args = try self.allocator.alloc(*Expr, 1 + explicit_args.len);
            combined_args[0] = target.base;
            for (explicit_args, 0..) |arg, index| combined_args[index + 1] = arg;

            self.allocator.destroy(callee_expr);
            const expr = try self.makeExpr(operation.result_type, .{ .call = .{
                .callee = operation.callee,
                .args = combined_args,
            } });
            if (std.mem.eql(u8, method_name, "cast") and operation.result_type == .named) {
                expr.owned_type_name = @constCast(operation.result_type.named);
            }
            return expr;
        }

        fn parseFieldProjection(self: *@This(), base_expr: *Expr) anyerror!*Expr {
            _ = self.advance();
            const field_token = self.advance();
            if (field_token.kind == .integer) {
                const index = tuple_types.projectionIndex(field_token.lexeme) orelse {
                    base_expr.deinit(self.allocator);
                    self.allocator.destroy(base_expr);
                    try self.diagnostics.add(.@"error", "type.tuple.projection", self.span, "tuple projection must use a non-negative field index", .{});
                    return makeUnsupportedExpr(self.allocator);
                };
                const tuple_name = switch (base_expr.ty) {
                    .named => |name| name,
                    else => "",
                };
                const element_type = try tuple_types.projectionElementType(self.allocator, tuple_name, index) orelse {
                    base_expr.deinit(self.allocator);
                    self.allocator.destroy(base_expr);
                    try self.diagnostics.add(.@"error", "type.tuple.projection", self.span, "invalid tuple projection '.{s}'", .{field_token.lexeme});
                    return makeUnsupportedExpr(self.allocator);
                };
                return self.makeExpr(element_type, .{ .field = .{
                    .base = base_expr,
                    .field_name = field_token.lexeme,
                } });
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
                    if (standard_families.familyFromName(base_name) != null) {
                        const maybe_variant = try standard_families.variantForExpected(self.allocator, self.expected_type, base_name, field_token.lexeme);
                        const variant = maybe_variant orelse {
                            base_expr.deinit(self.allocator);
                            self.allocator.destroy(base_expr);
                            try self.diagnostics.add(.@"error", "type.standard.variant_context", self.span, "standard variant '{s}.{s}' requires a matching contextual type", .{
                                base_name,
                                field_token.lexeme,
                            });
                            return makeUnsupportedExpr(self.allocator);
                        };
                        if (variant.payload_type_name == null) {
                            base_expr.deinit(self.allocator);
                            self.allocator.destroy(base_expr);
                            return self.makeExpr(.{ .named = variant.concrete_type_name }, .{ .enum_variant = .{
                                .enum_name = variant.concrete_type_name,
                                .enum_symbol = variant.family_name,
                                .variant_name = variant.variant_name,
                            } });
                        }
                        if (self.peek().kind != .colon_colon) {
                            base_expr.deinit(self.allocator);
                            self.allocator.destroy(base_expr);
                            try self.diagnostics.add(.@"error", "type.enum.variant_payload.invoke", self.span, "payload enum variants require immediate constructor invocation with ':: call'", .{});
                            return makeUnsupportedExpr(self.allocator);
                        }
                        base_expr.deinit(self.allocator);
                        self.allocator.destroy(base_expr);
                        return self.makeExpr(.unsupported, .{ .enum_constructor_target = .{
                            .enum_name = variant.concrete_type_name,
                            .enum_symbol = variant.family_name,
                            .variant_name = variant.variant_name,
                        } });
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
            const method_type_arg = try self.parseOptionalMethodTypeArgument(target_type_name, field_token.lexeme);

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
                        .type_arg_name = method_type_arg,
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
                    .type_arg_name = method_type_arg,
                } });
            }

            try self.diagnostics.add(.@"error", "type.field.struct_unsupported", self.span, "stage0 field projection supports only locally declared struct types", .{});
            return self.makeExpr(.unsupported, .{ .field = .{
                .base = base_expr,
                .field_name = field_token.lexeme,
            } });
        }

        fn parseOptionalMethodTypeArgument(self: *@This(), target_type_name: []const u8, method_name: []const u8) !?[]const u8 {
            const is_valist_next = c_va_list.isTypeName(target_type_name) and std.mem.eql(u8, method_name, "next");
            const is_pointer_cast = raw_pointer.parse(target_type_name) != null and std.mem.eql(u8, method_name, "cast");
            if (!is_valist_next and !is_pointer_cast) return null;
            if (self.peek().kind != .l_bracket) return null;
            _ = self.advance();
            const type_token = self.advance();
            if (type_token.kind != .identifier) {
                try self.diagnostics.add(.@"error", if (is_valist_next) "abi.c.valist.next_type" else "type.raw_pointer.cast.type", self.span, "method type argument must be a simple type name", .{});
                return null;
            }
            if (self.peek().kind != .r_bracket) {
                try self.diagnostics.add(.@"error", if (is_valist_next) "abi.c.valist.next_type" else "type.raw_pointer.cast.type", self.span, "stage0 method type argument must be a single type name", .{});
                while (self.peek().kind != .r_bracket and self.peek().kind != .eof) _ = self.advance();
            }
            if (self.peek().kind == .r_bracket) _ = self.advance();
            return type_token.lexeme;
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
            if (fixedArrayLength(base_expr.ty)) |length| {
                switch (index_expr.node) {
                    .integer => |index_value| {
                        if (index_value >= 0 and @as(usize, @intCast(index_value)) >= length) {
                            try self.diagnostics.add(.@"error", "type.expr.keyed_access.bounds", self.span, "array index is out of bounds", .{});
                        }
                    },
                    else => {},
                }
            }
            return self.makeExpr(element_type, .{ .index = .{
                .base = base_expr,
                .index = index_expr,
            } });
        }

        fn parseTupleExpression(self: *@This()) anyerror!*Expr {
            const expected_parts = switch (self.expected_type) {
                .named => |name| try tuple_types.splitTypeParts(self.allocator, name),
                else => null,
            };
            defer if (expected_parts) |parts| self.allocator.free(parts);

            var items = array_list.Managed(*Expr).init(self.allocator);
            defer items.deinit();
            var element_types = array_list.Managed(types.TypeRef).init(self.allocator);
            defer element_types.deinit();

            while (true) {
                const expected_element = if (expected_parts) |parts|
                    if (items.items.len < parts.len) tuple_types.shallowTypeRefFromName(parts[items.items.len]) else types.TypeRef.unsupported
                else
                    types.TypeRef.unsupported;
                const previous_expected = self.expected_type;
                self.expected_type = expected_element;
                const item = try self.parseConversion();
                self.expected_type = previous_expected;
                try items.append(item);
                try element_types.append(item.ty);

                if (self.peek().kind == .comma) {
                    _ = self.advance();
                    if (self.peek().kind == .r_paren) break;
                    continue;
                }
                break;
            }

            if (self.peek().kind == .r_paren) {
                _ = self.advance();
            } else {
                try self.diagnostics.add(.@"error", "parse.expr.tuple", self.span, "unterminated tuple expression", .{});
            }

            if (items.items.len < 2) {
                try self.diagnostics.add(.@"error", "type.tuple.arity", self.span, "tuple expressions must have at least two elements", .{});
            }
            if (expected_parts) |parts| {
                if (tuple_types.validTupleParts(parts) and parts.len != items.items.len) {
                    try self.diagnostics.add(.@"error", "type.tuple.arity", self.span, "tuple expression arity does not match the expected tuple type", .{});
                }
                for (items.items, 0..) |item, index| {
                    if (index >= parts.len) break;
                    const expected = tuple_types.shallowTypeRefFromName(parts[index]);
                    if (!item.ty.isUnsupported() and !expected.isUnsupported() and
                        !callArgumentTypeCompatible(item.ty, expected, parts[index], &.{}, false))
                    {
                        try self.diagnostics.add(.@"error", "type.expr.tuple.item", self.span, "tuple element {d} has the wrong type", .{index});
                    }
                }
            }

            const type_name = try tuple_types.makeTypeNameFromRefs(self.allocator, element_types.items);
            const expr = try self.makeExpr(.{ .named = type_name }, .{ .tuple = .{ .items = try items.toOwnedSlice() } });
            expr.owned_type_name = @constCast(type_name);
            return expr;
        }

        fn parseArrayLiteral(self: *@This()) anyerror!*Expr {
            const array_type = self.expected_type;
            const array_shape = fixedArrayShape(array_type);
            const element_type = if (array_shape) |shape| shape.element_type else types.TypeRef.unsupported;
            if (self.peek().kind == .r_bracket) {
                _ = self.advance();
                if (element_type.isUnsupported()) {
                    try self.diagnostics.add(.@"error", "type.expr.array.type", self.span, "array literal requires a fixed array contextual type", .{});
                }
                if (array_shape) |shape| {
                    if (shape.length) |length| {
                        if (length != 0) {
                            try self.diagnostics.add(.@"error", "type.expr.array.length", self.span, "empty array literal length does not match the expected array type", .{});
                        }
                    }
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
                if (array_shape) |shape| {
                    if (shape.length) |expected_length| {
                        switch (length.node) {
                            .integer => |actual_length| {
                                if (actual_length >= 0 and @as(usize, @intCast(actual_length)) != expected_length) {
                                    try self.diagnostics.add(.@"error", "type.expr.array.length", self.span, "array repetition length does not match the expected array type", .{});
                                }
                            },
                            else => {},
                        }
                    }
                }
                if (result_type.isUnsupported() and !first.ty.isUnsupported()) {
                    switch (length.node) {
                        .integer => |literal_length| {
                            if (literal_length >= 0) {
                                const inferred_name = try makeFixedArrayTypeName(self.allocator, first.ty, @intCast(literal_length));
                                const expr = try self.makeExpr(.{ .named = inferred_name }, .{ .array_repeat = .{
                                    .value = first,
                                    .length = length,
                                } });
                                expr.owned_type_name = @constCast(inferred_name);
                                return expr;
                            }
                        },
                        else => {},
                    }
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
            const inferred_element_type = first.ty;
            var element_mismatch = false;

            while (self.peek().kind == .comma) {
                _ = self.advance();
                if (self.peek().kind == .r_bracket) break;
                self.expected_type = element_type;
                const item = try self.parseConversion();
                self.expected_type = previous_expected;
                if (!inferred_element_type.isUnsupported() and !item.ty.isUnsupported() and
                    !callArgumentTypeCompatible(item.ty, inferred_element_type, inferred_element_type.displayName(), &.{}, false))
                {
                    element_mismatch = true;
                    try self.diagnostics.add(.@"error", "type.expr.array.element", self.span, "array literal elements must have one element type", .{});
                }
                try items.append(item);
            }
            if (self.peek().kind == .r_bracket) {
                _ = self.advance();
            } else {
                try self.diagnostics.add(.@"error", "parse.expr.array", self.span, "unterminated array literal", .{});
            }
            const result_type = if (element_type.isUnsupported()) types.TypeRef.unsupported else array_type;
            if (array_shape) |shape| {
                if (shape.length) |expected_length| {
                    if (expected_length != items.items.len) {
                        try self.diagnostics.add(.@"error", "type.expr.array.length", self.span, "array literal length does not match the expected array type", .{});
                    }
                }
            }
            if (result_type.isUnsupported()) {
                if (!inferred_element_type.isUnsupported() and !element_mismatch) {
                    const inferred_name = try makeFixedArrayTypeName(self.allocator, inferred_element_type, items.items.len);
                    const expr = try self.makeExpr(.{ .named = inferred_name }, .{ .array = .{ .items = try items.toOwnedSlice() } });
                    expr.owned_type_name = @constCast(inferred_name);
                    return expr;
                }
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
            if (self.expected_type == .named) {
                const expected_name = self.expected_type.named;
                if (try foreign_callable_types.parseSyntax(self.allocator, expected_name)) |syntax| {
                    var owned_syntax = syntax;
                    defer owned_syntax.deinit(self.allocator);
                    if (foreignCallablePrototypeCompatible(owned_syntax, prototype)) {
                        expr.ty = self.expected_type;
                        return expr;
                    }
                }
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

fn typesEqualityComparable(lhs: types.TypeRef, rhs: types.TypeRef) bool {
    if (lhs.eql(rhs)) return typeSupportsBuiltinEquality(lhs);
    if (lhs == .named and rhs == .named) {
        const lhs_pointer = raw_pointer.parse(lhs.named) orelse return false;
        const rhs_pointer = raw_pointer.parse(rhs.named) orelse return false;
        return std.mem.eql(u8, lhs_pointer.pointee, rhs_pointer.pointee) and
            (lhs_pointer.access == rhs_pointer.access or lhs_pointer.access == .read or rhs_pointer.access == .read);
    }
    return false;
}

fn typesOrderingComparable(lhs: types.TypeRef, rhs: types.TypeRef) bool {
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

fn usesOwnedPackedCallableInput(parameter_modes: []const ParameterMode) bool {
    for (parameter_modes) |mode| {
        if (mode != .owned and mode != .take) return false;
    }
    return true;
}

const FixedArrayShape = struct {
    element_type: types.TypeRef,
    length: ?usize,
};

fn fixedArrayShape(ty: types.TypeRef) ?FixedArrayShape {
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
    const length_text = std.mem.trim(u8, inner[separator + 1 ..], " \t");
    if (element_type.len == 0) return null;
    const builtin = types.Builtin.fromName(element_type);
    return .{
        .element_type = if (builtin != .unsupported) types.TypeRef.fromBuiltin(builtin) else .{ .named = element_type },
        .length = std.fmt.parseInt(usize, length_text, 10) catch null,
    };
}

fn fixedArrayElementType(ty: types.TypeRef) ?types.TypeRef {
    const shape = fixedArrayShape(ty) orelse return null;
    return shape.element_type;
}

fn fixedArrayLength(ty: types.TypeRef) ?usize {
    const shape = fixedArrayShape(ty) orelse return null;
    return shape.length;
}

fn makeFixedArrayTypeName(allocator: Allocator, element_type: types.TypeRef, length: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "[{s}; {d}]", .{ element_type.displayName(), length });
}

fn dynamicLookupTypeSupported(allocator: Allocator, raw_type_name: []const u8) !bool {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "*read ") or std.mem.startsWith(u8, trimmed, "*edit ")) return true;
    var syntax = try foreign_callable_types.parseSyntax(allocator, trimmed) orelse return false;
    defer syntax.deinit(allocator);
    return syntax.variadic_tail == null;
}

fn dynamicLookupResultOkType(allocator: Allocator, raw_type_name: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "Result[")) return null;
    const open_index = "Result".len;
    const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse return null;
    if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t\r\n").len != 0) return null;
    const args = try typed_text.splitTopLevelCommaParts(allocator, trimmed[open_index + 1 .. close_index]);
    defer allocator.free(args);
    if (args.len != 2) return null;
    const ok_type = std.mem.trim(u8, args[0], " \t\r\n");
    const err_type = std.mem.trim(u8, args[1], " \t\r\n");
    if (!std.mem.eql(u8, err_type, dynamic_library.lookup_error_type_name)) return null;
    if (!try dynamicLookupTypeSupported(allocator, ok_type)) return null;
    return ok_type;
}

fn isAddressablePlace(expr: *const Expr) bool {
    return switch (expr.node) {
        .identifier => true,
        .field => |field| isAddressablePlace(field.base),
        .index => |index| isAddressablePlace(index.base),
        else => false,
    };
}

fn contextualIntegerLiteralType(expected: types.TypeRef) types.TypeRef {
    if (expected.isNumeric()) return expected;
    switch (expected) {
        .named => |name| {
            const alias = types.CAbiAlias.fromName(name) orelse return types.TypeRef.fromBuiltin(.i32);
            return switch (alias) {
                .c_bool, .c_void => types.TypeRef.fromBuiltin(.i32),
                else => expected,
            };
        },
        else => return types.TypeRef.fromBuiltin(.i32),
    }
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
        if (!try emitAwaitSyntaxDiagnostic(diagnostics, syntax_expr, span)) {
            try diagnostics.add(.@"error", "type.expr.syntax", span, "malformed expression syntax in stage0", .{});
        }
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

fn emitAwaitSyntaxDiagnostic(diagnostics: *diag.Bag, expr: *const ast.BodyExprSyntax, span: source.Span) anyerror!bool {
    switch (expr.node) {
        .@"error" => |value| {
            const text = std.mem.trim(u8, value.text, " \t\r\n");
            if (startsWithIdentifier(text, "await")) {
                try diagnostics.add(.@"error", "type.await.standalone", span, "standalone await expressions are not part of v1; use the Task.await method surface", .{});
                return true;
            }
            if (containsAwaitInvocationQualifier(text)) {
                try diagnostics.add(.@"error", "type.await.qualifier", span, "await is not an invocation qualifier; use the Task.await method surface", .{});
                return true;
            }
            return false;
        },
        .group => |group| return emitAwaitSyntaxDiagnostic(diagnostics, group, span),
        .tuple => |items| return emitAwaitSyntaxDiagnosticInSlice(diagnostics, items, span),
        .array => |items| return emitAwaitSyntaxDiagnosticInSlice(diagnostics, items, span),
        .array_repeat => |array_repeat| {
            if (try emitAwaitSyntaxDiagnostic(diagnostics, array_repeat.value, span)) return true;
            return emitAwaitSyntaxDiagnostic(diagnostics, array_repeat.length, span);
        },
        .raw_pointer => |raw_pointer_expr| return emitAwaitSyntaxDiagnostic(diagnostics, raw_pointer_expr.place, span),
        .unary => |unary| return emitAwaitSyntaxDiagnostic(diagnostics, unary.operand, span),
        .binary => |binary| {
            if (try emitAwaitSyntaxDiagnostic(diagnostics, binary.lhs, span)) return true;
            return emitAwaitSyntaxDiagnostic(diagnostics, binary.rhs, span);
        },
        .field => |field| return emitAwaitSyntaxDiagnostic(diagnostics, field.base, span),
        .index => |index| {
            if (try emitAwaitSyntaxDiagnostic(diagnostics, index.base, span)) return true;
            return emitAwaitSyntaxDiagnostic(diagnostics, index.index, span);
        },
        .call => |call| {
            if (try emitAwaitSyntaxDiagnostic(diagnostics, call.callee, span)) return true;
            return emitAwaitSyntaxDiagnosticInSlice(diagnostics, call.args, span);
        },
        .method_call => |call| {
            if (try emitAwaitSyntaxDiagnostic(diagnostics, call.callee, span)) return true;
            return emitAwaitSyntaxDiagnosticInSlice(diagnostics, call.args, span);
        },
        .name, .integer, .string => return false,
    }
}

fn emitAwaitSyntaxDiagnosticInSlice(diagnostics: *diag.Bag, items: []const *ast.BodyExprSyntax, span: source.Span) anyerror!bool {
    for (items) |item| {
        if (try emitAwaitSyntaxDiagnostic(diagnostics, item, span)) return true;
    }
    return false;
}

fn containsAwaitInvocationQualifier(text: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, text, offset, "::")) |separator| {
        const after = trimLeadingWhitespace(text[separator + "::".len ..]);
        if (startsWithIdentifier(after, "await")) return true;
        offset = separator + "::".len;
    }
    return false;
}

fn trimLeadingWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and isWhitespace(text[index])) : (index += 1) {}
    return text[index..];
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn startsWithIdentifier(text: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, text, word)) return false;
    if (text.len == word.len) return true;
    return !isIdentifierContinue(text[word.len]);
}

fn isIdentifierContinue(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '_';
}

fn syntaxExprHasError(expr: *const ast.BodyExprSyntax) bool {
    return switch (expr.node) {
        .@"error" => true,
        .name, .integer, .string => false,
        .group => |group| syntaxExprHasError(group),
        .tuple => |items| exprSliceHasError(items),
        .array => |items| exprSliceHasError(items),
        .array_repeat => |array_repeat| syntaxExprHasError(array_repeat.value) or syntaxExprHasError(array_repeat.length),
        .raw_pointer => |raw_pointer_expr| syntaxExprHasError(raw_pointer_expr.place),
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
        .raw_pointer => |raw_pointer_expr| {
            try tokens.append(.{ .kind = .amp, .lexeme = "&" });
            try tokens.append(.{ .kind = .identifier, .lexeme = "raw" });
            try tokens.append(.{ .kind = .identifier, .lexeme = raw_pointer_expr.mode.text });
            try appendExprTokens(tokens, raw_pointer_expr.place);
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
    if (std.mem.eql(u8, raw, "&")) return .amp;
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
