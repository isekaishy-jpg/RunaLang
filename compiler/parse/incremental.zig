const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const cst = @import("../cst/root.zig");
const cst_lower = @import("cst_lower.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const syntax_store = @import("../syntax/store.zig");
const Allocator = std.mem.Allocator;

pub const TextEdit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

pub const ReparseStats = struct {
    reused_top_level_nodes: usize = 0,
    reparsed_top_level_nodes: usize = 0,
    reused_syntax_nodes: usize = 0,
    reparsed_syntax_nodes: usize = 0,
    reused_ast_items: usize = 0,
    reparsed_ast_items: usize = 0,
};

pub const ReparsedFile = struct {
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
    cst: cst.Tree,
    module: ast.Module,
    stats: ReparseStats,

    pub fn deinit(self: *ReparsedFile, allocator: Allocator) void {
        self.tokens.deinit(allocator);
        self.trivia.deinit(allocator);
        self.cst.deinit(allocator);
        self.module.deinit(allocator);
    }
};

const NodeRange = struct {
    child_index: usize,
    node_id: cst.NodeId,
    start_token: usize,
    end_token: usize,
    start_offset: usize,
    end_offset: usize,
};

const AffectedWindow = struct {
    first_index: usize,
    last_index: usize,
    old_start_token: usize,
    old_end_token: usize,
    old_start_offset: usize,
    old_end_offset: usize,
    new_start_offset: usize,
    new_end_offset: usize,
};

const BlockRegion = struct {
    path: []cst.NodeId,
    mode: cst.BlockMode,
    base_indent: usize,
    old_start_token: usize,
    old_end_token: usize,
    old_start_offset: usize,
    old_end_offset: usize,
    new_start_offset: usize,
    new_end_offset: usize,

    fn deinit(self: *BlockRegion, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

const ModuleBuild = struct {
    module: ast.Module,
    reused_ast_items: usize,
    reparsed_ast_items: usize,
};

const placeholder_chunk: *const cst.StoreChunk = @ptrFromInt(@alignOf(cst.StoreChunk));

pub fn countTopLevelNodes(tree: *const cst.Tree) usize {
    var count: usize = 0;
    for (tree.childSlice(tree.root)) |child| {
        switch (child) {
            .node => count += 1,
            else => {},
        }
    }
    return count;
}

pub fn countSyntaxNodes(tree: *const cst.Tree) usize {
    return countReachableNodes(tree, tree.root);
}

pub fn reparseFile(
    allocator: Allocator,
    previous_tokens: syntax.TokenStore,
    previous_tree: *const cst.Tree,
    previous_module: *const ast.Module,
    file: *const source.File,
    edits: []const TextEdit,
    diagnostics: *diag.Bag,
) !ReparsedFile {
    const normalized_edits = try normalizeEdits(allocator, file.contents.len, edits);
    defer allocator.free(normalized_edits);
    if (normalized_edits.len == 0) return parseWholeFile(allocator, file, diagnostics);

    const previous_ranges = try collectTopLevelRanges(allocator, previous_tree, previous_tokens);
    defer allocator.free(previous_ranges);
    if (previous_ranges.len == 0) return parseWholeFile(allocator, file, diagnostics);

    var affected = try chooseAffectedWindow(previous_ranges, normalized_edits);
    resolveNewOffsetRange(&affected, normalized_edits);

    if (try findDeepestBlockPath(allocator, previous_tree, previous_tokens, normalized_edits)) |deepest_path| {
        defer allocator.free(deepest_path);

        var candidate_path: []const cst.NodeId = deepest_path;
        while (true) {
            var owned_region = try buildBlockRegionFromPath(
                allocator,
                previous_tree,
                previous_tokens,
                normalized_edits,
                candidate_path,
            );

            var region_lexed = try syntax.lexFileRangeWithBaseIndent(
                allocator,
                file,
                owned_region.new_start_offset,
                owned_region.new_end_offset,
                owned_region.base_indent,
            );
            errdefer region_lexed.deinit(allocator);

            if (standaloneBlockFragmentIsStable(region_lexed.tokens)) {
                return reparseBlockRegion(
                    allocator,
                    previous_tokens,
                    previous_tree,
                    previous_module,
                    file,
                    &region_lexed,
                    owned_region,
                    diagnostics,
                );
            }

            region_lexed.deinit(allocator);
            owned_region.deinit(allocator);
            candidate_path = nextEnclosingBlockPath(previous_tree, candidate_path) orelse break;
        }
    }

    var window_lexed = try syntax.lexFileRangeWithBaseIndent(
        allocator,
        file,
        affected.new_start_offset,
        affected.new_end_offset,
        0,
    );
    errdefer window_lexed.deinit(allocator);
    return reparseTopLevelWindow(
        allocator,
        previous_tokens,
        previous_tree,
        previous_module,
        file,
        &window_lexed,
        affected,
        diagnostics,
    );
}

fn parseWholeFile(allocator: Allocator, file: *const source.File, diagnostics: *diag.Bag) !ReparsedFile {
    var lexed = try syntax.lexFile(allocator, file);
    errdefer lexed.deinit(allocator);

    var tree = try cst.parseLexedFile(allocator, lexed.tokens, lexed.trivia);
    errdefer tree.deinit(allocator);

    var module = try cst_lower.lowerModule(allocator, file, lexed.tokens, &tree, diagnostics);
    errdefer module.deinit(allocator);

    const stats: ReparseStats = .{
        .reused_top_level_nodes = 0,
        .reparsed_top_level_nodes = countTopLevelNodes(&tree),
        .reused_syntax_nodes = 0,
        .reparsed_syntax_nodes = countSyntaxNodes(&tree),
        .reused_ast_items = 0,
        .reparsed_ast_items = module.itemCount(),
    };

    const result = ReparsedFile{
        .tokens = lexed.tokens,
        .trivia = lexed.trivia,
        .cst = tree,
        .module = module,
        .stats = stats,
    };
    lexed.tokens = syntax.TokenStore.empty();
    lexed.trivia = syntax.TriviaStore.empty();
    return result;
}

fn reparseTopLevelWindow(
    allocator: Allocator,
    previous_tokens: syntax.TokenStore,
    previous_tree: *const cst.Tree,
    previous_module: *const ast.Module,
    file: *const source.File,
    new_lexed: *syntax.LexedFile,
    affected: AffectedWindow,
    diagnostics: *diag.Bag,
) !ReparsedFile {
    var window_tree = try cst.parseLexedFile(allocator, new_lexed.tokens, new_lexed.trivia);
    defer window_tree.deinit(allocator);

    var merged_tokens, var merged_trivia = try buildMergedStores(
        allocator,
        previous_tokens,
        new_lexed.tokens,
        affected.old_start_token,
        affected.old_end_token,
        file.contents,
        offsetDelta(affected.old_end_offset, affected.new_end_offset),
    );
    errdefer {
        merged_tokens.deinit(allocator);
        merged_trivia.deinit(allocator);
    }

    var merged_tree = try mergeTopLevelTree(allocator, previous_tree, &window_tree, affected.first_index, affected.last_index + 1, merged_tokens.len(), merged_trivia.len());
    errdefer merged_tree.deinit(allocator);

    const changed_child_count = countTopLevelNodes(&window_tree);
    const module_build = try buildIncrementalModule(
        allocator,
        previous_module,
        file,
        merged_tokens,
        &merged_tree,
        affected.first_index,
        affected.last_index + 1,
        affected.first_index,
        affected.first_index + changed_child_count,
        diagnostics,
    );
    errdefer {
        var owned_module = module_build.module;
        owned_module.deinit(allocator);
    }

    new_lexed.deinit(allocator);
    new_lexed.tokens = syntax.TokenStore.empty();
    new_lexed.trivia = syntax.TriviaStore.empty();

    const reused_syntax_nodes = countReusedNodes(&merged_tree, previous_tree);
    const reparsed_syntax_nodes = countSyntaxNodes(&merged_tree) - reused_syntax_nodes;
    return .{
        .tokens = merged_tokens,
        .trivia = merged_trivia,
        .cst = merged_tree,
        .module = module_build.module,
        .stats = .{
            .reused_top_level_nodes = affected.first_index + (previous_rangesLen(previous_tree) - (affected.last_index + 1)),
            .reparsed_top_level_nodes = changed_child_count,
            .reused_syntax_nodes = reused_syntax_nodes,
            .reparsed_syntax_nodes = reparsed_syntax_nodes,
            .reused_ast_items = module_build.reused_ast_items,
            .reparsed_ast_items = module_build.reparsed_ast_items,
        },
    };
}

fn reparseBlockRegion(
    allocator: Allocator,
    previous_tokens: syntax.TokenStore,
    previous_tree: *const cst.Tree,
    previous_module: *const ast.Module,
    file: *const source.File,
    new_lexed: *syntax.LexedFile,
    region: BlockRegion,
    diagnostics: *diag.Bag,
) !ReparsedFile {
    var owned_region = region;
    defer owned_region.deinit(allocator);

    var region_tree = try cst.parseLexedBlock(allocator, new_lexed.tokens, new_lexed.trivia, owned_region.mode);
    defer region_tree.deinit(allocator);

    var merged_tokens, var merged_trivia = try buildMergedStores(
        allocator,
        previous_tokens,
        new_lexed.tokens,
        owned_region.old_start_token,
        owned_region.old_end_token,
        file.contents,
        offsetDelta(owned_region.old_end_offset, owned_region.new_end_offset),
    );
    errdefer {
        merged_tokens.deinit(allocator);
        merged_trivia.deinit(allocator);
    }

    var merged_tree = try mergeBlockRegionTree(allocator, previous_tree, &region_tree, owned_region.path, merged_tokens.len(), merged_trivia.len());
    errdefer merged_tree.deinit(allocator);

    const top_level_index = topLevelIndexFromPath(previous_tree, owned_region.path);
    const module_build = try buildIncrementalModule(
        allocator,
        previous_module,
        file,
        merged_tokens,
        &merged_tree,
        top_level_index,
        top_level_index + 1,
        top_level_index,
        top_level_index + 1,
        diagnostics,
    );
    errdefer {
        var owned_module = module_build.module;
        owned_module.deinit(allocator);
    }

    new_lexed.deinit(allocator);
    new_lexed.tokens = syntax.TokenStore.empty();
    new_lexed.trivia = syntax.TriviaStore.empty();

    const reused_syntax_nodes = countReusedNodes(&merged_tree, previous_tree);
    const reparsed_syntax_nodes = countSyntaxNodes(&merged_tree) - reused_syntax_nodes;
    return .{
        .tokens = merged_tokens,
        .trivia = merged_trivia,
        .cst = merged_tree,
        .module = module_build.module,
        .stats = .{
            .reused_top_level_nodes = previous_rangesLen(previous_tree) - 1,
            .reparsed_top_level_nodes = 1,
            .reused_syntax_nodes = reused_syntax_nodes,
            .reparsed_syntax_nodes = reparsed_syntax_nodes,
            .reused_ast_items = module_build.reused_ast_items,
            .reparsed_ast_items = module_build.reparsed_ast_items,
        },
    };
}

fn normalizeEdits(allocator: Allocator, source_len: usize, edits: []const TextEdit) ![]TextEdit {
    if (edits.len == 0) return allocator.alloc(TextEdit, 0);

    const normalized = try allocator.dupe(TextEdit, edits);
    errdefer allocator.free(normalized);

    std.mem.sort(TextEdit, normalized, {}, struct {
        fn lessThan(_: void, lhs: TextEdit, rhs: TextEdit) bool {
            if (lhs.start != rhs.start) return lhs.start < rhs.start;
            return lhs.end < rhs.end;
        }
    }.lessThan);

    for (normalized, 0..) |edit, index| {
        if (edit.start > edit.end or edit.end > source_len) return error.InvalidIncrementalEdit;
        if (index != 0 and normalized[index - 1].end > edit.start) return error.InvalidIncrementalEdit;
    }

    return normalized;
}

fn collectTopLevelRanges(
    allocator: Allocator,
    tree: *const cst.Tree,
    tokens: syntax.TokenStore,
) ![]NodeRange {
    var ranges = array_list.Managed(NodeRange).init(allocator);
    defer ranges.deinit();

    var child_index: usize = 0;
    for (tree.childSlice(tree.root)) |child| {
        const node_id = switch (child) {
            .node => |value| value,
            else => continue,
        };

        const first_token = tree.firstTokenRef(node_id) orelse continue;
        const last_token = tree.lastTokenRef(node_id) orelse continue;
        const start_token = tokens.indexOfRef(first_token) orelse return error.InvalidIncrementalTree;
        const last_token_index = tokens.indexOfRef(last_token) orelse return error.InvalidIncrementalTree;
        const first_span = tokens.getRef(first_token).span;
        const last_span = tokens.getRef(last_token).span;
        try ranges.append(.{
            .child_index = child_index,
            .node_id = node_id,
            .start_token = start_token,
            .end_token = last_token_index + 1,
            .start_offset = first_span.start,
            .end_offset = last_span.end,
        });
        child_index += 1;
    }

    return try ranges.toOwnedSlice();
}

fn chooseAffectedWindow(ranges: []const NodeRange, edits: []const TextEdit) !AffectedWindow {
    if (ranges.len == 0) return error.InvalidIncrementalTree;

    var first_index: usize = std.math.maxInt(usize);
    var last_index: usize = 0;
    for (edits) |edit| {
        const start_index = rangeIndexForEditStart(ranges, edit);
        const end_index = rangeIndexForEditEnd(ranges, edit, start_index);
        if (start_index < first_index) first_index = start_index;
        if (end_index > last_index) last_index = end_index;
        widenWindowForGapTouch(ranges, edit, &first_index, &last_index);
    }

    return .{
        .first_index = first_index,
        .last_index = last_index,
        .old_start_token = ranges[first_index].start_token,
        .old_end_token = ranges[last_index].end_token,
        .old_start_offset = ranges[first_index].start_offset,
        .old_end_offset = ranges[last_index].end_offset,
        .new_start_offset = 0,
        .new_end_offset = 0,
    };
}

fn widenWindowForGapTouch(
    ranges: []const NodeRange,
    edit: TextEdit,
    first_index: *usize,
    last_index: *usize,
) void {
    for (ranges, 0..) |range, index| {
        if (index + 1 >= ranges.len) continue;
        const next = ranges[index + 1];
        if (range.end_offset >= next.start_offset) continue;

        if (edit.end == edit.start) {
            if (edit.start > range.end_offset and edit.start < next.start_offset) {
                if (index < first_index.*) first_index.* = index;
                if (index + 1 > last_index.*) last_index.* = index + 1;
                return;
            }
            continue;
        }

        if (edit.start < next.start_offset and edit.end > range.end_offset) {
            if (index < first_index.*) first_index.* = index;
            if (index + 1 > last_index.*) last_index.* = index + 1;
            return;
        }
    }
}

fn rangeIndexForEditStart(ranges: []const NodeRange, edit: TextEdit) usize {
    for (ranges, 0..) |range, index| {
        if (edit.start != range.end_offset) continue;
        const next_start = if (index + 1 < ranges.len) ranges[index + 1].start_offset else std.math.maxInt(usize);
        if (edit.start < next_start) return index;
    }
    return rangeIndexForPoint(ranges, edit.start);
}

fn rangeIndexForEditEnd(ranges: []const NodeRange, edit: TextEdit, start_index: usize) usize {
    if (edit.end == edit.start) return start_index;
    return rangeIndexForPoint(ranges, edit.end - 1);
}

fn rangeIndexForPoint(ranges: []const NodeRange, point: usize) usize {
    for (ranges, 0..) |range, index| {
        if (point < range.end_offset) return index;
    }
    return ranges.len - 1;
}

fn resolveNewOffsetRange(affected: *AffectedWindow, edits: []const TextEdit) void {
    affected.new_start_offset = translateOldOffsetToNew(edits, affected.old_start_offset);
    affected.new_end_offset = translateOldOffsetToNew(edits, affected.old_end_offset);
}

fn findDeepestBlockPath(
    allocator: Allocator,
    tree: *const cst.Tree,
    tokens: syntax.TokenStore,
    edits: []const TextEdit,
) !?[]cst.NodeId {
    var best_path: ?[]cst.NodeId = null;
    errdefer if (best_path) |path| allocator.free(path);

    var path = array_list.Managed(cst.NodeId).init(allocator);
    defer path.deinit();

    try searchDeepestBlock(allocator, tree, tokens, edits, tree.root, &path, &best_path);
    return best_path;
}

fn buildBlockRegionFromPath(
    allocator: Allocator,
    tree: *const cst.Tree,
    tokens: syntax.TokenStore,
    edits: []const TextEdit,
    path: []const cst.NodeId,
) !BlockRegion {
    const owned_path = try allocator.dupe(cst.NodeId, path);
    errdefer allocator.free(owned_path);

    const block_node = owned_path[owned_path.len - 1];
    const first_token = tree.firstTokenRef(block_node) orelse return error.InvalidIncrementalTree;
    const last_token = tree.lastTokenRef(block_node) orelse return error.InvalidIncrementalTree;
    const old_start_token = tokens.indexOfRef(first_token) orelse return error.InvalidIncrementalTree;
    const old_last_token = tokens.indexOfRef(last_token) orelse return error.InvalidIncrementalTree;
    const old_start_offset = tokens.getRef(first_token).span.start;
    const old_end_offset = tokens.getRef(last_token).span.end;
    const new_start_offset = translateOldOffsetToNew(edits, old_start_offset);
    const new_end_offset = translateOldOffsetToNew(edits, old_end_offset);

    return .{
        .path = owned_path,
        .mode = blockModeForPath(tree, owned_path),
        .base_indent = try baseIndentBeforeToken(allocator, tokens, old_start_token),
        .old_start_token = old_start_token,
        .old_end_token = old_last_token + 1,
        .old_start_offset = old_start_offset,
        .old_end_offset = old_end_offset,
        .new_start_offset = new_start_offset,
        .new_end_offset = new_end_offset,
    };
}

fn nextEnclosingBlockPath(tree: *const cst.Tree, path: []const cst.NodeId) ?[]const cst.NodeId {
    if (path.len < 2) return null;

    var index = path.len - 1;
    while (index != 0) {
        index -= 1;
        if (tree.nodeKind(path[index]) != .block) continue;
        if (index == 0) break;
        return path[0 .. index + 1];
    }
    return null;
}

fn searchDeepestBlock(
    allocator: Allocator,
    tree: *const cst.Tree,
    tokens: syntax.TokenStore,
    edits: []const TextEdit,
    node_id: cst.NodeId,
    path: *array_list.Managed(cst.NodeId),
    best_path: *?[]cst.NodeId,
) !void {
    const span = nodeSpan(tokens, tree, node_id) orelse return;
    if (!spanContainsAllEdits(span, edits)) return;

    try path.append(node_id);
    defer _ = path.pop();

    if (tree.nodeKind(node_id) == .block and path.items.len > 1) {
        if (best_path.*) |existing| allocator.free(existing);
        best_path.* = try allocator.dupe(cst.NodeId, path.items);
    }

    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| try searchDeepestBlock(allocator, tree, tokens, edits, child_node, path, best_path),
            else => {},
        }
    }
}

fn spanContainsAllEdits(span: source.Span, edits: []const TextEdit) bool {
    for (edits) |edit| {
        const end_offset = if (edit.end > edit.start) edit.end else edit.start;
        if (edit.start < span.start or end_offset > span.end) return false;
    }
    return true;
}

fn blockModeForPath(tree: *const cst.Tree, path: []const cst.NodeId) cst.BlockMode {
    if (path.len < 2) return .ordinary;
    const parent = path[path.len - 2];
    return switch (tree.nodeKind(parent)) {
        .select_statement => if (childNodeByKind(tree, parent, .select_head) != null) .subject_select_arms else .guarded_select_arms,
        .struct_item => .struct_fields,
        .union_item => .union_fields,
        .enum_item => .enum_variants,
        .trait_item => .trait_members,
        .impl_item => .impl_members,
        else => .ordinary,
    };
}

fn baseIndentBeforeToken(
    allocator: Allocator,
    tokens: syntax.TokenStore,
    token_index: usize,
) !usize {
    var stack = array_list.Managed(usize).init(allocator);
    defer stack.deinit();
    try stack.append(0);

    for (0..token_index) |index| {
        const token = tokens.get(index);
        switch (token.kind) {
            .indent => try stack.append(token.lexeme.len),
            .dedent => {
                if (stack.items.len > 1) _ = stack.pop();
            },
            else => {},
        }
    }
    return stack.items[stack.items.len - 1];
}

fn standaloneBlockFragmentIsStable(tokens: syntax.TokenStore) bool {
    var index: usize = 0;
    while (index < tokens.len() and tokens.get(index).kind == .newline) : (index += 1) {}
    if (index >= tokens.len()) return false;
    if (tokens.get(index).kind != .indent) return false;

    var depth: usize = 0;
    while (index < tokens.len()) : (index += 1) {
        switch (tokens.get(index).kind) {
            .indent => depth += 1,
            .dedent => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) {
                    index += 1;
                    while (index < tokens.len()) : (index += 1) {
                        switch (tokens.get(index).kind) {
                            .newline, .eof => {},
                            else => return false,
                        }
                    }
                    return true;
                }
            },
            .eof => return false,
            else => {},
        }
    }
    return false;
}

fn buildMergedStores(
    allocator: Allocator,
    previous_tokens: syntax.TokenStore,
    new_tokens: syntax.TokenStore,
    old_start_token: usize,
    old_end_token: usize,
    new_source_contents: []const u8,
    suffix_offset_delta: isize,
) !struct { syntax.TokenStore, syntax.TriviaStore } {
    const prefix_token_segments = try syntax_store.tokenSegmentsForRange(allocator, previous_tokens, 0, old_start_token, null, 0);
    defer allocator.free(prefix_token_segments);
    const window_token_segments = try syntax_store.tokenSegmentsForRange(allocator, new_tokens, 0, new_tokens.len(), null, 0);
    defer allocator.free(window_token_segments);
    const suffix_token_segments = try syntax_store.tokenSegmentsForRange(
        allocator,
        previous_tokens,
        old_end_token,
        previous_tokens.len(),
        if (suffix_offset_delta == 0) null else new_source_contents,
        suffix_offset_delta,
    );
    defer allocator.free(suffix_token_segments);

    const merged_token_segments = try allocator.alloc(syntax_store.TokenSegment, prefix_token_segments.len + window_token_segments.len + suffix_token_segments.len);
    defer allocator.free(merged_token_segments);
    var segment_index: usize = 0;
    for (prefix_token_segments) |segment| {
        merged_token_segments[segment_index] = segment;
        segment_index += 1;
    }
    for (window_token_segments) |segment| {
        merged_token_segments[segment_index] = segment;
        segment_index += 1;
    }
    for (suffix_token_segments) |segment| {
        merged_token_segments[segment_index] = segment;
        segment_index += 1;
    }

    const prefix_trivia_segments = try syntax_store.triviaSegmentsForTokenSegments(allocator, previous_tokens, prefix_token_segments);
    defer allocator.free(prefix_trivia_segments);
    const window_trivia_segments = try syntax_store.triviaSegmentsForTokenSegments(allocator, new_tokens, window_token_segments);
    defer allocator.free(window_trivia_segments);
    const suffix_trivia_segments = try syntax_store.triviaSegmentsForTokenSegments(allocator, previous_tokens, suffix_token_segments);
    defer allocator.free(suffix_trivia_segments);

    const merged_trivia_segments = try allocator.alloc(syntax_store.TriviaSegment, prefix_trivia_segments.len + window_trivia_segments.len + suffix_trivia_segments.len);
    defer allocator.free(merged_trivia_segments);
    var trivia_index: usize = 0;
    for (prefix_trivia_segments) |segment| {
        merged_trivia_segments[trivia_index] = segment;
        trivia_index += 1;
    }
    for (window_trivia_segments) |segment| {
        merged_trivia_segments[trivia_index] = segment;
        trivia_index += 1;
    }
    for (suffix_trivia_segments) |segment| {
        merged_trivia_segments[trivia_index] = segment;
        trivia_index += 1;
    }

    return .{
        try syntax.TokenStore.initFromSegments(allocator, merged_token_segments),
        try syntax.TriviaStore.initFromSegments(allocator, merged_trivia_segments),
    };
}

fn offsetDelta(old_end_offset: usize, new_end_offset: usize) isize {
    return @as(isize, @intCast(new_end_offset)) - @as(isize, @intCast(old_end_offset));
}

fn translateOldOffsetToNew(edits: []const TextEdit, old_offset: usize) usize {
    var delta: isize = 0;
    for (edits) |edit| {
        if (edit.end > old_offset) break;
        delta += @as(isize, @intCast(edit.replacement.len)) - @as(isize, @intCast(edit.end - edit.start));
    }
    return @intCast(@as(isize, @intCast(old_offset)) + delta);
}

fn mergeTopLevelTree(
    allocator: Allocator,
    previous_tree: *const cst.Tree,
    window_tree: *const cst.Tree,
    first_index: usize,
    suffix_start: usize,
    token_count: usize,
    trivia_count: usize,
) !cst.Tree {
    var children = array_list.Managed(cst.Child).init(allocator);
    defer children.deinit();

    const previous_root_children = previous_tree.childSlice(previous_tree.root);
    try children.appendSlice(previous_root_children[0..first_index]);
    try children.appendSlice(window_tree.childSlice(window_tree.root));
    try children.appendSlice(previous_root_children[suffix_start..]);

    const root_children = try children.toOwnedSlice();
    errdefer allocator.free(root_children);

    const nodes = try allocator.alloc(cst.GreenNode, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .kind = .source_file,
        .child_start = 0,
        .child_len = @intCast(root_children.len),
    };

    const root_chunk = try allocator.create(cst.StoreChunk);
    errdefer allocator.destroy(root_chunk);
    root_chunk.* = .{
        .nodes = nodes,
        .children = root_children,
    };

    return buildTreeWithChunks(
        allocator,
        &.{
            ChunkSource.fromRetained(previous_tree.chunks),
            ChunkSource.fromRetained(window_tree.chunks),
            ChunkSource.fromOwned(root_chunk),
        },
        .{ .chunk = root_chunk, .index = 0 },
        token_count,
        trivia_count,
    );
}

fn mergeBlockRegionTree(
    allocator: Allocator,
    previous_tree: *const cst.Tree,
    region_tree: *const cst.Tree,
    path: []const cst.NodeId,
    token_count: usize,
    trivia_count: usize,
) !cst.Tree {
    if (path.len < 2) return error.InvalidIncrementalTree;

    var nodes = array_list.Managed(cst.GreenNode).init(allocator);
    defer nodes.deinit();
    var children = array_list.Managed(cst.Child).init(allocator);
    defer children.deinit();

    var replacement = region_tree.root;
    var next_old = path[path.len - 1];

    var path_index = path.len - 1;
    while (path_index != 0) {
        path_index -= 1;
        const ancestor = path[path_index];
        const ancestor_node = previous_tree.node(ancestor);
        const ancestor_children = previous_tree.childSlice(ancestor);
        const child_start: u32 = @intCast(children.items.len);
        var replaced_child = false;

        for (ancestor_children) |child| {
            switch (child) {
                .node => |child_node| {
                    if (!replaced_child and nodeRefEqual(child_node, next_old)) {
                        const placeholder = if (replacement.chunk == region_tree.root.chunk)
                            replacement
                        else
                            cst.NodeId{ .chunk = placeholder_chunk, .index = replacement.index };
                        try children.append(.{ .node = placeholder });
                        replaced_child = true;
                    } else {
                        try children.append(child);
                    }
                },
                else => try children.append(child),
            }
        }

        if (!replaced_child) return error.InvalidIncrementalTree;

        replacement = .{
            .chunk = undefined,
            .index = @intCast(nodes.items.len),
        };
        try nodes.append(.{
            .kind = ancestor_node.kind,
            .child_start = child_start,
            .child_len = @intCast(ancestor_children.len),
        });
        next_old = ancestor;
    }

    const owned_nodes = try nodes.toOwnedSlice();
    errdefer allocator.free(owned_nodes);
    const owned_children = try children.toOwnedSlice();
    errdefer allocator.free(owned_children);

    const path_chunk = try allocator.create(cst.StoreChunk);
    errdefer allocator.destroy(path_chunk);
    for (owned_children) |*child| {
        switch (child.*) {
            .node => |*node_id| {
                if (node_id.chunk == placeholder_chunk) node_id.chunk = path_chunk;
            },
            else => {},
        }
    }
    path_chunk.* = .{
        .nodes = owned_nodes,
        .children = owned_children,
    };

    const root_ref = cst.NodeId{
        .chunk = path_chunk,
        .index = @intCast(owned_nodes.len - 1),
    };
    return buildTreeWithChunks(
        allocator,
        &.{
            ChunkSource.fromRetained(previous_tree.chunks),
            ChunkSource.fromRetained(region_tree.chunks),
            ChunkSource.fromOwned(path_chunk),
        },
        root_ref,
        token_count,
        trivia_count,
    );
}

const ChunkSource = union(enum) {
    retained_many: []const *cst.StoreChunk,
    owned_one: *cst.StoreChunk,

    fn fromRetained(chunks: []const *cst.StoreChunk) ChunkSource {
        return .{ .retained_many = chunks };
    }

    fn fromOwned(chunk: *cst.StoreChunk) ChunkSource {
        return .{ .owned_one = chunk };
    }
};

fn buildTreeWithChunks(
    allocator: Allocator,
    chunk_sources: []const ChunkSource,
    root: cst.NodeId,
    token_count: usize,
    trivia_count: usize,
) !cst.Tree {
    var chunk_count: usize = 0;
    for (chunk_sources) |source_chunks| {
        switch (source_chunks) {
            .retained_many => |chunks| chunk_count += chunks.len,
            .owned_one => chunk_count += 1,
        }
    }

    const chunks = try allocator.alloc(*cst.StoreChunk, chunk_count);
    errdefer allocator.free(chunks);

    var chunk_index: usize = 0;
    for (chunk_sources) |source_chunks| {
        switch (source_chunks) {
            .retained_many => |source_list| {
                for (source_list) |chunk| {
                    chunk.retain();
                    chunks[chunk_index] = chunk;
                    chunk_index += 1;
                }
            },
            .owned_one => |chunk| {
                chunks[chunk_index] = chunk;
                chunk_index += 1;
            },
        }
    }

    return .{
        .chunks = chunks,
        .root = root,
        .token_count = @intCast(token_count),
        .trivia_count = @intCast(trivia_count),
    };
}

fn buildIncrementalModule(
    allocator: Allocator,
    previous_module: *const ast.Module,
    file: *const source.File,
    tokens: syntax.TokenStore,
    tree: *const cst.Tree,
    previous_start_block: usize,
    previous_end_block: usize,
    changed_start_node_index: usize,
    changed_end_node_index: usize,
    diagnostics: *diag.Bag,
) !ModuleBuild {
    if (previous_module.blockCount() < previous_end_block) return error.InvalidIncrementalModule;

    var module = ast.Module.init(allocator, file.id);
    errdefer module.deinit(allocator);

    var reused_ast_items: usize = 0;
    for (0..previous_start_block) |block_index| {
        const block = previous_module.blockAt(block_index);
        reused_ast_items += block.items.len;
        try module.appendExistingBlock(block);
    }

    const item_count_before = module.itemCount();
    try cst_lower.appendModuleNodeRange(
        allocator,
        &module,
        file,
        tokens,
        tree,
        changed_start_node_index,
        changed_end_node_index,
        diagnostics,
    );
    const reparsed_ast_items = module.itemCount() - item_count_before;

    for (previous_end_block..previous_module.blockCount()) |block_index| {
        const block = previous_module.blockAt(block_index);
        reused_ast_items += block.items.len;
        try module.appendExistingBlock(block);
    }

    return .{
        .module = module,
        .reused_ast_items = reused_ast_items,
        .reparsed_ast_items = reparsed_ast_items,
    };
}

fn countReachableNodes(tree: *const cst.Tree, node_id: cst.NodeId) usize {
    var total: usize = 1;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| total += countReachableNodes(tree, child_node),
            else => {},
        }
    }
    return total;
}

fn countReusedNodes(tree: *const cst.Tree, previous_tree: *const cst.Tree) usize {
    return countReusedNodesFrom(tree, previous_tree, tree.root);
}

fn countReusedNodesFrom(tree: *const cst.Tree, previous_tree: *const cst.Tree, node_id: cst.NodeId) usize {
    var total: usize = if (chunkBelongsToTree(previous_tree, node_id.chunk)) 1 else 0;
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| total += countReusedNodesFrom(tree, previous_tree, child_node),
            else => {},
        }
    }
    return total;
}

fn chunkBelongsToTree(tree: *const cst.Tree, chunk: *const cst.StoreChunk) bool {
    for (tree.chunks) |candidate| {
        if (candidate == chunk) return true;
    }
    return false;
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

fn childNodeByKind(tree: *const cst.Tree, node_id: cst.NodeId, kind: cst.NodeKind) ?cst.NodeId {
    for (tree.childSlice(node_id)) |child| {
        switch (child) {
            .node => |child_node| if (tree.nodeKind(child_node) == kind) return child_node,
            else => {},
        }
    }
    return null;
}

fn previous_rangesLen(tree: *const cst.Tree) usize {
    return countTopLevelNodes(tree);
}

fn topLevelIndexFromPath(tree: *const cst.Tree, path: []const cst.NodeId) usize {
    if (path.len < 2) return 0;
    const top_level_node = path[1];
    var index: usize = 0;
    for (tree.childSlice(tree.root)) |child| {
        switch (child) {
            .node => |child_node| {
                if (nodeRefEqual(child_node, top_level_node)) return index;
                index += 1;
            },
            else => {},
        }
    }
    unreachable;
}

fn nodeRefEqual(lhs: cst.NodeId, rhs: cst.NodeId) bool {
    return lhs.chunk == rhs.chunk and lhs.index == rhs.index;
}

test "affected window widens across top-level boundary edits" {
    const ranges = [_]NodeRange{
        .{
            .child_index = 0,
            .node_id = undefined,
            .start_token = 0,
            .end_token = 4,
            .start_offset = 0,
            .end_offset = 10,
        },
        .{
            .child_index = 1,
            .node_id = undefined,
            .start_token = 4,
            .end_token = 8,
            .start_offset = 10,
            .end_offset = 20,
        },
    };

    const boundary_edit = [_]TextEdit{.{
        .start = 10,
        .end = 10,
        .replacement = "\n",
    }};
    const widened_boundary = try chooseAffectedWindow(&ranges, &boundary_edit);
    try std.testing.expectEqual(@as(usize, 0), widened_boundary.first_index);
    try std.testing.expectEqual(@as(usize, 1), widened_boundary.last_index);

    const gap_ranges = [_]NodeRange{
        .{
            .child_index = 0,
            .node_id = undefined,
            .start_token = 0,
            .end_token = 4,
            .start_offset = 0,
            .end_offset = 10,
        },
        .{
            .child_index = 1,
            .node_id = undefined,
            .start_token = 4,
            .end_token = 8,
            .start_offset = 12,
            .end_offset = 20,
        },
    };
    const gap_edit = [_]TextEdit{.{
        .start = 11,
        .end = 11,
        .replacement = "",
    }};
    const widened_gap = try chooseAffectedWindow(&gap_ranges, &gap_edit);
    try std.testing.expectEqual(@as(usize, 0), widened_gap.first_index);
    try std.testing.expectEqual(@as(usize, 1), widened_gap.last_index);
}

test "affected window keeps ordinary item-start edits local" {
    const ranges = [_]NodeRange{
        .{
            .child_index = 0,
            .node_id = undefined,
            .start_token = 0,
            .end_token = 4,
            .start_offset = 0,
            .end_offset = 10,
        },
        .{
            .child_index = 1,
            .node_id = undefined,
            .start_token = 4,
            .end_token = 8,
            .start_offset = 10,
            .end_offset = 20,
        },
    };

    const token_edit = [_]TextEdit{.{
        .start = 10,
        .end = 11,
        .replacement = "g",
    }};
    const affected = try chooseAffectedWindow(&ranges, &token_edit);
    try std.testing.expectEqual(@as(usize, 1), affected.first_index);
    try std.testing.expectEqual(@as(usize, 1), affected.last_index);
}

test "standalone block stability rejects trailing sibling tokens" {
    const source_text =
        \\    repeat:
        \\    return 1
        \\    return 2
        \\
    ;
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();
    const file_id = try table.addVirtualFile("unstable-block-fragment.rna", source_text);
    const file = table.get(file_id);

    var lexed = try syntax.lexFileRangeWithBaseIndent(std.testing.allocator, file, 0, file.contents.len, 4);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expect(!standaloneBlockFragmentIsStable(lexed.tokens));
}

test "next enclosing block path climbs to the outer block" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "incremental-nested-blocks.rna",
        "fn main() -> I32:\n    repeat:\n        select:\n            when ready => return 1\n        return 2\n    return 3\n",
    );
    const file = table.get(file_id);

    var lexed = try syntax.lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);
    var tree = try cst.parseLexedFile(std.testing.allocator, lexed.tokens, lexed.trivia);
    defer tree.deinit(std.testing.allocator);

    const edit_start = std.mem.indexOf(u8, file.contents, "return 1").?;
    const path = try findDeepestBlockPath(
        std.testing.allocator,
        &tree,
        lexed.tokens,
        &.{
            .{
                .start = edit_start,
                .end = edit_start + "return 1".len,
                .replacement = "return 11",
            },
        },
    ) orelse return error.UnexpectedStructure;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(cst.NodeKind.block, tree.nodeKind(path[path.len - 1]));
    const outer_path = nextEnclosingBlockPath(&tree, path) orelse return error.UnexpectedStructure;
    try std.testing.expect(outer_path.len < path.len);
    try std.testing.expectEqual(cst.NodeKind.block, tree.nodeKind(outer_path[outer_path.len - 1]));

    const deepest_region = try buildBlockRegionFromPath(std.testing.allocator, &tree, lexed.tokens, &.{
        .{
            .start = edit_start,
            .end = edit_start + "return 1".len,
            .replacement = "return 11",
        },
    }, path);
    defer deepest_region.deinit(std.testing.allocator);
    const outer_region = try buildBlockRegionFromPath(std.testing.allocator, &tree, lexed.tokens, &.{
        .{
            .start = edit_start,
            .end = edit_start + "return 1".len,
            .replacement = "return 11",
        },
    }, outer_path);
    defer outer_region.deinit(std.testing.allocator);

    try std.testing.expect(outer_region.old_start_offset < deepest_region.old_start_offset);
    try std.testing.expect(outer_region.old_end_offset > deepest_region.old_end_offset);
}
