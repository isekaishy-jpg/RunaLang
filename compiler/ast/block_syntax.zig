const std = @import("std");
const body_syntax = @import("body_syntax.zig");
const item_syntax = @import("item_syntax.zig");
const Allocator = std.mem.Allocator;

pub const SpanText = item_syntax.SpanText;
pub const Statement = body_syntax.Statement;
pub const StructuredBlock = body_syntax.Block;

pub const Line = struct {
    text: SpanText,
    block: ?Block = null,

    pub fn clone(self: Line, allocator: Allocator) anyerror!Line {
        return .{
            .text = self.text,
            .block = if (self.block) |block| try block.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *Line, allocator: Allocator) void {
        if (self.block) |*block| block.deinit(allocator);
        self.* = .{
            .text = self.text,
            .block = null,
        };
    }
};

pub const Block = struct {
    lines: []Line = &.{},
    structured: StructuredBlock = .{},

    pub fn clone(self: Block, allocator: Allocator) anyerror!Block {
        var lines = std.array_list.Managed(Line).init(allocator);
        defer lines.deinit();

        for (self.lines) |line| {
            try lines.append(try line.clone(allocator));
        }

        return .{
            .lines = try lines.toOwnedSlice(),
            .structured = try self.structured.clone(allocator),
        };
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        for (self.lines) |*line| line.deinit(allocator);
        allocator.free(self.lines);
        self.structured.deinit(allocator);
        self.* = .{};
    }
};
