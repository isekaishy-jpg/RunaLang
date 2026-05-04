const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const cst = @import("../cst/root.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

pub fn lowerNodeTypeSyntax(
    allocator: Allocator,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    wrapper_node: cst.NodeId,
) !ast.TypeSyntax {
    const span_text = spanTextForNode(file, tokens, tree, wrapper_node) orelse ast.SpanText{
        .text = "",
        .span = .{ .file_id = file.id, .start = 0, .end = 0 },
    };
    const token_refs = try tokenRefsForNodeRange(allocator, tokens, tree, wrapper_node);
    defer allocator.free(token_refs);
    return lowerTokenRangeTypeSyntax(allocator, span_text, tokens, token_refs);
}

pub fn lowerStandaloneTypeSyntax(
    allocator: Allocator,
    span_text: ast.SpanText,
) !ast.TypeSyntax {
    var line_starts = [_]usize{0};
    const fragment_file = source.File{
        .id = span_text.span.file_id,
        .path = "<type>",
        .contents = span_text.text,
        .line_starts = line_starts[0..],
    };

    var lexed = try syntax.lexFile(allocator, &fragment_file);
    defer lexed.deinit(allocator);

    var refs = array_list.Managed(syntax.TokenRef).init(allocator);
    defer refs.deinit();
    var iterator = lexed.tokens.iterateRange(0, lexed.tokens.len());
    while (iterator.next()) |token_ref| {
        const token = lexed.tokens.getRef(token_ref);
        if (token.kind == .eof or token.kind == .newline or token.kind == .indent or token.kind == .dedent) continue;
        try refs.append(token_ref);
    }
    if (refs.items.len == 0) return invalidTypeSyntax(allocator, span_text);
    var parser = InlineTypeParser.init(allocator, span_text, lexed.tokens, refs.items, 0);
    return parser.parse();
}

pub fn lowerTokenRangeTypeSyntax(
    allocator: Allocator,
    span_text: ast.SpanText,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
) !ast.TypeSyntax {
    if (token_refs.len == 0) return invalidTypeSyntax(allocator, span_text);
    var parser = InlineTypeParser.init(allocator, span_text, tokens, token_refs, span_text.span.start);
    return parser.parse();
}

pub fn invalidTypeSyntax(allocator: Allocator, span_text: ast.SpanText) !ast.TypeSyntax {
    const nodes = try allocator.alloc(ast.TypeNode, 1);
    nodes[0] = .{
        .source = span_text,
        .payload = .invalid,
    };
    return .{
        .source = span_text,
        .nodes = nodes,
        .child_indices = &.{},
    };
}

const InlineTypeParser = struct {
    allocator: Allocator,
    source_text: ast.SpanText,
    tokens: syntax.TokenStore,
    token_refs: []const syntax.TokenRef,
    token_span_base: usize,
    cursor: usize = 0,
    nodes: array_list.Managed(ast.TypeNode),
    child_indices: array_list.Managed(u32),

    fn init(
        allocator: Allocator,
        source_text: ast.SpanText,
        tokens: syntax.TokenStore,
        token_refs: []const syntax.TokenRef,
        token_span_base: usize,
    ) InlineTypeParser {
        return .{
            .allocator = allocator,
            .source_text = source_text,
            .tokens = tokens,
            .token_refs = token_refs,
            .token_span_base = token_span_base,
            .nodes = array_list.Managed(ast.TypeNode).init(allocator),
            .child_indices = array_list.Managed(u32).init(allocator),
        };
    }

    fn parse(self: *InlineTypeParser) Allocator.Error!ast.TypeSyntax {
        errdefer self.nodes.deinit();
        errdefer self.child_indices.deinit();

        const root = self.parseType() catch null;
        if (root == null or self.cursor != self.token_refs.len) {
            self.nodes.deinit();
            self.child_indices.deinit();
            return invalidTypeSyntax(self.allocator, self.source_text);
        }
        const old_nodes = try self.nodes.toOwnedSlice();
        errdefer self.allocator.free(old_nodes);
        const old_child_indices = try self.child_indices.toOwnedSlice();
        errdefer self.allocator.free(old_child_indices);

        var ordered_nodes = array_list.Managed(ast.TypeNode).init(self.allocator);
        errdefer ordered_nodes.deinit();
        var ordered_child_indices = array_list.Managed(u32).init(self.allocator);
        errdefer ordered_child_indices.deinit();
        const old_to_new = try self.allocator.alloc(u32, old_nodes.len);
        defer self.allocator.free(old_to_new);
        @memset(old_to_new, std.math.maxInt(u32));

        _ = try appendReorderedNode(
            self.allocator,
            root.?,
            old_nodes,
            old_child_indices,
            &ordered_nodes,
            &ordered_child_indices,
            old_to_new,
        );
        self.allocator.free(old_nodes);
        self.allocator.free(old_child_indices);
        return .{
            .source = self.source_text,
            .nodes = try ordered_nodes.toOwnedSlice(),
            .child_indices = try ordered_child_indices.toOwnedSlice(),
        };
    }

    fn parseType(self: *InlineTypeParser) Allocator.Error!?u32 {
        const token_ref = self.peek() orelse return null;
        const token = self.tokens.getRef(token_ref);
        return switch (token.kind) {
            .star => self.parseRawPointer(),
            .lifetime_name => self.appendLeafNode(1, .lifetime),
            .l_paren => self.parseTuple(),
            .l_bracket => self.parseFixedArray(),
            .keyword_extern => self.parseForeignCallable(),
            .identifier => blk: {
                if (std.mem.eql(u8, token.lexeme, "read") or
                    std.mem.eql(u8, token.lexeme, "edit") or
                    std.mem.eql(u8, token.lexeme, "hold"))
                {
                    break :blk self.parseBorrow();
                }
                break :blk self.parseSuffixedPrimary();
            },
            else => null,
        };
    }

    fn parseBorrow(self: *InlineTypeParser) Allocator.Error!?u32 {
        const start_index = self.cursor;
        const head_ref = self.consume() orelse return null;
        const head = self.tokens.getRef(head_ref);

        if (std.mem.eql(u8, head.lexeme, "read")) {
            const child = try self.parseType() orelse return null;
            return try self.appendCompositeNode(start_index, self.cursor - 1, .{ .borrow = .{ .access = .read } }, &.{child});
        }
        if (std.mem.eql(u8, head.lexeme, "edit")) {
            const child = try self.parseType() orelse return null;
            return try self.appendCompositeNode(start_index, self.cursor - 1, .{ .borrow = .{ .access = .edit } }, &.{child});
        }
        if (!std.mem.eql(u8, head.lexeme, "hold")) return null;

        if (!self.matchKind(.l_bracket)) return null;
        const lifetime = if (self.peekTokenKind() == .lifetime_name)
            self.tokenSpanText(self.consume().?)
        else
            null;
        if (!self.matchKind(.r_bracket)) return null;
        const access_ref = self.consume() orelse return null;
        const access = self.tokens.getRef(access_ref);
        const borrow_access: ast.BorrowAccess = if (std.mem.eql(u8, access.lexeme, "read"))
            .read
        else if (std.mem.eql(u8, access.lexeme, "edit"))
            .edit
        else
            return null;
        const child = try self.parseType() orelse return null;
        return try self.appendCompositeNode(
            start_index,
            self.cursor - 1,
            .{ .borrow = .{
                .access = borrow_access,
                .lifetime = lifetime,
            } },
            &.{child},
        );
    }

    fn parseRawPointer(self: *InlineTypeParser) Allocator.Error!?u32 {
        const start_index = self.cursor;
        _ = self.consume() orelse return null;
        const access_ref = self.consume() orelse return null;
        const access = self.tokens.getRef(access_ref);
        const pointer_access: ast.RawPointerAccess = if (std.mem.eql(u8, access.lexeme, "read"))
            .read
        else if (std.mem.eql(u8, access.lexeme, "edit"))
            .edit
        else
            return null;
        const child = try self.parseType() orelse return null;
        return try self.appendCompositeNode(
            start_index,
            self.cursor - 1,
            .{ .raw_pointer = .{ .access = pointer_access } },
            &.{child},
        );
    }

    fn parseTuple(self: *InlineTypeParser) Allocator.Error!?u32 {
        const start_index = self.cursor;
        _ = self.consume() orelse return null;

        var elements = array_list.Managed(u32).init(self.allocator);
        defer elements.deinit();

        const first = try self.parseType() orelse return null;
        try elements.append(first);
        if (!self.matchKind(.comma)) return null;

        while (true) {
            const element = try self.parseType() orelse return null;
            try elements.append(element);
            if (self.matchKind(.comma)) continue;
            if (!self.matchKind(.r_paren)) return null;
            break;
        }

        if (elements.items.len < 2) return null;
        return try self.appendCompositeNode(start_index, self.cursor - 1, .tuple, elements.items);
    }

    fn parseFixedArray(self: *InlineTypeParser) Allocator.Error!?u32 {
        const start_index = self.cursor;
        _ = self.consume() orelse return null;
        const element = try self.parseType() orelse return null;
        if (!self.matchKind(.semicolon)) return null;
        const length_start = self.cursor;
        while (self.peekTokenKind()) |kind| {
            if (kind == .r_bracket) break;
            _ = self.consume() orelse break;
        }
        if (length_start == self.cursor) return null;
        if (!self.matchKind(.r_bracket)) return null;
        return try self.appendCompositeNode(
            start_index,
            self.cursor - 1,
            .{ .fixed_array = .{
                .length = self.spanText(length_start, self.cursor - 2),
            } },
            &.{element},
        );
    }

    fn parseForeignCallable(self: *InlineTypeParser) Allocator.Error!?u32 {
        const start_index = self.cursor;
        _ = self.consume() orelse return null;
        if (!self.matchKind(.l_bracket)) return null;
        const abi_ref = self.consume() orelse return null;
        if (self.tokens.getRef(abi_ref).kind != .string_literal) return null;
        if (!self.matchKind(.r_bracket)) return null;
        if (!self.matchKind(.keyword_fn)) return null;
        if (!self.matchKind(.l_paren)) return null;

        var children = array_list.Managed(u32).init(self.allocator);
        defer children.deinit();
        var parameter_count: u32 = 0;
        var has_variadic_tail = false;

        if (self.peekTokenKind() != .r_paren) {
            while (true) {
                if (self.beginsVariadicTail()) {
                    const tail_start = self.cursor;
                    while (self.peekTokenKind()) |kind| {
                        if (kind == .r_paren) break;
                        _ = self.consume() orelse break;
                    }
                    if (tail_start == self.cursor) return null;
                    has_variadic_tail = true;
                    break;
                }

                const parameter = try self.parseType() orelse return null;
                try children.append(parameter);
                parameter_count += 1;
                if (self.matchKind(.comma)) continue;
                break;
            }
        }

        if (!self.matchKind(.r_paren)) return null;
        if (!self.matchKind(.arrow)) return null;
        const return_type = try self.parseType() orelse return null;
        try children.append(return_type);
        return try self.appendCompositeNode(
            start_index,
            self.cursor - 1,
            .{ .foreign_callable = .{
                .abi = self.tokenSpanText(abi_ref),
                .parameter_count = parameter_count,
                .has_variadic_tail = has_variadic_tail,
            } },
            children.items,
        );
    }

    fn beginsVariadicTail(self: *const InlineTypeParser) bool {
        const token_ref = self.peek() orelse return false;
        const token = self.tokens.getRef(token_ref);
        return token.kind == .range or token.kind == .range_inclusive or
            (token.kind == .dot and self.cursor + 2 < self.token_refs.len and
            self.tokens.getRef(self.token_refs[self.cursor + 1]).kind == .dot and
            self.tokens.getRef(self.token_refs[self.cursor + 2]).kind == .dot);
    }

    fn parseSuffixedPrimary(self: *InlineTypeParser) Allocator.Error!?u32 {
        var current = try self.appendLeafNode(1, .name_ref) orelse return null;
        while (true) {
            if (self.peekTokenKind() == .dot) {
                current = (try self.parseAssocSuffix(current)) orelse return null;
                continue;
            }
            if (self.peekTokenKind() == .l_bracket) {
                current = (try self.parseApplySuffix(current)) orelse return null;
                continue;
            }
            break;
        }
        return current;
    }

    fn parseAssocSuffix(self: *InlineTypeParser, base: u32) Allocator.Error!?u32 {
        const start_index = self.nodeTokenStart(base) orelse return null;
        _ = self.consume() orelse return null;
        const member_ref = self.consume() orelse return null;
        const member = self.tokens.getRef(member_ref);
        if (member.kind != .identifier) return null;
        return try self.appendCompositeNode(
            start_index,
            self.cursor - 1,
            .{ .assoc = .{
                .member = self.tokenSpanText(member_ref),
            } },
            &.{base},
        );
    }

    fn parseApplySuffix(self: *InlineTypeParser, base: u32) Allocator.Error!?u32 {
        const start_index = self.nodeTokenStart(base) orelse return null;
        _ = self.consume() orelse return null;

        var args = array_list.Managed(u32).init(self.allocator);
        defer args.deinit();
        try args.append(base);

        if (self.peekTokenKind() == .r_bracket) return null;
        while (true) {
            const arg = if (self.peekTokenKind() == .lifetime_name)
                try self.appendLeafNode(1, .lifetime)
            else
                try self.parseType() orelse return null;
            if (arg == null) return null;
            try args.append(arg.?);
            if (self.matchKind(.comma)) continue;
            if (self.matchKind(.r_bracket)) break;
            return null;
        }

        return try self.appendCompositeNode(start_index, self.cursor - 1, .apply, args.items);
    }

    fn appendLeafNode(self: *InlineTypeParser, count: usize, payload: ast.TypeNode.Payload) Allocator.Error!?u32 {
        if (self.cursor + count > self.token_refs.len) return null;
        const start_index = self.cursor;
        self.cursor += count;
        return try self.appendCompositeNode(start_index, self.cursor - 1, payload, &.{});
    }

    fn appendCompositeNode(
        self: *InlineTypeParser,
        start_index: usize,
        end_index: usize,
        payload: ast.TypeNode.Payload,
        children: []const u32,
    ) Allocator.Error!u32 {
        const child_start: u32 = @intCast(self.child_indices.items.len);
        try self.child_indices.appendSlice(children);
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(.{
            .source = self.spanText(start_index, end_index),
            .child_start = child_start,
            .child_len = @intCast(children.len),
            .payload = payload,
        });
        return index;
    }

    fn spanText(self: *const InlineTypeParser, start_index: usize, end_index: usize) ast.SpanText {
        const first = self.tokens.getRef(self.token_refs[start_index]);
        const last = self.tokens.getRef(self.token_refs[end_index]);
        const local_start = first.span.start - self.token_span_base;
        const local_end = last.span.end - self.token_span_base;
        return .{
            .text = self.source_text.text[local_start..local_end],
            .span = .{
                .file_id = self.source_text.span.file_id,
                .start = self.source_text.span.start + local_start,
                .end = self.source_text.span.start + local_end,
            },
        };
    }

    fn tokenSpanText(self: *const InlineTypeParser, token_ref: syntax.TokenRef) ast.SpanText {
        const token = self.tokens.getRef(token_ref);
        const local_start = token.span.start - self.token_span_base;
        const local_end = token.span.end - self.token_span_base;
        return .{
            .text = self.source_text.text[local_start..local_end],
            .span = .{
                .file_id = self.source_text.span.file_id,
                .start = self.source_text.span.start + local_start,
                .end = self.source_text.span.start + local_end,
            },
        };
    }

    fn nodeTokenStart(self: *const InlineTypeParser, node_index: u32) ?usize {
        const node_start = self.nodes.items[node_index].source.span.start;
        const local_start = node_start - self.source_text.span.start;
        const token_start = self.token_span_base + local_start;
        for (self.token_refs, 0..) |token_ref, index| {
            if (self.tokens.getRef(token_ref).span.start == token_start) return index;
        }
        return null;
    }

    fn peek(self: *const InlineTypeParser) ?syntax.TokenRef {
        if (self.cursor >= self.token_refs.len) return null;
        return self.token_refs[self.cursor];
    }

    fn peekTokenKind(self: *const InlineTypeParser) ?syntax.TokenKind {
        const token_ref = self.peek() orelse return null;
        return self.tokens.getRef(token_ref).kind;
    }

    fn consume(self: *InlineTypeParser) ?syntax.TokenRef {
        const token_ref = self.peek() orelse return null;
        self.cursor += 1;
        return token_ref;
    }

    fn matchKind(self: *InlineTypeParser, kind: syntax.TokenKind) bool {
        if (self.peekTokenKind() != kind) return false;
        _ = self.consume();
        return true;
    }
};

fn appendReorderedNode(
    allocator: Allocator,
    old_index: u32,
    old_nodes: []const ast.TypeNode,
    old_child_indices: []const u32,
    ordered_nodes: *array_list.Managed(ast.TypeNode),
    ordered_child_indices: *array_list.Managed(u32),
    old_to_new: []u32,
) Allocator.Error!u32 {
    if (old_to_new[old_index] != std.math.maxInt(u32)) return old_to_new[old_index];

    const old_node = old_nodes[old_index];
    const new_index: u32 = @intCast(ordered_nodes.items.len);
    old_to_new[old_index] = new_index;
    try ordered_nodes.append(.{
        .source = old_node.source,
        .child_start = 0,
        .child_len = 0,
        .payload = old_node.payload,
    });

    const children = old_child_indices[old_node.child_start .. old_node.child_start + old_node.child_len];
    var reordered_children = array_list.Managed(u32).init(allocator);
    defer reordered_children.deinit();
    for (children) |child_old_index| {
        try reordered_children.append(try appendReorderedNode(
            allocator,
            child_old_index,
            old_nodes,
            old_child_indices,
            ordered_nodes,
            ordered_child_indices,
            old_to_new,
        ));
    }
    const child_start: u32 = @intCast(ordered_child_indices.items.len);
    try ordered_child_indices.appendSlice(reordered_children.items);
    ordered_nodes.items[new_index].child_start = child_start;
    ordered_nodes.items[new_index].child_len = @intCast(children.len);
    return new_index;
}

fn tokenRefsForNodeRange(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ![]syntax.TokenRef {
    const first = tree.firstTokenRef(node_id) orelse return allocator.alloc(syntax.TokenRef, 0);
    const last = tree.lastTokenRef(node_id) orelse return allocator.alloc(syntax.TokenRef, 0);
    const first_index = tokens.indexOfRef(first) orelse return allocator.alloc(syntax.TokenRef, 0);
    const last_index = tokens.indexOfRef(last) orelse return allocator.alloc(syntax.TokenRef, 0);

    var refs = array_list.Managed(syntax.TokenRef).init(allocator);
    defer refs.deinit();
    var iterator = tokens.iterateRange(first_index, last_index + 1);
    while (iterator.next()) |token_ref| try refs.append(token_ref);
    return refs.toOwnedSlice();
}

fn spanTextForNode(
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    node_id: cst.NodeId,
) ?ast.SpanText {
    const span = nodeSpan(tokens, tree, node_id) orelse return null;
    const text = trimTrailingLineEnding(file.contents[span.start..span.end]);
    return .{
        .text = text,
        .span = .{
            .file_id = span.file_id,
            .start = span.start,
            .end = span.start + text.len,
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
    var end = raw.len;
    while (end != 0 and (raw[end - 1] == ' ' or raw[end - 1] == '\t' or raw[end - 1] == '\r' or raw[end - 1] == '\n')) : (end -= 1) {}
    return raw[0..end];
}
