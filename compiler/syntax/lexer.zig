const std = @import("std");
const array_list = std.array_list;
const source = @import("../source/root.zig");
const store = @import("store.zig");
const token_mod = @import("token.zig");
const trivia_mod = @import("trivia.zig");
const Allocator = std.mem.Allocator;

pub fn lexFile(allocator: Allocator, file: *const source.File) !store.LexedFile {
    return lexFileWithBaseIndent(allocator, file, 0);
}

pub fn lexFileWithBaseIndent(
    allocator: Allocator,
    file: *const source.File,
    base_indent: usize,
) !store.LexedFile {
    return lexFileRangeWithBaseIndent(allocator, file, 0, file.contents.len, base_indent);
}

pub fn lexFileRangeWithBaseIndent(
    allocator: Allocator,
    file: *const source.File,
    start_offset: usize,
    end_offset: usize,
    base_indent: usize,
) !store.LexedFile {
    std.debug.assert(start_offset <= end_offset);
    std.debug.assert(end_offset <= file.contents.len);
    return lexContents(allocator, .{
        .file_id = file.id,
        .contents = file.contents[start_offset..end_offset],
        .base_offset = start_offset,
    }, base_indent);
}

const LexSource = struct {
    file_id: source.FileId,
    contents: []const u8,
    base_offset: usize,
};

fn lexContents(
    allocator: Allocator,
    view: LexSource,
    base_indent: usize,
) !store.LexedFile {
    var tokens = array_list.Managed(token_mod.Token).init(allocator);
    errdefer tokens.deinit();

    var trivia = array_list.Managed(trivia_mod.Trivia).init(allocator);
    errdefer trivia.deinit();

    var indent_stack = array_list.Managed(usize).init(allocator);
    defer indent_stack.deinit();
    try indent_stack.append(base_indent);

    var index: usize = 0;
    var at_line_start = true;
    var pending_leading_start: u32 = 0;
    var pending_leading_len: u32 = 0;

    while (index < view.contents.len) {
        if (at_line_start) {
            const indent_start = index;
            while (index < view.contents.len and isIndentByte(view.contents[index])) : (index += 1) {}
            const indent_slice = view.contents[indent_start..index];

            if (index >= view.contents.len) {
                if (indent_slice.len != 0) try appendTrivia(&trivia, view, indent_start, index, .whitespace, &pending_leading_len);
                break;
            }

            if (startsLineComment(view.contents, index)) {
                if (indent_slice.len != 0) try appendTrivia(&trivia, view, indent_start, index, .whitespace, &pending_leading_len);
                const comment_end = consumeLineComment(view.contents, index);
                try appendTrivia(&trivia, view, index, comment_end, .comment, &pending_leading_len);
                index = comment_end;
                if (index < view.contents.len and view.contents[index] == '\n') {
                    try appendToken(&tokens, view, .newline, index, index + 1, view.contents[index .. index + 1], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 1;
                }
                at_line_start = true;
                continue;
            }

            if (view.contents[index] == '\n') {
                if (indent_slice.len != 0) try appendTrivia(&trivia, view, indent_start, index, .whitespace, &pending_leading_len);
                try appendToken(&tokens, view, .newline, index, index + 1, view.contents[index .. index + 1], pending_leading_start, pending_leading_len);
                pending_leading_start = @intCast(trivia.items.len);
                pending_leading_len = 0;
                index += 1;
                at_line_start = true;
                continue;
            }

            const indent = index - indent_start;
            const previous_indent = indent_stack.items[indent_stack.items.len - 1];
            var consumed_indent = false;

            if (indent > previous_indent) {
                try indent_stack.append(indent);
                try appendToken(&tokens, view, .indent, indent_start, index, indent_slice, pending_leading_start, pending_leading_len);
                pending_leading_start = @intCast(trivia.items.len);
                pending_leading_len = 0;
                consumed_indent = true;
            } else if (indent < previous_indent) {
                while (indent_stack.items.len > 1 and indent_stack.items[indent_stack.items.len - 1] > indent) {
                    _ = indent_stack.pop();
                    try appendToken(&tokens, view, .dedent, index, index, "", pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                }
                if (indent > indent_stack.items[indent_stack.items.len - 1]) {
                    try indent_stack.append(indent);
                    try appendToken(&tokens, view, .indent, indent_start, index, indent_slice, pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    consumed_indent = true;
                }
            }

            if (!consumed_indent and indent_slice.len != 0) {
                try appendTrivia(&trivia, view, indent_start, index, .whitespace, &pending_leading_len);
            }

            at_line_start = false;
            continue;
        }

        const byte = view.contents[index];
        switch (byte) {
            ' ', '\t' => {
                const start = index;
                while (index < view.contents.len and isIndentByte(view.contents[index])) : (index += 1) {}
                try appendTrivia(&trivia, view, start, index, .whitespace, &pending_leading_len);
                continue;
            },
            '\r' => {
                try appendTrivia(&trivia, view, index, index + 1, .whitespace, &pending_leading_len);
                index += 1;
                continue;
            },
            '\n' => {
                try appendToken(&tokens, view, .newline, index, index + 1, view.contents[index .. index + 1], pending_leading_start, pending_leading_len);
                pending_leading_start = @intCast(trivia.items.len);
                pending_leading_len = 0;
                index += 1;
                at_line_start = true;
                continue;
            },
            '(' => try appendSimple(&tokens, view, &index, .l_paren, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            ')' => try appendSimple(&tokens, view, &index, .r_paren, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '[' => try appendSimple(&tokens, view, &index, .l_bracket, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            ']' => try appendSimple(&tokens, view, &index, .r_bracket, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '{' => try appendSimple(&tokens, view, &index, .l_brace, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '}' => try appendSimple(&tokens, view, &index, .r_brace, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            ':' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == ':') {
                    try appendToken(&tokens, view, .double_colon, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .colon, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            ',' => try appendSimple(&tokens, view, &index, .comma, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            ';' => try appendSimple(&tokens, view, &index, .semicolon, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '#' => try appendSimple(&tokens, view, &index, .hash, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '!' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '=') {
                    try appendToken(&tokens, view, .bang_eq, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .bang, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '+' => try appendSimple(&tokens, view, &index, .plus, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '=' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '=') {
                    try appendToken(&tokens, view, .eq_eq, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else if (index + 1 < view.contents.len and view.contents[index + 1] == '>') {
                    try appendToken(&tokens, view, .fat_arrow, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .equal, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '-' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '>') {
                    try appendToken(&tokens, view, .arrow, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .minus, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '*' => try appendSimple(&tokens, view, &index, .star, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '.' => {
                if (index + 2 < view.contents.len and view.contents[index + 1] == '.' and view.contents[index + 2] == '=') {
                    try appendToken(&tokens, view, .range_inclusive, index, index + 3, view.contents[index .. index + 3], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 3;
                } else if (index + 1 < view.contents.len and view.contents[index + 1] == '.') {
                    try appendToken(&tokens, view, .range, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .dot, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '"' => {
                const end = consumeQuoted(view.contents, index, '"');
                try appendToken(&tokens, view, .string_literal, index, end, view.contents[index..end], pending_leading_start, pending_leading_len);
                pending_leading_start = @intCast(trivia.items.len);
                pending_leading_len = 0;
                index = end;
            },
            '\'' => {
                if (looksLikeCharLiteral(view.contents, index)) {
                    const end = consumeQuoted(view.contents, index, '\'');
                    try appendToken(&tokens, view, .char_literal, index, end, view.contents[index..end], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index = end;
                } else if (index + 1 < view.contents.len and isIdentifierStart(view.contents[index + 1])) {
                    const start = index;
                    index += 2;
                    while (index < view.contents.len and isIdentifierContinue(view.contents[index])) : (index += 1) {}
                    try appendToken(&tokens, view, .lifetime_name, start, index, view.contents[start..index], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                } else {
                    const end = consumeQuoted(view.contents, index, '\'');
                    try appendToken(&tokens, view, .char_literal, index, end, view.contents[index..end], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index = end;
                }
            },
            '0'...'9' => {
                const start = index;
                index += 1;
                while (index < view.contents.len and isNumberContinue(view.contents[index])) : (index += 1) {}
                try appendToken(&tokens, view, .integer_literal, start, index, view.contents[start..index], pending_leading_start, pending_leading_len);
                pending_leading_start = @intCast(trivia.items.len);
                pending_leading_len = 0;
            },
            '/' => {
                if (startsLineComment(view.contents, index)) {
                    const end = consumeLineComment(view.contents, index);
                    try appendTrivia(&trivia, view, index, end, .comment, &pending_leading_len);
                    index = end;
                } else {
                    try appendSimple(&tokens, view, &index, .slash, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '%' => try appendSimple(&tokens, view, &index, .percent, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '~' => try appendSimple(&tokens, view, &index, .tilde, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '&' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '&') {
                    try appendToken(&tokens, view, .amp_amp, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .amp, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '|' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '|') {
                    try appendToken(&tokens, view, .pipe_pipe, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .pipe, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '^' => try appendSimple(&tokens, view, &index, .caret, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len)),
            '<' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '=') {
                    try appendToken(&tokens, view, .lte, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else if (index + 1 < view.contents.len and view.contents[index + 1] == '<') {
                    try appendToken(&tokens, view, .lt_lt, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .lt, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            '>' => {
                if (index + 1 < view.contents.len and view.contents[index + 1] == '=') {
                    try appendToken(&tokens, view, .gte, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else if (index + 1 < view.contents.len and view.contents[index + 1] == '>') {
                    try appendToken(&tokens, view, .gt_gt, index, index + 2, view.contents[index .. index + 2], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 2;
                } else {
                    try appendSimple(&tokens, view, &index, .gt, pending_leading_start, &pending_leading_len, @intCast(trivia.items.len));
                }
            },
            else => {
                if (isIdentifierStart(byte)) {
                    const start = index;
                    index += 1;
                    while (index < view.contents.len and isIdentifierContinue(view.contents[index])) : (index += 1) {}
                    const lexeme = view.contents[start..index];
                    try appendToken(&tokens, view, keywordKind(lexeme), start, index, lexeme, pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                } else {
                    try appendToken(&tokens, view, .unknown, index, index + 1, view.contents[index .. index + 1], pending_leading_start, pending_leading_len);
                    pending_leading_start = @intCast(trivia.items.len);
                    pending_leading_len = 0;
                    index += 1;
                }
            },
        }
    }

    while (indent_stack.items.len > 1) {
        _ = indent_stack.pop();
        try appendToken(&tokens, view, .dedent, view.contents.len, view.contents.len, "", pending_leading_start, pending_leading_len);
        pending_leading_start = @intCast(trivia.items.len);
        pending_leading_len = 0;
    }

    try appendToken(&tokens, view, .eof, view.contents.len, view.contents.len, "", pending_leading_start, pending_leading_len);

    return try store.LexedFile.fromOwnedSlices(
        allocator,
        try tokens.toOwnedSlice(),
        try trivia.toOwnedSlice(),
    );
}

fn appendSimple(
    tokens: *array_list.Managed(token_mod.Token),
    view: LexSource,
    index: *usize,
    kind: token_mod.TokenKind,
    pending_leading_start: u32,
    pending_leading_len: *u32,
    next_trivia_start: u32,
) !void {
    try appendToken(tokens, view, kind, index.*, index.* + 1, view.contents[index.* .. index.* + 1], pending_leading_start, pending_leading_len.*);
    pending_leading_len.* = 0;
    index.* += 1;
    _ = next_trivia_start;
}

fn appendToken(
    tokens: *array_list.Managed(token_mod.Token),
    view: LexSource,
    kind: token_mod.TokenKind,
    start: usize,
    end: usize,
    lexeme: []const u8,
    leading_trivia_start: u32,
    leading_trivia_len: u32,
) !void {
    try tokens.append(.{
        .kind = kind,
        .span = .{
            .file_id = view.file_id,
            .start = view.base_offset + start,
            .end = view.base_offset + end,
        },
        .lexeme = lexeme,
        .leading_trivia = .{
            .start = leading_trivia_start,
            .len = leading_trivia_len,
        },
        .trailing_trivia = .{},
    });
}

fn appendTrivia(
    trivia: *array_list.Managed(trivia_mod.Trivia),
    view: LexSource,
    start: usize,
    end: usize,
    kind: trivia_mod.TriviaKind,
    pending_leading_len: *u32,
) !void {
    if (start == end) return;
    try trivia.append(.{
        .kind = kind,
        .span = .{
            .file_id = view.file_id,
            .start = view.base_offset + start,
            .end = view.base_offset + end,
        },
        .lexeme = view.contents[start..end],
    });
    pending_leading_len.* += 1;
}

fn keywordKind(lexeme: []const u8) token_mod.TokenKind {
    if (std.mem.eql(u8, lexeme, "pub")) return .keyword_pub;
    if (std.mem.eql(u8, lexeme, "package")) return .keyword_package;
    if (std.mem.eql(u8, lexeme, "mod")) return .keyword_mod;
    if (std.mem.eql(u8, lexeme, "use")) return .keyword_use;
    if (std.mem.eql(u8, lexeme, "where")) return .keyword_where;
    if (std.mem.eql(u8, lexeme, "fn")) return .keyword_fn;
    if (std.mem.eql(u8, lexeme, "suspend")) return .keyword_suspend;
    if (std.mem.eql(u8, lexeme, "const")) return .keyword_const;
    if (std.mem.eql(u8, lexeme, "struct")) return .keyword_struct;
    if (std.mem.eql(u8, lexeme, "enum")) return .keyword_enum;
    if (std.mem.eql(u8, lexeme, "trait")) return .keyword_trait;
    if (std.mem.eql(u8, lexeme, "impl")) return .keyword_impl;
    if (std.mem.eql(u8, lexeme, "union")) return .keyword_union;
    if (std.mem.eql(u8, lexeme, "extern")) return .keyword_extern;
    if (std.mem.eql(u8, lexeme, "opaque")) return .keyword_opaque;
    if (std.mem.eql(u8, lexeme, "type")) return .keyword_type;
    if (std.mem.eql(u8, lexeme, "for")) return .keyword_for;
    if (std.mem.eql(u8, lexeme, "while")) return .keyword_while;
    if (std.mem.eql(u8, lexeme, "in")) return .keyword_in;
    if (std.mem.eql(u8, lexeme, "when")) return .keyword_when;
    if (std.mem.eql(u8, lexeme, "repeat")) return .keyword_repeat;
    if (std.mem.eql(u8, lexeme, "select")) return .keyword_select;
    if (std.mem.eql(u8, lexeme, "else")) return .keyword_else;
    if (std.mem.eql(u8, lexeme, "defer")) return .keyword_defer;
    if (std.mem.eql(u8, lexeme, "break")) return .keyword_break;
    if (std.mem.eql(u8, lexeme, "continue")) return .keyword_continue;
    if (std.mem.eql(u8, lexeme, "return")) return .keyword_return;
    return .identifier;
}

fn isIndentByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isIdentifierStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or (byte >= '0' and byte <= '9') or byte == '\'';
}

fn isNumberContinue(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or byte == '_' or byte == 'x' or byte == 'b' or byte == 'o' or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F');
}

fn consumeQuoted(contents: []const u8, start: usize, quote: u8) usize {
    var index = start + 1;
    while (index < contents.len) : (index += 1) {
        if (contents[index] == '\\') {
            if (index + 1 < contents.len) index += 1;
            continue;
        }
        if (contents[index] == quote) return index + 1;
    }
    return contents.len;
}

fn startsLineComment(contents: []const u8, start: usize) bool {
    return start + 1 < contents.len and contents[start] == '/' and contents[start + 1] == '/';
}

fn consumeLineComment(contents: []const u8, start: usize) usize {
    var index = start;
    while (index < contents.len and contents[index] != '\n') : (index += 1) {}
    return index;
}

fn looksLikeCharLiteral(contents: []const u8, start: usize) bool {
    if (start + 2 >= contents.len) return false;
    if (contents[start] != '\'') return false;
    if (contents[start + 1] == '\\') {
        return start + 3 < contents.len and contents[start + 3] == '\'';
    }
    return contents[start + 2] == '\'';
}

test "lexer emits indent and dedent tokens" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "indent.rna",
        "fn main() -> Unit:\n    repeat\nvalue\n",
    );
    const file = table.get(file_id);

    var lexed = try lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    var saw_indent = false;
    var saw_dedent = false;
    var tokens = lexed.tokens.iterateRange(0, lexed.tokens.len());
    while (tokens.next()) |token_ref| {
        const token = lexed.tokens.getRef(token_ref);
        if (token.kind == .indent) saw_indent = true;
        if (token.kind == .dedent) saw_dedent = true;
    }

    try std.testing.expect(saw_indent);
    try std.testing.expect(saw_dedent);
}

test "lexer honors base indentation for nested fragments" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "nested-fragment.rna",
        "        return value\n    next\n",
    );
    const file = table.get(file_id);

    var lexed = try lexFileWithBaseIndent(std.testing.allocator, file, 4);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(token_mod.TokenKind.indent, lexed.tokens.get(0).kind);
    try std.testing.expectEqual(token_mod.TokenKind.keyword_return, lexed.tokens.get(1).kind);
    try std.testing.expectEqual(token_mod.TokenKind.newline, lexed.tokens.get(3).kind);
    try std.testing.expectEqual(token_mod.TokenKind.dedent, lexed.tokens.get(4).kind);
}

test "lexer preserves absolute spans for ranged lexing" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile(
        "ranged-fragment.rna",
        "fn first() -> I32:\n    return 1\nfn second() -> I32:\n    return 22\n",
    );
    const file = table.get(file_id);
    const start = std.mem.indexOf(u8, file.contents, "fn second").?;

    var lexed = try lexFileRangeWithBaseIndent(std.testing.allocator, file, start, file.contents.len, 0);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("fn", lexed.tokens.get(0).lexeme);
    try std.testing.expectEqual(start, lexed.tokens.get(0).span.start);
    try std.testing.expectEqualStrings("second", lexed.tokens.get(1).lexeme);
    try std.testing.expectEqual(start + "fn ".len, lexed.tokens.get(1).span.start);
    try std.testing.expectEqualStrings("22", lexed.tokens.get(11).lexeme);
}

test "lexer preserves whitespace trivia between tokens" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("trivia.rna", "fn main");
    const file = table.get(file_id);

    var lexed = try lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lexed.trivia.len());
    try std.testing.expectEqual(trivia_mod.TriviaKind.whitespace, lexed.trivia.get(0).kind);
    try std.testing.expectEqual(@as(u32, 1), lexed.tokens.get(1).leading_trivia.len);
}

test "lexer preserves line comments as trivia" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("comment.rna", "fn main // comment\n");
    const file = table.get(file_id);

    var lexed = try lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), lexed.trivia.len());
    try std.testing.expectEqual(trivia_mod.TriviaKind.whitespace, lexed.trivia.get(0).kind);
    try std.testing.expectEqual(trivia_mod.TriviaKind.comment, lexed.trivia.get(1).kind);
}

test "lexer recognizes expression operators" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("ops.rna", "value == other && !done << 1");
    const file = table.get(file_id);

    var lexed = try lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(token_mod.TokenKind.identifier, lexed.tokens.get(0).kind);
    try std.testing.expectEqual(token_mod.TokenKind.eq_eq, lexed.tokens.get(1).kind);
    try std.testing.expectEqual(token_mod.TokenKind.identifier, lexed.tokens.get(2).kind);
    try std.testing.expectEqual(token_mod.TokenKind.amp_amp, lexed.tokens.get(3).kind);
    try std.testing.expectEqual(token_mod.TokenKind.bang, lexed.tokens.get(4).kind);
    try std.testing.expectEqual(token_mod.TokenKind.identifier, lexed.tokens.get(5).kind);
    try std.testing.expectEqual(token_mod.TokenKind.lt_lt, lexed.tokens.get(6).kind);
    try std.testing.expectEqual(token_mod.TokenKind.integer_literal, lexed.tokens.get(7).kind);
}

test "lexer distinguishes lifetime names from char literals" {
    var table = source.Table.init(std.testing.allocator);
    defer table.deinit();

    const file_id = try table.addVirtualFile("lifetimes.rna", "hold['a] read T 'x'");
    const file = table.get(file_id);

    var lexed = try lexFile(std.testing.allocator, file);
    defer lexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(token_mod.TokenKind.identifier, lexed.tokens.get(0).kind);
    try std.testing.expectEqual(token_mod.TokenKind.l_bracket, lexed.tokens.get(1).kind);
    try std.testing.expectEqual(token_mod.TokenKind.lifetime_name, lexed.tokens.get(2).kind);
    try std.testing.expectEqual(token_mod.TokenKind.r_bracket, lexed.tokens.get(3).kind);
    try std.testing.expectEqual(token_mod.TokenKind.char_literal, lexed.tokens.get(6).kind);
}
