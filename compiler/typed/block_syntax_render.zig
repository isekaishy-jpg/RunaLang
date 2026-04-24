const std = @import("std");
const ast = @import("../ast/root.zig");
const Allocator = std.mem.Allocator;

pub fn renderBlockSyntax(
    allocator: Allocator,
    block: ast.BlockSyntax,
) ![]u8 {
    var rendered = std.array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();

    try appendBlock(&rendered, block, 4);
    return rendered.toOwnedSlice();
}

fn appendBlock(
    rendered: *std.array_list.Managed(u8),
    block: ast.BlockSyntax,
    indent: usize,
) !void {
    for (block.lines) |line| {
        try rendered.appendNTimes(' ', indent);
        try rendered.appendSlice(line.text.text);
        try rendered.append('\n');
        if (line.block) |nested| {
            try appendBlock(rendered, nested, indent + 4);
        }
    }
}

test "render block syntax emits nested indentation" {
    const nested = ast.BlockSyntax{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
            .{ .text = .{ .text = "return 2", .span = .{ .file_id = 0, .start = 20, .end = 28 } } },
        }),
    };
    var block = ast.BlockSyntax{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
            .{
                .text = .{ .text = "select:", .span = .{ .file_id = 0, .start = 0, .end = 7 } },
                .block = nested,
            },
            .{
                .text = .{ .text = "return 3", .span = .{ .file_id = 0, .start = 30, .end = 38 } },
            },
        }),
    };
    defer block.deinit(std.testing.allocator);

    const rendered = try renderBlockSyntax(std.testing.allocator, block);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\    select:
        \\        return 2
        \\    return 3
        \\
    , rendered);
}
