const std = @import("std");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub const CallableType = struct {
    is_suspend: bool,
    input_type_name: []const u8,
    output_type_name: []const u8,
};

pub fn makeCallableTypeName(
    allocator: Allocator,
    is_suspend: bool,
    input_type_name: []const u8,
    output_type_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}[{s}, {s}]", .{
        if (is_suspend) "__suspend_callread" else "__callread",
        std.mem.trim(u8, input_type_name, " \t"),
        std.mem.trim(u8, output_type_name, " \t"),
    });
}

pub fn makeCallableInputTypeName(
    allocator: Allocator,
    parameter_type_names: []const []const u8,
) ![]const u8 {
    if (parameter_type_names.len == 0) return allocator.dupe(u8, "Unit");
    if (parameter_type_names.len == 1) return allocator.dupe(u8, std.mem.trim(u8, parameter_type_names[0], " \t"));

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('(');
    for (parameter_type_names, 0..) |type_name, index| {
        if (index != 0) try out.appendSlice(", ");
        try out.appendSlice(std.mem.trim(u8, type_name, " \t"));
    }
    try out.append(')');
    return out.toOwnedSlice();
}

pub fn parseCallableTypeName(raw: []const u8, allocator: Allocator) !?CallableType {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const ordinary_prefix = "__callread[";
    const suspend_prefix = "__suspend_callread[";

    const prefix = if (std.mem.startsWith(u8, trimmed, ordinary_prefix))
        ordinary_prefix
    else if (std.mem.startsWith(u8, trimmed, suspend_prefix))
        suspend_prefix
    else
        return null;

    const close_index = findMatchingDelimiter(trimmed, prefix.len - 1, '[', ']') orelse return null;
    if (close_index + 1 != trimmed.len) return null;

    const inside = trimmed[prefix.len..close_index];
    const parts = try splitTopLevelCommaParts(allocator, inside);
    defer allocator.free(parts);
    if (parts.len != 2) return null;

    return .{
        .is_suspend = std.mem.eql(u8, prefix, suspend_prefix),
        .input_type_name = parts[0],
        .output_type_name = parts[1],
    };
}

pub fn isCallableTypeName(raw: []const u8, allocator: Allocator) !bool {
    return (try parseCallableTypeName(raw, allocator)) != null;
}

pub fn shallowTypeRefFromName(raw: []const u8) types.TypeRef {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const builtin = types.Builtin.fromName(trimmed);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = trimmed };
}
