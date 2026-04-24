const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Lowered source-oriented representation.";
pub const keeps_explicit_ownership = true;

pub const Visibility = ast.Visibility;
pub const Attribute = ast.Attribute;
pub const SpanText = ast.SpanText;
pub const BlockSyntax = ast.BlockSyntax;
pub const LineSyntax = ast.LineSyntax;
pub const BodyBlockSyntax = ast.BodyBlockSyntax;
pub const BodyStatementSyntax = ast.BodyStatementSyntax;
pub const BodyExprSyntax = ast.BodyExprSyntax;
pub const BodyPatternSyntax = ast.BodyPatternSyntax;
pub const AssignOpSyntax = ast.AssignOpSyntax;
pub const ParameterSyntax = ast.ParameterSyntax;
pub const FunctionSignatureSyntax = ast.FunctionSignatureSyntax;
pub const ConstSignatureSyntax = ast.ConstSignatureSyntax;
pub const NamedDeclSyntax = ast.NamedDeclSyntax;
pub const UseBindingSyntax = ast.UseBindingSyntax;
pub const ImplSignatureSyntax = ast.ImplSignatureSyntax;
pub const ItemSyntax = ast.ItemSyntax;
pub const FieldDeclSyntax = ast.FieldDeclSyntax;
pub const EnumVariantSyntax = ast.EnumVariantSyntax;
pub const AssociatedTypeDeclSyntax = ast.AssociatedTypeDeclSyntax;
pub const MethodDeclSyntax = ast.MethodDeclSyntax;
pub const TraitBodySyntax = ast.TraitBodySyntax;
pub const ImplBodySyntax = ast.ImplBodySyntax;
pub const ItemBodySyntax = ast.ItemBodySyntax;
pub const ItemKind = ast.ItemKind;

pub const Item = struct {
    kind: ItemKind,
    name: []const u8,
    visibility: Visibility,
    attributes: []Attribute,
    target_path: ?[]const u8 = null,
    span: source.Span,
    has_body: bool,
    foreign_abi: ?[]const u8 = null,
    syntax: ItemSyntax = .none,
    body_syntax: ItemBodySyntax = .none,
    block_syntax: ?BlockSyntax = null,

    pub fn deinit(self: Item, allocator: Allocator) void {
        var owned_syntax = self.syntax;
        owned_syntax.deinit(allocator);
        var owned_body_syntax = self.body_syntax;
        owned_body_syntax.deinit(allocator);
        if (self.block_syntax) |block| {
            var owned_block = block;
            owned_block.deinit(allocator);
        }
        allocator.free(self.attributes);
        allocator.free(self.name);
        if (self.target_path) |value| allocator.free(value);
    }

    pub fn clone(self: Item, allocator: Allocator) !Item {
        var cloned_syntax = try self.syntax.clone(allocator);
        errdefer cloned_syntax.deinit(allocator);
        var cloned_body_syntax = try self.body_syntax.clone(allocator);
        errdefer cloned_body_syntax.deinit(allocator);
        const cloned_block_syntax = if (self.block_syntax) |block| try block.clone(allocator) else null;
        errdefer if (cloned_block_syntax) |block| {
            var owned_block = block;
            owned_block.deinit(allocator);
        };

        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const attributes = try allocator.dupe(Attribute, self.attributes);
        errdefer allocator.free(attributes);
        const target_path = if (self.target_path) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (target_path) |value| allocator.free(value);

        return .{
            .kind = self.kind,
            .name = name,
            .visibility = self.visibility,
            .attributes = attributes,
            .target_path = target_path,
            .span = self.span,
            .has_body = self.has_body,
            .foreign_abi = self.foreign_abi,
            .syntax = cloned_syntax,
            .body_syntax = cloned_body_syntax,
            .block_syntax = cloned_block_syntax,
        };
    }
};

pub const Module = struct {
    file_id: source.FileId,
    items: array_list.Managed(Item),

    pub fn init(allocator: Allocator, file_id: source.FileId) Module {
        return .{
            .file_id = file_id,
            .items = array_list.Managed(Item).init(allocator),
        };
    }

    pub fn deinit(self: *Module, allocator: Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit();
    }
};

pub fn lowerModule(allocator: Allocator, parsed: ast.Module) !Module {
    var module = Module.init(allocator, parsed.file_id);
    errdefer module.deinit(allocator);

    var iter = parsed.iterator();
    while (iter.next()) |item| {
        try module.items.append(try lowerItem(allocator, item.*));
    }

    return module;
}

fn lowerItem(allocator: Allocator, item: ast.Item) !Item {
    var lowered_syntax = try item.syntax.clone(allocator);
    errdefer lowered_syntax.deinit(allocator);
    var lowered_body_syntax = try item.body_syntax.clone(allocator);
    errdefer lowered_body_syntax.deinit(allocator);
    const lowered_block_syntax = if (item.block_syntax) |block| try block.clone(allocator) else null;
    errdefer if (lowered_block_syntax) |block| {
        var owned_block = block;
        owned_block.deinit(allocator);
    };

    const name = try allocator.dupe(u8, item.name);
    errdefer allocator.free(name);
    const attributes = try allocator.dupe(Attribute, item.attributes);
    errdefer allocator.free(attributes);
    const target_path = if (item.target_path) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (target_path) |value| allocator.free(value);

    return .{
        .kind = item.kind,
        .name = name,
        .visibility = item.visibility,
        .attributes = attributes,
        .target_path = target_path,
        .span = item.span,
        .has_body = item.has_body,
        .foreign_abi = item.foreign_abi,
        .syntax = lowered_syntax,
        .body_syntax = lowered_body_syntax,
        .block_syntax = lowered_block_syntax,
    };
}

test "lower module preserves structured item syntax" {
    var parsed = ast.Module.init(std.testing.allocator, 0);
    defer parsed.deinit(std.testing.allocator);

    const span = source.Span{ .file_id = 0, .start = 0, .end = 4 };
    const span_text = ast.SpanText{ .text = "main", .span = span };
    const parameters = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
        .{ .name = span_text },
    });
    const where_clauses = try std.testing.allocator.dupe(ast.SpanText, &.{
        .{ .text = "where T: Send", .span = .{ .file_id = 0, .start = 5, .end = 18 } },
    });

    var parsed_items = try std.testing.allocator.alloc(ast.Item, 1);
    parsed_items[0] = .{
        .kind = .function,
        .name = try std.testing.allocator.dupe(u8, "main"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = span,
        .has_body = true,
        .syntax = .{
            .function = .{
                .name = span_text,
                .parameters = parameters,
                .where_clauses = where_clauses,
            },
        },
    };
    try parsed.appendOwnedBlock(std.testing.allocator, parsed_items);

    var lowered = try lowerModule(std.testing.allocator, parsed);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lowered.items.items.len);
    try std.testing.expect(parsed.itemAt(0).name.ptr != lowered.items.items[0].name.ptr);
    const parsed_signature = parsed.itemAt(0).syntax.function;
    switch (lowered.items.items[0].syntax) {
        .function => |signature| {
            try std.testing.expectEqual(@as(usize, 1), signature.parameters.len);
            try std.testing.expectEqual(@as(usize, 1), signature.where_clauses.len);
            try std.testing.expectEqualStrings("main", signature.name.?.text);
            try std.testing.expect(signature.parameters.ptr != parsed_signature.parameters.ptr);
        },
        else => return error.UnexpectedStructure,
    }
}

test "lower module preserves structured nested block syntax" {
    var parsed = ast.Module.init(std.testing.allocator, 0);
    defer parsed.deinit(std.testing.allocator);

    const span = source.Span{ .file_id = 0, .start = 0, .end = 6 };
    const nested_line = ast.LineSyntax{
        .text = .{ .text = "return", .span = span },
        .block = null,
    };
    const nested_block = ast.BlockSyntax{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{nested_line}),
    };
    const outer_line = ast.LineSyntax{
        .text = .{ .text = "select:", .span = span },
        .block = nested_block,
    };

    var parsed_items = try std.testing.allocator.alloc(ast.Item, 1);
    parsed_items[0] = .{
        .kind = .function,
        .name = try std.testing.allocator.dupe(u8, "main"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = span,
        .has_body = true,
        .block_syntax = .{
            .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{outer_line}),
        },
    };
    try parsed.appendOwnedBlock(std.testing.allocator, parsed_items);

    var lowered = try lowerModule(std.testing.allocator, parsed);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lowered.items.items.len);
    const block = lowered.items.items[0].block_syntax orelse return error.UnexpectedStructure;
    try std.testing.expectEqual(@as(usize, 1), block.lines.len);
    try std.testing.expectEqualStrings("select:", block.lines[0].text.text);
    try std.testing.expect(block.lines.ptr != parsed.itemAt(0).block_syntax.?.lines.ptr);
    try std.testing.expect(block.lines[0].block != null);
    try std.testing.expectEqualStrings("return", block.lines[0].block.?.lines[0].text.text);
}
