const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const block_syntax_lower = @import("block_syntax_lower.zig");
const body_syntax_lower = @import("body_syntax_lower.zig");
const type_syntax_lower = @import("type_syntax_lower.zig");
const cst = @import("../cst/root.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

pub fn lowerItemSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) !ast.ItemSyntax {
    const declaration_kind = tree.nodeKind(declaration_node);
    const header_node = try childNodeAt(tree, declaration_node, 0);
    const signature_node = try childNodeAt(tree, header_node, 0);
    const where_clauses = try lowerWhereClauses(allocator, file, tokens, tree, header_node);
    errdefer freeWhereClauseSlice(allocator, where_clauses);

    return switch (declaration_kind) {
        .function_item, .suspend_function_item, .foreign_function_item => .{
            .function = try lowerFunctionSignature(allocator, file, tokens, tree, signature_node, where_clauses),
        },
        .const_item => .{
            .const_item = .{
                .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
                .ty = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .const_type),
                .initializer = spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer),
                .initializer_expr = if (spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer)) |initializer|
                    try body_syntax_lower.lowerStandaloneExprSyntax(allocator, initializer)
                else
                    null,
            },
        },
        .type_alias_item => .{
        .type_alias = .{
            .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
            .generic_params = try lowerGenericParamListForChildKind(allocator, file, tokens, tree, signature_node, .generic_param_list),
            .target = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .type_alias_value),
            .where_clauses = where_clauses,
        },
        },
        .module_item, .struct_item, .enum_item, .union_item, .trait_item, .opaque_type_item => .{
            .named_decl = .{
                .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
                .generic_params = try lowerGenericParamListForChildKind(allocator, file, tokens, tree, signature_node, .generic_param_list),
                .where_clauses = where_clauses,
            },
        },
        .impl_item => .{
            .impl_block = .{
                .generic_params = try lowerGenericParamListForChildKind(allocator, file, tokens, tree, signature_node, .generic_param_list),
                .trait_name = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .impl_trait_name),
                .target_type = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .impl_target_type),
                .where_clauses = where_clauses,
            },
        },
        else => .none,
    };
}

pub fn lowerUseBindings(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) ![]ast.UseBindingSyntax {
    const header_node = try childNodeAt(tree, declaration_node, 0);
    const signature_node = try childNodeAt(tree, header_node, 0);
    const path_node = childNodeByKind(tree, signature_node, .use_path) orelse return &.{};
    const path_text = spanTextForNode(file, tokens, tree, path_node) orelse return &.{};
    const alias_text = if (childNodeByKind(tree, signature_node, .use_alias)) |alias_node|
        spanTextForNode(file, tokens, tree, alias_node)
    else
        null;

    if (std.mem.indexOfScalar(u8, path_text.text, '{') == null) {
        const binding = lowerSimpleUse(path_text, alias_text);
        return try allocator.dupe(ast.UseBindingSyntax, &.{binding});
    }

    return try lowerGroupedUseBindings(allocator, path_text);
}

pub fn lowerItemBodySyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) !ast.ItemBodySyntax {
    const body_node = childNodeAt(tree, declaration_node, 1) catch return .none;
    const declaration_kind = tree.nodeKind(declaration_node);

    return switch (declaration_kind) {
        .struct_item => .{ .struct_fields = try lowerFieldSlice(allocator, file, tokens, tree, body_node) },
        .union_item => .{ .union_fields = try lowerFieldSlice(allocator, file, tokens, tree, body_node) },
        .enum_item => .{ .enum_variants = try lowerEnumVariantSlice(allocator, file, tokens, tree, body_node) },
        .trait_item => .{ .trait_body = try lowerTraitBody(allocator, file, tokens, tree, body_node) },
        .impl_item => .{ .impl_body = try lowerImplBody(allocator, file, tokens, tree, body_node) },
        else => .none,
    };
}

fn lowerFunctionSignature(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    signature_node: cst.NodeId,
    where_clauses: []ast.WhereClauseSyntax,
) !ast.FunctionSignatureSyntax {
    return .{
        .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
        .generic_params = try lowerGenericParamListForChildKind(allocator, file, tokens, tree, signature_node, .generic_param_list),
        .parameters = try lowerParameters(allocator, file, tokens, tree, signature_node),
        .return_type = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .return_type),
        .where_clauses = where_clauses,
        .foreign_abi = spanTextForChildKind(file, tokens, tree, signature_node, .foreign_abi),
    };
}

fn lowerFieldSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) ![]ast.FieldDeclSyntax {
    var fields = array_list.Managed(ast.FieldDeclSyntax).init(allocator);
    defer fields.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| {
                if (tree.nodeKind(node_id) != .field_decl) continue;
                try fields.append(.{
                    .visibility = lowerVisibility(file, tokens, tree, node_id),
                    .name = spanTextForChildKind(file, tokens, tree, node_id, .field_name),
                    .ty = try typeSyntaxForChildKind(allocator, file, tokens, tree, node_id, .field_type),
                });
            },
            else => {},
        }
    }

    return try fields.toOwnedSlice();
}

fn lowerEnumVariantSlice(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) ![]ast.EnumVariantSyntax {
    var variants = array_list.Managed(ast.EnumVariantSyntax).init(allocator);
    defer variants.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| {
                if (tree.nodeKind(node_id) != .variant_decl) continue;
                try variants.append(try lowerEnumVariant(allocator, file, tokens, tree, node_id));
            },
            else => {},
        }
    }

    return try variants.toOwnedSlice();
}

fn lowerEnumVariant(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    variant_node: cst.NodeId,
) !ast.EnumVariantSyntax {
    const discriminant = spanTextForChildKind(file, tokens, tree, variant_node, .variant_discriminant);
    return .{
        .name = spanTextForChildKind(file, tokens, tree, variant_node, .variant_name),
        .tuple_payload = try lowerTuplePayloadSyntax(file, tokens, tree, variant_node, .variant_tuple_payload, allocator),
        .discriminant_source = discriminant,
        .discriminant_expr = if (discriminant) |expr| try body_syntax_lower.lowerStandaloneExprSyntax(allocator, expr) else null,
        .named_fields = if (childNodeByKind(tree, variant_node, .block)) |block_node|
            try lowerFieldSlice(allocator, file, tokens, tree, block_node)
        else
            &.{},
    };
}

fn lowerTraitBody(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) !ast.TraitBodySyntax {
    var methods = array_list.Managed(ast.MethodDeclSyntax).init(allocator);
    defer methods.deinit();
    var associated_types = array_list.Managed(ast.AssociatedTypeDeclSyntax).init(allocator);
    defer associated_types.deinit();
    var associated_consts = array_list.Managed(ast.ConstSignatureSyntax).init(allocator);
    errdefer {
        for (associated_consts.items) |*const_item| const_item.deinit(allocator);
    }
    defer associated_consts.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| switch (tree.nodeKind(node_id)) {
                .associated_type_decl => try associated_types.append(try lowerAssociatedType(allocator, file, tokens, tree, node_id)),
                .const_item => try associated_consts.append(try lowerAssociatedConst(allocator, file, tokens, tree, node_id)),
                .function_item, .suspend_function_item => try methods.append(try lowerMethodDecl(allocator, file, tokens, tree, node_id)),
                else => {},
            },
            else => {},
        }
    }

    return .{
        .methods = try methods.toOwnedSlice(),
        .associated_types = try associated_types.toOwnedSlice(),
        .associated_consts = try associated_consts.toOwnedSlice(),
    };
}

fn lowerImplBody(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) !ast.ImplBodySyntax {
    var methods = array_list.Managed(ast.MethodDeclSyntax).init(allocator);
    defer methods.deinit();
    var associated_types = array_list.Managed(ast.AssociatedTypeDeclSyntax).init(allocator);
    defer associated_types.deinit();
    var associated_consts = array_list.Managed(ast.ConstSignatureSyntax).init(allocator);
    errdefer {
        for (associated_consts.items) |*const_item| const_item.deinit(allocator);
    }
    defer associated_consts.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| switch (tree.nodeKind(node_id)) {
                .associated_type_decl => try associated_types.append(try lowerAssociatedType(allocator, file, tokens, tree, node_id)),
                .const_item => try associated_consts.append(try lowerAssociatedConst(allocator, file, tokens, tree, node_id)),
                .function_item, .suspend_function_item => try methods.append(try lowerMethodDecl(allocator, file, tokens, tree, node_id)),
                else => {},
            },
            else => {},
        }
    }

    return .{
        .methods = try methods.toOwnedSlice(),
        .associated_types = try associated_types.toOwnedSlice(),
        .associated_consts = try associated_consts.toOwnedSlice(),
    };
}

fn lowerAssociatedConst(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) !ast.ConstSignatureSyntax {
    const header_node = try childNodeAt(tree, declaration_node, 0);
    const signature_node = try childNodeAt(tree, header_node, 0);
    return lowerConstSignature(allocator, file, tokens, tree, signature_node);
}

fn lowerConstSignature(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    signature_node: cst.NodeId,
) !ast.ConstSignatureSyntax {
    return .{
        .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
        .ty = try typeSyntaxForChildKind(allocator, file, tokens, tree, signature_node, .const_type),
        .initializer = spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer),
        .initializer_expr = if (spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer)) |initializer|
            try body_syntax_lower.lowerStandaloneExprSyntax(allocator, initializer)
        else
            null,
    };
}

fn lowerAssociatedType(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) !ast.AssociatedTypeDeclSyntax {
    return .{
        .name = spanTextForChildKind(file, tokens, tree, node_id, .item_name),
        .value = try typeSyntaxForChildKind(allocator, file, tokens, tree, node_id, .associated_type_value),
    };
}

fn lowerMethodDecl(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) !ast.MethodDeclSyntax {
    const header_node = try childNodeAt(tree, declaration_node, 0);
    const signature_node = try childNodeAt(tree, header_node, 0);
    const where_clauses = try lowerWhereClauses(allocator, file, tokens, tree, header_node);
    errdefer freeWhereClauseSlice(allocator, where_clauses);
    const body_node = childNodeAt(tree, declaration_node, 1) catch null;

    return .{
        .span = nodeSpan(tokens, tree, declaration_node) orelse source.Span{
            .file_id = file.id,
            .start = 0,
            .end = 0,
        },
        .is_suspend = tree.nodeKind(declaration_node) == .suspend_function_item,
        .signature = try lowerFunctionSignature(allocator, file, tokens, tree, signature_node, where_clauses),
        .block_syntax = if (body_node) |node_id| try block_syntax_lower.lowerBlockSyntax(allocator, file, tokens, tree, node_id) else null,
    };
}

fn lowerParameters(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    signature_node: cst.NodeId,
) ![]ast.ParameterSyntax {
    const parameter_list_node = childNodeByKind(tree, signature_node, .parameter_list) orelse return &.{};

    var parameters = array_list.Managed(ast.ParameterSyntax).init(allocator);
    defer parameters.deinit();

    for (tree.childSlice(parameter_list_node)) |child| {
        switch (child) {
            .node => |parameter_node| {
                if (tree.nodeKind(parameter_node) != .parameter) continue;
                try parameters.append(.{
                    .mode = lowerParameterModeForChildKind(file, tokens, tree, parameter_node, .parameter_mode),
                    .name = spanTextForChildKind(file, tokens, tree, parameter_node, .parameter_name),
                    .ty = try typeSyntaxForChildKind(allocator, file, tokens, tree, parameter_node, .parameter_type),
                });
            },
            else => {},
        }
    }

    return try parameters.toOwnedSlice();
}

fn lowerWhereClauses(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    header_node: cst.NodeId,
 ) ![]ast.WhereClauseSyntax {
    var clauses = array_list.Managed(ast.WhereClauseSyntax).init(allocator);
    defer clauses.deinit();

    for (tree.childSlice(header_node)) |child| {
        switch (child) {
            .node => |child_node| {
                if (tree.nodeKind(child_node) != .where_clause) continue;
                try clauses.append(try lowerWhereClauseSyntax(allocator, file, tokens, tree, child_node));
            },
            else => {},
        }
    }

    return try clauses.toOwnedSlice();
}

fn lowerSimpleUse(path_text: ast.SpanText, alias_text: ?ast.SpanText) ast.UseBindingSyntax {
    if (std.mem.lastIndexOfScalar(u8, path_text.text, '.')) |dot_index| {
        return .{
            .prefix = makeSubspanText(path_text, 0, dot_index),
            .leaf = makeSubspanText(path_text, dot_index + 1, path_text.text.len),
            .alias = alias_text,
        };
    }
    return .{
        .leaf = path_text,
        .alias = alias_text,
    };
}

fn lowerGroupedUseBindings(allocator: Allocator, path_text: ast.SpanText) ![]ast.UseBindingSyntax {
    const open_index = std.mem.indexOfScalar(u8, path_text.text, '{') orelse return &.{};
    const close_index = std.mem.lastIndexOfScalar(u8, path_text.text, '}') orelse return &.{};
    if (close_index <= open_index) return &.{};

    const prefix_raw = trimHorizontal(path_text.text[0..open_index]);
    const prefix_without_dot = if (prefix_raw.len != 0 and prefix_raw[prefix_raw.len - 1] == '.')
        prefix_raw[0 .. prefix_raw.len - 1]
    else
        prefix_raw;
    const prefix_offset = prefixRawOffset(path_text.text[0..open_index], prefix_without_dot);
    const prefix = if (prefix_without_dot.len == 0)
        null
    else
        makeSubspanText(path_text, prefix_offset, prefix_offset + prefix_without_dot.len);

    var bindings = array_list.Managed(ast.UseBindingSyntax).init(allocator);
    defer bindings.deinit();

    const inner_start = open_index + 1;
    const inner = path_text.text[inner_start..close_index];
    var entry_start: usize = 0;
    while (entry_start < inner.len) {
        var entry_end = entry_start;
        while (entry_end < inner.len and inner[entry_end] != ',') : (entry_end += 1) {}

        const raw_entry = inner[entry_start..entry_end];
        if (trimmedRange(raw_entry)) |entry_range| {
            const entry_base = inner_start + entry_start + entry_range.start;
            const entry_text = raw_entry[entry_range.start..entry_range.end];
            if (std.mem.indexOf(u8, entry_text, " as ")) |alias_index| {
                const leaf_text = trimHorizontal(entry_text[0..alias_index]);
                const alias_slice = trimHorizontal(entry_text[alias_index + " as ".len ..]);
                const leaf_offset = entry_base + leadingTrimCount(entry_text[0..alias_index]);
                const alias_offset = entry_base + alias_index + " as ".len + leadingTrimCount(entry_text[alias_index + " as ".len ..]);
                try bindings.append(.{
                    .prefix = prefix,
                    .leaf = if (leaf_text.len == 0) null else makeSubspanText(path_text, leaf_offset, leaf_offset + leaf_text.len),
                    .alias = if (alias_slice.len == 0) null else makeSubspanText(path_text, alias_offset, alias_offset + alias_slice.len),
                });
            } else {
                const leaf_offset = entry_base + leadingTrimCount(entry_text);
                try bindings.append(.{
                    .prefix = prefix,
                    .leaf = makeSubspanText(path_text, leaf_offset, leaf_offset + trimHorizontal(entry_text).len),
                });
            }
        }

        entry_start = entry_end + 1;
    }

    return try bindings.toOwnedSlice();
}

fn spanTextForChildKind(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
    kind: cst.NodeKind,
) ?ast.SpanText {
    const child_node = childNodeByKind(tree, parent_node, kind) orelse return null;
    return spanTextForNode(file, tokens, tree, child_node);
}

fn typeSyntaxForChildKind(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
    kind: cst.NodeKind,
) !?ast.TypeSyntax {
    const child_node = childNodeByKind(tree, parent_node, kind) orelse return null;
    return try lowerTypeSyntax(file, tokens, tree, child_node, allocator);
}

fn lowerTypeSyntax(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    wrapper_node: cst.NodeId,
    allocator: Allocator,
) !ast.TypeSyntax {
    return type_syntax_lower.lowerNodeTypeSyntax(allocator, file, tokens, tree, wrapper_node);
}

fn lowerTuplePayloadSyntax(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
    kind: cst.NodeKind,
    allocator: Allocator,
) !?ast.TuplePayloadSyntax {
    const span_text = spanTextForChildKind(file, tokens, tree, parent_node, kind) orelse return null;
    const payload_node = childNodeByKind(tree, parent_node, kind) orelse return null;
    const token_refs = try tokenRefsForNode(allocator, tree, payload_node);
    defer allocator.free(token_refs);
    if (token_refs.len < 2 or tokens.getRef(token_refs[0]).kind != .l_paren or tokens.getRef(token_refs[token_refs.len - 1]).kind != .r_paren) {
        return .{
            .span = span_text.span,
            .types = &.{},
            .invalid_kind = .malformed_payload,
        };
    }
    if (token_refs.len == 2) {
        return .{
            .span = span_text.span,
            .types = &.{},
            .invalid_kind = .empty_payload,
        };
    }

    var lowered = array_list.Managed(ast.TypeSyntax).init(allocator);
    errdefer lowered.deinit();
    var invalid_kind: ?ast.TuplePayloadInvalidKindSyntax = null;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var entry_start: usize = 1;
    var index: usize = 1;
    while (index < token_refs.len - 1) : (index += 1) {
        const token_kind = tokens.getRef(token_refs[index]).kind;
        switch (token_kind) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            .comma => {
                if (paren_depth != 0 or bracket_depth != 0) continue;
                if (entry_start == index) {
                    invalid_kind = .empty_entry;
                } else {
                    try lowered.append(try type_syntax_lower.lowerTokenRangeTypeSyntax(
                        allocator,
                        spanTextForTokenRange(file, tokens, token_refs[entry_start..index]),
                        tokens,
                        token_refs[entry_start..index],
                    ));
                }
                entry_start = index + 1;
            },
            else => {},
        }
    }
    if (entry_start == token_refs.len - 1) {
        invalid_kind = .empty_entry;
    } else {
        try lowered.append(try type_syntax_lower.lowerTokenRangeTypeSyntax(
            allocator,
            spanTextForTokenRange(file, tokens, token_refs[entry_start .. token_refs.len - 1]),
            tokens,
            token_refs[entry_start .. token_refs.len - 1],
        ));
        if (lowered.items.len != 0) {
            for (lowered.items) |lowered_type| {
                if (typeSyntaxIsInvalid(lowered_type)) {
                    invalid_kind = .malformed_payload;
                    break;
                }
            }
        } else {
            invalid_kind = .empty_entry;
        }
    }

    return .{
        .span = span_text.span,
        .types = try lowered.toOwnedSlice(),
        .invalid_kind = invalid_kind,
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

fn childNodeAt(tree: *const cst.Tree, node_id: cst.NodeId, child_index: usize) !cst.NodeId {
    const children = tree.childSlice(node_id);
    if (child_index >= children.len) return error.InvalidParse;
    return switch (children[child_index]) {
        .node => |nested| nested,
        else => error.InvalidParse,
    };
}

fn childNodeByKind(tree: *const cst.Tree, node_id: cst.NodeId, kind: cst.NodeKind) ?cst.NodeId {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| {
                if (tree.nodeKind(child_node) == kind) return child_node;
            },
            else => {},
        }
    }
    return null;
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

fn makeSubspanText(parent: ast.SpanText, start: usize, end: usize) ?ast.SpanText {
    if (end <= start or end > parent.text.len) return null;
    return .{
        .text = parent.text[start..end],
        .span = .{
            .file_id = parent.span.file_id,
            .start = parent.span.start + start,
            .end = parent.span.start + end,
        },
    };
}

fn lowerVisibility(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
) ast.Visibility {
    const visibility = spanTextForChildKind(file, tokens, tree, parent_node, .visibility) orelse return .private;
    if (std.mem.eql(u8, visibility.text, "pub")) return .pub_item;
    if (std.mem.eql(u8, visibility.text, "pub(package)")) return .pub_package;
    return .private;
}

fn trimmedRange(raw: []const u8) ?struct { start: usize, end: usize } {
    const start = leadingTrimCount(raw);
    const end = trailingTrimEnd(raw);
    if (end <= start) return null;
    return .{ .start = start, .end = end };
}

fn prefixRawOffset(raw: []const u8, trimmed: []const u8) usize {
    if (trimmed.len == 0) return 0;
    const start = leadingTrimCount(raw);
    if (start + trimmed.len <= raw.len) return start;
    return 0;
}

fn leadingTrimCount(raw: []const u8) usize {
    var index: usize = 0;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {}
    return index;
}

fn trailingTrimEnd(raw: []const u8) usize {
    var end = raw.len;
    while (end != 0 and (raw[end - 1] == ' ' or raw[end - 1] == '\t' or raw[end - 1] == '\r' or raw[end - 1] == '\n')) : (end -= 1) {}
    return end;
}

fn trimHorizontal(raw: []const u8) []const u8 {
    const start = leadingTrimCount(raw);
    var end = raw.len;
    while (end > start and (raw[end - 1] == ' ' or raw[end - 1] == '\t')) : (end -= 1) {}
    return raw[start..end];
}

fn trimTrailingLineEnding(raw: []const u8) []const u8 {
    const end = trailingTrimEnd(raw);
    return raw[0..end];
}

fn lowerParameterModeForChildKind(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
    kind: cst.NodeKind,
) ast.ParameterModeSyntax {
    const span_text = spanTextForChildKind(file, tokens, tree, parent_node, kind) orelse return .owned;
    const trimmed = std.mem.trim(u8, span_text.text, " \t");
    if (std.mem.eql(u8, trimmed, "take")) return .{ .take = span_text.span };
    if (std.mem.eql(u8, trimmed, "read")) return .{ .read = span_text.span };
    if (std.mem.eql(u8, trimmed, "edit")) return .{ .edit = span_text.span };
    return .{ .invalid = span_text };
}

fn lowerGenericParamListForChildKind(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    parent_node: cst.NodeId,
    kind: cst.NodeKind,
) !?ast.GenericParamListSyntax {
    const child_node = childNodeByKind(tree, parent_node, kind) orelse return null;
    return try lowerGenericParamListSyntax(allocator, file, tokens, tree, child_node);
}

fn lowerGenericParamListSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) !ast.GenericParamListSyntax {
    const span_text = spanTextForNode(file, tokens, tree, node_id) orelse ast.SpanText{
        .text = "",
        .span = .{ .file_id = file.id, .start = 0, .end = 0 },
    };
    const children = tree.childSlice(node_id);
    if (children.len < 2) {
        return .{
            .span = span_text.span,
            .params = &.{},
            .invalid_kind = .malformed_entry,
        };
    }

    var params = array_list.Managed(ast.GenericParamSyntax).init(allocator);
    errdefer params.deinit();
    var invalid_kind: ?ast.GenericParamListInvalidKindSyntax = null;
    var saw_entry = false;
    var expect_entry = true;
    var index: usize = 1;
    while (index + 1 < children.len) : (index += 1) {
        switch (children[index]) {
            .token => |token_ref| {
                const token = tokens.getRef(token_ref);
                if (expect_entry) {
                    switch (token.kind) {
                        .identifier => {
                            saw_entry = true;
                            try params.append(.{
                                .name = token.lexeme,
                                .span = token.span,
                                .kind = .type_param,
                            });
                            expect_entry = false;
                        },
                        .lifetime_name => {
                            saw_entry = true;
                            try params.append(.{
                                .name = token.lexeme,
                                .span = token.span,
                                .kind = .lifetime_param,
                            });
                            expect_entry = false;
                        },
                        .comma => invalid_kind = .malformed_entry,
                        else => {
                            invalid_kind = .malformed_entry;
                            expect_entry = false;
                        },
                    }
                } else if (token.kind == .comma) {
                    expect_entry = true;
                } else {
                    invalid_kind = .malformed_entry;
                }
            },
            else => invalid_kind = .malformed_entry,
        }
    }

    if (!saw_entry) {
        return .{
            .span = span_text.span,
            .params = &.{},
            .invalid_kind = .empty_list,
        };
    }
    if (expect_entry) invalid_kind = .malformed_entry;

    return .{
        .span = span_text.span,
        .params = try params.toOwnedSlice(),
        .invalid_kind = invalid_kind,
    };
}

fn lowerWhereClauseSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) !ast.WhereClauseSyntax {
    const span_text = spanTextForNode(file, tokens, tree, node_id) orelse ast.SpanText{
        .text = "",
        .span = .{ .file_id = file.id, .start = 0, .end = 0 },
    };
    const token_refs = try tokenRefsForNode(allocator, tree, node_id);
    defer allocator.free(token_refs);
    if (token_refs.len == 0) {
        return .{
            .span = span_text.span,
            .predicates = &.{},
            .invalid_kind = .empty_clause,
        };
    }

    const first_token = tokens.getRef(token_refs[0]);
    if (first_token.kind != .keyword_where) {
        return .{
            .span = span_text.span,
            .predicates = try allocator.dupe(ast.WherePredicateSyntax, &.{.{ .invalid = span_text }}),
        };
    }

    var body_end = token_refs.len;
    if (body_end > 0 and tokens.getRef(token_refs[body_end - 1]).kind == .newline) body_end -= 1;
    if (body_end > 1 and tokens.getRef(token_refs[body_end - 1]).kind == .colon) body_end -= 1;
    if (body_end <= 1) {
        return .{
            .span = span_text.span,
            .predicates = &.{},
            .invalid_kind = .empty_clause,
        };
    }

    var predicates = array_list.Managed(ast.WherePredicateSyntax).init(allocator);
    errdefer predicates.deinit();

    var predicate_start: usize = 1;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var index: usize = 1;
    while (index < body_end) : (index += 1) {
        const token = tokens.getRef(token_refs[index]);
        switch (token.kind) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            .comma => {
                if (paren_depth == 0 and bracket_depth == 0) {
                    try predicates.append(try lowerWherePredicateSyntax(allocator, file, tokens, token_refs[predicate_start..index]));
                    predicate_start = index + 1;
                }
            },
            else => {},
        }
    }
    try predicates.append(try lowerWherePredicateSyntax(allocator, file, tokens, token_refs[predicate_start..body_end]));

    return .{
        .span = span_text.span,
        .predicates = try predicates.toOwnedSlice(),
    };
}

fn lowerWherePredicateSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
) !ast.WherePredicateSyntax {
    if (token_refs.len == 0) {
        return .{ .invalid = .{
            .text = "",
            .span = .{ .file_id = file.id, .start = 0, .end = 0 },
        } };
    }

    const span_text = spanTextForTokenRange(file, tokens, token_refs);
    if (findTopLevelTokenIndex(tokens, token_refs, .equal)) |equal_index| {
        const left = token_refs[0..equal_index];
        const right = token_refs[equal_index + 1 ..];
        if (findTopLevelTokenIndex(tokens, left, .dot)) |dot_index| {
            const subject_name = tokenRangeText(file, tokens, left[0..dot_index]) orelse return .{ .invalid = span_text };
            const associated_name = tokenRangeText(file, tokens, left[dot_index + 1 ..]) orelse return .{ .invalid = span_text };
            const value_type = try tokenRangeTypeSyntax(allocator, file, tokens, right) orelse return .{ .invalid = span_text };
            if (subject_name.text.len != 0 and associated_name.text.len != 0 and !typeSyntaxIsInvalid(value_type)) {
                return .{ .projection_equality = .{
                    .subject_name = subject_name.text,
                    .associated_name = associated_name.text,
                    .value_type = value_type,
                    .span = span_text.span,
                } };
            }
        }
        return .{ .invalid = span_text };
    }

    if (findTopLevelTokenIndex(tokens, token_refs, .colon)) |colon_index| {
        const left = tokenRangeText(file, tokens, token_refs[0..colon_index]) orelse return .{ .invalid = span_text };
        const right = tokenRangeText(file, tokens, token_refs[colon_index + 1 ..]) orelse return .{ .invalid = span_text };
        if (isLifetimeName(left.text) and isLifetimeName(right.text)) {
            return .{ .lifetime_outlives = .{
                .longer_name = left.text,
                .shorter_name = right.text,
                .span = span_text.span,
            } };
        }
        if (isLifetimeName(right.text)) {
            return .{ .type_outlives = .{
                .type_name = left.text,
                .lifetime_name = right.text,
                .span = span_text.span,
            } };
        }
        const right_type = try tokenRangeTypeSyntax(allocator, file, tokens, token_refs[colon_index + 1 ..]) orelse return .{ .invalid = span_text };
        return .{ .bound = .{
            .subject_name = left.text,
            .contract_type = right_type,
            .span = span_text.span,
        } };
    }

    return .{ .invalid = span_text };
}

fn isPlainIdentifier(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (!(std.ascii.isAlphabetic(raw[0]) or raw[0] == '_')) return false;
    for (raw[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isLifetimeName(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '\'') return false;
    const body = raw[1..];
    if (std.mem.eql(u8, body, "static")) return true;
    if (!(std.ascii.isAlphabetic(body[0]) or body[0] == '_')) return false;
    for (body[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn tokenRefsForNode(
    allocator: Allocator,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ![]syntax.TokenRef {
    var refs = array_list.Managed(syntax.TokenRef).init(allocator);
    defer refs.deinit();
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .token => |token_ref| try refs.append(token_ref),
            else => {},
        }
    }
    return refs.toOwnedSlice();
}

fn spanTextForTokenRange(
    file: *const source.File,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
) ast.SpanText {
    const first = tokens.getRef(token_refs[0]);
    const last = tokens.getRef(token_refs[token_refs.len - 1]);
    return .{
        .text = file.contents[first.span.start..last.span.end],
        .span = .{
            .file_id = first.span.file_id,
            .start = first.span.start,
            .end = last.span.end,
        },
    };
}

fn tokenRangeText(
    file: *const source.File,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
) ?ast.SpanText {
    if (token_refs.len == 0) return null;
    return spanTextForTokenRange(file, tokens, token_refs);
}

fn tokenRangeTypeSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
) !?ast.TypeSyntax {
    const span_text = tokenRangeText(file, tokens, token_refs) orelse return null;
    return try type_syntax_lower.lowerTokenRangeTypeSyntax(allocator, span_text, tokens, token_refs);
}

fn typeSyntaxIsInvalid(syntax_value: ast.TypeSyntax) bool {
    if (syntax_value.nodes.len == 0) return true;
    return switch (syntax_value.nodes[0].payload) {
        .invalid => true,
        else => false,
    };
}

fn findTopLevelTokenIndex(
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
    target: syntax.TokenKind,
) ?usize {
    var bracket_depth: usize = 0;
    var paren_depth: usize = 0;
    for (token_refs, 0..) |token_ref, index| {
        const token = tokens.getRef(token_ref);
        switch (token.kind) {
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            else => {},
        }
        if (bracket_depth == 0 and paren_depth == 0 and token.kind == target) return index;
    }
    return null;
}

fn findTopLevelScalar(raw: []const u8, start: usize, end: usize, needle: u8) ?usize {
    var square_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_string = false;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = raw[index];
        if (byte == '"' and !quoteIsEscaped(raw, index)) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        switch (byte) {
            '[' => square_depth += 1,
            ']' => {
                if (square_depth != 0) square_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            else => {},
        }
        if (square_depth == 0 and paren_depth == 0 and byte == needle) return index;
    }
    return null;
}

fn quoteIsEscaped(raw: []const u8, index: usize) bool {
    if (index == 0 or raw[index] != '"') return false;

    var backslash_count: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (raw[cursor] != '\\') break;
        backslash_count += 1;
    }
    return backslash_count % 2 == 1;
}

fn subspan(parent: source.Span, offset: usize, len: usize) source.Span {
    return .{
        .file_id = parent.file_id,
        .start = parent.start + offset,
        .end = parent.start + offset + len,
    };
}

fn freeWhereClauseSlice(allocator: Allocator, items: []ast.WhereClauseSyntax) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len != 0) allocator.free(items);
}
