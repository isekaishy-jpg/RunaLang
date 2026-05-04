const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const cst = @import("../cst/root.zig");
const type_syntax_lower = @import("type_syntax_lower.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

const Range = struct {
    start: usize,
    end: usize,
};

pub fn lowerBlockBodySyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) anyerror!ast.BodyBlockSyntax {
    var statements = array_list.Managed(ast.BodyStatementSyntax).init(allocator);
    defer statements.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| {
                const kind = tree.nodeKind(node_id);
                switch (kind) {
                    .statement,
                    .select_statement,
                    .repeat_statement,
                    .return_statement,
                    .defer_statement,
                    .break_statement,
                    .continue_statement,
                    .unsafe_statement,
                    .@"error",
                    => try statements.append(try lowerStatement(allocator, file, tokens, tree, node_id)),
                    else => {},
                }
            },
            else => {},
        }
    }

    return .{
        .statements = try statements.toOwnedSlice(),
    };
}

pub fn lowerStandaloneExprSyntax(
    allocator: Allocator,
    span_text: ast.SpanText,
) anyerror!*ast.BodyExprSyntax {
    const normalized = normalizeLeadingUnsafeExpr(span_text);
    var line_starts = [_]usize{0};
    const fragment_file = source.File{
        .id = normalized.span.span.file_id,
        .path = "<expr>",
        .contents = normalized.span.text,
        .line_starts = line_starts[0..],
    };

    var lexed = try syntax.lexFile(allocator, &fragment_file);
    defer lexed.deinit(allocator);

    var tree = try cst.parseLexedExpression(allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(allocator);

    const expr = try lowerExprNode(allocator, &fragment_file, lexed.tokens, &tree, tree.root);
    expr.force_unsafe = normalized.force_unsafe;
    expr.span = normalized.span.span;
    return expr;
}

pub fn lowerStandalonePatternSyntax(
    allocator: Allocator,
    span_text: ast.SpanText,
) anyerror!*ast.BodyPatternSyntax {
    var line_starts = [_]usize{0};
    const fragment_file = source.File{
        .id = span_text.span.file_id,
        .path = "<pattern>",
        .contents = span_text.text,
        .line_starts = line_starts[0..],
    };

    var lexed = try syntax.lexFile(allocator, &fragment_file);
    defer lexed.deinit(allocator);

    var tree = try cst.parseLexedPattern(allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(allocator);

    return lowerPatternNode(allocator, &fragment_file, lexed.tokens, &tree, tree.root);
}

fn lowerStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    return switch (tree.nodeKind(node_id)) {
        .statement => lowerGenericStatement(allocator, file, tokens, tree, node_id),
        .select_statement => lowerSelectStatement(allocator, file, tokens, tree, node_id),
        .repeat_statement => lowerRepeatStatement(allocator, file, tokens, tree, node_id),
        .return_statement => lowerReturnStatement(allocator, file, tokens, tree, node_id),
        .defer_statement => lowerDeferStatement(allocator, file, tokens, tree, node_id),
        .break_statement => .break_stmt,
        .continue_statement => .continue_stmt,
        .unsafe_statement => lowerUnsafeStatement(allocator, file, tokens, tree, node_id),
        .@"error" => .{ .placeholder = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens) },
        else => .{ .placeholder = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens) },
    };
}

fn lowerGenericStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    if (firstExprChild(tree, node_id)) |expr_node| {
        return .{ .expr_stmt = try lowerExprNodeAllowingUnsafePrefix(allocator, file, tokens, tree, expr_node) };
    }

    const line_node = childNodeByKind(tree, node_id, .statement_line) orelse {
        return .{ .placeholder = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens) };
    };
    const line_text = spanTextForNode(file, tokens, tree, line_node) orelse emptySpanText(tokens);
    return lowerLineStatement(allocator, line_text);
}

fn lowerSelectStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    const select_stmt = try allocator.create(ast.BodyStatementSyntax.SelectStmt);
    errdefer allocator.destroy(select_stmt);
    select_stmt.* = .{};
    errdefer select_stmt.deinit(allocator);

    if (childNodeByKind(tree, node_id, .select_head)) |head_node| {
        if (firstNodeChild(tree, head_node)) |expr_node| {
            select_stmt.subject = try lowerExprNode(allocator, file, tokens, tree, expr_node);
        }
    }

    if (childNodeByKind(tree, node_id, .block)) |block_node| {
        var arms = array_list.Managed(ast.BodyStatementSyntax.SelectArm).init(allocator);
        defer arms.deinit();

        for (tree.childSlice(block_node)) |child| {
            switch (child) {
                .node => |arm_node| switch (tree.nodeKind(arm_node)) {
                    .when_arm => try arms.append(try lowerWhenArm(allocator, file, tokens, tree, arm_node, select_stmt.subject != null)),
                    .else_arm => {
                        const maybe_else = try lowerElseArm(allocator, file, tokens, tree, arm_node);
                        if (select_stmt.else_body == null) {
                            select_stmt.else_body = maybe_else;
                        } else {
                            maybe_else.deinit(allocator);
                            allocator.destroy(maybe_else);
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        select_stmt.arms = try arms.toOwnedSlice();
    }

    return .{ .select_stmt = select_stmt };
}

fn lowerWhenArm(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    subject_select: bool,
) anyerror!ast.BodyStatementSyntax.SelectArm {
    const head_node = childNodeByKind(tree, node_id, .arm_head) orelse {
        return .{
            .head = if (subject_select)
                .{ .pattern = try makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)) }
            else
                .{ .guard = try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)) },
            .body = try lowerArmBody(allocator, file, tokens, tree, node_id),
        };
    };

    return .{
        .head = if (subject_select)
            .{ .pattern = try lowerWrappedPatternNode(allocator, file, tokens, tree, head_node) }
        else
            .{ .guard = try lowerWrappedExprNode(allocator, file, tokens, tree, head_node) },
        .body = try lowerArmBody(allocator, file, tokens, tree, node_id),
    };
}

fn lowerElseArm(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyBlockSyntax {
    return lowerArmBody(allocator, file, tokens, tree, node_id);
}

fn lowerArmBody(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyBlockSyntax {
    const body = try allocator.create(ast.BodyBlockSyntax);
    errdefer allocator.destroy(body);
    body.* = .{};
    errdefer body.deinit(allocator);

    var statements = array_list.Managed(ast.BodyStatementSyntax).init(allocator);
    defer statements.deinit();

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| switch (tree.nodeKind(child_node)) {
                .statement,
                .select_statement,
                .repeat_statement,
                .return_statement,
                .defer_statement,
                .break_statement,
                .continue_statement,
                .unsafe_statement,
                .@"error",
                => try statements.append(try lowerStatement(allocator, file, tokens, tree, child_node)),
                .block => {
                    const nested = try lowerBlockBodySyntax(allocator, file, tokens, tree, child_node);
                    for (nested.statements) |statement| try statements.append(statement);
                    if (nested.statements.len != 0) allocator.free(nested.statements);
                },
                else => {},
            },
            else => {},
        }
    }

    body.* = .{
        .statements = try statements.toOwnedSlice(),
    };
    return body;
}

fn lowerRepeatStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    const repeat_stmt = try allocator.create(ast.BodyStatementSyntax.RepeatStmt);
    errdefer allocator.destroy(repeat_stmt);
    repeat_stmt.* = .{
        .body = try allocator.create(ast.BodyBlockSyntax),
    };
    errdefer allocator.destroy(repeat_stmt.body);
    repeat_stmt.body.* = .{};
    errdefer repeat_stmt.body.deinit(allocator);

    if (childNodeByKind(tree, node_id, .repeat_condition)) |condition_node| {
        repeat_stmt.header = .{ .while_condition = try lowerWrappedExprNode(allocator, file, tokens, tree, condition_node) };
    } else if (childNodeByKind(tree, node_id, .repeat_binding)) |binding_node| {
        if (childNodeByKind(tree, node_id, .repeat_iterable)) |iterable_node| {
            repeat_stmt.header = .{ .iteration = .{
                .binding = try lowerWrappedPatternNode(allocator, file, tokens, tree, binding_node),
                .iterable = try lowerWrappedExprNode(allocator, file, tokens, tree, iterable_node),
            } };
        }
    } else if (childNodeByKind(tree, node_id, .statement_line)) |raw_node| {
        repeat_stmt.header = .{ .invalid = spanTextForNode(file, tokens, tree, raw_node) orelse emptySpanText(tokens) };
    }

    if (childNodeByKind(tree, node_id, .block)) |block_node| {
        repeat_stmt.body.* = try lowerBlockBodySyntax(allocator, file, tokens, tree, block_node);
    }

    return .{ .repeat_stmt = repeat_stmt };
}

fn lowerReturnStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    if (firstExprChild(tree, node_id)) |expr_node| {
        return .{ .return_stmt = try lowerExprNodeAllowingUnsafePrefix(allocator, file, tokens, tree, expr_node) };
    }
    return .{ .return_stmt = null };
}

fn lowerDeferStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    if (firstExprChild(tree, node_id)) |expr_node| {
        return .{ .defer_stmt = try lowerExprNodeAllowingUnsafePrefix(allocator, file, tokens, tree, expr_node) };
    }
    return .{ .defer_stmt = try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)) };
}

fn lowerUnsafeStatement(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyStatementSyntax {
    if (childNodeByKind(tree, node_id, .block) == null) {
        return .{ .expr_stmt = try lowerStandaloneExprSyntax(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)) };
    }

    const body = try allocator.create(ast.BodyBlockSyntax);
    errdefer allocator.destroy(body);
    body.* = try lowerBlockBodySyntax(allocator, file, tokens, tree, childNodeByKind(tree, node_id, .block).?);
    errdefer body.deinit(allocator);
    return .{ .unsafe_block = body };
}

fn lowerLineStatement(allocator: Allocator, line_text: ast.SpanText) anyerror!ast.BodyStatementSyntax {
    const trimmed = trimSpanText(line_text) orelse return .{ .placeholder = line_text };

    if (std.mem.eql(u8, trimmed.text, "...")) {
        return .{ .placeholder = trimmed };
    }

    if (std.mem.startsWith(u8, trimmed.text, "let ")) {
        return lowerBindingStatement(allocator, trimmed, false);
    }

    if (std.mem.startsWith(u8, trimmed.text, "const ")) {
        return lowerBindingStatement(allocator, trimmed, true);
    }

    if (std.mem.startsWith(u8, trimmed.text, "defer ")) {
        const expr_text = trimSpanText(makeSubspanText(trimmed, "defer ".len, trimmed.text.len)) orelse return .{ .placeholder = trimmed };
        return .{ .defer_stmt = try lowerStandaloneExprSyntax(allocator, expr_text) };
    }

    if (findAssignmentOperator(trimmed.text)) |match| {
        return .{ .assign_stmt = .{
            .target = try lowerStandaloneExprSyntax(allocator, trimSpanText(makeSubspanText(trimmed, match.target.start, match.target.end)) orelse trimmed),
            .op = match.op,
            .expr = try lowerStandaloneExprSyntax(allocator, trimSpanText(makeSubspanText(trimmed, match.expr.start, match.expr.end)) orelse trimmed),
        } };
    }

    return .{ .expr_stmt = try lowerStandaloneExprSyntax(allocator, trimmed) };
}

fn lowerBindingStatement(
    allocator: Allocator,
    line_text: ast.SpanText,
    is_const: bool,
) anyerror!ast.BodyStatementSyntax {
    const raw = if (is_const) line_text.text["const ".len..] else line_text.text["let ".len..];
    const base = makeSubspanText(line_text, if (is_const) "const ".len else "let ".len, line_text.text.len);
    const equal_index = findTopLevelAssignmentEqual(raw) orelse return .{ .placeholder = line_text };

    const left_trimmed = trimSpanText(makeSubspanText(base, 0, equal_index)) orelse return .{ .placeholder = line_text };
    const expr_trimmed = trimSpanText(makeSubspanText(base, equal_index + 1, raw.len)) orelse return .{ .placeholder = line_text };

    var name_text = left_trimmed;
    var declared_type: ?ast.TypeSyntax = null;
    if (findTopLevelColon(left_trimmed.text)) |colon_index| {
        name_text = trimSpanText(makeSubspanText(left_trimmed, 0, colon_index)) orelse left_trimmed;
        const raw_declared_type = makeSubspanText(left_trimmed, colon_index + 1, left_trimmed.text.len);
        if (trimSpanText(raw_declared_type)) |type_text| {
            declared_type = try type_syntax_lower.lowerStandaloneTypeSyntax(allocator, type_text);
        } else {
            declared_type = try type_syntax_lower.invalidTypeSyntax(
                allocator,
                .{
                    .text = "",
                    .span = .{
                        .file_id = raw_declared_type.span.file_id,
                        .start = raw_declared_type.span.start,
                        .end = raw_declared_type.span.start,
                    },
                },
            );
        }
    }

    const binding: ast.BodyStatementSyntax.BindingDecl = .{
        .name = name_text,
        .declared_type = declared_type,
        .expr = try lowerStandaloneExprSyntax(allocator, expr_trimmed),
    };

    return if (is_const)
        .{ .const_decl = binding }
    else
        .{ .let_decl = binding };
}

fn lowerExprNode(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyExprSyntax {
    return switch (tree.nodeKind(node_id)) {
        .expr_name => makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .name = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .expr_integer => makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .integer = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .expr_string => makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .string = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .expr_group => blk: {
            const child = firstExprChild(tree, node_id) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
                .group = try lowerExprNode(allocator, file, tokens, tree, child),
            });
        },
        .expr_tuple => blk: {
            const items = try lowerExprNodeSlice(allocator, file, tokens, tree, node_id);
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .tuple = items });
        },
        .expr_array => blk: {
            const items = try lowerExprNodeSlice(allocator, file, tokens, tree, node_id);
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .array = items });
        },
        .expr_array_repeat => blk: {
            const value = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const length = nthExprChild(tree, node_id, 1) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .array_repeat = .{
                .value = try lowerExprNode(allocator, file, tokens, tree, value),
                .length = try lowerExprNode(allocator, file, tokens, tree, length),
            } });
        },
        .expr_raw_pointer => blk: {
            const mode = nthTokenSpanText(file, tokens, tree, node_id, 2) orelse emptySpanText(tokens);
            const place = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .raw_pointer = .{
                .mode = mode,
                .place = try lowerExprNode(allocator, file, tokens, tree, place),
            } });
        },
        .expr_unary => blk: {
            const operator = firstTokenSpanText(file, tokens, tree, node_id) orelse emptySpanText(tokens);
            const operand = firstExprChild(tree, node_id) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .unary = .{
                .operator = operator,
                .operand = try lowerExprNode(allocator, file, tokens, tree, operand),
            } });
        },
        .expr_binary => blk: {
            const lhs = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const rhs = nthExprChild(tree, node_id, 1) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const operator = nthTokenSpanText(file, tokens, tree, node_id, 0) orelse emptySpanText(tokens);
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .binary = .{
                .operator = operator,
                .lhs = try lowerExprNode(allocator, file, tokens, tree, lhs),
                .rhs = try lowerExprNode(allocator, file, tokens, tree, rhs),
            } });
        },
        .expr_field => blk: {
            const base = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const field_name = lastTokenSpanText(file, tokens, tree, node_id) orelse emptySpanText(tokens);
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .field = .{
                .base = try lowerExprNode(allocator, file, tokens, tree, base),
                .field_name = field_name,
            } });
        },
        .expr_index => blk: {
            const base = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const index_expr = nthExprChild(tree, node_id, 1) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .index = .{
                .base = try lowerExprNode(allocator, file, tokens, tree, base),
                .index = try lowerExprNode(allocator, file, tokens, tree, index_expr),
            } });
        },
        .expr_call => blk: {
            const callee = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const args_node = nthNodeChild(tree, node_id, 1) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .call = .{
                .callee = try lowerExprNode(allocator, file, tokens, tree, callee),
                .args = try lowerExprArgumentSlice(allocator, file, tokens, tree, args_node),
            } });
        },
        .expr_method_call => blk: {
            const callee = nthExprChild(tree, node_id, 0) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const args_node = nthNodeChild(tree, node_id, 1) orelse break :blk try makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            break :blk makeExpr(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .method_call = .{
                .callee = try lowerExprNode(allocator, file, tokens, tree, callee),
                .args = try lowerExprArgumentSlice(allocator, file, tokens, tree, args_node),
            } });
        },
        .@"error" => makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)),
        else => makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)),
    };
}

fn lowerWrappedExprNode(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyExprSyntax {
    if (firstNodeChild(tree, node_id)) |child| return lowerExprNode(allocator, file, tokens, tree, child);
    return makeErrorExpr(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
}

fn lowerExprNodeAllowingUnsafePrefix(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyExprSyntax {
    const text = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens);
    if (normalizeLeadingUnsafeExpr(text).force_unsafe) {
        return lowerStandaloneExprSyntax(allocator, text);
    }
    return lowerExprNode(allocator, file, tokens, tree, node_id);
}

fn lowerExprNodeSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror![]*ast.BodyExprSyntax {
    var items = array_list.Managed(*ast.BodyExprSyntax).init(allocator);
    defer items.deinit();

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| switch (tree.nodeKind(child_node)) {
                .expr_name,
                .expr_integer,
                .expr_string,
                .expr_group,
                .expr_tuple,
                .expr_array,
                .expr_array_repeat,
                .expr_raw_pointer,
                .expr_unary,
                .expr_binary,
                .expr_field,
                .expr_index,
                .expr_call,
                .expr_method_call,
                .@"error",
                => try items.append(try lowerExprNode(allocator, file, tokens, tree, child_node)),
                else => {},
            },
            else => {},
        }
    }

    return try items.toOwnedSlice();
}

fn lowerExprArgumentSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror![]*ast.BodyExprSyntax {
    return lowerExprNodeSlice(allocator, file, tokens, tree, node_id);
}

fn lowerPatternNode(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyPatternSyntax {
    return switch (tree.nodeKind(node_id)) {
        .pattern_wildcard => makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .wildcard),
        .pattern_binding => makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .binding = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .pattern_integer => makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .integer = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .pattern_string => makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{
            .string = spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens),
        }),
        .pattern_tuple => blk: {
            const items = try lowerPatternNodeSlice(allocator, file, tokens, tree, node_id);
            break :blk makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .tuple = items });
        },
        .pattern_struct => blk: {
            const name_node = nthNodeChild(tree, node_id, 0) orelse break :blk try makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const payload = if (nthNodeChild(tree, node_id, 1)) |payload_node|
                try lowerAggregatePayload(allocator, file, tokens, tree, payload_node)
            else
                ast.BodyPatternSyntax.AggregatePayload.none;
            break :blk makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .struct_pattern = .{
                .name = spanTextForNode(file, tokens, tree, name_node) orelse emptySpanText(tokens),
                .payload = payload,
            } });
        },
        .pattern_variant => blk: {
            const name_node = nthNodeChild(tree, node_id, 0) orelse break :blk try makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
            const payload = if (nthNodeChild(tree, node_id, 1)) |payload_node|
                try lowerAggregatePayload(allocator, file, tokens, tree, payload_node)
            else
                ast.BodyPatternSyntax.AggregatePayload.none;
            break :blk makePattern(allocator, nodeSpan(tokens, tree, node_id) orelse zeroSpan(tokens), .{ .variant_pattern = .{
                .name = spanTextForNode(file, tokens, tree, name_node) orelse emptySpanText(tokens),
                .payload = payload,
            } });
        },
        .@"error" => makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)),
        else => makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens)),
    };
}

fn lowerWrappedPatternNode(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!*ast.BodyPatternSyntax {
    if (firstNodeChild(tree, node_id)) |child| return lowerPatternNode(allocator, file, tokens, tree, child);
    return makeErrorPattern(allocator, spanTextForNode(file, tokens, tree, node_id) orelse emptySpanText(tokens));
}

fn lowerPatternNodeSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror![]*ast.BodyPatternSyntax {
    var items = array_list.Managed(*ast.BodyPatternSyntax).init(allocator);
    defer items.deinit();

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| switch (tree.nodeKind(child_node)) {
                .pattern_wildcard,
                .pattern_binding,
                .pattern_integer,
                .pattern_string,
                .pattern_tuple,
                .pattern_struct,
                .pattern_variant,
                .@"error",
                => try items.append(try lowerPatternNode(allocator, file, tokens, tree, child_node)),
                else => {},
            },
            else => {},
        }
    }

    return try items.toOwnedSlice();
}

fn lowerAggregatePayload(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!ast.BodyPatternSyntax.AggregatePayload {
    return switch (tree.nodeKind(node_id)) {
        .pattern_tuple => .{ .tuple = try lowerPatternNodeSlice(allocator, file, tokens, tree, node_id) },
        .pattern_field_list => .{ .fields = try lowerPatternFieldSlice(allocator, file, tokens, tree, node_id) },
        else => .none,
    };
}

fn lowerPatternFieldSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror![]ast.BodyPatternSyntax.Field {
    var fields = array_list.Managed(ast.BodyPatternSyntax.Field).init(allocator);
    defer fields.deinit();

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |field_node| {
                if (tree.nodeKind(field_node) != .pattern_field) continue;
                const name = firstTokenSpanText(file, tokens, tree, field_node) orelse emptySpanText(tokens);
                const pattern = firstNodeChild(tree, field_node) orelse {
                    try fields.append(.{
                        .name = name,
                        .pattern = try makeErrorPattern(allocator, name),
                    });
                    continue;
                };
                try fields.append(.{
                    .name = name,
                    .pattern = try lowerPatternNode(allocator, file, tokens, tree, pattern),
                });
            },
            else => {},
        }
    }

    return try fields.toOwnedSlice();
}

fn makeExpr(allocator: Allocator, span: source.Span, node: ast.BodyExprSyntax.Node) anyerror!*ast.BodyExprSyntax {
    const expr = try allocator.create(ast.BodyExprSyntax);
    expr.* = .{
        .span = span,
        .node = node,
    };
    return expr;
}

fn makeErrorExpr(allocator: Allocator, span_text: ast.SpanText) anyerror!*ast.BodyExprSyntax {
    return makeExpr(allocator, span_text.span, .{ .@"error" = span_text });
}

fn makePattern(allocator: Allocator, span: source.Span, node: ast.BodyPatternSyntax.Node) anyerror!*ast.BodyPatternSyntax {
    const pattern = try allocator.create(ast.BodyPatternSyntax);
    pattern.* = .{
        .span = span,
        .node = node,
    };
    return pattern;
}

fn makeErrorPattern(allocator: Allocator, span_text: ast.SpanText) anyerror!*ast.BodyPatternSyntax {
    return makePattern(allocator, span_text.span, .{ .@"error" = span_text });
}

fn firstNodeChild(tree: *const cst.Tree, node_id: cst.NodeId) ?cst.NodeId {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| return child_node,
            else => {},
        }
    }
    return null;
}

fn nthNodeChild(tree: *const cst.Tree, node_id: cst.NodeId, target_index: usize) ?cst.NodeId {
    var count: usize = 0;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| {
                if (count == target_index) return child_node;
                count += 1;
            },
            else => {},
        }
    }
    return null;
}

fn childNodeByKind(tree: *const cst.Tree, node_id: cst.NodeId, kind: cst.NodeKind) ?cst.NodeId {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| if (tree.nodeKind(child_node) == kind) return child_node,
            else => {},
        }
    }
    return null;
}

fn firstExprChild(tree: *const cst.Tree, node_id: cst.NodeId) ?cst.NodeId {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| switch (tree.nodeKind(child_node)) {
                .expr_name,
                .expr_integer,
                .expr_string,
                .expr_group,
                .expr_tuple,
                .expr_array,
                .expr_array_repeat,
                .expr_raw_pointer,
                .expr_unary,
                .expr_binary,
                .expr_field,
                .expr_index,
                .expr_call,
                .expr_method_call,
                .@"error",
                => return child_node,
                else => {},
            },
            else => {},
        }
    }
    return null;
}

fn nthExprChild(tree: *const cst.Tree, node_id: cst.NodeId, target_index: usize) ?cst.NodeId {
    var count: usize = 0;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| switch (tree.nodeKind(child_node)) {
                .expr_name,
                .expr_integer,
                .expr_string,
                .expr_group,
                .expr_tuple,
                .expr_array,
                .expr_array_repeat,
                .expr_raw_pointer,
                .expr_unary,
                .expr_binary,
                .expr_field,
                .expr_index,
                .expr_call,
                .expr_method_call,
                .@"error",
                => {
                    if (count == target_index) return child_node;
                    count += 1;
                },
                else => {},
            },
            else => {},
        }
    }
    return null;
}

fn firstTokenSpanText(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ?ast.SpanText {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .token => |token_id| return tokenSpanText(file, tokens, token_id),
            else => {},
        }
    }
    return null;
}

fn nthTokenSpanText(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    target_index: usize,
) ?ast.SpanText {
    var count: usize = 0;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .token => |token_id| {
                if (count == target_index) return tokenSpanText(file, tokens, token_id);
                count += 1;
            },
            else => {},
        }
    }
    return null;
}

fn lastTokenSpanText(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ?ast.SpanText {
    const children = tree.childSlice(node_id);
    var index = children.len;
    while (index != 0) {
        index -= 1;
        switch (children[index]) {
            .token => |token_id| return tokenSpanText(file, tokens, token_id),
            else => {},
        }
    }
    return null;
}

fn tokenSpanText(file: *const source.File, tokens: syntax.TokenStore, token_id: cst.TokenId) ast.SpanText {
    const token = tokens.getRef(token_id);
    return .{
        .text = file.contents[token.span.start..token.span.end],
        .span = token.span,
    };
}

fn spanTextForNode(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ?ast.SpanText {
    const span = nodeSpan(tokens, tree, node_id) orelse return null;
    return .{
        .text = trimTrailingLineEnding(file.contents[span.start..span.end]),
        .span = .{
            .file_id = span.file_id,
            .start = span.start,
            .end = span.start + trimTrailingLineEnding(file.contents[span.start..span.end]).len,
        },
    };
}

fn nodeSpan(tokens: syntax.TokenStore, tree: *const cst.Tree, node_id: cst.NodeId) ?source.Span {
    const first_token = tree.firstTokenRef(node_id) orelse return null;
    const last_token = tree.lastTokenRef(node_id) orelse return null;
    const first_span = tokens.getRef(first_token).span;
    const last_span = tokens.getRef(last_token).span;
    return .{
        .file_id = first_span.file_id,
        .start = first_span.start,
        .end = last_span.end,
    };
}

fn trimTrailingLineEnding(raw: []const u8) []const u8 {
    var trimmed = raw;
    while (trimmed.len != 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

fn trimSpanText(span_text: ast.SpanText) ?ast.SpanText {
    const range = trimmedRange(span_text.text) orelse return null;
    return makeSubspanText(span_text, range.start, range.end);
}

fn makeSubspanText(base: ast.SpanText, start: usize, end: usize) ast.SpanText {
    return .{
        .text = base.text[start..end],
        .span = .{
            .file_id = base.span.file_id,
            .start = base.span.start + start,
            .end = base.span.start + end,
        },
    };
}

fn trimmedRange(raw: []const u8) ?Range {
    var start: usize = 0;
    var end = raw.len;
    while (start < end and (raw[start] == ' ' or raw[start] == '\t')) : (start += 1) {}
    while (end > start and (raw[end - 1] == ' ' or raw[end - 1] == '\t')) : (end -= 1) {}
    if (start == end) return null;
    return .{ .start = start, .end = end };
}

fn findTopLevelAssignmentEqual(raw: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        switch (raw[index]) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth != 0) brace_depth -= 1;
            },
            '=' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0) continue;
                if (index > 0 and raw[index - 1] == '=') continue;
                if (index + 1 < raw.len and (raw[index + 1] == '=' or raw[index + 1] == '>')) continue;
                return index;
            },
            else => {},
        }
    }
    return null;
}

fn findTopLevelColon(raw: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (raw, 0..) |byte, index| {
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth != 0) brace_depth -= 1;
            },
            ':' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and (index + 1 >= raw.len or raw[index + 1] != ':')) return index;
            },
            else => {},
        }
    }
    return null;
}

const AssignmentMatch = struct {
    target: Range,
    expr: Range,
    op: ?ast.AssignOpSyntax,
};

fn findAssignmentOperator(raw: []const u8) ?AssignmentMatch {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        switch (raw[index]) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth != 0) brace_depth -= 1;
            },
            '=' => {
                if (paren_depth != 0 or bracket_depth != 0 or brace_depth != 0) continue;
                if (index > 0) {
                    const previous = raw[index - 1];
                    if (previous == '=' or previous == '!') continue;
                    if (previous == '<' and !(index > 1 and raw[index - 2] == '<')) continue;
                    if (previous == '>' and !(index > 1 and raw[index - 2] == '>')) continue;
                }
                if (index + 1 < raw.len and (raw[index + 1] == '=' or raw[index + 1] == '>')) continue;

                var target_end = index;
                var op: ?ast.AssignOpSyntax = null;
                if (index > 0) {
                    switch (raw[index - 1]) {
                        '+' => {
                            target_end -= 1;
                            op = .add;
                        },
                        '-' => {
                            target_end -= 1;
                            op = .sub;
                        },
                        '*' => {
                            target_end -= 1;
                            op = .mul;
                        },
                        '/' => {
                            target_end -= 1;
                            op = .div;
                        },
                        '%' => {
                            target_end -= 1;
                            op = .mod;
                        },
                        '&' => {
                            target_end -= 1;
                            op = .bit_and;
                        },
                        '^' => {
                            target_end -= 1;
                            op = .bit_xor;
                        },
                        '|' => {
                            target_end -= 1;
                            op = .bit_or;
                        },
                        '<' => {
                            if (index > 1 and raw[index - 2] == '<') {
                                target_end -= 2;
                                op = .shl;
                            }
                        },
                        '>' => {
                            if (index > 1 and raw[index - 2] == '>') {
                                target_end -= 2;
                                op = .shr;
                            }
                        },
                        else => {},
                    }
                }

                return .{
                    .target = .{ .start = 0, .end = target_end },
                    .expr = .{ .start = index + 1, .end = raw.len },
                    .op = op,
                };
            },
            else => {},
        }
    }
    return null;
}

fn emptySpanText(tokens: syntax.TokenStore) ast.SpanText {
    return .{
        .text = "",
        .span = zeroSpan(tokens),
    };
}

fn zeroSpan(tokens: syntax.TokenStore) source.Span {
    return .{
        .file_id = if (tokens.len() != 0) tokens.get(0).span.file_id else 0,
        .start = 0,
        .end = 0,
    };
}

const NormalizedUnsafeExpr = struct {
    span: ast.SpanText,
    force_unsafe: bool,
};

fn normalizeLeadingUnsafeExpr(span_text: ast.SpanText) NormalizedUnsafeExpr {
    var current = trimSpanText(span_text) orelse span_text;
    var force_unsafe = false;

    while (std.mem.startsWith(u8, current.text, "#unsafe")) {
        const rest = current.text["#unsafe".len..];
        if (rest.len == 0) break;
        if (rest[0] != ' ' and rest[0] != '\t') break;
        force_unsafe = true;
        current = trimSpanText(makeSubspanText(current, "#unsafe".len, current.text.len)) orelse current;
    }

    return .{
        .span = current,
        .force_unsafe = force_unsafe,
    };
}
