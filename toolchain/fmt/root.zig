const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const cli_context = @import("../cli/context.zig");
const workspace = @import("../workspace/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Formatting pipeline over the shared CST parse front-end.";

pub const Result = struct {
    formatted_files: usize,
    changed_files: usize,
};

pub const Options = struct {
    check: bool = false,
};

pub const CommandResult = struct {
    active: compiler.session.Session,
    formatted_files: usize,
    changed_files: usize,
    blocking_errors: usize,
    check_mismatches: usize,

    pub fn deinit(self: *CommandResult) void {
        self.active.deinit();
    }

    pub fn failed(self: *const CommandResult) bool {
        return self.blocking_errors != 0 or self.check_mismatches != 0;
    }
};

pub fn formatCommandContext(
    allocator: Allocator,
    io: std.Io,
    command_context: *const cli_context.CommandContext,
    options: Options,
) !CommandResult {
    return switch (command_context.*) {
        .manifest_rooted => |*manifest_rooted| formatManifestRooted(allocator, io, manifest_rooted, options),
        .standalone => error.MissingManifest,
    };
}

pub fn formatManifestRooted(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: Options,
) !CommandResult {
    var source_paths = array_list.Managed([]const u8).init(allocator);
    defer {
        for (source_paths.items) |path| allocator.free(path);
        source_paths.deinit();
    }
    try workspace.collectLocalAuthoringSourceFiles(allocator, io, manifest_rooted.command_root, &source_paths);

    var active = try compiler.session.prepareFiles(allocator, io, source_paths.items);
    var active_owned = true;
    errdefer if (active_owned) active.deinit();

    var result = CommandResult{
        .active = active,
        .formatted_files = 0,
        .changed_files = 0,
        .blocking_errors = blockingFormatErrorCount(&active.pipeline.diagnostics),
        .check_mismatches = 0,
    };
    active_owned = false;
    errdefer result.deinit();

    if (result.blocking_errors != 0) return result;

    var seen_files = std.StringHashMap(void).init(allocator);
    defer seen_files.deinit();
    var rewrites = array_list.Managed(PendingRewrite).init(allocator);
    defer {
        for (rewrites.items) |*rewrite| rewrite.deinit(allocator);
        rewrites.deinit();
    }

    for (result.active.pipeline.modules.items) |module| {
        const file = result.active.pipeline.sources.get(module.parsed.module.file_id);

        const seen = try seen_files.getOrPut(file.path);
        if (seen.found_existing) continue;
        seen.value_ptr.* = {};

        const rendered = try renderParsedFile(allocator, &module.parsed);
        defer allocator.free(rendered);

        result.formatted_files += 1;
        if (std.mem.eql(u8, file.contents, rendered)) continue;

        result.changed_files += 1;
        if (options.check) {
            result.check_mismatches += 1;
            try result.active.pipeline.diagnostics.add(
                .@"error",
                "fmt.check.changed",
                .{ .file_id = file.id, .start = 0, .end = 0 },
                "file is not formatted",
                .{},
            );
            continue;
        }

        try rewrites.append(.{
            .path = file.path,
            .contents = try allocator.dupe(u8, rendered),
        });
    }

    if (!options.check) try applyPendingRewrites(allocator, io, rewrites.items);
    return result;
}

const PendingRewrite = struct {
    path: []const u8,
    contents: []u8,

    fn deinit(self: *PendingRewrite, allocator: Allocator) void {
        allocator.free(self.contents);
    }
};

fn applyPendingRewrites(
    allocator: Allocator,
    io: std.Io,
    rewrites: []const PendingRewrite,
) !void {
    if (rewrites.len == 0) return;
    var atomic = try allocator.alloc(workspace.AtomicRewrite, rewrites.len);
    defer allocator.free(atomic);
    for (rewrites, 0..) |rewrite, index| {
        atomic[index] = .{
            .path = rewrite.path,
            .contents = rewrite.contents,
        };
    }
    try workspace.atomicRewriteFiles(allocator, io, atomic);
}

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
            try workspace.atomicRewriteFile(allocator, io, file.path, rendered);
        }
    }

    return result;
}

fn blockingFormatErrorCount(diagnostics: *const compiler.diag.Bag) usize {
    var count: usize = 0;
    for (diagnostics.items.items) |item| {
        if (item.severity != .@"error") continue;
        if (std.mem.startsWith(u8, item.code, "parse.") or
            std.mem.startsWith(u8, item.code, "syntax.") or
            std.mem.eql(u8, item.code, "workspace.root.missing"))
        {
            count += 1;
        }
    }
    return count;
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
    try appendTrailingLineComment(&raw, tree, tokens, node_id);
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

fn appendTrailingLineComment(
    out: *array_list.Managed(u8),
    tree: *const compiler.cst.Tree,
    tokens: compiler.syntax.TokenStore,
    node_id: compiler.cst.NodeId,
) anyerror!void {
    const last_token = tree.lastTokenRef(node_id) orelse return;
    const last_index = tokens.indexOfRef(last_token) orelse return;
    if (last_index + 1 >= tokens.len()) return;

    const next_token = tokens.refAt(last_index + 1);
    if (tokens.getRef(next_token).kind != .newline) return;

    var trivia = tokens.leadingTriviaIterator(next_token);
    while (trivia.next()) |item| {
        if (item.kind != .comment) continue;
        if (out.items.len != 0 and out.items[out.items.len - 1] != ' ' and out.items[out.items.len - 1] != '\t') {
            try out.append(' ');
        }
        try out.appendSlice(item.lexeme);
        return;
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
