const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const Allocator = std.mem.Allocator;

pub const summary = "Formatting pipeline over the shared CST parse front-end.";

pub const Result = struct {
    formatted_files: usize,
    changed_files: usize,
};

pub fn formatPipeline(allocator: Allocator, io: std.Io, pipeline: *const compiler.driver.Pipeline, write_changes: bool) !Result {
    var result = Result{
        .formatted_files = 0,
        .changed_files = 0,
    };

    for (pipeline.modules.items) |module| {
        const file = pipeline.sources.get(module.parsed.module.file_id);
        const rendered = try renderParsedFile(allocator, &module.parsed);
        defer allocator.free(rendered);

        result.formatted_files += 1;
        if (std.mem.eql(u8, file.contents, rendered)) continue;
        result.changed_files += 1;

        if (write_changes) {
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = file.path,
                .data = rendered,
            });
        }
    }

    return result;
}

pub fn renderParsedFile(allocator: Allocator, parsed: *const compiler.parse.ParsedFile) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendNode(&out, &parsed.cst, parsed.tokens, parsed.trivia, parsed.cst.root, 0);

    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn appendNode(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
    indent: usize,
) anyerror!void {
    switch (tree.nodeKind(node_id)) {
        .source_file => try appendRoot(out, tree, tokens, trivia, node_id),
        .item => try appendItem(out, tree, tokens, trivia, node_id),
        .block => try appendBlock(out, tree, tokens, trivia, node_id, indent),
        else => try appendStructuredNode(out, tree, tokens, trivia, node_id, indent),
    }
}

fn appendRoot(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
) anyerror!void {
    for (tree.childSlice(node_id)) |child| {
        const child_node = switch (child) {
            .node => |value| value,
            else => continue,
        };
        try appendNode(out, tree, tokens, trivia, child_node, 0);
    }
}

fn appendItem(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
) anyerror!void {
    for (tree.childSlice(node_id)) |child| {
        const child_node = switch (child) {
            .node => |value| value,
            else => continue,
        };
        try appendNode(out, tree, tokens, trivia, child_node, 0);
    }
}

fn appendBlock(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
    indent: usize,
) anyerror!void {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| try appendNode(out, tree, tokens, trivia, child_node, indent),
            .token => |token_id| switch (tokens.getRef(token_id).kind) {
                .indent, .dedent, .eof => {},
                else => {},
            },
            .missing_token => {},
        }
    }
}

fn appendStructuredNode(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
    indent: usize,
) anyerror!void {
    var raw = array_list.Managed(u8).init(out.allocator);
    defer raw.deinit();

    try appendInlineTokens(&raw, tree, tokens, trivia, node_id);
    try appendNormalizedLines(out, raw.items, indent);

    for (tree.childSlice(node_id)) |child| {
        const child_node = switch (child) {
            .node => |value| value,
            else => continue,
        };
        if (tree.nodeKind(child_node) == .block) {
            try appendBlock(out, tree, tokens, trivia, child_node, indent + 4);
        }
    }
}

fn appendInlineTokens(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    trivia: compiler.syntax.TriviaStore,
    node_id: compiler.cst.NodeId,
) anyerror!void {
    if (tree.nodeKind(node_id) == .block) return;

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| try appendInlineTokens(out, tree, tokens, trivia, child_node),
            .token => |token_id| {
                const token = tokens.getRef(token_id);
                try appendTriviaIterator(out, tokens.leadingTriviaIterator(token_id));
                switch (token.kind) {
                    .indent, .dedent, .eof => {},
                    else => try out.appendSlice(token.lexeme),
                }
                try appendTriviaIterator(out, tokens.trailingTriviaIterator(token_id));
            },
            .missing_token => {},
        }
    }
}

fn appendTriviaIterator(out: *array_list.Managed(u8), iterator: compiler.syntax.TokenStore.TriviaIterator) anyerror!void {
    var items = iterator;
    while (items.next()) |item| {
        try out.appendSlice(item.lexeme);
    }
}

fn appendNormalizedLines(out: *array_list.Managed(u8), raw: []const u8, indent: usize) anyerror!void {
    var start: usize = 0;
    while (start < raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse raw.len;
        const has_newline = end < raw.len;
        const line = raw[start..end];
        const trimmed = trimLeading(line);

        if (trimmed.len == 0) {
            if (has_newline) try out.append('\n');
        } else {
            try out.appendNTimes(' ', indent);
            try out.appendSlice(trimmed);
            if (has_newline) try out.append('\n');
        }

        start = if (has_newline) end + 1 else end;
    }
}

fn trimLeading(raw: []const u8) []const u8 {
    var index: usize = 0;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\r')) : (index += 1) {}
    return raw[index..];
}
