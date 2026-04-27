const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const block_syntax_lower = @import("block_syntax_lower.zig");
const cst = @import("../cst/root.zig");
const diag = @import("../diag/root.zig");
const item_syntax_lower = @import("item_syntax_lower.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

pub fn lowerModule(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    diagnostics: *diag.Bag,
) !ast.Module {
    var module = ast.Module.init(allocator, file.id);
    errdefer module.deinit(allocator);

    try appendModuleNodeRange(allocator, &module, file, tokens, tree, 0, std.math.maxInt(usize), diagnostics);

    return module;
}

pub fn appendModuleNodeRange(
    allocator: Allocator,
    module: *ast.Module,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    start_node_index: usize,
    end_node_index: usize,
    diagnostics: *diag.Bag,
) !void {
    if (start_node_index >= end_node_index) return;

    var node_index: usize = 0;
    for (tree.childSlice(tree.root)) |child| {
        const node_id = switch (child) {
            .node => |value| value,
            else => continue,
        };
        if (node_index >= start_node_index and node_index < end_node_index) {
            const items = try lowerTopLevelNodeItems(allocator, file, tokens, tree, node_id, diagnostics);
            errdefer freeOwnedItems(allocator, items);
            try module.appendOwnedBlock(allocator, items);
        }
        node_index += 1;
        if (node_index >= end_node_index) break;
    }
}

fn lowerTopLevelNodeItems(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    diagnostics: *diag.Bag,
) ![]ast.Item {
    switch (tree.nodeKind(node_id)) {
        .blank_line => return allocator.alloc(ast.Item, 0),
        .item => return lowerItemItems(allocator, file, tokens, tree, node_id, diagnostics),
        .@"error" => try diagnoseTopLevelError(file, tokens, tree, node_id, diagnostics),
        else => try diagnoseGenericTopLevelError(file, tokens, tree, node_id, diagnostics),
    }

    return allocator.alloc(ast.Item, 0);
}

fn lowerItemItems(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    item_node: cst.NodeId,
    diagnostics: *diag.Bag,
) ![]ast.Item {
    var pending_attributes = array_list.Managed(ast.Attribute).init(allocator);
    defer pending_attributes.deinit();

    const item_children = tree.childSlice(item_node);
    var declaration: ?cst.NodeId = null;

    for (item_children) |child| {
        switch (child) {
            .node => |node_id| switch (tree.nodeKind(node_id)) {
                .attribute_line => try pending_attributes.append(try lowerAttribute(file, tokens, tree, node_id)),
                else => {
                    if (declaration == null) declaration = node_id;
                },
            },
            else => {},
        }
    }

    const declaration_node = declaration orelse {
        if (pending_attributes.items.len != 0) {
            try diagnostics.add(.@"error", "parse.attr.orphan", pending_attributes.items[0].span, "attribute lines must attach to a following declaration", .{});
        }
        return allocator.alloc(ast.Item, 0);
    };

    const declaration_kind = tree.nodeKind(declaration_node);
    if (declaration_kind == .@"error") {
        try diagnoseMalformedItem(file, tokens, tree, declaration_node, diagnostics);
        return allocator.alloc(ast.Item, 0);
    }

    const item_span = nodeSpan(tokens, tree, declaration_node) orelse return allocator.alloc(ast.Item, 0);
    const visibility = lowerVisibility(file, tokens, tree, declaration_node);
    var lowered_syntax = try item_syntax_lower.lowerItemSyntax(allocator, file, tokens, tree, declaration_node);
    errdefer lowered_syntax.deinit(allocator);
    var lowered_body_syntax = try item_syntax_lower.lowerItemBodySyntax(allocator, file, tokens, tree, declaration_node);
    errdefer lowered_body_syntax.deinit(allocator);
    const lowered_block_syntax = try block_syntax_lower.lowerItemBlockSyntax(allocator, file, tokens, tree, declaration_node);
    errdefer if (lowered_block_syntax) |block| {
        var owned_block = block;
        owned_block.deinit(allocator);
    };

    const body_node = childNodeAt(tree, declaration_node, 1) catch null;
    const has_body = body_node != null;

    if (declaration_kind == .use_item) {
        try diagnoseStructuredUse(file, tokens, tree, declaration_node, diagnostics);
        const use_syntax = try item_syntax_lower.lowerUseBindings(allocator, file, tokens, tree, declaration_node);
        defer if (use_syntax.len != 0) allocator.free(use_syntax);

        var lowered_items = try allocator.alloc(ast.Item, use_syntax.len);
        var initialized_count: usize = 0;
        errdefer {
            for (lowered_items[0..initialized_count]) |item| item.deinit(allocator);
            allocator.free(lowered_items);
        }

        for (use_syntax, 0..) |binding, binding_index| {
            const local_name = useBindingName(binding) orelse "";
            const target_path = try useBindingTargetPath(allocator, binding);
            errdefer if (target_path) |value| allocator.free(value);
            lowered_items[binding_index] = .{
                .kind = .use_decl,
                .name = try allocator.dupe(u8, local_name),
                .visibility = visibility,
                .attributes = try allocator.dupe(ast.Attribute, pending_attributes.items),
                .target_path = target_path,
                .span = item_span,
                .has_body = false,
                .foreign_abi = null,
                .syntax = .{ .use_decl = binding },
            };
            initialized_count = binding_index + 1;
        }

        return lowered_items;
    }

    try diagnoseStructuredDeclaration(item_span, declaration_kind, lowered_syntax, has_body, diagnostics);

    var parsed_items = try allocator.alloc(ast.Item, 1);
    errdefer allocator.free(parsed_items);
    parsed_items[0] = .{
        .kind = astItemKind(declaration_kind),
        .name = try allocator.dupe(u8, itemNameFromSyntax(lowered_syntax)),
        .visibility = visibility,
        .attributes = try allocator.dupe(ast.Attribute, pending_attributes.items),
        .target_path = null,
        .span = item_span,
        .has_body = has_body,
        .foreign_abi = itemForeignAbi(lowered_syntax),
        .syntax = lowered_syntax,
        .body_syntax = lowered_body_syntax,
        .block_syntax = lowered_block_syntax,
    };
    return parsed_items;
}

fn lowerAttribute(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) !ast.Attribute {
    const span = nodeSpan(tokens, tree, node_id) orelse return error.InvalidParse;
    const raw = trimTrailingLineEnding(file.contents[span.start..span.end]);
    return .{
        .name = attributeName(raw),
        .raw = raw,
        .span = span,
    };
}

fn diagnoseStructuredDeclaration(
    item_span: source.Span,
    declaration_kind: cst.NodeKind,
    lowered_syntax: ast.ItemSyntax,
    has_body: bool,
    diagnostics: *diag.Bag,
) !void {
    switch (declaration_kind) {
        .function_item => {
            const signature = lowered_syntax.function;
            if (signature.return_type == null) {
                try diagnostics.add(.@"error", "parse.fn.return", item_span, "functions must declare an explicit return type", .{});
            }
            if (!has_body) {
                try diagnostics.add(.@"error", "parse.fn.body", item_span, "ordinary functions require a body in v1", .{});
            }
        },
        .suspend_function_item => {
            if (lowered_syntax.function.return_type == null) {
                try diagnostics.add(.@"error", "parse.fn.return", item_span, "functions must declare an explicit return type", .{});
            }
        },
        .foreign_function_item => {
            if (lowered_syntax.function.return_type == null) {
                try diagnostics.add(.@"error", "parse.fn.return", item_span, "foreign functions must declare an explicit return type", .{});
            }
        },
        .const_item => {
            if (lowered_syntax.const_item.initializer == null) {
                try diagnostics.add(.@"error", "parse.const.init", item_span, "const declarations require an initializer", .{});
            }
        },
        else => {},
    }
}

fn diagnoseStructuredUse(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
    diagnostics: *diag.Bag,
) !void {
    const header_node = childNodeAt(tree, declaration_node, 0) catch return;
    const signature_node = childNodeAt(tree, header_node, 0) catch return;
    const path_node = childNodeByKind(tree, signature_node, .use_path) orelse return;
    const path_span = nodeSpan(tokens, tree, path_node) orelse return;
    const path_text = trimTrailingLineEnding(file.contents[path_span.start..path_span.end]);
    if (std.mem.indexOfScalar(u8, path_text, '*') != null) {
        try diagnostics.add(.@"error", "parse.use.wildcard", path_span, "wildcard imports are not part of v1", .{});
    }
    if (startsWithRelativeSuper(path_text)) {
        try diagnostics.add(.@"error", "parse.use.relative", path_span, "relative import climbing is not part of v1", .{});
    }
}

fn itemNameFromSyntax(lowered_syntax: ast.ItemSyntax) []const u8 {
    return switch (lowered_syntax) {
        .function => |signature| if (signature.name) |name| name.text else "",
        .const_item => |signature| if (signature.name) |name| name.text else "",
        .type_alias => |signature| if (signature.name) |name| name.text else "",
        .named_decl => |signature| if (signature.name) |name| name.text else "",
        .use_decl => |binding| if (binding.alias) |alias| alias.text else if (binding.leaf) |leaf| leaf.text else "",
        .impl_block, .none => "",
    };
}

fn itemForeignAbi(lowered_syntax: ast.ItemSyntax) ?[]const u8 {
    return switch (lowered_syntax) {
        .function => |signature| if (signature.foreign_abi) |abi| trimAbiLiteral(abi.text) else null,
        else => null,
    };
}

fn useBindingName(binding: ast.UseBindingSyntax) ?[]const u8 {
    if (binding.alias) |alias| return alias.text;
    if (binding.leaf) |leaf| return leaf.text;
    return null;
}

fn useBindingTargetPath(allocator: Allocator, binding: ast.UseBindingSyntax) !?[]u8 {
    const leaf = if (binding.leaf) |value| value.text else return null;
    if (binding.prefix) |prefix| {
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix.text, leaf });
    }
    return try allocator.dupe(u8, leaf);
}

fn diagnoseTopLevelError(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    diagnostics: *diag.Bag,
) !void {
    const children = tree.childSlice(node_id);
    if (children.len != 0) {
        switch (children[0]) {
            .node => |child_node| {
                if (tree.nodeKind(child_node) == .attribute_line) {
                    const attribute = try lowerAttribute(file, tokens, tree, child_node);
                    try diagnostics.add(.@"error", "parse.attr.orphan", attribute.span, "attribute lines must attach to a following declaration", .{});
                    return;
                }
            },
            .token => |token_id| {
                const token = tokens.getRef(token_id);
                if (token.kind == .indent or token.kind == .dedent) {
                    try diagnostics.add(.@"error", "parse.indent", token.span, "unexpected top-level indentation", .{});
                    return;
                }
            },
            .missing_token => {},
        }
    }

    try diagnoseGenericTopLevelError(file, tokens, tree, node_id, diagnostics);
}

fn diagnoseMalformedItem(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    diagnostics: *diag.Bag,
) !void {
    if (nodeSpan(tokens, tree, node_id)) |span| {
        try diagnostics.add(.@"error", "parse.item", span, "unsupported or malformed top-level item", .{});
        return;
    }
    try diagnoseGenericTopLevelError(file, tokens, tree, node_id, diagnostics);
}

fn diagnoseGenericTopLevelError(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
    diagnostics: *diag.Bag,
) !void {
    _ = file;
    if (nodeSpan(tokens, tree, node_id)) |span| {
        try diagnostics.add(.@"error", "parse.item", span, "unsupported or malformed top-level item", .{});
    } else {
        try diagnostics.add(.@"error", "parse.item", null, "unsupported or malformed top-level item", .{});
    }
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

fn astItemKind(kind: cst.NodeKind) ast.ItemKind {
    return switch (kind) {
        .module_item => .module_decl,
        .use_item => .use_decl,
        .function_item => .function,
        .suspend_function_item => .suspend_function,
        .foreign_function_item => .foreign_function,
        .const_item => .const_item,
        .type_alias_item => .type_alias,
        .struct_item => .struct_type,
        .enum_item => .enum_type,
        .union_item => .union_type,
        .trait_item => .trait_type,
        .impl_item => .impl_block,
        .opaque_type_item => .opaque_type,
        else => unreachable,
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

fn freeOwnedItems(allocator: Allocator, items: []ast.Item) void {
    for (items) |item| item.deinit(allocator);
    allocator.free(items);
}

fn lowerVisibility(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ast.Visibility {
    const header_node = childNodeAt(tree, node_id, 0) catch return .private;
    for (tree.childSlice(header_node)) |child| {
        switch (child) {
            .node => |child_node| {
                if (tree.nodeKind(child_node) == .visibility) {
                    return visibilityFromNode(file, tokens, tree, child_node);
                }
                for (tree.childSlice(child_node)) |grandchild| {
                    switch (grandchild) {
                        .node => |grandchild_node| {
                            if (tree.nodeKind(grandchild_node) == .visibility) {
                                return visibilityFromNode(file, tokens, tree, grandchild_node);
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return .private;
}

fn trimTrailingLineEnding(raw: []const u8) []const u8 {
    var trimmed = trimCarriageReturn(raw);
    while (trimmed.len != 0 and trimmed[trimmed.len - 1] == '\n') {
        trimmed = trimmed[0 .. trimmed.len - 1];
        trimmed = trimCarriageReturn(trimmed);
    }
    return trimmed;
}

fn startsWithRelativeSuper(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (!std.mem.startsWith(u8, trimmed, "super")) return false;
    if (trimmed.len == "super".len) return true;

    const next = trimmed["super".len];
    return !std.ascii.isAlphanumeric(next) and next != '_';
}

fn attributeName(trimmed: []const u8) []const u8 {
    const start = if (trimmed.len > 0 and trimmed[0] == '#') @as(usize, 1) else 0;
    const end = std.mem.indexOfAnyPos(u8, trimmed, start, "[ \t") orelse trimmed.len;
    return trimmed[start..end];
}

fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}

fn trimAbiLiteral(raw: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    }
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn visibilityFromNode(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ast.Visibility {
    const span = nodeSpan(tokens, tree, node_id) orelse return .private;
    const raw = trimTrailingLineEnding(file.contents[span.start..span.end]);
    if (std.mem.eql(u8, raw, "pub")) return .pub_item;
    if (std.mem.eql(u8, raw, "pub(package)")) return .pub_package;
    return .private;
}
