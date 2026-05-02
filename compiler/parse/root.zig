const std = @import("std");
const ast = @import("../ast/root.zig");
const cst = @import("../cst/root.zig");
const cst_lower = @import("cst_lower.zig");
const diag = @import("../diag/root.zig");
const incremental = @import("incremental.zig");
const source = @import("../source/root.zig");
const syntax = @import("../syntax/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Parsing from tokens and CST into AST.";

pub const TextEdit = incremental.TextEdit;
pub const ReparseStats = incremental.ReparseStats;

pub const ParsedFile = struct {
    tokens: syntax.TokenStore,
    trivia: syntax.TriviaStore,
    cst: cst.Tree,
    module: ast.Module,
    stats: ReparseStats = .{},

    pub fn deinit(self: *ParsedFile, allocator: Allocator) void {
        self.tokens.deinit(allocator);
        self.trivia.deinit(allocator);
        self.cst.deinit(allocator);
        self.module.deinit(allocator);
    }
};

pub fn parseFile(allocator: Allocator, file: *const source.File, diagnostics: *diag.Bag) !ParsedFile {
    var lexed = try syntax.lexFile(allocator, file);
    errdefer lexed.deinit(allocator);

    var syntax_tree = try cst.parseLexedFile(allocator, lexed.tokens, lexed.trivia);
    errdefer syntax_tree.deinit(allocator);

    var parsed = ParsedFile{
        .tokens = lexed.tokens,
        .trivia = lexed.trivia,
        .cst = syntax_tree,
        .module = try cst_lower.lowerModule(allocator, file, lexed.tokens, &syntax_tree, diagnostics),
        .stats = .{
            .reused_top_level_nodes = 0,
            .reparsed_top_level_nodes = incremental.countTopLevelNodes(&syntax_tree),
            .reused_syntax_nodes = 0,
            .reparsed_syntax_nodes = incremental.countSyntaxNodes(&syntax_tree),
            .reused_ast_items = 0,
            .reparsed_ast_items = 0,
        },
    };
    lexed.tokens = syntax.TokenStore.empty();
    lexed.trivia = syntax.TriviaStore.empty();
    errdefer parsed.deinit(allocator);

    parsed.stats.reparsed_ast_items = parsed.module.itemCount();

    return parsed;
}

pub fn reparseFile(
    allocator: Allocator,
    previous: *const ParsedFile,
    file: *const source.File,
    edits: []const TextEdit,
    diagnostics: *diag.Bag,
) !ParsedFile {
    var reparsed = try incremental.reparseFile(
        allocator,
        previous.tokens,
        &previous.cst,
        &previous.module,
        file,
        edits,
        diagnostics,
    );
    errdefer reparsed.deinit(allocator);

    return .{
        .tokens = reparsed.tokens,
        .trivia = reparsed.trivia,
        .cst = reparsed.cst,
        .module = reparsed.module,
        .stats = reparsed.stats,
    };
}

fn findTokenIndex(tokens: syntax.TokenStore, lexeme: []const u8) ?usize {
    for (0..tokens.len()) |index| {
        if (std.mem.eql(u8, tokens.lexemeAt(index), lexeme)) return index;
    }
    return null;
}

test "parse file lowers shallow AST items from CST grouping" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "parse-items.rna",
        "#foreign\npub fn main[T](value: T) -> Unit\nwhere T: Send:\n    return value\nuse package.core.{answer as result, helper}\n",
    );
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    const function_item = parsed.module.itemAt(0).*;
    try std.testing.expectEqual(ast.ItemKind.function, function_item.kind);
    try std.testing.expectEqualStrings("main", function_item.name);
    try std.testing.expectEqual(ast.Visibility.pub_item, function_item.visibility);
    try std.testing.expectEqual(@as(usize, 1), function_item.attributes.len);
    try std.testing.expectEqualStrings("foreign", function_item.attributes[0].name);
    switch (function_item.syntax) {
        .function => |signature| {
            try std.testing.expectEqualStrings("main", signature.name.?.text);
            try std.testing.expectEqual(@as(usize, 1), signature.generic_params.?.params.len);
            try std.testing.expectEqual(ast.GenericParamKindSyntax.type_param, signature.generic_params.?.params[0].kind);
            try std.testing.expectEqualStrings("T", signature.generic_params.?.params[0].name);
            try std.testing.expectEqual(@as(usize, 1), signature.parameters.len);
            try std.testing.expectEqualStrings("value", signature.parameters[0].name.?.text);
            try std.testing.expectEqualStrings("T", signature.parameters[0].ty.?.text());
            try std.testing.expectEqual(ast.ParameterModeSyntax.owned, signature.parameters[0].mode);
            try std.testing.expectEqualStrings("Unit", signature.return_type.?.text());
            try std.testing.expectEqual(@as(usize, 1), signature.where_clauses.len);
            try std.testing.expectEqual(@as(usize, 1), signature.where_clauses[0].predicates.len);
            switch (signature.where_clauses[0].predicates[0]) {
                .bound => |predicate| {
                    try std.testing.expectEqualStrings("T", predicate.subject_name);
                    try std.testing.expectEqualStrings("Send", predicate.contract_name);
                },
                else => return error.UnexpectedStructure,
            }
        },
        else => return error.UnexpectedStructure,
    }

    const use_result = parsed.module.itemAt(1).*;
    try std.testing.expectEqual(ast.ItemKind.use_decl, use_result.kind);
    try std.testing.expectEqualStrings("result", use_result.name);
    try std.testing.expectEqualStrings("package.core.answer", use_result.target_path.?);
    switch (use_result.syntax) {
        .use_decl => |binding| {
            try std.testing.expectEqualStrings("package.core", binding.prefix.?.text);
            try std.testing.expectEqualStrings("answer", binding.leaf.?.text);
            try std.testing.expectEqualStrings("result", binding.alias.?.text);
        },
        else => return error.UnexpectedStructure,
    }

    const use_helper = parsed.module.itemAt(2).*;
    try std.testing.expectEqual(ast.ItemKind.use_decl, use_helper.kind);
    try std.testing.expectEqualStrings("helper", use_helper.name);
    try std.testing.expectEqualStrings("package.core.helper", use_helper.target_path.?);
    switch (use_helper.syntax) {
        .use_decl => |binding| {
            try std.testing.expectEqualStrings("package.core", binding.prefix.?.text);
            try std.testing.expectEqualStrings("helper", binding.leaf.?.text);
            try std.testing.expect(binding.alias == null);
        },
        else => return error.UnexpectedStructure,
    }
}

test "parse file keeps orphan attribute diagnostics under CST lowering" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("parse-orphan-attr.rna", "#export\n");
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 1), diagnostics.errorCount());
    try std.testing.expectEqualStrings("parse.attr.orphan", diagnostics.items.items[0].code);
}

test "parse file accepts use paths containing super as a substring" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("parse-use-supervisor.rna", "use pkg.supervisor.util\n");
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(ast.ItemKind.use_decl, parsed.module.itemAt(0).kind);
    try std.testing.expectEqualStrings("util", parsed.module.itemAt(0).name);
    try std.testing.expectEqualStrings("pkg.supervisor.util", parsed.module.itemAt(0).target_path.?);
}

test "parse file lowers structured declaration body syntax" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "parse-bodies.rna",
        "struct Box[T]:\n    pub value: T\nenum Choice:\n    Some(T)\n    None:\n        code: I32\ntrait Buffer:\n    type Item\n    const LIMIT: Index\n    fn read(read self: Buffer) -> Item\nimpl[T] Buffer for Box[T]:\n    const LIMIT: Index = 4\n    fn read(read self: Box[T]) -> T:\n        return self.value\n",
    );
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    switch (parsed.module.itemAt(0).body_syntax) {
        .struct_fields => |fields| {
            try std.testing.expectEqual(@as(usize, 1), fields.len);
            try std.testing.expectEqual(ast.Visibility.pub_item, fields[0].visibility);
            try std.testing.expectEqualStrings("value", fields[0].name.?.text);
            try std.testing.expectEqualStrings("T", fields[0].ty.?.text());
        },
        else => return error.UnexpectedStructure,
    }

    switch (parsed.module.itemAt(1).body_syntax) {
        .enum_variants => |variants| {
            try std.testing.expectEqual(@as(usize, 2), variants.len);
            try std.testing.expectEqualStrings("Some", variants[0].name.?.text);
            try std.testing.expectEqual(@as(usize, 1), variants[0].tuple_payload.?.types.len);
            try std.testing.expectEqualStrings("T", variants[0].tuple_payload.?.types[0].text());
            try std.testing.expectEqualStrings("None", variants[1].name.?.text);
            try std.testing.expectEqual(@as(usize, 1), variants[1].named_fields.len);
            try std.testing.expectEqualStrings("code", variants[1].named_fields[0].name.?.text);
        },
        else => return error.UnexpectedStructure,
    }

    switch (parsed.module.itemAt(2).body_syntax) {
        .trait_body => |body| {
            try std.testing.expectEqual(@as(usize, 1), body.associated_types.len);
            try std.testing.expectEqual(@as(usize, 1), body.associated_consts.len);
            try std.testing.expectEqual(@as(usize, 1), body.methods.len);
            try std.testing.expectEqualStrings("Item", body.associated_types[0].name.?.text);
            try std.testing.expectEqualStrings("LIMIT", body.associated_consts[0].name.?.text);
            try std.testing.expectEqualStrings("Index", body.associated_consts[0].ty.?.text());
            try std.testing.expectEqualStrings("read", body.methods[0].signature.name.?.text);
        },
        else => return error.UnexpectedStructure,
    }

    switch (parsed.module.itemAt(3).body_syntax) {
        .impl_body => |body| {
            try std.testing.expectEqual(@as(usize, 1), body.associated_consts.len);
            try std.testing.expectEqualStrings("LIMIT", body.associated_consts[0].name.?.text);
            try std.testing.expectEqualStrings("4", body.associated_consts[0].initializer.?.text);
            try std.testing.expectEqual(@as(usize, 1), body.methods.len);
            try std.testing.expectEqualStrings("read", body.methods[0].signature.name.?.text);
            try std.testing.expect(body.methods[0].block_syntax != null);
            try std.testing.expectEqualStrings("return self.value", body.methods[0].block_syntax.?.lines[0].text.text);
        },
        else => return error.UnexpectedStructure,
    }
}

test "parse file lowers structured nested function block syntax" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "parse-blocks.rna",
        "fn main(flag: Bool) -> I32:\n    select:\n        when flag => return 1\n        else =>\n            return 2\n    repeat:\n        return 3\n",
    );
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    const block = parsed.module.itemAt(0).block_syntax orelse return error.UnexpectedStructure;
    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try std.testing.expectEqualStrings("select:", block.lines[0].text.text);
    try std.testing.expect(block.lines[0].block != null);
    try std.testing.expectEqual(@as(usize, 2), block.lines[0].block.?.lines.len);
    try std.testing.expectEqualStrings("when flag => return 1", block.lines[0].block.?.lines[0].text.text);
    try std.testing.expectEqualStrings("else =>", block.lines[0].block.?.lines[1].text.text);
    try std.testing.expect(block.lines[0].block.?.lines[1].block != null);
    try std.testing.expectEqualStrings("return 2", block.lines[0].block.?.lines[1].block.?.lines[0].text.text);
    try std.testing.expectEqualStrings("repeat:", block.lines[1].text.text);
    try std.testing.expect(block.lines[1].block != null);
    try std.testing.expectEqualStrings("return 3", block.lines[1].block.?.lines[0].text.text);
}

test "parse file keeps declaration and local declared types as TypeSyntax carriers" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "parse-type-carriers.rna",
        "type Output = Option[Str]\nimpl Reader for Buffer:\n    type Item = Str\nfn main(input: Str) -> Str:\n    let copy: Str = input\n    const count: Index = 4\n    return copy\n",
    );
    const file = table.get(file_id);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var parsed = try parseFile(std.testing.allocator, file, &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.module.itemCount());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    switch (parsed.module.itemAt(0).syntax) {
        .type_alias => |alias| try std.testing.expectEqualStrings("Option[Str]", alias.target.?.text()),
        else => return error.UnexpectedStructure,
    }

    switch (parsed.module.itemAt(1).body_syntax) {
        .impl_body => |body| {
            try std.testing.expectEqual(@as(usize, 1), body.associated_types.len);
            try std.testing.expectEqualStrings("Str", body.associated_types[0].value.?.text());
        },
        else => return error.UnexpectedStructure,
    }

    const structured = parsed.module.itemAt(2).block_syntax.?.structured;
    try std.testing.expectEqual(@as(usize, 3), structured.statements.len);
    switch (structured.statements[0]) {
        .let_decl => |binding| try std.testing.expectEqualStrings("Str", binding.declared_type.?.text()),
        else => return error.UnexpectedStructure,
    }
    switch (structured.statements[1]) {
        .const_decl => |binding| try std.testing.expectEqualStrings("Index", binding.declared_type.?.text()),
        else => return error.UnexpectedStructure,
    }
}

test "incremental reparse reuses unchanged top-level CST nodes" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 2
        \\fn third() -> I32:
        \\    return 3
        \\
    ;
    const new_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 22
        \\fn third() -> I32:
        \\    return 3
        \\
    ;

    const old_id = try table.addVirtualFile("incremental-old.rna", old_source);
    const new_id = try table.addVirtualFile("incremental-new.rna", new_source);
    const old_file = table.get(old_id);
    const new_file = table.get(new_id);

    var old_diagnostics = diag.Bag.init(std.testing.allocator);
    defer old_diagnostics.deinit();
    var parsed = try parseFile(std.testing.allocator, old_file, &old_diagnostics);
    defer parsed.deinit(std.testing.allocator);

    const old_value_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    var new_diagnostics = diag.Bag.init(std.testing.allocator);
    defer new_diagnostics.deinit();
    var reparsed = try reparseFile(
        std.testing.allocator,
        &parsed,
        new_file,
        &.{
            .{
                .start = old_value_start,
                .end = old_value_start + 1,
                .replacement = "22",
            },
        },
        &new_diagnostics,
    );
    defer reparsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), new_diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 2), reparsed.stats.reused_top_level_nodes);
    try std.testing.expectEqual(@as(usize, 1), reparsed.stats.reparsed_top_level_nodes);
    try std.testing.expect(reparsed.stats.reused_syntax_nodes >= reparsed.stats.reused_top_level_nodes);
    try std.testing.expectEqual(@as(usize, 3), reparsed.module.itemCount());

    const block = reparsed.module.itemAt(1).block_syntax orelse return error.UnexpectedStructure;
    try std.testing.expectEqualStrings("return 22", block.lines[0].text.text);
}

test "incremental reparse reuses nested block subtrees for edit-local changes" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn main(flag: Bool) -> I32:
        \\    return 0
        \\    select:
        \\        when flag =>
        \\            return 1
        \\        else =>
        \\            return 2
        \\    return 3
        \\
    ;
    const new_source =
        \\fn main(flag: Bool) -> I32:
        \\    return 0
        \\    select:
        \\        when flag =>
        \\            return 1
        \\        else =>
        \\            return 22
        \\    return 3
        \\
    ;

    const old_id = try table.addVirtualFile("incremental-block-old.rna", old_source);
    const new_id = try table.addVirtualFile("incremental-block-new.rna", new_source);

    var old_diagnostics = diag.Bag.init(std.testing.allocator);
    defer old_diagnostics.deinit();
    var parsed = try parseFile(std.testing.allocator, table.get(old_id), &old_diagnostics);
    defer parsed.deinit(std.testing.allocator);

    const edit_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    var new_diagnostics = diag.Bag.init(std.testing.allocator);
    defer new_diagnostics.deinit();
    var reparsed = try reparseFile(
        std.testing.allocator,
        &parsed,
        table.get(new_id),
        &.{
            .{
                .start = edit_start,
                .end = edit_start + 1,
                .replacement = "22",
            },
        },
        &new_diagnostics,
    );
    defer reparsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), new_diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 0), reparsed.stats.reused_top_level_nodes);
    try std.testing.expectEqual(@as(usize, 1), reparsed.stats.reparsed_top_level_nodes);
    try std.testing.expect(reparsed.stats.reused_syntax_nodes > 0);
    try std.testing.expect(reparsed.stats.reparsed_syntax_nodes < incremental.countSyntaxNodes(&parsed.cst));

    const block = reparsed.module.itemAt(0).block_syntax orelse return error.UnexpectedStructure;
    try std.testing.expectEqualStrings("return 0", block.lines[0].text.text);
    try std.testing.expectEqualStrings("return 3", block.lines[2].text.text);
    const select_block = block.lines[1].block orelse return error.UnexpectedStructure;
    try std.testing.expectEqualStrings("else =>", select_block.lines[1].text.text);
    const else_block = select_block.lines[1].block orelse return error.UnexpectedStructure;
    try std.testing.expectEqualStrings("return 22", else_block.lines[0].text.text);
}

test "incremental reparse preserves suffix spans for length-changing edits" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 2
        \\fn third() -> I32:
        \\    return 3
        \\
    ;
    const new_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 22
        \\fn third() -> I32:
        \\    return 3
        \\
    ;

    const old_id = try table.addVirtualFile("incremental-shift-old.rna", old_source);
    const new_id = try table.addVirtualFile("incremental-shift-new.rna", new_source);

    var old_diagnostics = diag.Bag.init(std.testing.allocator);
    defer old_diagnostics.deinit();
    var parsed = try parseFile(std.testing.allocator, table.get(old_id), &old_diagnostics);
    defer parsed.deinit(std.testing.allocator);

    const edit_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    var new_diagnostics = diag.Bag.init(std.testing.allocator);
    defer new_diagnostics.deinit();
    var reparsed = try reparseFile(
        std.testing.allocator,
        &parsed,
        table.get(new_id),
        &.{
            .{
                .start = edit_start,
                .end = edit_start + 1,
                .replacement = "22",
            },
        },
        &new_diagnostics,
    );
    defer reparsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), new_diagnostics.errorCount());
    try std.testing.expect(parsed.module.blockAt(0) == reparsed.module.blockAt(0));
    try std.testing.expect(reparsed.stats.reused_ast_items > 0);
    try std.testing.expect(parsed.tokens.refAt(0).chunk == reparsed.tokens.refAt(0).chunk);
    try std.testing.expect(reparsed.tokens.segmentCount() >= 2);

    const third_index = findTokenIndex(reparsed.tokens, "third") orelse return error.UnexpectedStructure;
    try std.testing.expectEqual(std.mem.indexOf(u8, new_source, "third").?, reparsed.tokens.get(third_index).span.start);
    try std.testing.expectEqualStrings("third", reparsed.tokens.lexemeAt(third_index));
}

test "incremental reparse preserves reuse and valid refs across repeated edits" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 2
        \\fn third() -> I32:
        \\    return 3
        \\
    ;
    const mid_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 22
        \\fn third() -> I32:
        \\    return 3
        \\
    ;
    const final_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 22
        \\fn third() -> I32:
        \\    return 33
        \\
    ;

    const old_id = try table.addVirtualFile("incremental-repeat-old.rna", old_source);
    const mid_id = try table.addVirtualFile("incremental-repeat-mid.rna", mid_source);
    const final_id = try table.addVirtualFile("incremental-repeat-final.rna", final_source);

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();
    var parsed = try parseFile(std.testing.allocator, table.get(old_id), &diagnostics);
    defer parsed.deinit(std.testing.allocator);

    const first_edit_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    var first_reparse_diags = diag.Bag.init(std.testing.allocator);
    defer first_reparse_diags.deinit();
    var first_reparse = try reparseFile(
        std.testing.allocator,
        &parsed,
        table.get(mid_id),
        &.{
            .{
                .start = first_edit_start,
                .end = first_edit_start + 1,
                .replacement = "22",
            },
        },
        &first_reparse_diags,
    );
    defer first_reparse.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), first_reparse_diags.errorCount());
    const first_ref = first_reparse.tokens.refAt(0);
    try std.testing.expectEqual(@as(?usize, 0), first_reparse.tokens.indexOfRef(first_ref));
    try std.testing.expect(parsed.module.blockAt(0) == first_reparse.module.blockAt(0));

    const second_edit_start = std.mem.indexOf(u8, mid_source, "return 3").? + "return ".len;
    var second_reparse_diags = diag.Bag.init(std.testing.allocator);
    defer second_reparse_diags.deinit();
    var second_reparse = try reparseFile(
        std.testing.allocator,
        &first_reparse,
        table.get(final_id),
        &.{
            .{
                .start = second_edit_start,
                .end = second_edit_start + 1,
                .replacement = "33",
            },
        },
        &second_reparse_diags,
    );
    defer second_reparse.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), second_reparse_diags.errorCount());
    try std.testing.expect(first_reparse.module.blockAt(0) == second_reparse.module.blockAt(0));
    try std.testing.expect(first_ref.chunk == second_reparse.tokens.refAt(0).chunk);
    try std.testing.expectEqual(@as(?usize, 0), second_reparse.tokens.indexOfRef(second_reparse.tokens.refAt(0)));

    const third_index = findTokenIndex(second_reparse.tokens, "33") orelse return error.UnexpectedStructure;
    try std.testing.expectEqualStrings("33", second_reparse.tokens.lexemeAt(third_index));
    try std.testing.expectEqual(std.mem.indexOf(u8, final_source, "33").?, second_reparse.tokens.get(third_index).span.start);
}

test "incremental reparse widens when a nested block no longer stands alone" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn main() -> I32:
        \\    repeat:
        \\        return 1
        \\    return 2
        \\
    ;
    const new_source =
        \\fn main() -> I32:
        \\    repeat:
        \\    return 1
        \\    return 2
        \\
    ;

    const old_id = try table.addVirtualFile("incremental-block-shrink-old.rna", old_source);
    const new_id = try table.addVirtualFile("incremental-block-shrink-new.rna", new_source);

    var old_diagnostics = diag.Bag.init(std.testing.allocator);
    defer old_diagnostics.deinit();
    var parsed = try parseFile(std.testing.allocator, table.get(old_id), &old_diagnostics);
    defer parsed.deinit(std.testing.allocator);

    const indent_start = std.mem.indexOf(u8, old_source, "        return 1").?;
    var new_diagnostics = diag.Bag.init(std.testing.allocator);
    defer new_diagnostics.deinit();
    var reparsed = try reparseFile(
        std.testing.allocator,
        &parsed,
        table.get(new_id),
        &.{
            .{
                .start = indent_start,
                .end = indent_start + 4,
                .replacement = "",
            },
        },
        &new_diagnostics,
    );
    defer reparsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), new_diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), reparsed.module.itemCount());
    try std.testing.expect(reparsed.stats.reused_syntax_nodes > 0);
    const block = reparsed.module.itemAt(0).block_syntax orelse return error.UnexpectedStructure;
    try std.testing.expectEqual(@as(usize, 3), block.lines.len);
    try std.testing.expectEqualStrings("repeat:", block.lines[0].text.text);
    try std.testing.expectEqualStrings("return 1", block.lines[1].text.text);
    try std.testing.expectEqualStrings("return 2", block.lines[2].text.text);
}
