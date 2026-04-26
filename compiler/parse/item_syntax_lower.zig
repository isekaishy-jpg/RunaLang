const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const block_syntax_lower = @import("block_syntax_lower.zig");
const body_syntax_lower = @import("body_syntax_lower.zig");
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
    errdefer freeSpanTextSlice(allocator, where_clauses);

    return switch (declaration_kind) {
        .function_item, .suspend_function_item, .foreign_function_item => .{
            .function = try lowerFunctionSignature(allocator, file, tokens, tree, signature_node, where_clauses),
        },
        .const_item => .{
            .const_item = .{
                .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
                .ty = spanTextForChildKind(file, tokens, tree, signature_node, .const_type),
                .initializer = spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer),
                .initializer_expr = if (spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer)) |initializer|
                    try body_syntax_lower.lowerStandaloneExprSyntax(allocator, initializer)
                else
                    null,
            },
        },
        .module_item, .struct_item, .enum_item, .union_item, .trait_item, .opaque_type_item => .{
            .named_decl = .{
                .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
                .generic_params = spanTextForChildKind(file, tokens, tree, signature_node, .generic_param_list),
                .where_clauses = where_clauses,
            },
        },
        .impl_item => .{
            .impl_block = .{
                .generic_params = spanTextForChildKind(file, tokens, tree, signature_node, .generic_param_list),
                .trait_name = spanTextForChildKind(file, tokens, tree, signature_node, .impl_trait_name),
                .target_type = spanTextForChildKind(file, tokens, tree, signature_node, .impl_target_type),
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
    where_clauses: []ast.SpanText,
) !ast.FunctionSignatureSyntax {
    return .{
        .name = spanTextForChildKind(file, tokens, tree, signature_node, .item_name),
        .generic_params = spanTextForChildKind(file, tokens, tree, signature_node, .generic_param_list),
        .parameters = try lowerParameters(allocator, file, tokens, tree, signature_node),
        .return_type = spanTextForChildKind(file, tokens, tree, signature_node, .return_type),
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
                    .ty = spanTextForChildKind(file, tokens, tree, node_id, .field_type),
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
    return .{
        .name = spanTextForChildKind(file, tokens, tree, variant_node, .variant_name),
        .tuple_payload = spanTextForChildKind(file, tokens, tree, variant_node, .variant_tuple_payload),
        .discriminant = spanTextForChildKind(file, tokens, tree, variant_node, .variant_discriminant),
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
                .associated_type_decl => try associated_types.append(lowerAssociatedType(file, tokens, tree, node_id)),
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
                .associated_type_decl => try associated_types.append(lowerAssociatedType(file, tokens, tree, node_id)),
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
        .ty = spanTextForChildKind(file, tokens, tree, signature_node, .const_type),
        .initializer = spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer),
        .initializer_expr = if (spanTextForChildKind(file, tokens, tree, signature_node, .const_initializer)) |initializer|
            try body_syntax_lower.lowerStandaloneExprSyntax(allocator, initializer)
        else
            null,
    };
}

fn lowerAssociatedType(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ast.AssociatedTypeDeclSyntax {
    return .{
        .name = spanTextForChildKind(file, tokens, tree, node_id, .item_name),
        .value = spanTextForChildKind(file, tokens, tree, node_id, .associated_type_value),
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
    errdefer freeSpanTextSlice(allocator, where_clauses);
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
                    .mode = spanTextForChildKind(file, tokens, tree, parameter_node, .parameter_mode),
                    .name = spanTextForChildKind(file, tokens, tree, parameter_node, .parameter_name),
                    .ty = spanTextForChildKind(file, tokens, tree, parameter_node, .parameter_type),
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
) ![]ast.SpanText {
    var clauses = array_list.Managed(ast.SpanText).init(allocator);
    defer clauses.deinit();

    for (tree.childSlice(header_node)) |child| {
        switch (child) {
            .node => |child_node| {
                if (tree.nodeKind(child_node) != .where_clause) continue;
                if (spanTextForNode(file, tokens, tree, child_node)) |span_text| {
                    try clauses.append(span_text);
                }
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

fn freeSpanTextSlice(allocator: Allocator, items: []ast.SpanText) void {
    if (items.len != 0) allocator.free(items);
}
