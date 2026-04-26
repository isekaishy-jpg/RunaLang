const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn findMatchingDelimiter(raw: []const u8, open_index: usize, open_char: u8, close_char: u8) ?usize {
    if (open_index >= raw.len or raw[open_index] != open_char) return null;

    var depth: usize = 0;
    var index = open_index;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte == open_char) {
            depth += 1;
        } else if (byte == close_char) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

pub fn findTopLevelHeaderScalar(raw: []const u8, needle: u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (raw, 0..) |byte, index| {
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            else => {},
        }
        if (paren_depth == 0 and bracket_depth == 0 and byte == needle) return index;
    }
    return null;
}

pub fn splitTopLevelCommaParts(allocator: Allocator, raw: []const u8) ![][]const u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    errdefer parts.deinit();

    var start: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (raw, 0..) |byte, index| {
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) {
                try parts.append(std.mem.trim(u8, raw[start..index], " \t"));
                start = index + 1;
            },
            else => {},
        }
    }

    try parts.append(std.mem.trim(u8, raw[start..], " \t"));
    return parts.toOwnedSlice();
}

pub fn splitTopLevelCommaSlices(allocator: Allocator, raw: []const u8) ![][]const u8 {
    if (raw.len == 0) return allocator.alloc([]const u8, 0);

    var parts = std.array_list.Managed([]const u8).init(allocator);
    defer parts.deinit();

    var start: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const ch = raw[index];
        if (in_string) {
            if (ch == '\\' and index + 1 < raw.len) {
                index += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) {
                try parts.append(raw[start..index]);
                start = index + 1;
            },
            else => {},
        }
    }
    try parts.append(raw[start..]);
    return parts.toOwnedSlice();
}

pub fn findTopLevelScalar(raw: []const u8, needle: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const ch = raw[index];
        if (in_string) {
            if (ch == '\\' and index + 1 < raw.len) {
                index += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (depth == 0 and ch == needle) return index;
    }
    return null;
}

pub fn isPlainIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

pub fn baseTypeName(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        return std.mem.trim(u8, trimmed[0..open_index], " \t");
    }
    return trimmed;
}

pub fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}

pub fn leadingSpaceCount(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

pub fn consumeQuoted(contents: []const u8, start: usize, quote: u8) usize {
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

pub fn isIdentifierStart(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or byte == '_';
}

pub fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or (byte >= '0' and byte <= '9') or byte == '\'';
}
