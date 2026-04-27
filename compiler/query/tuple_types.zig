const std = @import("std");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub fn splitTypeParts(allocator: Allocator, raw: []const u8) !?[][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '(') return null;
    const close_index = findMatchingDelimiter(trimmed, 0, '(', ')') orelse return null;
    if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t\r\n").len != 0) return null;
    return try splitTopLevelCommaParts(allocator, trimmed[1..close_index]);
}

pub fn isTupleTypeName(allocator: Allocator, raw: []const u8) !bool {
    const parts = (try splitTypeParts(allocator, raw)) orelse return false;
    defer allocator.free(parts);
    return validTupleParts(parts);
}

pub fn validTupleParts(parts: []const []const u8) bool {
    if (parts.len < 2) return false;
    for (parts) |part| {
        if (std.mem.trim(u8, part, " \t\r\n").len == 0) return false;
    }
    return true;
}

pub fn shallowTypeRefFromName(raw: []const u8) types.TypeRef {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const builtin = types.Builtin.fromName(trimmed);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = trimmed };
}

pub fn makeTypeNameFromRefs(allocator: Allocator, element_types: []const types.TypeRef) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('(');
    for (element_types, 0..) |element_type, index| {
        if (index != 0) try out.appendSlice(", ");
        try out.appendSlice(element_type.displayName());
    }
    try out.append(')');
    return out.toOwnedSlice();
}

pub fn typeNamesStructurallyEqual(allocator: Allocator, left: []const u8, right: []const u8) !bool {
    const left_parts = (try splitTypeParts(allocator, left)) orelse return false;
    defer allocator.free(left_parts);
    const right_parts = (try splitTypeParts(allocator, right)) orelse return false;
    defer allocator.free(right_parts);
    if (!validTupleParts(left_parts) or !validTupleParts(right_parts)) return false;
    if (left_parts.len != right_parts.len) return false;
    for (left_parts, right_parts) |left_part, right_part| {
        const left_trimmed = std.mem.trim(u8, left_part, " \t\r\n");
        const right_trimmed = std.mem.trim(u8, right_part, " \t\r\n");
        if (try typeNamesStructurallyEqual(allocator, left_trimmed, right_trimmed)) continue;
        if (!std.mem.eql(u8, left_trimmed, right_trimmed)) return false;
    }
    return true;
}

pub fn projectionIndex(raw: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(usize, trimmed, 10) catch null;
}

pub fn projectionElementType(allocator: Allocator, raw_tuple_name: []const u8, index: usize) !?types.TypeRef {
    const parts = (try splitTypeParts(allocator, raw_tuple_name)) orelse return null;
    defer allocator.free(parts);
    if (!validTupleParts(parts) or index >= parts.len) return null;
    return shallowTypeRefFromName(parts[index]);
}
