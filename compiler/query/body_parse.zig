const std = @import("std");
const array_list = std.array_list;
const c_va_list = @import("../abi/c/va_list.zig");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const dynamic_library = @import("../runtime/dynamic_library/root.zig");
const foreign_callable_types = @import("foreign_callable_types.zig");
const query_attributes = @import("attributes.zig");
const expression_parse = @import("expression_parse.zig");
const pattern_parse = @import("pattern_parse.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const typed_expr = @import("../typed/expr.zig");
const type_support = @import("type_support.zig");
const tuple_types = @import("tuple_types.zig");
const query_text = @import("text.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const Expr = typed.Expr;
const BinaryOp = typed.BinaryOp;
const Statement = typed.Statement;
const Block = typed.Block;
const FunctionData = typed.FunctionData;
const FunctionPrototype = typed.FunctionPrototype;
const MethodPrototype = typed.MethodPrototype;
const StructPrototype = typed.StructPrototype;
const EnumPrototype = typed.EnumPrototype;
const Item = typed.Item;
const WherePredicate = typed.WherePredicate;
const cloneExprForTyped = typed_expr.cloneExpr;
const baseTypeName = query_text.baseTypeName;
const findMatchingDelimiter = query_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = query_text.findTopLevelHeaderScalar;
const findTopLevelScalar = query_text.findTopLevelScalar;
const isPlainIdentifier = query_text.isPlainIdentifier;
const BoundaryType = type_support.BoundaryType;
const boundaryFromParameter = type_support.boundaryFromParameter;
const boundaryFromTypeRef = type_support.boundaryFromTypeRef;
const inferExprBoundaryTypeInScope = type_support.inferExprBoundaryTypeInScope;
const findEnumPrototype = type_support.findEnumPrototype;
const findStructPrototype = type_support.findStructPrototype;
const parseExpressionSyntax = expression_parse.parseExpressionSyntax;
const returnTypeStructurallyCompatible = type_support.returnTypeStructurallyCompatible;

pub fn parseFunctionBody(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    global_scope: *const Scope,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
) !void {
    var scope = Scope.init(allocator);
    defer scope.deinit();
    try scope.extendFrom(global_scope);

    for (function.parameters.items) |parameter| {
        try scope.putWithOrigin(c_va_list.localName(parameter.name), parameter.ty, switch (parameter.mode) {
            .read => false,
            .owned, .take, .edit => true,
        }, boundaryFromParameter(parameter));
    }

    const block = function.block_syntax orelse return error.InvalidParse;
    try appendStructuredBlockStatements(
        allocator,
        item,
        function,
        &function.body,
        &block.structured,
        &scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        0,
        function.is_suspend,
        item.is_unsafe,
    );

    if (!function.return_type.eql(types.TypeRef.fromBuiltin(.unit))) {
        const missing_explicit_return = !blockDefinitelyReturns(&function.body);
        if (missing_explicit_return) {
            try diagnostics.add(.@"error", "type.return.missing", item.span, "non-Unit function '{s}' must end with an explicit return", .{item.name});
        }
    }
}

fn parseStructuredBlockAllocated(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!*Block {
    const body = try allocator.create(Block);
    errdefer allocator.destroy(body);
    body.* = Block.init(allocator);
    errdefer body.deinit(allocator);

    try appendStructuredBlockStatements(
        allocator,
        item,
        function,
        body,
        block_syntax,
        scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        loop_depth,
        suspend_context,
        unsafe_context,
    );
    return body;
}

fn appendStructuredBlockStatements(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    body: *Block,
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!void {
    for (block_syntax.statements) |statement_syntax| {
        try body.statements.append(try parseStructuredStatement(
            allocator,
            item,
            function,
            statement_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ));
    }
}

fn predeclareStructuredBlockConstBindings(
    block_syntax: *const ast.BodyBlockSyntax,
    scope: *Scope,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
) !void {
    for (block_syntax.statements) |statement_syntax| {
        switch (statement_syntax) {
            .const_decl => |binding| {
                const declared_type_syntax = binding.declared_type orelse continue;
                const name = std.mem.trim(u8, binding.name.text, " \t");
                const declared_type_name = std.mem.trim(u8, declared_type_syntax.text(), " \t");
                if (declared_type_name.len == 0) continue;
                const declared_type = try resolveDeclaredValueType(
                    declared_type_name,
                    struct_prototypes,
                    enum_prototypes,
                    span,
                    diagnostics,
                );
                try scope.put(name, declared_type, false);
            },
            else => {},
        }
    }
}

fn parseStructuredStatement(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    statement_syntax: ast.BodyStatementSyntax,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    return switch (statement_syntax) {
        .placeholder => |line| parsePlaceholderStatement(item, line, diagnostics),
        .let_decl => |binding| parseBindingStatementSyntax(
            allocator,
            binding,
            false,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .const_decl => |binding| parseBindingStatementSyntax(
            allocator,
            binding,
            true,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .assign_stmt => |assign| parseAssignmentStatementSyntax(
            allocator,
            assign,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ),
        .select_stmt => |select_syntax| parseStructuredSelect(
            allocator,
            item,
            function,
            select_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ),
        .repeat_stmt => |repeat_syntax| parseStructuredRepeat(
            allocator,
            item,
            function,
            repeat_syntax,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            unsafe_context,
        ),
        .unsafe_block => |unsafe_block| .{ .unsafe_block = try parseStructuredBlockAllocated(
            allocator,
            item,
            function,
            unsafe_block,
            scope,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            loop_depth,
            suspend_context,
            true,
        ) },
        .defer_stmt => |expr_syntax| .{ .defer_stmt = try parseExpressionSyntax(
            allocator,
            expr_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ) },
        .break_stmt => blk: {
            if (loop_depth == 0) {
                try diagnostics.add(.@"error", "type.repeat.break", item.span, "break is only valid inside repeat", .{});
                break :blk .placeholder;
            }
            break :blk .break_stmt;
        },
        .continue_stmt => blk: {
            if (loop_depth == 0) {
                try diagnostics.add(.@"error", "type.repeat.continue", item.span, "continue is only valid inside repeat", .{});
                break :blk .placeholder;
            }
            break :blk .continue_stmt;
        },
        .return_stmt => |maybe_expr_syntax| blk: {
            if (maybe_expr_syntax) |expr_syntax| {
                const expr = try parseExpressionSyntax(
                    allocator,
                    expr_syntax,
                    function.return_type,
                    scope,
                    function.where_predicates,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    item.span,
                    suspend_context,
                    unsafe_context,
                );
                if (!function.return_type.isUnsupported() and !expr.ty.isUnsupported() and
                    !returnTypeStructurallyCompatible(expr.ty, function.return_type))
                {
                    try diagnostics.add(.@"error", "type.return.mismatch", item.span, "return type mismatch in function '{s}'", .{item.name});
                }
                break :blk .{ .return_stmt = expr };
            }

            if (!function.return_type.eql(types.TypeRef.fromBuiltin(.unit))) {
                try diagnostics.add(.@"error", "type.return.missing_value", item.span, "non-Unit function '{s}' must return a value", .{item.name});
            }
            break :blk .{ .return_stmt = null };
        },
        .expr_stmt => |expr_syntax| .{ .expr_stmt = try parseExpressionSyntax(
            allocator,
            expr_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        ) },
    };
}

fn parsePlaceholderStatement(item: *Item, line: ast.SpanText, diagnostics: *diag.Bag) !Statement {
    const text = std.mem.trim(u8, line.text, " \t");
    if (std.mem.eql(u8, text, "...")) return .placeholder;

    if (std.mem.eql(u8, text, "#unsafe:") or
        std.mem.eql(u8, text, "select:") or
        (std.mem.startsWith(u8, text, "select ") and std.mem.endsWith(u8, text, ":")) or
        std.mem.eql(u8, text, "repeat:") or
        std.mem.eql(u8, text, "repeat") or
        std.mem.startsWith(u8, text, "repeat "))
    {
        try diagnostics.add(.@"error", "type.statement.block", item.span, "statement form '{s}' requires its own indented body", .{text});
        return .placeholder;
    }

    if (text.len != 0) {
        try diagnostics.add(.@"error", "type.stage0.statement", item.span, "stage0 does not yet implement statement form '{s}'", .{text});
    }
    return .placeholder;
}

fn parseStructuredSelect(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    select_syntax: *const ast.BodyStatementSyntax.SelectStmt,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const select_data = try allocator.create(Statement.SelectData);
    errdefer allocator.destroy(select_data);
    select_data.* = .{
        .arms = &.{},
    };
    errdefer select_data.deinit(allocator);

    var arms = array_list.Managed(Statement.SelectArm).init(allocator);
    defer arms.deinit();
    var pattern_diagnostics = array_list.Managed(Statement.PatternDiagnostic).init(allocator);
    errdefer {
        for (pattern_diagnostics.items) |pattern_diagnostic| pattern_diagnostic.deinit(allocator);
        pattern_diagnostics.deinit();
    }

    if (select_syntax.subject) |subject_syntax| {
        const subject = try parseExpressionSyntax(
            allocator,
            subject_syntax,
            .unsupported,
            scope,
            function.where_predicates,
            prototypes,
            method_prototypes,
            struct_prototypes,
            enum_prototypes,
            diagnostics,
            item.span,
            suspend_context,
            unsafe_context,
        );
        select_data.subject = subject;
        select_data.subject_temp_name = try std.fmt.allocPrint(allocator, "runa_select_subject_{d}_{d}", .{
            item.span.file_id,
            item.span.start,
        });

        const subject_value = try makeIdentifierExpr(allocator, subject.ty, select_data.subject_temp_name.?);
        defer {
            subject_value.deinit(allocator);
            allocator.destroy(subject_value);
        }

        for (select_syntax.arms) |arm_syntax| {
            const pattern_syntax = switch (arm_syntax.head) {
                .pattern => |pattern| pattern,
                .guard => {
                    try diagnostics.add(.@"error", "type.select.arm", item.span, "unsupported select arm head in subject select", .{});
                    continue;
                },
            };

            var pattern = try pattern_parse.parseSubjectPatternSyntax(
                parseExpressionSyntax,
                allocator,
                pattern_syntax,
                subject_value,
                itemSymbolPrefix(item),
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                suspend_context,
                unsafe_context,
            );
            defer pattern.deinit(allocator);
            for (pattern.diagnostics) |pattern_diagnostic| try pattern_diagnostics.append(pattern_diagnostic);
            allocator.free(pattern.diagnostics);
            pattern.diagnostics = &.{};

            var arm_scope = try cloneScope(allocator, scope);
            defer arm_scope.deinit();
            for (pattern.bindings) |binding| {
                try arm_scope.put(binding.name, binding.ty, true);
            }

            const moved_cleanup_condition = try makeIdentifierExpr(allocator, types.TypeRef.fromBuiltin(.bool), "runa_pattern_moved");
            const moved_cleanup_bindings = try allocator.alloc(Statement.SelectBinding, 0);
            try arms.append(.{
                .condition = pattern.condition,
                .bindings = pattern.bindings,
                .pattern_irrefutable = pattern.irrefutable,
                .body = try parseStructuredBlockAllocated(
                    allocator,
                    item,
                    function,
                    arm_syntax.body,
                    &arm_scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    loop_depth,
                    suspend_context,
                    unsafe_context,
                ),
            });
            pattern.condition = moved_cleanup_condition;
            pattern.bindings = moved_cleanup_bindings;
        }

        if (select_syntax.else_body) |else_body| {
            var arm_scope = try cloneScope(allocator, scope);
            defer arm_scope.deinit();
            select_data.else_body = try parseStructuredBlockAllocated(
                allocator,
                item,
                function,
                else_body,
                &arm_scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                loop_depth,
                suspend_context,
                unsafe_context,
            );
        }
    } else {
        for (select_syntax.arms) |arm_syntax| {
            const guard_syntax = switch (arm_syntax.head) {
                .guard => |guard| guard,
                .pattern => {
                    try diagnostics.add(.@"error", "type.select.arm", item.span, "malformed guarded select arm", .{});
                    continue;
                },
            };
            const condition = try parseExpressionSyntax(
                allocator,
                guard_syntax,
                types.TypeRef.fromBuiltin(.bool),
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            if (!condition.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !condition.ty.isUnsupported()) {
                try diagnostics.add(.@"error", "type.select.guard", item.span, "guarded select conditions must be Bool", .{});
            }

            try arms.append(.{
                .condition = condition,
                .bindings = try allocator.alloc(Statement.SelectBinding, 0),
                .body = try parseStructuredBlockAllocated(
                    allocator,
                    item,
                    function,
                    arm_syntax.body,
                    scope,
                    prototypes,
                    method_prototypes,
                    struct_prototypes,
                    enum_prototypes,
                    diagnostics,
                    loop_depth,
                    suspend_context,
                    unsafe_context,
                ),
            });
        }

        if (select_syntax.else_body) |else_body| {
            select_data.else_body = try parseStructuredBlockAllocated(
                allocator,
                item,
                function,
                else_body,
                scope,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                loop_depth,
                suspend_context,
                unsafe_context,
            );
        }
    }

    if (arms.items.len == 0) {
        try diagnostics.add(.@"error", "type.select.empty", item.span, "select requires at least one when arm", .{});
    }

    select_data.arms = try arms.toOwnedSlice();
    select_data.pattern_diagnostics = try pattern_diagnostics.toOwnedSlice();
    return .{ .select_stmt = select_data };
}

fn parseStructuredRepeat(
    allocator: Allocator,
    item: *Item,
    function: *FunctionData,
    repeat_syntax: *const ast.BodyStatementSyntax.RepeatStmt,
    scope: *Scope,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    loop_depth: usize,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    var condition: ?*Expr = null;
    var reject_iteration = false;
    var iteration_type: ?types.TypeRef = null;
    var iteration_scope: ?Scope = null;
    defer if (iteration_scope) |*scoped| scoped.deinit();

    switch (repeat_syntax.header) {
        .infinite => {},
        .while_condition => |condition_syntax| {
            condition = try parseExpressionSyntax(
                allocator,
                condition_syntax,
                types.TypeRef.fromBuiltin(.bool),
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            if (!condition.?.ty.eql(types.TypeRef.fromBuiltin(.bool)) and !condition.?.ty.isUnsupported()) {
                try diagnostics.add(.@"error", "type.repeat.cond", item.span, "repeat while condition must be Bool", .{});
            }
        },
        .iteration => |iteration| {
            reject_iteration = true;

            const items_expr = try parseExpressionSyntax(
                allocator,
                iteration.iterable,
                .unsupported,
                scope,
                function.where_predicates,
                prototypes,
                method_prototypes,
                struct_prototypes,
                enum_prototypes,
                diagnostics,
                item.span,
                suspend_context,
                unsafe_context,
            );
            defer {
                items_expr.deinit(allocator);
                allocator.destroy(items_expr);
            }
            iteration_type = items_expr.ty;

            switch (iteration.binding.node) {
                .wildcard => {
                    reject_iteration = false;
                },
                .binding => |binding| {
                    if (std.mem.eql(u8, binding.text, "true") or std.mem.eql(u8, binding.text, "false")) {
                        try diagnostics.add(.@"error", "type.repeat.pattern", item.span, "repeat iteration requires an irrefutable binding pattern", .{});
                    } else {
                        var scoped = try cloneScope(allocator, scope);
                        errdefer scoped.deinit();
                        try scoped.put(binding.text, .unsupported, false);
                        iteration_scope = scoped;
                        reject_iteration = false;
                    }
                },
                .tuple => {
                    try diagnostics.add(.@"error", "type.repeat.pattern.tuple", item.span, "repeat tuple binding patterns require tuple iteration item types", .{});
                },
                else => {
                    try diagnostics.add(.@"error", "type.repeat.pattern", item.span, "repeat iteration requires an irrefutable binding pattern", .{});
                },
            }
        },
        .invalid => |invalid| {
            reject_iteration = true;
            try diagnostics.add(.@"error", "type.repeat.syntax", item.span, "malformed repeat statement '{s}'", .{invalid.text});
        },
    }

    const body_scope = if (iteration_scope) |*scoped| scoped else scope;
    const body = try parseStructuredBlockAllocated(
        allocator,
        item,
        function,
        repeat_syntax.body,
        body_scope,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        loop_depth + 1,
        suspend_context,
        unsafe_context,
    );
    errdefer {
        body.deinit(allocator);
        allocator.destroy(body);
    }

    if (reject_iteration) {
        body.deinit(allocator);
        allocator.destroy(body);
        return .placeholder;
    }

    const loop_data = try allocator.create(Statement.LoopData);
    errdefer allocator.destroy(loop_data);
    loop_data.* = .{
        .condition = condition,
        .body = body,
        .iteration_type = iteration_type,
    };
    return .{ .loop_stmt = loop_data };
}

fn parseBindingStatementSyntax(
    allocator: Allocator,
    binding: ast.BodyStatementSyntax.BindingDecl,
    is_const: bool,
    scope: *Scope,
    current_where_predicates: []const WherePredicate,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const name = std.mem.trim(u8, binding.name.text, " \t");
    var declared_type: types.TypeRef = .unsupported;
    if (binding.declared_type) |declared_type_syntax| {
        const declared_type_name = std.mem.trim(u8, declared_type_syntax.text(), " \t");
        if (declared_type_name.len == 0) {
            try diagnostics.add(.@"error", "type.binding.declared", span, "local binding '{s}' requires a type after ':'", .{name});
        } else {
            declared_type = try resolveDeclaredValueType(
                declared_type_name,
                struct_prototypes,
                enum_prototypes,
                span,
                diagnostics,
            );
        }
    } else if (is_const) {
        try diagnostics.add(.@"error", "type.const.type", span, "local const '{s}' requires an explicit const-safe type", .{name});
    }

    const expr = try parseExpressionSyntax(
        allocator,
        binding.expr,
        declared_type,
        scope,
        current_where_predicates,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        span,
        suspend_context,
        unsafe_context,
    );
    const binding_type = if (!declared_type.isUnsupported()) declared_type else expr.ty;

    if (!declared_type.isUnsupported() and !expr.ty.isUnsupported() and
        !type_support.callArgumentTypeCompatible(expr.ty, declared_type, declared_type.displayName(), &.{}, false))
    {
        try diagnostics.add(.@"error", "type.binding.mismatch", span, "local binding '{s}' initializer type does not match declared type", .{name});
    }

    try scope.putFull(name, binding_type, !is_const, is_const, inferExprBoundaryTypeInScope(scope, expr));

    const lowered = Statement.BindingDecl{
        .name = name,
        .ty = binding_type,
        .explicit_type = binding.declared_type != null,
        .span = span,
        .expr = expr,
    };
    return if (is_const)
        .{ .const_decl = lowered }
    else
        .{ .let_decl = lowered };
}

fn parseAssignmentStatementSyntax(
    allocator: Allocator,
    assign: ast.BodyStatementSyntax.AssignStmt,
    scope: *Scope,
    current_where_predicates: []const WherePredicate,
    prototypes: []const FunctionPrototype,
    method_prototypes: []const MethodPrototype,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
    suspend_context: bool,
    unsafe_context: bool,
) anyerror!Statement {
    const resolved_target = try resolveAssignmentTargetSyntax(allocator, assign.target, scope, struct_prototypes, diagnostics, span) orelse return .placeholder;
    errdefer if (resolved_target.owns_name) allocator.free(resolved_target.rendered_name);

    const binary_op = if (assign.op) |op| syntaxAssignOpToBinaryOp(op) else null;
    const rhs_expected_type = if (binary_op) |op| compoundAssignmentExpectedRhs(op, resolved_target.ty) else resolved_target.ty;
    const expr = try parseExpressionSyntax(
        allocator,
        assign.expr,
        rhs_expected_type,
        scope,
        current_where_predicates,
        prototypes,
        method_prototypes,
        struct_prototypes,
        enum_prototypes,
        diagnostics,
        span,
        suspend_context,
        unsafe_context,
    );
    if (binary_op) |op| {
        const target_builtin = switch (resolved_target.ty) {
            .builtin => |value| value,
            else => .unsupported,
        };
        const expr_builtin = switch (expr.ty) {
            .builtin => |value| value,
            else => .unsupported,
        };
        const result_type = compoundAssignmentResult(op, target_builtin, expr_builtin);
        if (result_type == .unsupported and !resolved_target.ty.isUnsupported() and !expr.ty.isUnsupported()) {
            try diagnostics.add(.@"error", "type.assign.compound", span, "compound assignment requires matching numeric operands in stage0", .{});
        } else if (result_type != .unsupported and !resolved_target.ty.eql(types.TypeRef.fromBuiltin(result_type))) {
            try diagnostics.add(.@"error", "type.assign.compound", span, "compound assignment result must match the target type", .{});
        }
    } else if (!resolved_target.ty.isUnsupported() and !expr.ty.isUnsupported() and !resolved_target.ty.eql(expr.ty)) {
        try diagnostics.add(.@"error", "type.assign.mismatch", span, "assignment target '{s}' does not match the right-hand type", .{resolved_target.rendered_name});
    }

    if (assign.op == null and
        std.mem.indexOfScalar(u8, resolved_target.rendered_name, '.') == null and
        std.mem.indexOfScalar(u8, resolved_target.rendered_name, '[') == null)
    {
        scope.updateOrigin(resolved_target.rendered_name, inferExprBoundaryTypeInScope(scope, expr));
    }

    return .{ .assign_stmt = .{
        .name = resolved_target.rendered_name,
        .owns_name = resolved_target.owns_name,
        .ty = resolved_target.ty,
        .op = binary_op,
        .expr = expr,
    } };
}

fn resolveAssignmentTargetSyntax(
    allocator: Allocator,
    target: *const ast.BodyExprSyntax,
    scope: *Scope,
    struct_prototypes: []const StructPrototype,
    diagnostics: *diag.Bag,
    span: source.Span,
) !?ResolvedAssignmentTarget {
    switch (target.node) {
        .name => |name| {
            const name_text = std.mem.trim(u8, name.text, " \t");
            if (!isPlainIdentifier(name_text)) {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }
            const target_type = scope.get(name_text) orelse {
                try diagnostics.add(.@"error", "type.assign.unknown", span, "assignment target '{s}' is not a known local name", .{name_text});
                return null;
            };
            if (!scope.isMutable(name_text)) {
                try diagnostics.add(.@"error", "type.assign.immutable", span, "assignment target '{s}' is not mutable in stage0", .{name_text});
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
                    try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                    return null;
                },
            };
            const field_name = std.mem.trim(u8, field.field_name.text, " \t");
            if (tuple_types.projectionIndex(field_name) != null) {
                try diagnostics.add(.@"error", "type.tuple.assign", span, "tuple field assignment is not part of v1", .{});
                return null;
            }
            if (!isPlainIdentifier(base_name) or !isPlainIdentifier(field_name)) {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
                return null;
            }

            const base_type = scope.get(base_name) orelse {
                try diagnostics.add(.@"error", "type.assign.unknown", span, "assignment target '{s}' is not a known local name", .{base_name});
                return null;
            };
            if (!scope.isMutable(base_name)) {
                try diagnostics.add(.@"error", "type.assign.immutable", span, "assignment target '{s}' is not mutable in stage0", .{base_name});
                return null;
            }

            const struct_name = switch (base_type) {
                .named => |name| name,
                else => {
                    try diagnostics.add(.@"error", "type.assign.target", span, "field assignment requires a struct-typed base expression", .{});
                    return null;
                },
            };
            const prototype = findStructPrototype(struct_prototypes, struct_name) orelse {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 field assignment supports only locally declared struct types", .{});
                return null;
            };
            for (prototype.fields) |field_proto| {
                if (std.mem.eql(u8, field_proto.name, field_name)) {
                    return .{
                        .rendered_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, field_name }),
                        .owns_name = true,
                        .ty = field_proto.ty,
                    };
                }
            }

            try diagnostics.add(.@"error", "type.field.unknown", span, "unknown field '{s}' on struct '{s}'", .{
                field_name,
                struct_name,
            });
            return null;
        },
        .index => |index| {
            const base_name = switch (index.base.node) {
                .name => |name| std.mem.trim(u8, name.text, " \t"),
                else => {
                    try diagnostics.add(.@"error", "type.assign.target", span, "array element assignment requires a local array base", .{});
                    return null;
                },
            };
            if (!isPlainIdentifier(base_name)) {
                try diagnostics.add(.@"error", "type.assign.target", span, "array element assignment requires a local array base", .{});
                return null;
            }
            const base_type = scope.get(base_name) orelse {
                try diagnostics.add(.@"error", "type.assign.unknown", span, "assignment target '{s}' is not a known local name", .{base_name});
                return null;
            };
            if (!scope.isMutable(base_name)) {
                try diagnostics.add(.@"error", "type.assign.immutable", span, "assignment target '{s}' is not mutable in stage0", .{base_name});
                return null;
            }
            const element_type = fixedArrayElementType(base_type) orelse {
                try diagnostics.add(.@"error", "type.assign.target", span, "array element assignment requires a fixed array target", .{});
                return null;
            };
            const index_text = simpleIndexTargetText(index.index) orelse {
                try diagnostics.add(.@"error", "type.assign.target", span, "stage0 array element assignment requires a simple index key", .{});
                return null;
            };
            if (index.index.node == .name) {
                const key_type = scope.get(index_text) orelse .unsupported;
                if (!key_type.eql(types.TypeRef.fromBuiltin(.index)) and !key_type.isUnsupported()) {
                    try diagnostics.add(.@"error", "type.expr.keyed_access.index", span, "keyed access requires an Index expression", .{});
                }
            }
            return .{
                .rendered_name = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ base_name, index_text }),
                .owns_name = true,
                .ty = element_type,
            };
        },
        else => {
            try diagnostics.add(.@"error", "type.assign.target", span, "stage0 assignment supports only plain locals or one struct field projection", .{});
            return null;
        },
    }
}

fn syntaxAssignOpToBinaryOp(op: ast.AssignOpSyntax) BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .shl => .shl,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_xor => .bit_xor,
        .bit_or => .bit_or,
    };
}

fn makeIdentifierExpr(allocator: Allocator, ty: types.TypeRef, name: []const u8) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{
        .ty = ty,
        .node = .{ .identifier = name },
    };
    return expr;
}

fn itemSymbolPrefix(item: *const Item) []const u8 {
    if (std.mem.endsWith(u8, item.symbol_name, item.name)) {
        return item.symbol_name[0 .. item.symbol_name.len - item.name.len];
    }
    return "";
}

fn cloneScope(allocator: Allocator, scope: *const Scope) !Scope {
    var cloned = Scope.init(allocator);
    try cloned.extendFrom(scope);
    return cloned;
}

fn blockDefinitelyReturns(block: *const Block) bool {
    if (block.statements.items.len == 0) return false;
    const last = block.statements.items[block.statements.items.len - 1];
    return statementDefinitelyReturns(last);
}

fn statementDefinitelyReturns(statement: Statement) bool {
    return switch (statement) {
        .return_stmt => true,
        .select_stmt => |select_data| selectDefinitelyReturns(select_data),
        .unsafe_block => |body| blockDefinitelyReturns(body),
        else => false,
    };
}

fn selectDefinitelyReturns(select_data: *const Statement.SelectData) bool {
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

fn isDefinitelyTrueExpr(expr: *const Expr) bool {
    return switch (expr.node) {
        .bool_lit => |value| value,
        else => false,
    };
}

const ResolvedAssignmentTarget = struct {
    rendered_name: []const u8,
    owns_name: bool = false,
    ty: types.TypeRef,
};

fn compoundAssignmentResult(op: BinaryOp, lhs: types.Builtin, rhs: types.Builtin) types.Builtin {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => if (lhs == rhs and lhs.isNumeric()) lhs else .unsupported,
        .bit_and, .bit_xor, .bit_or => if (lhs == rhs and lhs.isInteger()) lhs else .unsupported,
        .shl, .shr => if (lhs.isInteger() and rhs == .index) lhs else .unsupported,
        else => .unsupported,
    };
}

fn compoundAssignmentExpectedRhs(op: BinaryOp, lhs: types.TypeRef) types.TypeRef {
    return switch (op) {
        .shl, .shr => types.TypeRef.fromBuiltin(.index),
        else => lhs,
    };
}

fn resolveDeclaredValueType(
    type_name: []const u8,
    struct_prototypes: []const StructPrototype,
    enum_prototypes: []const EnumPrototype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !types.TypeRef {
    const builtin = types.Builtin.fromName(type_name);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    if (c_va_list.isTypeName(type_name)) return .{ .named = c_va_list.type_name };
    if (dynamic_library.isTypeName(type_name)) return .{ .named = dynamic_library.type_name };
    if (types.CAbiAlias.fromName(type_name) != null) return .{ .named = type_name };
    if (rawPointerPointee(type_name) != null) return .{ .named = type_name };
    if (foreign_callable_types.startsForeignCallableType(type_name)) return .{ .named = type_name };
    const trimmed_type_name = std.mem.trim(u8, type_name, " \t");
    if (std.mem.startsWith(u8, trimmed_type_name, "Option[") or
        std.mem.startsWith(u8, trimmed_type_name, "Result["))
    {
        return .{ .named = type_name };
    }
    if (std.mem.startsWith(u8, trimmed_type_name, "[")) return .{ .named = type_name };
    if (try tuple_types.isTupleTypeName(diagnostics.allocator, type_name)) return .{ .named = type_name };
    if (findStructPrototype(struct_prototypes, type_name) != null) return .{ .named = type_name };
    if (findEnumPrototype(enum_prototypes, type_name) != null) return .{ .named = type_name };
    try diagnostics.add(.@"error", "type.binding.declared", span, "unsupported stage0 local binding type '{s}'", .{type_name});
    return .unsupported;
}

fn rawPointerPointee(raw_type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_type_name, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "*read ")) return std.mem.trim(u8, trimmed["*read ".len..], " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "*edit ")) return std.mem.trim(u8, trimmed["*edit ".len..], " \t\r\n");
    return null;
}

fn fixedArrayElementType(ty: types.TypeRef) ?types.TypeRef {
    const raw = switch (ty) {
        .named => |name| std.mem.trim(u8, name, " \t\r\n"),
        else => return null,
    };
    if (!std.mem.startsWith(u8, raw, "[")) return null;
    const close_index = findMatchingDelimiter(raw, 0, '[', ']') orelse return null;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t\r\n").len != 0) return null;
    const inner = raw[1..close_index];
    const separator = findTopLevelHeaderScalar(inner, ';') orelse return null;
    const element_name = std.mem.trim(u8, inner[0..separator], " \t\r\n");
    if (element_name.len == 0) return null;
    const builtin = types.Builtin.fromName(element_name);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = element_name };
}

fn simpleIndexTargetText(expr: *const ast.BodyExprSyntax) ?[]const u8 {
    return switch (expr.node) {
        .integer => |integer| std.mem.trim(u8, integer.text, " \t\r\n"),
        .name => |name| std.mem.trim(u8, name.text, " \t\r\n"),
        else => null,
    };
}

const NameSet = struct {
    allocator: Allocator,
    names: array_list.Managed([]const u8),

    fn init(allocator: Allocator) NameSet {
        return .{
            .allocator = allocator,
            .names = array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *NameSet) void {
        self.names.deinit();
    }

    fn put(self: *NameSet, name: []const u8) !void {
        if (self.contains(name)) return;
        try self.names.append(name);
    }

    pub fn contains(self: *const NameSet, name: []const u8) bool {
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }
};

pub const Scope = struct {
    allocator: Allocator,
    names: array_list.Managed([]const u8),
    types_list: array_list.Managed(types.TypeRef),
    mutable_list: array_list.Managed(bool),
    const_list: array_list.Managed(bool),
    origins: array_list.Managed(BoundaryType),

    pub fn init(allocator: Allocator) Scope {
        return .{
            .allocator = allocator,
            .names = array_list.Managed([]const u8).init(allocator),
            .types_list = array_list.Managed(types.TypeRef).init(allocator),
            .mutable_list = array_list.Managed(bool).init(allocator),
            .const_list = array_list.Managed(bool).init(allocator),
            .origins = array_list.Managed(BoundaryType).init(allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.names.deinit();
        self.types_list.deinit();
        self.mutable_list.deinit();
        self.const_list.deinit();
        self.origins.deinit();
    }

    pub fn extendFrom(self: *Scope, other: *const Scope) !void {
        for (other.names.items, other.types_list.items, other.mutable_list.items, other.const_list.items, other.origins.items) |name, ty, mutable, is_const, origin| {
            try self.putFull(name, ty, mutable, is_const, origin);
        }
    }

    fn put(self: *Scope, name: []const u8, ty: types.TypeRef, mutable: bool) !void {
        try self.putFull(name, ty, mutable, false, boundaryFromTypeRef(ty));
    }

    pub fn putConst(self: *Scope, name: []const u8, ty: types.TypeRef) !void {
        try self.putFull(name, ty, false, true, boundaryFromTypeRef(ty));
    }

    pub fn putWithOrigin(self: *Scope, name: []const u8, ty: types.TypeRef, mutable: bool, origin: BoundaryType) !void {
        try self.putFull(name, ty, mutable, false, origin);
    }

    fn putFull(self: *Scope, name: []const u8, ty: types.TypeRef, mutable: bool, is_const: bool, origin: BoundaryType) !void {
        try self.names.append(name);
        try self.types_list.append(ty);
        try self.mutable_list.append(mutable);
        try self.const_list.append(is_const);
        try self.origins.append(origin);
    }

    pub fn get(self: *const Scope, name: []const u8) ?types.TypeRef {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.types_list.items[index];
        }
        return null;
    }

    pub fn isMutable(self: *const Scope, name: []const u8) bool {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.mutable_list.items[index];
        }
        return false;
    }

    pub fn isConst(self: *const Scope, name: []const u8) bool {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.const_list.items[index];
        }
        return false;
    }

    pub fn getOrigin(self: *const Scope, name: []const u8) ?BoundaryType {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) return self.origins.items[index];
        }
        return null;
    }

    fn updateOrigin(self: *Scope, name: []const u8, origin: BoundaryType) void {
        var index = self.names.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.names.items[index], name)) {
                self.origins.items[index] = origin;
                return;
            }
        }
    }
};
