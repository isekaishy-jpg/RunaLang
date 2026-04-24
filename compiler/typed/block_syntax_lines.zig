const std = @import("std");
const ast = @import("../ast/root.zig");
const declaration_parse = @import("declaration_parse.zig");
const Allocator = std.mem.Allocator;

pub const BodyLine = declaration_parse.BodyLine;

pub fn collectBlockLines(allocator: Allocator, block: ast.BlockSyntax) ![]BodyLine {
    var lines = std.array_list.Managed(BodyLine).init(allocator);
    defer lines.deinit();

    try appendBlockLines(&lines, block, 4);
    return lines.toOwnedSlice();
}

fn appendBlockLines(
    lines: *std.array_list.Managed(BodyLine),
    block: ast.BlockSyntax,
    indent: usize,
) !void {
    for (block.lines) |line| {
        try lines.append(.{
            .raw = line.text.text,
            .trimmed = std.mem.trim(u8, line.text.text, " \t"),
            .indent = indent,
        });
        if (line.block) |nested| {
            try appendBlockLines(lines, nested, indent + 4);
        }
    }
}

test "collect block lines preserves nested indentation" {
    const nested = ast.BlockSyntax{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
            .{
                .text = .{ .text = "return 2", .span = .{ .file_id = 0, .start = 10, .end = 18 } },
            },
        }),
    };
    var block = ast.BlockSyntax{
        .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
            .{
                .text = .{ .text = "select:", .span = .{ .file_id = 0, .start = 0, .end = 7 } },
                .block = nested,
            },
            .{
                .text = .{ .text = "return 3", .span = .{ .file_id = 0, .start = 20, .end = 28 } },
            },
        }),
    };
    defer block.deinit(std.testing.allocator);

    const lines = try collectBlockLines(std.testing.allocator, block);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("select:", lines[0].trimmed);
    try std.testing.expectEqual(@as(usize, 4), lines[0].indent);
    try std.testing.expectEqualStrings("return 2", lines[1].trimmed);
    try std.testing.expectEqual(@as(usize, 8), lines[1].indent);
    try std.testing.expectEqualStrings("return 3", lines[2].trimmed);
    try std.testing.expectEqual(@as(usize, 4), lines[2].indent);
}
