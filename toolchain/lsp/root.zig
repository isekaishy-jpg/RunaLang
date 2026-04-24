const compiler = @import("compiler");
const Allocator = @import("std").mem.Allocator;

pub const summary = "Language server indexing over the shared typed front-end.";

pub const Index = struct {
    files: usize,
    items: usize,
    symbols: usize,
    exported_items: usize,
    reflectable_items: usize,
    boundary_apis: usize,
    type_items: usize,
    struct_fields: usize,
    enum_variants: usize,
    union_fields: usize,
    trait_items: usize,
    trait_methods: usize,
    associated_types: usize,
    impl_items: usize,
    impl_methods: usize,
    syntax_tokens: usize,
    cst_nodes: usize,
    reused_top_level_nodes: usize,
};

pub const DocumentState = struct {
    parsed: compiler.parse.ParsedFile,

    pub fn init(
        allocator: Allocator,
        file: *const compiler.source.File,
        diagnostics: *compiler.diag.Bag,
    ) !DocumentState {
        return .{
            .parsed = try compiler.parse.parseFile(allocator, file, diagnostics),
        };
    }

    pub fn deinit(self: *DocumentState, allocator: Allocator) void {
        self.parsed.deinit(allocator);
    }

    pub fn applyEdits(
        self: *DocumentState,
        allocator: Allocator,
        file: *const compiler.source.File,
        edits: []const compiler.parse.TextEdit,
        diagnostics: *compiler.diag.Bag,
    ) !void {
        const reparsed = try compiler.parse.reparseFile(allocator, &self.parsed, file, edits, diagnostics);
        self.parsed.deinit(allocator);
        self.parsed = reparsed;
    }
};

pub fn buildIndex(pipeline: *const compiler.driver.Pipeline) Index {
    var index = Index{
        .files = pipeline.sourceFileCount(),
        .items = 0,
        .symbols = 0,
        .exported_items = 0,
        .reflectable_items = 0,
        .boundary_apis = 0,
        .type_items = 0,
        .struct_fields = 0,
        .enum_variants = 0,
        .union_fields = 0,
        .trait_items = 0,
        .trait_methods = 0,
        .associated_types = 0,
        .impl_items = 0,
        .impl_methods = 0,
        .syntax_tokens = 0,
        .cst_nodes = 0,
        .reused_top_level_nodes = 0,
    };

    for (pipeline.modules.items) |module| {
        index.symbols += module.resolved.symbols.items.len;
        index.syntax_tokens += module.parsed.tokens.len();
        index.cst_nodes += module.parsed.cst.nodeCount();
        index.reused_top_level_nodes += module.parsed.stats.reused_top_level_nodes;

        var iter = module.parsed.module.iterator();
        while (iter.next()) |item| {
            index.items += 1;
            switch (item.visibility) {
                .pub_item => index.exported_items += 1,
                .private, .pub_package => {},
            }
            if (hasAttribute(item.attributes, "reflect")) index.reflectable_items += 1;
            if (hasAttribute(item.attributes, "boundary")) index.boundary_apis += 1;
            switch (item.body_syntax) {
                .struct_fields => |fields| {
                    index.type_items += 1;
                    index.struct_fields += fields.len;
                },
                .enum_variants => |variants| {
                    index.type_items += 1;
                    index.enum_variants += variants.len;
                },
                .union_fields => |fields| {
                    index.type_items += 1;
                    index.union_fields += fields.len;
                },
                .trait_body => |body| {
                    index.trait_items += 1;
                    index.trait_methods += body.methods.len;
                    index.associated_types += body.associated_types.len;
                },
                .impl_body => |body| {
                    index.impl_items += 1;
                    index.impl_methods += body.methods.len;
                },
                .none => switch (item.kind) {
                    .opaque_type, .struct_type, .enum_type, .union_type => index.type_items += 1,
                    else => {},
                },
            }
        }

        for (module.typed.items.items) |item| {
            if (item.is_synthetic) continue;
            if (item.is_boundary_api and !hasParsedBoundaryAttribute(module.parsed.module, item.name, item.kind)) {
                index.boundary_apis += 1;
            }
        }
    }

    return index;
}

fn hasAttribute(attributes: []const compiler.ast.Attribute, name: []const u8) bool {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return true;
    }
    return false;
}

fn hasParsedBoundaryAttribute(module: compiler.ast.Module, item_name: []const u8, item_kind: compiler.ast.ItemKind) bool {
    var iter = module.iterator();
    while (iter.next()) |item| {
        if (item.kind != item_kind) continue;
        if (!std.mem.eql(u8, item.name, item_name)) continue;
        return hasAttribute(item.attributes, "boundary");
    }
    return false;
}

const std = @import("std");

test "document state applies incremental reparses through shared parser" {
    var table = compiler.source.Table.init(std.testing.allocator);
    defer table.deinit();

    const old_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 2
        \\
    ;
    const new_source =
        \\fn first() -> I32:
        \\    return 1
        \\fn second() -> I32:
        \\    return 22
        \\
    ;

    const old_id = try table.addVirtualFile("lsp-old.rna", old_source);
    const new_id = try table.addVirtualFile("lsp-new.rna", new_source);

    var diagnostics = compiler.diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var document = try DocumentState.init(std.testing.allocator, table.get(old_id), &diagnostics);
    defer document.deinit(std.testing.allocator);

    const edit_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    try document.applyEdits(
        std.testing.allocator,
        table.get(new_id),
        &.{
            .{
                .start = edit_start,
                .end = edit_start + 1,
                .replacement = "22",
            },
        },
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 1), document.parsed.stats.reused_top_level_nodes);
    try std.testing.expectEqual(@as(usize, 1), document.parsed.stats.reparsed_top_level_nodes);
    try std.testing.expectEqualStrings("return 22", document.parsed.module.itemAt(1).block_syntax.?.lines[0].text.text);
}

test "document state preserves indexes across repeated incremental reparses" {
    var table = compiler.source.Table.init(std.testing.allocator);
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

    const old_id = try table.addVirtualFile("lsp-repeat-old.rna", old_source);
    const mid_id = try table.addVirtualFile("lsp-repeat-mid.rna", mid_source);
    const final_id = try table.addVirtualFile("lsp-repeat-final.rna", final_source);

    var diagnostics = compiler.diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var document = try DocumentState.init(std.testing.allocator, table.get(old_id), &diagnostics);
    defer document.deinit(std.testing.allocator);

    const first_ref = document.parsed.tokens.refAt(0);
    const reused_block = document.parsed.module.blockAt(0);

    const first_edit_start = std.mem.indexOf(u8, old_source, "return 2").? + "return ".len;
    try document.applyEdits(
        std.testing.allocator,
        table.get(mid_id),
        &.{
            .{
                .start = first_edit_start,
                .end = first_edit_start + 1,
                .replacement = "22",
            },
        },
        &diagnostics,
    );

    try std.testing.expectEqual(@as(?usize, 0), document.parsed.tokens.indexOfRef(first_ref));
    try std.testing.expect(document.parsed.module.blockAt(0) == reused_block);

    const second_edit_start = std.mem.indexOf(u8, mid_source, "return 3").? + "return ".len;
    try document.applyEdits(
        std.testing.allocator,
        table.get(final_id),
        &.{
            .{
                .start = second_edit_start,
                .end = second_edit_start + 1,
                .replacement = "33",
            },
        },
        &diagnostics,
    );

    try std.testing.expectEqual(@as(?usize, 0), document.parsed.tokens.indexOfRef(first_ref));
    try std.testing.expect(document.parsed.module.blockAt(0) == reused_block);
    try std.testing.expectEqualStrings("return 33", document.parsed.module.itemAt(2).block_syntax.?.lines[0].text.text);
}
