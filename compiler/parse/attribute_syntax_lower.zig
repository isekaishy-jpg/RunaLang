const std = @import("std");
const ast = @import("../ast/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;
const IndexedRange = struct { start: usize, end: usize };

pub fn lowerAttribute(
    allocator: Allocator,
    file: *const source.File,
    span: source.Span,
) !ast.Attribute {
    const raw = trimTrailingLineEnding(file.contents[span.start..span.end]);
    const name_range = parseAttributeNameRange(raw) orelse return error.InvalidParse;
    const name = raw[name_range.start..name_range.end];
    const cursor = skipHorizontal(raw, name_range.end);
    if (cursor >= raw.len) {
        return .{
            .name = name,
            .span = span,
            .form = .bare,
        };
    }

    if (raw[cursor] != '[') {
        return .{
            .name = name,
            .span = span,
            .form = .{ .invalid = .unexpected_trailing_text },
        };
    }

    const open_index = cursor;
    const close_index = findMatchingBracket(raw, open_index) orelse {
        return .{
            .name = name,
            .span = span,
            .form = .{ .invalid = .unterminated_args },
        };
    };
    if (trimRange(raw[close_index + 1 ..])) |_| {
        return .{
            .name = name,
            .span = span,
            .form = .{ .invalid = .trailing_after_args },
        };
    }
    const inner_start = open_index + 1;
    const inner_end = if (close_index > inner_start) close_index else inner_start;
    const arguments = parseArguments(allocator, raw, span, inner_start, inner_end) catch |err| switch (err) {
        error.EmptyAttributeArgument => return .{
            .name = name,
            .span = span,
            .form = .{ .invalid = .empty_argument },
        },
        else => return err,
    };
    return .{
        .name = name,
        .span = span,
        .form = .{ .args = arguments },
    };
}

fn parseArguments(
    allocator: Allocator,
    raw: []const u8,
    span: source.Span,
    start: usize,
    end: usize,
) ![]ast.AttributeArgument {
    if (end <= start) return allocator.alloc(ast.AttributeArgument, 0);

    var arguments = std.array_list.Managed(ast.AttributeArgument).init(allocator);
    errdefer arguments.deinit();

    var part_start = start;
    var index = start;
    var square_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_string = false;
    while (index < end) : (index += 1) {
        const byte = raw[index];
        if (byte == '"' and !quoteIsEscaped(raw, index)) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        switch (byte) {
            '[' => square_depth += 1,
            ']' => {
                if (square_depth != 0) square_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            ',' => if (square_depth == 0 and paren_depth == 0) {
                const status = try appendArgument(&arguments, raw, span, part_start, index);
                if (status == .empty) return error.EmptyAttributeArgument;
                part_start = index + 1;
            },
            else => {},
        }
    }
    const tail_status = try appendArgument(&arguments, raw, span, part_start, end);
    if (tail_status == .empty and part_start != start) return error.EmptyAttributeArgument;
    return arguments.toOwnedSlice();
}

const AppendStatus = enum {
    appended,
    empty,
};

fn appendArgument(
    arguments: *std.array_list.Managed(ast.AttributeArgument),
    raw: []const u8,
    span: source.Span,
    start: usize,
    end: usize,
) !AppendStatus {
    const trimmed = trimIndexedRange(raw, start, end) orelse return .empty;
    const eq_index = findTopLevelScalar(raw, trimmed.start, trimmed.end, '=') orelse {
        try arguments.append(.{
            .key = null,
            .value = classifyValue(raw[trimmed.start..trimmed.end]),
            .span = .{
                .file_id = span.file_id,
                .start = span.start + trimmed.start,
                .end = span.start + trimmed.end,
            },
        });
        return .appended;
    };

    const key_range = trimIndexedRange(raw, trimmed.start, eq_index) orelse IndexedRange{ .start = eq_index, .end = eq_index };
    const value_range = trimIndexedRange(raw, eq_index + 1, trimmed.end) orelse IndexedRange{ .start = trimmed.end, .end = trimmed.end };
    const key = raw[key_range.start..key_range.end];
    const value_text = raw[value_range.start..value_range.end];
    try arguments.append(.{
        .key = key,
        .value = classifyValue(value_text),
        .span = .{
            .file_id = span.file_id,
            .start = span.start + trimmed.start,
            .end = span.start + trimmed.end,
        },
    });
    return .appended;
}

fn classifyValue(raw: []const u8) ast.AttributeValue {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return .{ .string_literal = raw[1 .. raw.len - 1] };
    }
    if (looksLikeTypeText(raw)) return .{ .type_text = raw };
    return .{ .identifier = raw };
}

fn looksLikeTypeText(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (std.ascii.isUpper(raw[0])) return true;
    for (raw) |byte| {
        switch (byte) {
            '[', ']', '(', ')', '*', '.', ':', ' ' => return true,
            else => {},
        }
    }
    return false;
}

fn parseAttributeNameRange(raw: []const u8) ?IndexedRange {
    var start = skipHorizontal(raw, 0);
    if (start >= raw.len) return null;
    if (raw[start] == '#') start += 1;
    if (start >= raw.len) return null;

    var end = start;
    while (end < raw.len and raw[end] != '[' and raw[end] != ' ' and raw[end] != '\t') : (end += 1) {}
    if (end <= start) return null;
    return .{ .start = start, .end = end };
}

fn findMatchingBracket(raw: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var index = open_index;
    var in_string = false;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte == '"' and !quoteIsEscaped(raw, index)) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        switch (byte) {
            '[' => depth += 1,
            ']' => {
                if (depth == 0) continue;
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

fn findTopLevelScalar(raw: []const u8, start: usize, end: usize, needle: u8) ?usize {
    var square_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_string = false;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = raw[index];
        if (byte == '"' and !quoteIsEscaped(raw, index)) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        switch (byte) {
            '[' => square_depth += 1,
            ']' => {
                if (square_depth != 0) square_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
            },
            else => {},
        }
        if (square_depth == 0 and paren_depth == 0 and byte == needle) return index;
    }
    return null;
}

fn trimIndexedRange(raw: []const u8, start: usize, end: usize) ?IndexedRange {
    if (end <= start) return null;
    var trimmed_start = start;
    while (trimmed_start < end and isTrimByte(raw[trimmed_start])) : (trimmed_start += 1) {}
    var trimmed_end = end;
    while (trimmed_end > trimmed_start and isTrimByte(raw[trimmed_end - 1])) : (trimmed_end -= 1) {}
    if (trimmed_end <= trimmed_start) return null;
    return .{ .start = trimmed_start, .end = trimmed_end };
}

fn quoteIsEscaped(raw: []const u8, index: usize) bool {
    if (index == 0 or raw[index] != '"') return false;

    var backslash_count: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (raw[cursor] != '\\') break;
        backslash_count += 1;
    }
    return backslash_count % 2 == 1;
}

fn trimRange(raw: []const u8) ?IndexedRange {
    return trimIndexedRange(raw, 0, raw.len);
}

fn skipHorizontal(raw: []const u8, start: usize) usize {
    var index = start;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {}
    return index;
}

fn isTrimByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn trimTrailingLineEnding(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end != 0 and (raw[end - 1] == '\r' or raw[end - 1] == '\n')) : (end -= 1) {}
    return raw[0..end];
}

test "lower attribute preserves structured arguments" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#repr[c, CInt]\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#repr[c, CInt]\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("repr", attribute.name);
    try std.testing.expect(!attribute.isBare());
    try std.testing.expectEqual(@as(usize, 2), attribute.arguments().len);
    try std.testing.expectEqualStrings("c", attribute.arguments()[0].value.text());
    try std.testing.expectEqualStrings("CInt", attribute.arguments()[1].value.text());
}

test "lower attribute keeps keyed string arguments" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#export[name = \"runa_add\"]\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#export[name = \"runa_add\"]\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("export", attribute.name);
    try std.testing.expectEqual(@as(usize, 1), attribute.arguments().len);
    try std.testing.expectEqualStrings("name", attribute.arguments()[0].key.?);
    try std.testing.expectEqualStrings("runa_add", attribute.arguments()[0].value.text());
}

test "lower attribute marks unterminated argument lists invalid" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#export[name = \"runa_add\"\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#export[name = \"runa_add\"\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(ast.InvalidKind.unterminated_args, attribute.invalidKind().?);
}

test "lower attribute marks trailing text after args invalid" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#export[name = \"runa_add\"] junk\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#export[name = \"runa_add\"] junk\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(ast.InvalidKind.trailing_after_args, attribute.invalidKind().?);
}

test "lower attribute marks empty arguments invalid" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#repr[c,]\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#repr[c,]\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(ast.InvalidKind.empty_argument, attribute.invalidKind().?);
}

test "lower attribute preserves escaped quotes inside string arguments" {
    var sources = source.Table.init(std.testing.allocator);
    defer sources.deinit();

    const file_id = try sources.addVirtualFile("test.runa", "#export[name = \"runa\\\",add\"]\n");
    const file = sources.get(file_id);
    const attribute = try lowerAttribute(std.testing.allocator, file, .{
        .file_id = file_id,
        .start = 0,
        .end = "#export[name = \"runa\\\",add\"]\n".len,
    });
    defer {
        var owned = attribute;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expect(attribute.invalidKind() == null);
    try std.testing.expectEqual(@as(usize, 1), attribute.arguments().len);
    try std.testing.expectEqualStrings("name", attribute.arguments()[0].key.?);
    try std.testing.expectEqualStrings("runa\\\",add", attribute.arguments()[0].value.text());
}
