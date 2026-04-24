const std = @import("std");
const array_list = std.array_list;
const syntax = @import("../syntax/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Concrete syntax tree scaffolding.";

pub const NodeRef = struct {
    chunk: *const StoreChunk,
    index: u32,
};

pub const NodeId = NodeRef;
pub const TokenId = syntax.TokenRef;

pub const NodeKind = enum {
    source_file,
    blank_line,
    item,
    attribute_line,
    visibility,
    item_name,
    generic_param_list,
    parameter_list,
    parameter,
    parameter_mode,
    parameter_name,
    parameter_type,
    return_type,
    const_type,
    const_initializer,
    use_path,
    use_alias,
    foreign_abi,
    impl_trait_name,
    impl_target_type,
    field_decl,
    field_name,
    field_type,
    variant_decl,
    variant_name,
    variant_tuple_payload,
    variant_discriminant,
    associated_type_decl,
    associated_type_value,
    module_item,
    use_item,
    function_item,
    suspend_function_item,
    foreign_function_item,
    const_item,
    struct_item,
    enum_item,
    union_item,
    trait_item,
    impl_item,
    opaque_type_item,
    item_header,
    item_signature,
    where_clause,
    block,
    statement,
    select_statement,
    select_head,
    repeat_statement,
    repeat_condition,
    repeat_binding,
    repeat_iterable,
    when_arm,
    else_arm,
    return_statement,
    defer_statement,
    break_statement,
    continue_statement,
    unsafe_statement,
    arm_head,
    pattern_name,
    pattern_wildcard,
    pattern_binding,
    pattern_integer,
    pattern_string,
    pattern_tuple,
    pattern_struct,
    pattern_variant,
    pattern_field_list,
    pattern_field,
    type_name_ref,
    type_lifetime,
    type_apply,
    type_borrow,
    type_assoc,
    expr_name,
    expr_integer,
    expr_string,
    expr_group,
    expr_tuple,
    expr_array,
    expr_array_repeat,
    expr_unary,
    expr_binary,
    expr_field,
    expr_index,
    expr_argument_list,
    expr_call,
    expr_method_call,
    statement_line,
    @"error",
};

pub const MissingToken = struct {
    expected: syntax.TokenKind,
};

pub const Child = union(enum) {
    node: NodeId,
    token: TokenId,
    missing_token: MissingToken,
};

pub const GreenNode = struct {
    kind: NodeKind,
    child_start: u32,
    child_len: u32,
};

pub const StoreChunk = struct {
    ref_count: usize = 1,
    nodes: []GreenNode,
    children: []Child,

    pub fn retain(self: *StoreChunk) void {
        self.ref_count += 1;
    }

    pub fn release(self: *StoreChunk, allocator: Allocator) void {
        std.debug.assert(self.ref_count != 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        allocator.free(self.nodes);
        allocator.free(self.children);
        allocator.destroy(self);
    }
};

pub const Tree = struct {
    chunks: []*StoreChunk,
    root: NodeId,
    token_count: u32,
    trivia_count: u32,

    pub fn deinit(self: *Tree, allocator: Allocator) void {
        for (self.chunks) |chunk| chunk.release(allocator);
        allocator.free(self.chunks);
        self.* = .{
            .chunks = &.{},
            .root = undefined,
            .token_count = 0,
            .trivia_count = 0,
        };
    }

    pub fn fromLexedFile(
        allocator: Allocator,
        tokens: syntax.TokenStore,
        trivia: syntax.TriviaStore,
    ) !Tree {
        const nodes = try allocator.alloc(GreenNode, 1);
        errdefer allocator.free(nodes);
        nodes[0] = .{
            .kind = .source_file,
            .child_start = 0,
            .child_len = @intCast(tokens.len()),
        };

        const children = try allocator.alloc(Child, tokens.len());
        errdefer allocator.free(children);
        for (0..tokens.len()) |index| {
            children[index] = .{ .token = tokens.refAt(index) };
        }

        const chunk = try allocator.create(StoreChunk);
        errdefer allocator.destroy(chunk);
        chunk.* = .{
            .nodes = nodes,
            .children = children,
        };

        return try initFromOwnedChunks(
            allocator,
            &.{chunk},
            .{
                .chunk = chunk,
                .index = 0,
            },
            @intCast(tokens.len()),
            @intCast(trivia.len()),
        );
    }

    pub fn rootNode(self: *const Tree) GreenNode {
        return self.node(self.root);
    }

    pub fn childSlice(self: *const Tree, node_id: NodeId) []const Child {
        const green = self.node(node_id);
        return node_id.chunk.children[green.child_start .. green.child_start + green.child_len];
    }

    pub fn node(self: *const Tree, node_id: NodeId) GreenNode {
        _ = self;
        return node_id.chunk.nodes[node_id.index];
    }

    pub fn nodeKind(self: *const Tree, node_id: NodeId) NodeKind {
        return self.node(node_id).kind;
    }

    pub fn firstTokenRef(self: *const Tree, node_id: NodeId) ?TokenId {
        for (self.childSlice(node_id)) |child| {
            switch (child) {
                .token => |token_id| return token_id,
                .node => |child_node| if (self.firstTokenRef(child_node)) |token_id| return token_id,
                .missing_token => {},
            }
        }
        return null;
    }

    pub fn lastTokenRef(self: *const Tree, node_id: NodeId) ?TokenId {
        const children = self.childSlice(node_id);
        var index = children.len;
        while (index != 0) {
            index -= 1;
            switch (children[index]) {
                .token => |token_id| return token_id,
                .node => |child_node| if (self.lastTokenRef(child_node)) |token_id| return token_id,
                .missing_token => {},
            }
        }
        return null;
    }

    pub fn nodeCount(self: *const Tree) usize {
        var total: usize = 0;
        for (self.chunks) |chunk| total += chunk.nodes.len;
        return total;
    }

    pub fn childCount(self: *const Tree) usize {
        var total: usize = 0;
        for (self.chunks) |chunk| total += chunk.children.len;
        return total;
    }
};

fn initFromOwnedChunks(
    allocator: Allocator,
    owned_chunks: []const *StoreChunk,
    root: NodeId,
    token_count: u32,
    trivia_count: u32,
) !Tree {
    const chunks = try allocator.alloc(*StoreChunk, owned_chunks.len);
    errdefer allocator.free(chunks);
    for (owned_chunks, 0..) |chunk, index| {
        chunks[index] = chunk;
    }
    return .{
        .chunks = chunks,
        .root = root,
        .token_count = token_count,
        .trivia_count = trivia_count,
    };
}

pub fn parseLexedFile(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
) !Tree {
    var builder = Builder.init(allocator, tokens);
    defer builder.deinit();

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .trivia = trivia,
        .builder = &builder,
    };
    return parser.parse();
}

pub fn parseLexedExpression(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
) !Tree {
    var builder = Builder.init(allocator, tokens);
    defer builder.deinit();

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .trivia = trivia,
        .builder = &builder,
    };
    return parser.parseStandaloneExpression();
}

pub fn parseLexedPattern(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
) !Tree {
    var builder = Builder.init(allocator, tokens);
    defer builder.deinit();

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .trivia = trivia,
        .builder = &builder,
    };
    return parser.parseStandalonePattern();
}

pub fn parseLexedBlock(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
    mode: BlockMode,
) !Tree {
    var builder = Builder.init(allocator, tokens);
    defer builder.deinit();

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .trivia = trivia,
        .builder = &builder,
    };
    return parser.parseStandaloneBlock(mode);
}

const Builder = struct {
    allocator: Allocator,
    tokens: syntax.TokenStore,
    nodes: array_list.Managed(GreenNode),
    children: array_list.Managed(Child),

    fn init(allocator: Allocator, tokens: syntax.TokenStore) Builder {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .nodes = array_list.Managed(GreenNode).init(allocator),
            .children = array_list.Managed(Child).init(allocator),
        };
    }

    fn deinit(self: *Builder) void {
        self.nodes.deinit();
        self.children.deinit();
    }

    fn appendNode(self: *Builder, kind: NodeKind, child_items: []const Child) !NodeId {
        const child_start: u32 = @intCast(self.children.items.len);
        try self.children.appendSlice(child_items);
        const node_id = NodeId{
            .chunk = undefined,
            .index = @intCast(self.nodes.items.len),
        };
        try self.nodes.append(.{
            .kind = kind,
            .child_start = child_start,
            .child_len = @intCast(child_items.len),
        });
        return node_id;
    }

    fn appendTokenRange(self: *Builder, kind: NodeKind, start: usize, end: usize) !NodeId {
        const child_start: u32 = @intCast(self.children.items.len);
        for (start..end) |token_index| {
            try self.children.append(.{ .token = self.tokens.refAt(token_index) });
        }

        const node_id = NodeId{
            .chunk = undefined,
            .index = @intCast(self.nodes.items.len),
        };
        try self.nodes.append(.{
            .kind = kind,
            .child_start = child_start,
            .child_len = @intCast(end - start),
        });
        return node_id;
    }

    fn finish(
        self: *Builder,
        root: NodeId,
        tokens: syntax.TokenStore,
        trivia: syntax.TriviaStore,
    ) !Tree {
        const nodes = try self.nodes.toOwnedSlice();
        errdefer self.allocator.free(nodes);
        const children = try self.children.toOwnedSlice();
        errdefer self.allocator.free(children);

        const chunk = try self.allocator.create(StoreChunk);
        errdefer self.allocator.destroy(chunk);
        for (children) |*child| {
            switch (child.*) {
                .node => |*node_id| node_id.chunk = chunk,
                else => {},
            }
        }

        chunk.* = .{
            .nodes = nodes,
            .children = children,
        };

        self.* = Builder.init(self.allocator, self.tokens);
        return try initFromOwnedChunks(
            self.allocator,
            &.{chunk},
            .{
                .chunk = chunk,
                .index = root.index,
            },
            @intCast(tokens.len()),
            @intCast(trivia.len()),
        );
    }
};

const Parser = struct {
    allocator: Allocator,
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
    builder: *Builder,
    index: usize = 0,

    fn parse(self: *Parser) !Tree {
        var root_children = array_list.Managed(Child).init(self.allocator);
        defer root_children.deinit();

        while (true) {
            while (self.currentKind() == .newline) {
                try root_children.append(.{ .node = try self.parseBlankLine() });
            }
            if (self.currentKind() == .eof) break;
            try root_children.append(.{ .node = try self.parseTopLevelNode() });
        }

        const root = try self.builder.appendNode(.source_file, root_children.items);
        return self.builder.finish(root, self.tokens, self.trivia);
    }

    fn parseStandaloneExpression(self: *Parser) !Tree {
        while (self.currentKind() == .newline) self.index += 1;
        const end = self.findStandaloneEnd();
        const root = try self.parseExpressionSlice(self.index, end);
        self.index = end;
        return self.builder.finish(root, self.tokens, self.trivia);
    }

    fn parseStandalonePattern(self: *Parser) !Tree {
        while (self.currentKind() == .newline) self.index += 1;
        const end = self.findStandaloneEnd();
        const root = try parsePatternSlice(self, self.index, end);
        self.index = end;
        return self.builder.finish(root, self.tokens, self.trivia);
    }

    fn parseStandaloneBlock(self: *Parser, mode: BlockMode) !Tree {
        while (self.currentKind() == .newline) self.index += 1;
        const root = try self.parseBlockWithMode(mode);
        return self.builder.finish(root, self.tokens, self.trivia);
    }

    fn findStandaloneEnd(self: *const Parser) usize {
        var end = self.tokens.len();
        while (end != 0) {
            end -= 1;
            switch (self.tokens.get(end).kind) {
                .eof, .newline => continue,
                else => return end + 1,
            }
        }
        return 0;
    }

    fn parseBlankLine(self: *Parser) !NodeId {
        const start = self.index;
        self.index += 1;
        return self.builder.appendTokenRange(.blank_line, start, self.index);
    }

    fn parseTopLevelNode(self: *Parser) !NodeId {
        if (self.currentKind() == .indent or self.currentKind() == .dedent) {
            const start = self.index;
            self.consumeLineRemainder();
            return self.builder.appendTokenRange(.@"error", start, self.index);
        }

        var item_children = array_list.Managed(Child).init(self.allocator);
        defer item_children.deinit();

        while (self.isAttributeLineStart()) {
            try item_children.append(.{ .node = try self.parseAttributeLine() });
        }

        if (self.currentKind() == .eof) {
            if (item_children.items.len != 0) return self.builder.appendNode(.@"error", item_children.items);
            return self.builder.appendTokenRange(.@"error", self.index, self.index);
        }

        const item_kind = self.classifyItemKind() orelse {
            try item_children.append(.{ .node = try self.parseBrokenItem() });
            return self.builder.appendNode(.item, item_children.items);
        };

        try item_children.append(.{ .node = try self.parseTypedItem(item_kind) });
        return self.builder.appendNode(.item, item_children.items);
    }

    fn parseAttributeLine(self: *Parser) !NodeId {
        return self.parseLineNode(.attribute_line);
    }

    fn parseBrokenItem(self: *Parser) !NodeId {
        const start = self.index;
        self.consumeLineRemainder();
        return self.builder.appendTokenRange(.@"error", start, self.index);
    }

    fn parseTypedItem(self: *Parser, item_kind: NodeKind) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseItemHeader(item_kind) });
        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseItemBody(item_kind) });
        }
        return self.builder.appendNode(item_kind, children.items);
    }

    fn parseItemBody(self: *Parser, item_kind: NodeKind) anyerror!NodeId {
        const mode: BlockMode = switch (item_kind) {
            .struct_item => .struct_fields,
            .union_item => .union_fields,
            .enum_item => .enum_variants,
            .trait_item => .trait_members,
            .impl_item => .impl_members,
            else => .ordinary,
        };
        return self.parseBlockWithMode(mode);
    }

    fn parseItemHeader(self: *Parser, item_kind: NodeKind) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseItemSignature(item_kind) });
        while (self.currentKind() == .keyword_where) {
            try children.append(.{ .node = try self.parseLineNode(.where_clause) });
        }
        return self.builder.appendNode(.item_header, children.items);
    }

    fn parseItemSignature(self: *Parser, item_kind: NodeKind) !NodeId {
        const line_end = self.findLineEnd();
        return switch (item_kind) {
            .function_item, .suspend_function_item, .foreign_function_item => self.parseFunctionSignature(line_end),
            .const_item => self.parseConstSignature(line_end),
            .module_item => self.parseModuleSignature(line_end),
            .use_item => self.parseUseSignature(line_end),
            .impl_item => self.parseImplSignature(line_end),
            .struct_item, .enum_item, .union_item, .trait_item, .opaque_type_item => self.parseNamedTypeSignature(line_end),
            else => self.parseRawSignature(line_end),
        };
    }

    fn parseFunctionSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);

        if (self.currentKind() == .keyword_extern) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
            if (self.currentKind() == .l_bracket) {
                try children.append(.{ .node = try self.parseDelimitedRange(.foreign_abi, .l_bracket, .r_bracket, line_end) });
            }
        }

        while (self.index < line_end and self.currentKind() != .identifier) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .l_bracket) {
            try children.append(.{ .node = try self.parseDelimitedRange(.generic_param_list, .l_bracket, .r_bracket, line_end) });
        }

        if (self.currentKind() == .l_paren) {
            try children.append(.{ .node = try self.parseParameterList(line_end) });
        }

        if (self.currentKind() == .arrow) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;

            const type_end = self.findTrailingColonBoundary(line_end);
            if (self.index < type_end) {
                try children.append(.{ .node = try self.parseTypeNode(.return_type, self.index, type_end) });
                self.index = type_end;
            }
        }

        if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_signature, self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseConstSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);

        if (self.currentKind() == .keyword_const) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .colon) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;

            const type_end = self.findTopLevelToken(self.index, line_end, .equal) orelse line_end;
            if (self.index < type_end) {
                try children.append(.{ .node = try self.parseTypeNode(.const_type, self.index, type_end) });
                self.index = type_end;
            }
        }

        if (self.currentKind() == .equal) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
            if (self.index < line_end) {
                try children.append(.{ .node = try self.parseExpressionNode(.const_initializer, self.index, line_end) });
                self.index = line_end;
            }
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseModuleSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);
        if (self.currentKind() == .keyword_mod) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseImplSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        if (self.currentKind() == .keyword_impl) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .l_bracket) {
            try children.append(.{ .node = try self.parseDelimitedRange(.generic_param_list, .l_bracket, .r_bracket, line_end) });
        }

        const for_index = self.findTopLevelToken(self.index, self.findTrailingColonBoundary(line_end), .keyword_for);
        if (for_index) |index_for| {
            if (self.index < index_for) {
                try children.append(.{ .node = try self.parseTypeNode(.impl_trait_name, self.index, index_for) });
                self.index = index_for;
            }
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        const target_end = self.findTrailingColonBoundary(line_end);
        if (self.index < target_end) {
            try children.append(.{ .node = try self.parseTypeNode(.impl_target_type, self.index, target_end) });
            self.index = target_end;
        }

        if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_signature, self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseUseSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);
        if (self.currentKind() == .keyword_use) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        const alias_index = self.findAliasIndex(self.index, line_end);
        const path_end = alias_index orelse line_end;
        if (self.index < path_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.use_path, self.index, path_end) });
            self.index = path_end;
        }

        if (alias_index) |_| {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
            if (self.index < line_end) {
                try children.append(.{ .node = try self.builder.appendTokenRange(.use_alias, self.index, line_end) });
                self.index = line_end;
            }
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseNamedTypeSignature(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);
        while (self.index < line_end and self.currentKind() != .identifier) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .l_bracket) {
            try children.append(.{ .node = try self.parseDelimitedRange(.generic_param_list, .l_bracket, .r_bracket, line_end) });
        }

        if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_signature, self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseRawSignature(self: *Parser, line_end: usize) !NodeId {
        const start = self.index;
        self.index = line_end;

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();
        if (start < line_end) try children.append(.{ .node = try self.builder.appendTokenRange(.item_signature, start, line_end) });
        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }
        return self.builder.appendNode(.item_signature, children.items);
    }

    fn parseParameterList(self: *Parser, line_end: usize) !NodeId {
        const open_index = self.index;
        self.index += 1;

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.tokens.refAt(open_index) });

        while (self.index < line_end and self.currentKind() != .r_paren) {
            try children.append(.{ .node = try self.parseParameter(line_end) });
            if (self.currentKind() == .comma) {
                try children.append(.{ .token = self.tokens.refAt(self.index) });
                self.index += 1;
                continue;
            }
            break;
        }

        if (self.currentKind() == .r_paren) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_paren } });
        }
        return self.builder.appendNode(.parameter_list, children.items);
    }

    fn parseParameter(self: *Parser, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        if (self.currentKind() == .identifier and self.isParameterModeLexeme(self.tokens.get(self.index).lexeme)) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.parameter_mode, self.index, self.index + 1) });
            self.index += 1;
        }

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.parameter_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .colon) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;

            const type_end = self.findParameterTypeEnd(line_end);
            if (self.index < type_end) {
                try children.append(.{ .node = try self.parseTypeNode(.parameter_type, self.index, type_end) });
                self.index = type_end;
            }
        } else {
            try children.append(.{ .missing_token = .{ .expected = .colon } });
        }

        return self.builder.appendNode(.parameter, children.items);
    }

    fn parseDelimitedRange(self: *Parser, kind: NodeKind, open_kind: syntax.TokenKind, close_kind: syntax.TokenKind, line_end: usize) !NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        if (self.currentKind() != open_kind) {
            try children.append(.{ .missing_token = .{ .expected = open_kind } });
            return self.builder.appendNode(kind, children.items);
        }

        var depth: usize = 0;
        while (self.index < line_end) : (self.index += 1) {
            const token_kind = self.currentKind();
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            if (token_kind == open_kind) {
                depth += 1;
            } else if (token_kind == close_kind) {
                depth -= 1;
                if (depth == 0) {
                    self.index += 1;
                    break;
                }
            }
        }
        if (depth != 0) {
            try children.append(.{ .missing_token = .{ .expected = close_kind } });
        }
        return self.builder.appendNode(kind, children.items);
    }

    fn appendVisibilityIfPresent(self: *Parser, children: *array_list.Managed(Child), line_end: usize) !void {
        const start = self.index;
        if (self.currentKind() != .keyword_pub) return;

        self.index += 1;
        if (self.currentKind() == .l_paren and self.index + 2 < line_end and self.tokenKindAt(self.index + 1) == .keyword_package and self.tokenKindAt(self.index + 2) == .r_paren) {
            self.index += 3;
        }

        try children.append(.{ .node = try self.builder.appendTokenRange(.visibility, start, self.index) });
    }

    fn findTrailingColonBoundary(self: *const Parser, line_end: usize) usize {
        if (line_end > self.index and self.tokenKindAt(line_end - 1) == .colon) return line_end - 1;
        return line_end;
    }

    fn findParameterTypeEnd(self: *const Parser, line_end: usize) usize {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var cursor = self.index;
        while (cursor < line_end) : (cursor += 1) {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth == 0 and bracket_depth == 0) return cursor;
                    if (paren_depth != 0) paren_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => {
                    if (bracket_depth != 0) bracket_depth -= 1;
                },
                .comma => if (paren_depth == 0 and bracket_depth == 0) return cursor,
                else => {},
            }
        }
        return line_end;
    }

    fn findAliasIndex(self: *const Parser, start: usize, line_end: usize) ?usize {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var cursor = start;
        while (cursor < line_end) : (cursor += 1) {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth != 0) paren_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => {
                    if (bracket_depth != 0) bracket_depth -= 1;
                },
                .l_brace => brace_depth += 1,
                .r_brace => {
                    if (brace_depth != 0) brace_depth -= 1;
                },
                .identifier => {
                    if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and std.mem.eql(u8, self.tokens.get(cursor).lexeme, "as")) {
                        return cursor;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn isParameterModeLexeme(self: *const Parser, lexeme: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, lexeme, "read") or std.mem.eql(u8, lexeme, "edit") or std.mem.eql(u8, lexeme, "take");
    }

    fn parseBlock(self: *Parser) anyerror!NodeId {
        return self.parseBlockWithMode(.ordinary);
    }

    fn parseBlockWithMode(self: *Parser, mode: BlockMode) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        if (self.currentKind() != .indent) {
            try children.append(.{ .missing_token = .{ .expected = .indent } });
            return self.builder.appendNode(.block, children.items);
        }

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        while (true) {
            switch (self.currentKind()) {
                .newline => try children.append(.{ .node = try self.parseBlankLine() }),
                .dedent => {
                    try children.append(.{ .token = self.tokens.refAt(self.index) });
                    self.index += 1;
                    break;
                },
                .eof => {
                    try children.append(.{ .missing_token = .{ .expected = .dedent } });
                    break;
                },
                else => try children.append(.{ .node = try self.parseBlockEntry(mode) }),
            }
        }

        return self.builder.appendNode(.block, children.items);
    }

    fn parseBlockEntry(self: *Parser, mode: BlockMode) anyerror!NodeId {
        return switch (mode) {
            .ordinary, .guarded_select_arms, .subject_select_arms => self.parseStatement(mode),
            .struct_fields, .union_fields => self.parseFieldDecl(),
            .enum_variants => self.parseEnumVariantDecl(),
            .trait_members => self.parseTraitMember(),
            .impl_members => self.parseImplMember(),
        };
    }

    fn parseStatement(self: *Parser, mode: BlockMode) anyerror!NodeId {
        if (self.currentKind() == .indent or self.currentKind() == .dedent) {
            const start = self.index;
            self.consumeLineRemainder();
            return self.builder.appendTokenRange(.@"error", start, self.index);
        }

        return switch (self.classifyStatementKind()) {
            .select_statement => self.parseSelectStatement(),
            .repeat_statement => self.parseRepeatStatement(),
            .return_statement => self.parseReturnStatement(),
            .defer_statement => self.parseDeferStatement(),
            .break_statement => self.parseBreakStatement(),
            .continue_statement => self.parseContinueStatement(),
            .unsafe_statement => self.parseUnsafeStatement(),
            .when_arm => self.parseWhenArm(mode),
            .else_arm => self.parseElseArm(),
            else => self.parseGenericStatement(),
        };
    }

    fn parseSelectStatement(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        const colon_index = self.findTopLevelToken(self.index, line_end, .colon) orelse return self.parseRawStatement(.select_statement);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        const arm_mode: BlockMode = if (self.index < colon_index) .subject_select_arms else .guarded_select_arms;
        if (self.index < colon_index) {
            var head_children = array_list.Managed(Child).init(self.allocator);
            defer head_children.deinit();
            try head_children.append(.{ .node = try self.parseExpressionSlice(self.index, colon_index) });
            try children.append(.{ .node = try self.builder.appendNode(.select_head, head_children.items) });
            self.index = colon_index;
        }

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(arm_mode) });
        }

        return self.builder.appendNode(.select_statement, children.items);
    }

    fn parseRepeatStatement(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        const colon_index = self.findTopLevelToken(self.index, line_end, .colon) orelse return self.parseRawStatement(.repeat_statement);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.index < colon_index) {
            if (self.currentKind() == .keyword_while) {
                try children.append(.{ .token = self.tokens.refAt(self.index) });
                self.index += 1;
                if (self.index < colon_index) {
                    try children.append(.{ .node = try self.parseExpressionNode(.repeat_condition, self.index, colon_index) });
                    self.index = colon_index;
                }
            } else if (self.findTopLevelToken(self.index, colon_index, .keyword_in)) |in_index| {
                if (self.index < in_index) {
                    try children.append(.{ .node = try self.parsePatternNode(.repeat_binding, self.index, in_index) });
                }
                self.index = in_index;
                try children.append(.{ .token = self.tokens.refAt(self.index) });
                self.index += 1;
                if (self.index < colon_index) {
                    try children.append(.{ .node = try self.parseExpressionNode(.repeat_iterable, self.index, colon_index) });
                    self.index = colon_index;
                }
            } else {
                try children.append(.{ .node = try self.builder.appendTokenRange(.statement_line, self.index, colon_index) });
                self.index = colon_index;
            }
        }

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }

        return self.builder.appendNode(.repeat_statement, children.items);
    }

    fn parseReturnStatement(self: *Parser) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        const line_end = self.findLineEnd();
        if (self.index < line_end) {
            try children.append(.{ .node = try self.parseExpressionSlice(self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.return_statement, children.items);
    }

    fn parseDeferStatement(self: *Parser) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        const line_end = self.findLineEnd();
        if (self.index < line_end) {
            try children.append(.{ .node = try self.parseExpressionSlice(self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.defer_statement, children.items);
    }

    fn parseBreakStatement(self: *Parser) anyerror!NodeId {
        return self.parseSimpleControlStatement(.break_statement);
    }

    fn parseContinueStatement(self: *Parser) anyerror!NodeId {
        return self.parseSimpleControlStatement(.continue_statement);
    }

    fn parseSimpleControlStatement(self: *Parser, kind: NodeKind) anyerror!NodeId {
        const line_end = self.findLineEnd();
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(kind, children.items);
    }

    fn parseUnsafeStatement(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        const colon_index = self.findTopLevelToken(self.index, line_end, .colon) orelse return self.parseRawStatement(.unsafe_statement);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .identifier and std.mem.eql(u8, self.tokens.get(self.index).lexeme, "unsafe")) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.index < colon_index) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", self.index, colon_index) });
            self.index = colon_index;
        }

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }

        return self.builder.appendNode(.unsafe_statement, children.items);
    }

    fn parseWhenArm(self: *Parser, mode: BlockMode) anyerror!NodeId {
        const line_end = self.findLineEnd();
        const arrow_index = self.findTopLevelToken(self.index, line_end, .fat_arrow) orelse return self.parseRawStatement(.when_arm);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.index < arrow_index) {
            const head_node = switch (mode) {
                .subject_select_arms => try self.parsePatternNode(.arm_head, self.index, arrow_index),
                else => try self.parseExpressionNode(.arm_head, self.index, arrow_index),
            };
            try children.append(.{ .node = head_node });
        }

        self.index = arrow_index;
        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.index < line_end) {
            try children.append(.{ .node = try self.parseInlineStatement(line_end) });
        } else if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }

        return self.builder.appendNode(.when_arm, children.items);
    }

    fn parseElseArm(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        const arrow_index = self.findTopLevelToken(self.index, line_end, .fat_arrow) orelse return self.parseRawStatement(.else_arm);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        self.index = arrow_index;
        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.index < line_end) {
            try children.append(.{ .node = try self.parseInlineStatement(line_end) });
        } else if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }

        return self.builder.appendNode(.else_arm, children.items);
    }

    fn parseGenericStatement(self: *Parser) anyerror!NodeId {
        const kind = self.classifyStatementKind();
        const line_end = self.findLineEnd();
        if (kind == .statement and self.shouldTryExpressionStatement(self.index, line_end)) {
            return self.parseExpressionStatement(kind, line_end);
        }
        return self.parseRawStatement(kind);
    }

    fn parseExpressionStatement(self: *Parser, kind: NodeKind, line_end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseExpressionSlice(self.index, line_end) });
        self.index = line_end;

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }

        return self.builder.appendNode(kind, children.items);
    }

    fn parseInlineStatement(self: *Parser, line_end: usize) anyerror!NodeId {
        return switch (self.classifyStatementKind()) {
            .return_statement => self.parseReturnStatement(),
            .defer_statement => self.parseDeferStatement(),
            .break_statement => self.parseBreakStatement(),
            .continue_statement => self.parseContinueStatement(),
            else => self.parseInlineExpressionStatement(line_end),
        };
    }

    fn parseInlineExpressionStatement(self: *Parser, line_end: usize) anyerror!NodeId {
        if (!self.shouldTryExpressionStatement(self.index, line_end)) return self.parseRawInlineStatement(.statement);

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseExpressionSlice(self.index, line_end) });
        self.index = line_end;

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.statement, children.items);
    }

    fn parseRawStatement(self: *Parser, kind: NodeKind) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseLineNode(.statement_line) });
        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlock() });
        }
        return self.builder.appendNode(kind, children.items);
    }

    fn parseRawInlineStatement(self: *Parser, kind: NodeKind) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseLineNode(.statement_line) });
        return self.builder.appendNode(kind, children.items);
    }

    fn parseFieldDecl(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try self.appendVisibilityIfPresent(&children, line_end);

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.field_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .colon) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;

            if (self.index < line_end) {
                try children.append(.{ .node = try self.parseTypeNode(.field_type, self.index, line_end) });
                self.index = line_end;
            }
        } else if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.field_decl, children.items);
    }

    fn parseEnumVariantDecl(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.variant_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .l_paren) {
            try children.append(.{ .node = try self.parseDelimitedRange(.variant_tuple_payload, .l_paren, .r_paren, line_end) });
        }

        if (self.currentKind() == .equal) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
            if (self.index < line_end) {
                try children.append(.{ .node = try self.builder.appendTokenRange(.variant_discriminant, self.index, line_end) });
                self.index = line_end;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .integer_literal } });
            }
        } else if (self.currentKind() == .colon) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        } else if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.struct_fields) });
        }

        return self.builder.appendNode(.variant_decl, children.items);
    }

    fn parseTraitMember(self: *Parser) anyerror!NodeId {
        if (self.currentKind() == .keyword_type) return self.parseAssociatedTypeDecl();
        return self.parseMethodMember();
    }

    fn parseImplMember(self: *Parser) anyerror!NodeId {
        if (self.currentKind() == .keyword_type) return self.parseAssociatedTypeDecl();
        return self.parseMethodMember();
    }

    fn parseAssociatedTypeDecl(self: *Parser) anyerror!NodeId {
        const line_end = self.findLineEnd();
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .identifier) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.item_name, self.index, self.index + 1) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .equal) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
            if (self.index < line_end) {
                try children.append(.{ .node = try self.parseTypeNode(.associated_type_value, self.index, line_end) });
                self.index = line_end;
            }
        } else if (self.index < line_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", self.index, line_end) });
            self.index = line_end;
        }

        if (self.currentKind() == .newline) {
            try children.append(.{ .token = self.tokens.refAt(self.index) });
            self.index += 1;
        }

        return self.builder.appendNode(.associated_type_decl, children.items);
    }

    fn parseMethodMember(self: *Parser) anyerror!NodeId {
        const item_kind = self.classifyMethodItemKind() orelse return self.parseBrokenItem();

        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = try self.parseItemHeader(item_kind) });
        if (self.currentKind() == .indent) {
            try children.append(.{ .node = try self.parseBlockWithMode(.ordinary) });
        }
        return self.builder.appendNode(item_kind, children.items);
    }

    fn parseLineNode(self: *Parser, kind: NodeKind) !NodeId {
        const start = self.index;
        while (self.index < self.tokens.len()) : (self.index += 1) {
            const token_kind = self.tokens.get(self.index).kind;
            if (token_kind == .eof or token_kind == .dedent) break;
            if (token_kind == .newline) {
                self.index += 1;
                break;
            }
        }
        return self.builder.appendTokenRange(kind, start, self.index);
    }

    fn consumeLineRemainder(self: *Parser) void {
        while (self.index < self.tokens.len()) : (self.index += 1) {
            const token_kind = self.tokens.get(self.index).kind;
            if (token_kind == .newline) {
                self.index += 1;
                return;
            }
            if (token_kind == .eof) return;
        }
    }

    fn findLineEnd(self: *const Parser) usize {
        var cursor = self.index;
        while (cursor < self.tokens.len()) : (cursor += 1) {
            const kind = self.tokens.get(cursor).kind;
            if (kind == .newline or kind == .dedent or kind == .eof) break;
        }
        return cursor;
    }

    fn shouldTryExpressionStatement(self: *const Parser, start: usize, end: usize) bool {
        if (start >= end) return false;

        switch (self.tokenKindAt(start)) {
            .identifier, .integer_literal, .string_literal, .l_paren, .l_bracket, .bang, .minus, .tilde => {},
            else => return false,
        }

        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        for (start..end) |cursor| {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth != 0) paren_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => {
                    if (bracket_depth != 0) bracket_depth -= 1;
                },
                .equal, .fat_arrow => if (paren_depth == 0 and bracket_depth == 0) return false,
                else => {},
            }
        }
        return true;
    }

    fn findTopLevelToken(self: *const Parser, start: usize, end: usize, target: syntax.TokenKind) ?usize {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var cursor = start;
        while (cursor < end) : (cursor += 1) {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth != 0) paren_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => {
                    if (bracket_depth != 0) bracket_depth -= 1;
                },
                else => {},
            }
            if (paren_depth == 0 and bracket_depth == 0 and self.tokenKindAt(cursor) == target) return cursor;
        }
        return null;
    }

    fn parseExpressionSlice(self: *Parser, start: usize, end: usize) anyerror!NodeId {
        if (start >= end) return self.builder.appendTokenRange(.@"error", start, end);

        var parser = ExprParser{
            .parser = self,
            .start = start,
            .end = end,
            .index = start,
        };
        const parsed = try parser.parsePrecedence(0);
        if (parser.index == end) return parsed;
        return self.wrapRecoveredNode(parsed, parser.index, end);
    }

    fn parseExpressionNode(self: *Parser, kind: NodeKind, start: usize, end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();
        try children.append(.{ .node = try self.parseExpressionSlice(start, end) });
        return self.builder.appendNode(kind, children.items);
    }

    fn parsePatternNode(self: *Parser, kind: NodeKind, start: usize, end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();
        try children.append(.{ .node = try parsePatternSlice(self, start, end) });
        return self.builder.appendNode(kind, children.items);
    }

    fn parseTypeNode(self: *Parser, kind: NodeKind, start: usize, end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();
        try children.append(.{ .node = try parseTypeSlice(self, start, end) });
        return self.builder.appendNode(kind, children.items);
    }

    fn wrapRecoveredNode(self: *Parser, parsed: NodeId, trailing_start: usize, trailing_end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.allocator);
        defer children.deinit();

        try children.append(.{ .node = parsed });
        if (trailing_start < trailing_end) {
            try children.append(.{ .node = try self.builder.appendTokenRange(.@"error", trailing_start, trailing_end) });
        }
        return self.builder.appendNode(.@"error", children.items);
    }

    fn classifyItemKind(self: *const Parser) ?NodeKind {
        var cursor = self.index;

        if (self.tokenKindAt(cursor) == .keyword_pub) {
            cursor += 1;
            if (self.tokenKindAt(cursor) == .l_paren and self.tokenKindAt(cursor + 1) == .keyword_package and self.tokenKindAt(cursor + 2) == .r_paren) {
                cursor += 3;
            }
        }

        return switch (self.tokenKindAt(cursor)) {
            .keyword_suspend => if (self.tokenKindAt(cursor + 1) == .keyword_fn) .suspend_function_item else null,
            .keyword_fn => .function_item,
            .keyword_extern => .foreign_function_item,
            .keyword_const => .const_item,
            .keyword_struct => .struct_item,
            .keyword_enum => .enum_item,
            .keyword_union => .union_item,
            .keyword_trait => .trait_item,
            .keyword_impl => .impl_item,
            .keyword_opaque => if (self.tokenKindAt(cursor + 1) == .keyword_type) .opaque_type_item else null,
            .keyword_mod => .module_item,
            .keyword_use => .use_item,
            else => null,
        };
    }

    fn classifyMethodItemKind(self: *const Parser) ?NodeKind {
        return switch (self.currentKind()) {
            .keyword_suspend => if (self.tokenKindAt(self.index + 1) == .keyword_fn) .suspend_function_item else null,
            .keyword_fn => .function_item,
            else => null,
        };
    }

    fn isAttributeLineStart(self: *const Parser) bool {
        return self.currentKind() == .hash;
    }

    fn classifyStatementKind(self: *const Parser) NodeKind {
        return switch (self.currentKind()) {
            .keyword_select => .select_statement,
            .keyword_repeat => .repeat_statement,
            .keyword_when => .when_arm,
            .keyword_else => .else_arm,
            .keyword_return => .return_statement,
            .keyword_defer => .defer_statement,
            .keyword_break => .break_statement,
            .keyword_continue => .continue_statement,
            .hash => if (self.tokenKindAt(self.index + 1) == .identifier and std.mem.eql(u8, self.tokens.get(self.index + 1).lexeme, "unsafe")) .unsafe_statement else .statement,
            else => .statement,
        };
    }

    fn currentKind(self: *const Parser) syntax.TokenKind {
        return self.tokenKindAt(self.index);
    }

    fn tokenKindAt(self: *const Parser, index: usize) syntax.TokenKind {
        if (index >= self.tokens.len()) return .eof;
        return self.tokens.get(index).kind;
    }
};

pub const BlockMode = enum {
    ordinary,
    guarded_select_arms,
    subject_select_arms,
    struct_fields,
    union_fields,
    enum_variants,
    trait_members,
    impl_members,
};

fn parsePatternSlice(parser: *Parser, start: usize, end: usize) anyerror!NodeId {
    if (start >= end) return parser.builder.appendTokenRange(.@"error", start, end);

    var pattern_parser = PatternParser{
        .parser = parser,
        .start = start,
        .end = end,
        .index = start,
    };
    const parsed = try pattern_parser.parsePattern();
    if (pattern_parser.index == end) return parsed;
    return parser.wrapRecoveredNode(parsed, pattern_parser.index, end);
}

fn parseTypeSlice(parser: *Parser, start: usize, end: usize) anyerror!NodeId {
    if (start >= end) return parser.builder.appendTokenRange(.@"error", start, end);

    var type_parser = TypeParser{
        .parser = parser,
        .start = start,
        .end = end,
        .index = start,
    };
    const parsed = try type_parser.parseType();
    if (type_parser.index == end) return parsed;
    return parser.wrapRecoveredNode(parsed, type_parser.index, end);
}

const PatternParser = struct {
    parser: *Parser,
    start: usize,
    end: usize,
    index: usize,

    fn parse(self: *PatternParser) anyerror!NodeId {
        const pattern = try self.parsePattern();
        if (self.index != self.end) return self.parser.builder.appendTokenRange(.@"error", self.start, self.end);
        return pattern;
    }

    fn parsePattern(self: *PatternParser) anyerror!NodeId {
        return switch (self.currentKind()) {
            .identifier => self.parseIdentifierPattern(),
            .integer_literal => self.parseLeaf(.pattern_integer),
            .string_literal => self.parseLeaf(.pattern_string),
            .l_paren => self.parseTuplePattern(),
            else => self.parseErrorLeaf(),
        };
    }

    fn parseIdentifierPattern(self: *PatternParser) anyerror!NodeId {
        if (std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "_")) return self.parseLeaf(.pattern_wildcard);

        const path_start = self.index;
        self.index += 1;
        var has_dot = false;
        while (self.currentKind() == .dot and self.index + 1 < self.end and self.tokenKindAt(self.index + 1) == .identifier) {
            has_dot = true;
            self.index += 2;
        }
        const path_end = self.index;

        if (!has_dot and self.currentKind() != .l_paren) {
            return self.parser.builder.appendTokenRange(.pattern_binding, path_start, path_end);
        }

        const name_node = try self.parser.builder.appendTokenRange(.pattern_name, path_start, path_end);
        if (self.currentKind() != .l_paren) {
            var children = array_list.Managed(Child).init(self.parser.allocator);
            defer children.deinit();
            try children.append(.{ .node = name_node });
            return self.parser.builder.appendNode(if (has_dot) .pattern_variant else .pattern_struct, children.items);
        }

        const payload = try self.parseNamedOrTuplePayload();
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .node = name_node });
        try children.append(.{ .node = payload });
        return self.parser.builder.appendNode(if (has_dot) .pattern_variant else .pattern_struct, children.items);
    }

    fn parseNamedOrTuplePayload(self: *PatternParser) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;

        if (self.currentKind() == .r_paren) {
            var children = array_list.Managed(Child).init(self.parser.allocator);
            defer children.deinit();
            try children.append(.{ .token = self.parser.tokens.refAt(open_index) });
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
            return self.parser.builder.appendNode(.pattern_tuple, children.items);
        }

        if (self.looksLikeNamedFieldPayload()) {
            return self.parseFieldList(open_index);
        }

        return self.parseTuplePayload(open_index);
    }

    fn parseTuplePattern(self: *PatternParser) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;
        return self.parseTuplePayload(open_index);
    }

    fn parseTuplePayload(self: *PatternParser, open_index: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });

        while (self.index < self.end and self.currentKind() != .r_paren) {
            try children.append(.{ .node = try self.parsePattern() });
            if (self.currentKind() == .comma) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
                continue;
            }
            break;
        }

        if (self.currentKind() == .r_paren) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_paren } });
        }
        return self.parser.builder.appendNode(.pattern_tuple, children.items);
    }

    fn parseFieldList(self: *PatternParser, open_index: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });

        while (self.index < self.end and self.currentKind() != .r_paren) {
            try children.append(.{ .node = try self.parseField() });
            if (self.currentKind() == .comma) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
                continue;
            }
            break;
        }

        if (self.currentKind() == .r_paren) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_paren } });
        }
        return self.parser.builder.appendNode(.pattern_field_list, children.items);
    }

    fn parseField(self: *PatternParser) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();

        if (self.currentKind() == .identifier) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        if (self.currentKind() == .equal) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .equal } });
        }

        try children.append(.{ .node = try self.parsePattern() });
        return self.parser.builder.appendNode(.pattern_field, children.items);
    }

    fn looksLikeNamedFieldPayload(self: *const PatternParser) bool {
        var cursor = self.index;
        var nested_depth: usize = 0;
        while (cursor < self.end) : (cursor += 1) {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => nested_depth += 1,
                .r_paren => {
                    if (nested_depth == 0) break;
                    nested_depth -= 1;
                },
                .equal => if (nested_depth == 0) return true,
                .comma => if (nested_depth == 0) return false,
                else => {},
            }
        }
        return false;
    }

    fn parseLeaf(self: *PatternParser, kind: NodeKind) anyerror!NodeId {
        const start = self.index;
        self.index += 1;
        return self.parser.builder.appendTokenRange(kind, start, self.index);
    }

    fn parseErrorLeaf(self: *PatternParser) anyerror!NodeId {
        const start = self.index;
        if (self.index < self.end) self.index += 1;
        return self.parser.builder.appendTokenRange(.@"error", start, self.index);
    }

    fn currentKind(self: *const PatternParser) syntax.TokenKind {
        return self.tokenKindAt(self.index);
    }

    fn tokenKindAt(self: *const PatternParser, index: usize) syntax.TokenKind {
        if (index >= self.end) return .eof;
        return self.parser.tokenKindAt(index);
    }
};

const TypeParser = struct {
    parser: *Parser,
    start: usize,
    end: usize,
    index: usize,

    fn parse(self: *TypeParser) anyerror!NodeId {
        const ty = try self.parseType();
        if (self.index != self.end) return self.parser.builder.appendTokenRange(.@"error", self.start, self.end);
        return ty;
    }

    fn parseType(self: *TypeParser) anyerror!NodeId {
        if (self.currentKind() == .identifier and std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "read")) {
            return self.parseBorrowPrefix();
        }
        if (self.currentKind() == .identifier and std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "edit")) {
            return self.parseBorrowPrefix();
        }
        if (self.currentKind() == .identifier and std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "hold")) {
            return self.parseHoldBorrow();
        }

        var left = try self.parsePrimary();
        while (self.currentKind() == .dot) {
            const dot_index = self.index;
            self.index += 1;

            var children = array_list.Managed(Child).init(self.parser.allocator);
            defer children.deinit();
            try children.append(.{ .node = left });
            try children.append(.{ .token = self.parser.tokens.refAt(dot_index) });
            if (self.currentKind() == .identifier) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .identifier } });
            }
            left = try self.parser.builder.appendNode(.type_assoc, children.items);
        }
        return left;
    }

    fn parseBorrowPrefix(self: *TypeParser) anyerror!NodeId {
        const mode_index = self.index;
        self.index += 1;
        const inner = try self.parseType();

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(mode_index) });
        try children.append(.{ .node = inner });
        return self.parser.builder.appendNode(.type_borrow, children.items);
    }

    fn parseHoldBorrow(self: *TypeParser) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();

        try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
        self.index += 1;

        if (self.currentKind() == .l_bracket) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
            if (self.currentKind() == .lifetime_name) {
                try children.append(.{ .node = try self.parser.builder.appendTokenRange(.type_lifetime, self.index, self.index + 1) });
                self.index += 1;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .lifetime_name } });
            }
            if (self.currentKind() == .r_bracket) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .r_bracket } });
            }
        } else {
            try children.append(.{ .missing_token = .{ .expected = .l_bracket } });
        }

        if (self.currentKind() == .identifier and (std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "read") or std.mem.eql(u8, self.parser.tokens.get(self.index).lexeme, "edit"))) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .identifier } });
        }

        try children.append(.{ .node = try self.parseType() });
        return self.parser.builder.appendNode(.type_borrow, children.items);
    }

    fn parsePrimary(self: *TypeParser) anyerror!NodeId {
        if (self.currentKind() == .identifier) {
            const name_start = self.index;
            self.index += 1;
            var base = try self.parser.builder.appendTokenRange(.type_name_ref, name_start, self.index);
            if (self.currentKind() == .l_bracket) {
                base = try self.parseTypeApply(base);
            }
            return base;
        }
        if (self.currentKind() == .lifetime_name) {
            const start = self.index;
            self.index += 1;
            return self.parser.builder.appendTokenRange(.type_lifetime, start, self.index);
        }
        return self.parseErrorLeaf();
    }

    fn parseTypeApply(self: *TypeParser, base: NodeId) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .node = base });
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });

        while (self.index < self.end and self.currentKind() != .r_bracket) {
            const arg = switch (self.currentKind()) {
                .lifetime_name => blk: {
                    const start = self.index;
                    self.index += 1;
                    break :blk try self.parser.builder.appendTokenRange(.type_lifetime, start, self.index);
                },
                else => try self.parseType(),
            };
            try children.append(.{ .node = arg });
            if (self.currentKind() == .comma) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
                continue;
            }
            break;
        }

        if (self.currentKind() == .r_bracket) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_bracket } });
        }
        return self.parser.builder.appendNode(.type_apply, children.items);
    }

    fn parseErrorLeaf(self: *TypeParser) anyerror!NodeId {
        const start = self.index;
        if (self.index < self.end) self.index += 1;
        return self.parser.builder.appendTokenRange(.@"error", start, self.index);
    }

    fn currentKind(self: *const TypeParser) syntax.TokenKind {
        return self.tokenKindAt(self.index);
    }

    fn tokenKindAt(self: *const TypeParser, index: usize) syntax.TokenKind {
        if (index >= self.end) return .eof;
        return self.parser.tokenKindAt(index);
    }
};

const ExprParser = struct {
    parser: *Parser,
    start: usize,
    end: usize,
    index: usize,

    fn parse(self: *ExprParser) anyerror!NodeId {
        const expr = try self.parsePrecedence(0);
        if (self.index != self.end) return self.parser.builder.appendTokenRange(.@"error", self.start, self.end);
        return expr;
    }

    fn parsePrecedence(self: *ExprParser, min_precedence: u8) anyerror!NodeId {
        var left = try self.parsePrefix();

        while (true) {
            if (self.currentKind() == .dot) {
                left = try self.parseDotSuffix(left);
                continue;
            }
            if (self.currentKind() == .l_bracket) {
                left = try self.parseIndexSuffix(left);
                continue;
            }
            if (self.currentKind() == .double_colon) {
                left = try self.parseInvocationSuffix(left);
                continue;
            }

            const precedence = infixPrecedence(self.currentKind()) orelse break;
            if (precedence < min_precedence) break;

            const operator_index = self.index;
            self.index += 1;
            const right = try self.parsePrecedence(precedence + 1);

            var children = array_list.Managed(Child).init(self.parser.allocator);
            defer children.deinit();
            try children.append(.{ .node = left });
            try children.append(.{ .token = self.parser.tokens.refAt(operator_index) });
            try children.append(.{ .node = right });
            left = try self.parser.builder.appendNode(.expr_binary, children.items);
        }

        return left;
    }

    fn parsePrefix(self: *ExprParser) anyerror!NodeId {
        return switch (self.currentKind()) {
            .identifier => self.parseLeaf(.expr_name),
            .integer_literal => self.parseLeaf(.expr_integer),
            .string_literal => self.parseLeaf(.expr_string),
            .l_paren => self.parseParenLike(),
            .l_bracket => self.parseArray(),
            .bang, .minus, .tilde => self.parseUnary(),
            else => self.parseErrorLeaf(),
        };
    }

    fn parseLeaf(self: *ExprParser, kind: NodeKind) anyerror!NodeId {
        const start = self.index;
        self.index += 1;
        return self.parser.builder.appendTokenRange(kind, start, self.index);
    }

    fn parseErrorLeaf(self: *ExprParser) anyerror!NodeId {
        const start = self.index;
        if (self.index < self.end) self.index += 1;
        return self.parser.builder.appendTokenRange(.@"error", start, self.index);
    }

    fn parseUnary(self: *ExprParser) anyerror!NodeId {
        const operator_index = self.index;
        self.index += 1;
        const operand = try self.parsePrecedence(90);

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(operator_index) });
        try children.append(.{ .node = operand });
        return self.parser.builder.appendNode(.expr_unary, children.items);
    }

    fn parseParenLike(self: *ExprParser) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;

        if (self.currentKind() == .r_paren) {
            var empty_children = array_list.Managed(Child).init(self.parser.allocator);
            defer empty_children.deinit();
            try empty_children.append(.{ .token = self.parser.tokens.refAt(open_index) });
            try empty_children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
            return self.parser.builder.appendNode(.expr_tuple, empty_children.items);
        }

        const first = try self.parsePrecedence(0);
        if (self.currentKind() == .comma) {
            var children = array_list.Managed(Child).init(self.parser.allocator);
            defer children.deinit();
            try children.append(.{ .token = self.parser.tokens.refAt(open_index) });
            try children.append(.{ .node = first });

            while (self.currentKind() == .comma) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
                if (self.currentKind() == .r_paren) break;
                try children.append(.{ .node = try self.parsePrecedence(0) });
            }

            if (self.currentKind() == .r_paren) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .r_paren } });
            }
            return self.parser.builder.appendNode(.expr_tuple, children.items);
        }

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });
        try children.append(.{ .node = first });
        if (self.currentKind() == .r_paren) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_paren } });
        }
        return self.parser.builder.appendNode(.expr_group, children.items);
    }

    fn parseArray(self: *ExprParser) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });

        if (self.currentKind() == .r_bracket) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
            return self.parser.builder.appendNode(.expr_array, children.items);
        }

        try children.append(.{ .node = try self.parsePrecedence(0) });
        if (self.currentKind() == .semicolon) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
            try children.append(.{ .node = try self.parsePrecedence(0) });
            if (self.currentKind() == .r_bracket) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
            } else {
                try children.append(.{ .missing_token = .{ .expected = .r_bracket } });
            }
            return self.parser.builder.appendNode(.expr_array_repeat, children.items);
        }

        while (self.index < self.end and self.currentKind() != .r_bracket) {
            if (self.currentKind() == .comma) {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
                if (self.currentKind() == .r_bracket) break;
                try children.append(.{ .node = try self.parsePrecedence(0) });
                continue;
            }
            break;
        }

        if (self.currentKind() == .r_bracket) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_bracket } });
        }
        return self.parser.builder.appendNode(.expr_array, children.items);
    }

    fn parseDotSuffix(self: *ExprParser, left: NodeId) anyerror!NodeId {
        const dot_index = self.index;
        self.index += 1;

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .node = left });
        try children.append(.{ .token = self.parser.tokens.refAt(dot_index) });

        switch (self.currentKind()) {
            .identifier, .integer_literal => {
                try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
                self.index += 1;
            },
            else => try children.append(.{ .missing_token = .{ .expected = .identifier } }),
        }

        return self.parser.builder.appendNode(.expr_field, children.items);
    }

    fn parseIndexSuffix(self: *ExprParser, left: NodeId) anyerror!NodeId {
        const open_index = self.index;
        self.index += 1;

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .node = left });
        try children.append(.{ .token = self.parser.tokens.refAt(open_index) });

        if (self.currentKind() != .r_bracket) {
            try children.append(.{ .node = try self.parsePrecedence(0) });
        }

        if (self.currentKind() == .r_bracket) {
            try children.append(.{ .token = self.parser.tokens.refAt(self.index) });
            self.index += 1;
        } else {
            try children.append(.{ .missing_token = .{ .expected = .r_bracket } });
        }

        return self.parser.builder.appendNode(.expr_index, children.items);
    }

    fn parseInvocationSuffix(self: *ExprParser, left: NodeId) anyerror!NodeId {
        const first_separator = self.index;
        self.index += 1;

        const args_start = self.index;
        const second_separator = self.findTopLevelToken(args_start, self.end, .double_colon) orelse return self.parser.builder.appendTokenRange(.@"error", first_separator, self.end);
        const args = try self.parseArgumentList(args_start, second_separator);

        self.index = second_separator;
        const second_separator_index = self.index;
        self.index += 1;

        const qualifier_index = self.index;
        if (qualifier_index >= self.end or self.currentKind() != .identifier) {
            return self.parser.builder.appendTokenRange(.@"error", first_separator, self.index);
        }

        const qualifier = self.parser.tokens.get(qualifier_index).lexeme;
        const invocation_kind: NodeKind = if (std.mem.eql(u8, qualifier, "call"))
            .expr_call
        else if (std.mem.eql(u8, qualifier, "method"))
            .expr_method_call
        else
            return self.parser.builder.appendTokenRange(.@"error", first_separator, qualifier_index + 1);
        self.index += 1;

        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();
        try children.append(.{ .node = left });
        try children.append(.{ .token = self.parser.tokens.refAt(first_separator) });
        try children.append(.{ .node = args });
        try children.append(.{ .token = self.parser.tokens.refAt(second_separator_index) });
        try children.append(.{ .token = self.parser.tokens.refAt(qualifier_index) });
        return self.parser.builder.appendNode(invocation_kind, children.items);
    }

    fn parseArgumentList(self: *ExprParser, start: usize, end: usize) anyerror!NodeId {
        var children = array_list.Managed(Child).init(self.parser.allocator);
        defer children.deinit();

        if (start == end) return self.parser.builder.appendNode(.expr_argument_list, children.items);

        var cursor = start;
        while (cursor < end) {
            const comma_index = self.findTopLevelToken(cursor, end, .comma);
            const part_end = comma_index orelse end;
            try children.append(.{ .node = try self.parser.parseExpressionSlice(cursor, part_end) });
            cursor = part_end;
            if (cursor < end) {
                try children.append(.{ .token = self.parser.tokens.refAt(cursor) });
                cursor += 1;
            }
        }

        return self.parser.builder.appendNode(.expr_argument_list, children.items);
    }

    fn findTopLevelToken(self: *const ExprParser, start: usize, end: usize, target: syntax.TokenKind) ?usize {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var cursor = start;
        while (cursor < end) : (cursor += 1) {
            switch (self.tokenKindAt(cursor)) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth != 0) paren_depth -= 1;
                },
                .l_bracket => bracket_depth += 1,
                .r_bracket => {
                    if (bracket_depth != 0) bracket_depth -= 1;
                },
                else => {},
            }
            if (paren_depth == 0 and bracket_depth == 0 and self.tokenKindAt(cursor) == target) return cursor;
        }
        return null;
    }

    fn currentKind(self: *const ExprParser) syntax.TokenKind {
        return self.tokenKindAt(self.index);
    }

    fn tokenKindAt(self: *const ExprParser, index: usize) syntax.TokenKind {
        if (index >= self.end) return .eof;
        return self.parser.tokenKindAt(index);
    }
};

fn infixPrecedence(kind: syntax.TokenKind) ?u8 {
    return switch (kind) {
        .star, .slash, .percent => 80,
        .plus, .minus => 70,
        .lt_lt, .gt_gt => 60,
        .lt, .lte, .gt, .gte => 50,
        .eq_eq, .bang_eq => 40,
        .amp => 30,
        .caret => 25,
        .pipe => 20,
        .amp_amp => 15,
        .pipe_pipe => 10,
        else => null,
    };
}

fn tokenCoverage(tree: *const Tree, children: []const Child) usize {
    var total: usize = 0;
    for (children) |child| {
        switch (child) {
            .token => total += 1,
            .node => |node_id| total += tokenCoverage(tree, tree.childSlice(node_id)),
            .missing_token => {},
        }
    }
    return total;
}

fn firstChildNode(tree: *const Tree, node_id: NodeId, child_index: usize) !NodeId {
    const children = tree.childSlice(node_id);
    return switch (children[child_index]) {
        .node => |nested| nested,
        else => error.UnexpectedStructure,
    };
}

fn nthNodeChild(tree: *const Tree, node_id: NodeId, node_index: usize) !NodeId {
    var seen: usize = 0;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |nested| {
                if (seen == node_index) return nested;
                seen += 1;
            },
            else => {},
        }
    }
    return error.UnexpectedStructure;
}

test "token-backed CST scaffold covers full token stream" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("test.rna", "fn main() -> Unit:\n    repeat\n");
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try Tree.fromLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, @intCast(lexed.tokens.len)), tree.token_count);
    try std.testing.expectEqual(@as(u32, @intCast(lexed.trivia.len)), tree.trivia_count);
    try std.testing.expectEqual(@as(usize, lexed.tokens.len), tree.childSlice(tree.root).len);
}

test "structured CST classifies top-level declarations and preserves token coverage" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "items.rna",
        "#foreign\npub fn main() -> Unit:\n    repeat\nconst answer: I32 = 42\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const root_children = tree.childSlice(tree.root);
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    try std.testing.expectEqual(@as(usize, lexed.tokens.len), tokenCoverage(&tree, root_children));

    const first_item = switch (root_children[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.item, tree.nodes[@intFromEnum(first_item)].kind);

    const declaration = try firstChildNode(&tree, first_item, 1);
    try std.testing.expectEqual(NodeKind.function_item, tree.nodes[@intFromEnum(declaration)].kind);

    const function_body = try firstChildNode(&tree, declaration, 1);
    try std.testing.expectEqual(NodeKind.block, tree.nodes[@intFromEnum(function_body)].kind);

    const header = try firstChildNode(&tree, declaration, 0);
    const signature = try firstChildNode(&tree, header, 0);
    const signature_children = tree.childSlice(signature);
    try std.testing.expectEqual(NodeKind.visibility, tree.nodes[@intFromEnum(switch (signature_children[0]) { .node => |node_id| node_id, else => return error.UnexpectedStructure })].kind);
    try std.testing.expectEqual(NodeKind.item_name, tree.nodes[@intFromEnum(switch (signature_children[3]) { .node => |node_id| node_id, else => return error.UnexpectedStructure })].kind);
}

test "structured CST groups where clauses and nested blocks" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "nested.rna",
        "fn main[T](value: T) -> Unit\nwhere T: Send:\n    select:\n        when ready => act\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const first_item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, first_item, 0);
    const header = try firstChildNode(&tree, declaration, 0);
    const header_children = tree.childSlice(header);

    try std.testing.expectEqual(NodeKind.function_item, tree.nodes[@intFromEnum(declaration)].kind);
    try std.testing.expectEqual(@as(usize, 2), header_children.len);

    const where_clause = try firstChildNode(&tree, header, 1);
    try std.testing.expectEqual(NodeKind.where_clause, tree.nodes[@intFromEnum(where_clause)].kind);

    const outer_block = try firstChildNode(&tree, declaration, 1);
    const first_statement = try firstChildNode(&tree, outer_block, 1);
    const nested_block = try firstChildNode(&tree, first_statement, 3);
    try std.testing.expectEqual(NodeKind.block, tree.nodes[@intFromEnum(nested_block)].kind);
}

test "structured CST classifies control-flow statements and arms" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "control.rna",
        "fn main() -> Unit:\n    select:\n        when ready => act\n        else => wait\n    repeat:\n        break\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, item, 0);
    const block = try firstChildNode(&tree, declaration, 1);

    const select_stmt = try firstChildNode(&tree, block, 1);
    try std.testing.expectEqual(NodeKind.select_statement, tree.nodes[@intFromEnum(select_stmt)].kind);

    const select_block = try firstChildNode(&tree, select_stmt, 3);
    const when_arm = try firstChildNode(&tree, select_block, 1);
    const else_arm = try firstChildNode(&tree, select_block, 2);
    try std.testing.expectEqual(NodeKind.when_arm, tree.nodes[@intFromEnum(when_arm)].kind);
    try std.testing.expectEqual(NodeKind.else_arm, tree.nodes[@intFromEnum(else_arm)].kind);

    const repeat_stmt = try firstChildNode(&tree, block, 2);
    try std.testing.expectEqual(NodeKind.repeat_statement, tree.nodes[@intFromEnum(repeat_stmt)].kind);
}

test "structured CST parses invocation and binary expressions in statements" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "exprs.rna",
        "fn main() -> Unit:\n    render.frame :: value + 1, items[index] :: method\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, item, 0);
    const block = try firstChildNode(&tree, declaration, 1);
    const statement = try firstChildNode(&tree, block, 1);
    const expr = try firstChildNode(&tree, statement, 0);
    try std.testing.expectEqual(NodeKind.expr_method_call, tree.nodes[@intFromEnum(expr)].kind);

    const args = try firstChildNode(&tree, expr, 2);
    try std.testing.expectEqual(NodeKind.expr_argument_list, tree.nodes[@intFromEnum(args)].kind);

    const first_arg = try firstChildNode(&tree, args, 0);
    try std.testing.expectEqual(NodeKind.expr_binary, tree.nodes[@intFromEnum(first_arg)].kind);
}

test "structured CST parses return expressions and inline arm bodies" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "returns.rna",
        "fn main(flag: Bool) -> I32:\n    select:\n        when flag => return 1 + 2\n        else => return 0\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, item, 0);
    const block = try firstChildNode(&tree, declaration, 1);
    const select_stmt = try firstChildNode(&tree, block, 1);
    const select_block = try firstChildNode(&tree, select_stmt, 3);
    const when_arm = try firstChildNode(&tree, select_block, 1);

    const inline_return = try firstChildNode(&tree, when_arm, 3);
    try std.testing.expectEqual(NodeKind.return_statement, tree.nodes[@intFromEnum(inline_return)].kind);

    const return_expr = try firstChildNode(&tree, inline_return, 1);
    try std.testing.expectEqual(NodeKind.expr_binary, tree.nodes[@intFromEnum(return_expr)].kind);
}

test "structured CST parses select subjects and repeat headers" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "headers.rna",
        "fn main(items: List[I32], flag: Bool) -> Unit:\n    select items[index]:\n        when value => value :: :: call\n    repeat while flag && ready:\n        continue\n    repeat item in items:\n        break\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, item, 0);
    const block = try firstChildNode(&tree, declaration, 1);

    const select_stmt = try firstChildNode(&tree, block, 1);
    const select_head = try firstChildNode(&tree, select_stmt, 1);
    try std.testing.expectEqual(NodeKind.select_head, tree.nodes[@intFromEnum(select_head)].kind);
    const select_subject_expr = try firstChildNode(&tree, select_head, 0);
    try std.testing.expectEqual(NodeKind.expr_index, tree.nodes[@intFromEnum(select_subject_expr)].kind);

    const repeat_while = try firstChildNode(&tree, block, 2);
    const repeat_condition = try firstChildNode(&tree, repeat_while, 2);
    try std.testing.expectEqual(NodeKind.repeat_condition, tree.nodes[@intFromEnum(repeat_condition)].kind);

    const repeat_in = try firstChildNode(&tree, block, 3);
    const repeat_binding = try firstChildNode(&tree, repeat_in, 1);
    const repeat_iterable = try firstChildNode(&tree, repeat_in, 3);
    try std.testing.expectEqual(NodeKind.repeat_binding, tree.nodes[@intFromEnum(repeat_binding)].kind);
    try std.testing.expectEqual(NodeKind.repeat_iterable, tree.nodes[@intFromEnum(repeat_iterable)].kind);
    const repeat_binding_pattern = try firstChildNode(&tree, repeat_binding, 0);
    try std.testing.expectEqual(NodeKind.pattern_binding, tree.nodes[@intFromEnum(repeat_binding_pattern)].kind);
}

test "structured CST distinguishes guarded-arm expressions from subject-arm patterns" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "arms.rna",
        "fn main(pair: Pair, ready: Bool, items: List[(I32, I32)]) -> Unit:\n    select:\n        when ready && active => use :: :: call\n    select pair:\n        when Pair(left = l, right = r) => use_pair :: l, r :: call\n    repeat (key, value) in items:\n        continue\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try firstChildNode(&tree, item, 0);
    const block = try firstChildNode(&tree, declaration, 1);

    const guarded_select = try firstChildNode(&tree, block, 1);
    const guarded_block = try firstChildNode(&tree, guarded_select, 3);
    const guarded_when = try firstChildNode(&tree, guarded_block, 1);
    const guarded_head = try firstChildNode(&tree, guarded_when, 1);
    const guarded_head_expr = try firstChildNode(&tree, guarded_head, 0);
    try std.testing.expectEqual(NodeKind.expr_binary, tree.nodes[@intFromEnum(guarded_head_expr)].kind);

    const subject_select = try firstChildNode(&tree, block, 2);
    const subject_block = try firstChildNode(&tree, subject_select, 3);
    const subject_when = try firstChildNode(&tree, subject_block, 1);
    const subject_head = try firstChildNode(&tree, subject_when, 1);
    const subject_pattern = try firstChildNode(&tree, subject_head, 0);
    try std.testing.expectEqual(NodeKind.pattern_struct, tree.nodes[@intFromEnum(subject_pattern)].kind);

    const repeat_stmt = try firstChildNode(&tree, block, 3);
    const tuple_binding = try firstChildNode(&tree, repeat_stmt, 1);
    const tuple_pattern = try firstChildNode(&tree, tuple_binding, 0);
    try std.testing.expectEqual(NodeKind.pattern_tuple, tree.nodes[@intFromEnum(tuple_pattern)].kind);
}

test "structured CST parses function signatures const initializers and use aliases" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "signatures.rna",
        "pub fn choose['a, T](take left: hold['a] read T, right: T) -> T\nwhere T: Clone:\n    return left\nconst answer: I32 = 40 + 2\nuse package.core.answer as value\nmod tools\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const function_item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const function_decl = try firstChildNode(&tree, function_item, 0);
    const function_header = try firstChildNode(&tree, function_decl, 0);
    const function_signature = try firstChildNode(&tree, function_header, 0);
    const function_sig_children = tree.childSlice(function_signature);
    const generic_params = switch (function_sig_children[4]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const parameter_list = switch (function_sig_children[5]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const return_type = switch (function_sig_children[7]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.generic_param_list, tree.nodes[@intFromEnum(generic_params)].kind);
    try std.testing.expectEqual(NodeKind.parameter_list, tree.nodes[@intFromEnum(parameter_list)].kind);
    try std.testing.expectEqual(NodeKind.return_type, tree.nodes[@intFromEnum(return_type)].kind);

    const const_item = switch (tree.childSlice(tree.root)[2]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const const_decl = try firstChildNode(&tree, const_item, 0);
    const const_signature = try firstChildNode(&tree, try firstChildNode(&tree, const_decl, 0), 0);
    const const_initializer = switch (tree.childSlice(const_signature)[4]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.const_initializer, tree.nodes[@intFromEnum(const_initializer)].kind);

    const use_item = switch (tree.childSlice(tree.root)[3]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const use_decl = try firstChildNode(&tree, use_item, 0);
    const use_signature = try firstChildNode(&tree, try firstChildNode(&tree, use_decl, 0), 0);
    const use_path = switch (tree.childSlice(use_signature)[1]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const use_alias = switch (tree.childSlice(use_signature)[3]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.use_path, tree.nodes[@intFromEnum(use_path)].kind);
    try std.testing.expectEqual(NodeKind.use_alias, tree.nodes[@intFromEnum(use_alias)].kind);

    const mod_item = switch (tree.childSlice(tree.root)[4]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const mod_decl = try firstChildNode(&tree, mod_item, 0);
    const mod_signature = try firstChildNode(&tree, try firstChildNode(&tree, mod_decl, 0), 0);
    const mod_name = switch (tree.childSlice(mod_signature)[1]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.item_name, tree.nodes[@intFromEnum(mod_name)].kind);
}

test "structured CST parses struct and enum declaration bodies" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "types.rna",
        "struct WindowSpec:\n    pub title: Str\n    width: Index\n\nenum Event:\n    Quit\n    Resize(width: Index, height: Index)\n    Drop:\n        path: Str\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const struct_item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const struct_decl = try firstChildNode(&tree, struct_item, 0);
    const struct_block = try firstChildNode(&tree, struct_decl, 1);
    const first_field = try firstChildNode(&tree, struct_block, 1);
    const second_field = try firstChildNode(&tree, struct_block, 2);
    try std.testing.expectEqual(NodeKind.field_decl, tree.nodes[@intFromEnum(first_field)].kind);
    try std.testing.expectEqual(NodeKind.field_decl, tree.nodes[@intFromEnum(second_field)].kind);

    const field_visibility = try firstChildNode(&tree, first_field, 0);
    const field_name = try firstChildNode(&tree, first_field, 1);
    const field_type = try firstChildNode(&tree, first_field, 3);
    try std.testing.expectEqual(NodeKind.visibility, tree.nodes[@intFromEnum(field_visibility)].kind);
    try std.testing.expectEqual(NodeKind.field_name, tree.nodes[@intFromEnum(field_name)].kind);
    try std.testing.expectEqual(NodeKind.field_type, tree.nodes[@intFromEnum(field_type)].kind);

    const enum_item = switch (tree.childSlice(tree.root)[2]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const enum_decl = try firstChildNode(&tree, enum_item, 0);
    const enum_block = try firstChildNode(&tree, enum_decl, 1);
    const resize_variant = try firstChildNode(&tree, enum_block, 2);
    const drop_variant = try firstChildNode(&tree, enum_block, 3);
    try std.testing.expectEqual(NodeKind.variant_decl, tree.nodes[@intFromEnum(resize_variant)].kind);
    try std.testing.expectEqual(NodeKind.variant_decl, tree.nodes[@intFromEnum(drop_variant)].kind);

    const tuple_payload = try firstChildNode(&tree, resize_variant, 1);
    try std.testing.expectEqual(NodeKind.variant_tuple_payload, tree.nodes[@intFromEnum(tuple_payload)].kind);

    const named_payload = try firstChildNode(&tree, drop_variant, 2);
    const payload_field = try firstChildNode(&tree, named_payload, 1);
    try std.testing.expectEqual(NodeKind.block, tree.nodes[@intFromEnum(named_payload)].kind);
    try std.testing.expectEqual(NodeKind.field_decl, tree.nodes[@intFromEnum(payload_field)].kind);
}

test "structured CST parses trait and impl members" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "traits.rna",
        "trait Iterator:\n    type Item\n    fn next(edit self) -> Option[Self.Item]\n    fn reset(edit self) -> Unit\n    where Self: Clone:\n        return self.state\n\nimpl Iterator for Cursor:\n    type Item = Str\n    fn next(edit self) -> Option[Self.Item]:\n        return self.value\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const trait_item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const trait_decl = try firstChildNode(&tree, trait_item, 0);
    const trait_block = try firstChildNode(&tree, trait_decl, 1);
    const assoc_type = try firstChildNode(&tree, trait_block, 1);
    const method = try firstChildNode(&tree, trait_block, 2);
    const default_method = try firstChildNode(&tree, trait_block, 3);
    try std.testing.expectEqual(NodeKind.associated_type_decl, tree.nodes[@intFromEnum(assoc_type)].kind);
    try std.testing.expectEqual(NodeKind.function_item, tree.nodes[@intFromEnum(method)].kind);
    try std.testing.expectEqual(NodeKind.function_item, tree.nodes[@intFromEnum(default_method)].kind);

    const method_header = try firstChildNode(&tree, default_method, 0);
    try std.testing.expectEqual(@as(usize, 2), tree.childSlice(method_header).len);
    const method_body = try firstChildNode(&tree, default_method, 1);
    try std.testing.expectEqual(NodeKind.block, tree.nodes[@intFromEnum(method_body)].kind);

    const impl_item = switch (tree.childSlice(tree.root)[2]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const impl_decl = try firstChildNode(&tree, impl_item, 0);
    const impl_block = try firstChildNode(&tree, impl_decl, 1);
    const impl_assoc = try firstChildNode(&tree, impl_block, 1);
    const impl_method = try firstChildNode(&tree, impl_block, 2);
    try std.testing.expectEqual(NodeKind.associated_type_decl, tree.nodes[@intFromEnum(impl_assoc)].kind);
    try std.testing.expectEqual(NodeKind.function_item, tree.nodes[@intFromEnum(impl_method)].kind);
}

test "structured CST parses foreign ABIs and impl header targets" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "headers2.rna",
        "extern[\"C\"] fn puts(read text: Str) -> I32\nimpl[T] Iterator for Cursor[T]:\n    fn next(edit self) -> Option[Self.Item]:\n        return self.value\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const foreign_item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const foreign_decl = try firstChildNode(&tree, foreign_item, 0);
    const foreign_signature = try firstChildNode(&tree, try firstChildNode(&tree, foreign_decl, 0), 0);
    const foreign_abi = switch (tree.childSlice(foreign_signature)[1]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.foreign_abi, tree.nodes[@intFromEnum(foreign_abi)].kind);

    const impl_item = switch (tree.childSlice(tree.root)[1]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const impl_decl = try firstChildNode(&tree, impl_item, 0);
    const impl_signature = try firstChildNode(&tree, try firstChildNode(&tree, impl_decl, 0), 0);
    const impl_trait = switch (tree.childSlice(impl_signature)[2]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const impl_target = switch (tree.childSlice(impl_signature)[4]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    try std.testing.expectEqual(NodeKind.impl_trait_name, tree.nodes[@intFromEnum(impl_trait)].kind);
    try std.testing.expectEqual(NodeKind.impl_target_type, tree.nodes[@intFromEnum(impl_target)].kind);
}

test "structured CST parses unsafe blocks and inline control arm bodies" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "control-flow.rna",
        "fn main(flag: Bool) -> Unit:\n    repeat:\n        #unsafe:\n            select:\n                when flag => break\n                else => continue\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try nthNodeChild(&tree, item, 0);
    const body = try nthNodeChild(&tree, declaration, 1);
    const repeat_stmt = try nthNodeChild(&tree, body, 0);
    const repeat_block = try nthNodeChild(&tree, repeat_stmt, 0);
    const unsafe_stmt = try nthNodeChild(&tree, repeat_block, 0);
    try std.testing.expectEqual(NodeKind.unsafe_statement, tree.nodes[@intFromEnum(unsafe_stmt)].kind);

    const unsafe_block = try nthNodeChild(&tree, unsafe_stmt, 0);
    const select_stmt = try nthNodeChild(&tree, unsafe_block, 0);
    const select_block = try nthNodeChild(&tree, select_stmt, 0);
    const when_arm = try nthNodeChild(&tree, select_block, 0);
    const else_arm = try nthNodeChild(&tree, select_block, 1);
    const inline_break = try nthNodeChild(&tree, when_arm, 1);
    const inline_continue = try nthNodeChild(&tree, else_arm, 0);

    try std.testing.expectEqual(NodeKind.break_statement, tree.nodes[@intFromEnum(inline_break)].kind);
    try std.testing.expectEqual(NodeKind.continue_statement, tree.nodes[@intFromEnum(inline_continue)].kind);
}

test "structured CST keeps recovery nodes for malformed type pattern and expression slices" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "recovery.rna",
        "fn broken(read value: List[I32) -> Unit:\n    select pair:\n        when Pair(left = one) extra => value )\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var tree = try parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const item = switch (tree.childSlice(tree.root)[0]) {
        .node => |node_id| node_id,
        else => return error.UnexpectedStructure,
    };
    const declaration = try nthNodeChild(&tree, item, 0);
    const header = try nthNodeChild(&tree, declaration, 0);
    const signature = try nthNodeChild(&tree, header, 0);
    const parameter_list = try nthNodeChild(&tree, signature, 1);
    const parameter = try nthNodeChild(&tree, parameter_list, 0);
    const parameter_type = try nthNodeChild(&tree, parameter, 2);
    const type_root = try nthNodeChild(&tree, parameter_type, 0);
    try std.testing.expectEqual(NodeKind.type_apply, tree.nodes[@intFromEnum(type_root)].kind);
    const type_children = tree.childSlice(type_root);
    try std.testing.expectEqual(@as(usize, 4), type_children.len);
    switch (type_children[type_children.len - 1]) {
        .missing_token => |missing| try std.testing.expectEqual(syntax.TokenKind.r_bracket, missing.expected),
        else => return error.UnexpectedStructure,
    }

    const body = try nthNodeChild(&tree, declaration, 1);
    const select_stmt = try nthNodeChild(&tree, body, 0);
    const select_block = try nthNodeChild(&tree, select_stmt, 0);
    const when_arm = try nthNodeChild(&tree, select_block, 0);
    const arm_head = try nthNodeChild(&tree, when_arm, 0);
    const arm_head_recovery = try nthNodeChild(&tree, arm_head, 0);
    try std.testing.expectEqual(NodeKind.@"error", tree.nodes[@intFromEnum(arm_head_recovery)].kind);
    try std.testing.expectEqual(NodeKind.pattern_struct, tree.nodes[@intFromEnum(try nthNodeChild(&tree, arm_head_recovery, 0))].kind);

    const inline_statement = try nthNodeChild(&tree, when_arm, 1);
    const expr_recovery = try nthNodeChild(&tree, inline_statement, 0);
    try std.testing.expectEqual(NodeKind.@"error", tree.nodes[@intFromEnum(expr_recovery)].kind);
    try std.testing.expectEqual(NodeKind.expr_name, tree.nodes[@intFromEnum(try nthNodeChild(&tree, expr_recovery, 0))].kind);
}
