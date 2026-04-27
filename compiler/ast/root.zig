const std = @import("std");
const array_list = std.array_list;
const block_syntax = @import("block_syntax.zig");
const body_syntax = @import("body_syntax.zig");
const item_syntax = @import("item_syntax.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Parsed syntax tree with explicit ownership syntax.";

pub const Visibility = item_syntax.Visibility;

pub const Attribute = struct {
    name: []const u8,
    raw: []const u8,
    span: source.Span,
};

pub const SpanText = item_syntax.SpanText;
pub const BlockSyntax = block_syntax.Block;
pub const LineSyntax = block_syntax.Line;
pub const BodyBlockSyntax = body_syntax.Block;
pub const BodyStatementSyntax = body_syntax.Statement;
pub const BodyExprSyntax = body_syntax.Expr;
pub const BodyPatternSyntax = body_syntax.Pattern;
pub const AssignOpSyntax = body_syntax.AssignOp;
pub const ParameterSyntax = item_syntax.Parameter;
pub const FunctionSignatureSyntax = item_syntax.FunctionSignature;
pub const ConstSignatureSyntax = item_syntax.ConstSignature;
pub const TypeAliasSyntax = item_syntax.TypeAlias;
pub const NamedDeclSyntax = item_syntax.NamedDecl;
pub const UseBindingSyntax = item_syntax.UseBinding;
pub const ImplSignatureSyntax = item_syntax.ImplSignature;
pub const ItemSyntax = item_syntax.ItemSyntax;
pub const FieldDeclSyntax = item_syntax.FieldDecl;
pub const EnumVariantSyntax = item_syntax.EnumVariant;
pub const AssociatedTypeDeclSyntax = item_syntax.AssociatedTypeDecl;
pub const MethodDeclSyntax = item_syntax.MethodDecl;
pub const TraitBodySyntax = item_syntax.TraitBody;
pub const ImplBodySyntax = item_syntax.ImplBody;
pub const ItemBodySyntax = item_syntax.ItemBodySyntax;

pub const ItemKind = enum {
    module_decl,
    use_decl,
    function,
    suspend_function,
    foreign_function,
    const_item,
    type_alias,
    struct_type,
    enum_type,
    union_type,
    trait_type,
    impl_block,
    opaque_type,
};

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
        var syntax = self.syntax;
        syntax.deinit(allocator);
        var owned_body_syntax = self.body_syntax;
        owned_body_syntax.deinit(allocator);
        if (self.block_syntax) |block_syntax_item| {
            var owned_block_syntax = block_syntax_item;
            owned_block_syntax.deinit(allocator);
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

pub const ItemBlock = struct {
    ref_count: usize = 1,
    items: []Item,

    pub fn retain(self: *ItemBlock) void {
        self.ref_count += 1;
    }

    pub fn release(self: *ItemBlock, allocator: Allocator) void {
        std.debug.assert(self.ref_count != 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        allocator.destroy(self);
    }
};

pub const ModuleSnapshot = struct {
    file_id: source.FileId,
    blocks: array_list.Managed(*ItemBlock),
    total_items: usize,

    pub fn init(allocator: Allocator, file_id: source.FileId) ModuleSnapshot {
        return .{
            .file_id = file_id,
            .blocks = array_list.Managed(*ItemBlock).init(allocator),
            .total_items = 0,
        };
    }

    pub fn deinit(self: *ModuleSnapshot, allocator: Allocator) void {
        for (self.blocks.items) |block| block.release(allocator);
        self.blocks.deinit();
        self.total_items = 0;
    }

    pub fn appendOwnedBlock(self: *ModuleSnapshot, allocator: Allocator, items: []Item) !void {
        const block = try allocator.create(ItemBlock);
        errdefer allocator.destroy(block);
        block.* = .{
            .items = items,
        };
        try self.blocks.append(block);
        self.total_items += items.len;
    }

    pub fn appendEmptyBlock(self: *ModuleSnapshot, allocator: Allocator) !void {
        return self.appendOwnedBlock(allocator, try allocator.alloc(Item, 0));
    }

    pub fn appendExistingBlock(self: *ModuleSnapshot, block: *ItemBlock) !void {
        block.retain();
        errdefer block.release(self.blocks.allocator);
        try self.blocks.append(block);
        self.total_items += block.items.len;
    }

    pub fn blockCount(self: *const ModuleSnapshot) usize {
        return self.blocks.items.len;
    }

    pub fn blockAt(self: *const ModuleSnapshot, index: usize) *ItemBlock {
        return self.blocks.items[index];
    }

    pub fn itemCount(self: *const ModuleSnapshot) usize {
        return self.total_items;
    }

    pub fn itemAt(self: *const ModuleSnapshot, index: usize) *const Item {
        var remaining = index;
        for (self.blocks.items) |block| {
            if (remaining < block.items.len) return &block.items[remaining];
            remaining -= block.items.len;
        }
        unreachable;
    }

    pub fn itemAtMut(self: *ModuleSnapshot, index: usize) *Item {
        var remaining = index;
        for (self.blocks.items) |block| {
            if (remaining < block.items.len) return &block.items[remaining];
            remaining -= block.items.len;
        }
        unreachable;
    }

    pub fn iterator(self: *const ModuleSnapshot) ItemIterator {
        return .{
            .module = self,
        };
    }
};

pub const Module = ModuleSnapshot;

pub const ItemIterator = struct {
    module: *const Module,
    block_index: usize = 0,
    item_index: usize = 0,

    pub fn next(self: *ItemIterator) ?*const Item {
        while (self.block_index < self.module.blocks.items.len) {
            const block = self.module.blocks.items[self.block_index];
            if (self.item_index < block.items.len) {
                const item = &block.items[self.item_index];
                self.item_index += 1;
                return item;
            }
            self.block_index += 1;
            self.item_index = 0;
        }
        return null;
    }
};
