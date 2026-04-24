const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const body_syntax_lower = @import("body_syntax_lower.zig");
const cst = @import("../cst/root.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

pub fn lowerItemBlockSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    declaration_node: cst.NodeId,
) !?ast.BlockSyntax {
    switch (tree.nodeKind(declaration_node)) {
        .function_item, .suspend_function_item, .foreign_function_item => {},
        else => return null,
    }

    const body_node = childNodeAt(tree, declaration_node, 1) catch return null;
    return try lowerBlockSyntax(allocator, file, tokens, tree, body_node);
}

pub fn lowerBlockSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    block_node: cst.NodeId,
) !ast.BlockSyntax {
    var lines = array_list.Managed(ast.LineSyntax).init(allocator);
    defer lines.deinit();

    for (tree.childSlice(block_node)) |child| {
        switch (child) {
            .node => |node_id| {
                const kind = tree.nodeKind(node_id);
                switch (kind) {
                    .statement,
                    .select_statement,
                    .repeat_statement,
                    .when_arm,
                    .else_arm,
                    .return_statement,
                    .defer_statement,
                    .break_statement,
                    .continue_statement,
                    .unsafe_statement,
                    .@"error",
                    => {
                        if (try lowerLineSyntax(allocator, file, tokens, tree, node_id)) |line| {
                            try lines.append(line);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    return .{
        .lines = try lines.toOwnedSlice(),
        .structured = try body_syntax_lower.lowerBlockBodySyntax(allocator, file, tokens, tree, block_node),
    };
}

fn lowerLineSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) anyerror!?ast.LineSyntax {
    const text = lineTextForNode(file, tokens, tree, node_id) orelse return null;
    return .{
        .text = text,
        .block = if (childNodeByKind(tree, node_id, .block)) |block_node|
            try lowerBlockSyntax(allocator, file, tokens, tree, block_node)
        else
            null,
    };
}

fn lineTextForNode(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ?ast.SpanText {
    const children = tree.childSlice(node_id);
    var start_offset: ?usize = null;
    var end_offset: ?usize = null;

    for (children) |child| {
        switch (child) {
            .token => |token_id| {
                const token = tokens.getRef(token_id);
                if (token.kind == .newline or token.kind == .indent or token.kind == .dedent) break;
                if (start_offset == null) start_offset = token.span.start;
                end_offset = token.span.end;
            },
            .node => |child_node| {
                if (tree.nodeKind(child_node) == .block) break;
                if (nodeSpan(tokens, tree, child_node)) |span| {
                    if (start_offset == null) start_offset = span.start;
                    end_offset = span.end;
                }
            },
            .missing_token => {},
        }
    }

    const start = start_offset orelse return null;
    const end = end_offset orelse return null;
    if (end <= start) return null;
    const first_token = tree.firstTokenRef(node_id) orelse return null;
    return makeSpanText(file, tokens.getRef(first_token).span.file_id, start, end);
}

fn makeSpanText(file: *const source.File, file_id: source.FileId, start: usize, end: usize) ast.SpanText {
    const trimmed = trimTrailingLineEnding(file.contents[start..end]);
    return .{
        .text = trimmed,
        .span = .{
            .file_id = file_id,
            .start = start,
            .end = start + trimmed.len,
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
            .node => |child_node| if (tree.nodeKind(child_node) == kind) return child_node,
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

fn trimTrailingLineEnding(raw: []const u8) []const u8 {
    var trimmed = raw;
    while (trimmed.len != 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

test "lower function block syntax preserves nested statement blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file = source.File{
        .id = 0,
        .path = "block_syntax_test.rna",
        .contents =
        \\fn main() -> Unit:
        \\    select:
        \\        when flag => return 1
        \\        else =>
        \\            return 2
        \\    repeat:
        \\        return 3
        ,
    };

    const lexed = try syntax.lexFile(allocator, &file);
    const tree = try cst.parseLexedFile(allocator, lexed.tokens, lexed.trivia);

    const item_node = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration_node = childNodeAt(&tree, item_node, 0) catch return error.UnexpectedStructure;
    const block = (try lowerItemBlockSyntax(allocator, &file, lexed.tokens, &tree, declaration_node)) orelse return error.UnexpectedStructure;

    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try std.testing.expectEqualStrings("select:", block.lines[0].text.text);
    try std.testing.expect(block.lines[0].block != null);
    try std.testing.expectEqual(@as(usize, 2), block.lines[0].block.?.lines.len);
    try std.testing.expectEqualStrings("when flag => return 1", block.lines[0].block.?.lines[0].text.text);
    try std.testing.expectEqualStrings("else =>", block.lines[0].block.?.lines[1].text.text);
    try std.testing.expect(block.lines[0].block.?.lines[1].block != null);
    try std.testing.expectEqualStrings("repeat:", block.lines[1].text.text);
    try std.testing.expect(block.lines[1].block != null);
}
