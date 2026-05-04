const std = @import("std");
const ast = @import("../ast/root.zig");
const type_syntax_lower = @import("type_syntax_lower.zig");

const Allocator = std.mem.Allocator;

pub fn lowerStandalone(allocator: Allocator, raw: []const u8) !?ast.TypeSyntax {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try type_syntax_lower.lowerStandaloneTypeSyntax(allocator, .{
        .text = trimmed,
        .span = .{ .file_id = 0, .start = 0, .end = trimmed.len },
    });
}

pub fn lowerFromSource(allocator: Allocator, value: ast.SpanText) !?ast.TypeSyntax {
    const trimmed = std.mem.trim(u8, value.text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var leading_trim: usize = 0;
    while (leading_trim < value.text.len and std.mem.indexOfScalar(u8, " \t\r\n", value.text[leading_trim]) != null) : (leading_trim += 1) {}
    return try type_syntax_lower.lowerStandaloneTypeSyntax(allocator, .{
        .text = trimmed,
        .span = .{
            .file_id = value.span.file_id,
            .start = value.span.start + leading_trim,
            .end = value.span.start + leading_trim + trimmed.len,
        },
    });
}
