const std = @import("std");
const ast = @import("ast/root.zig");
const hir = @import("hir/root.zig");
const types = @import("types/root.zig");
const Allocator = std.mem.Allocator;

pub const BoundaryKind = enum {
    api,
    value,
    capability,
};

pub const ReprInfo = struct {
    has_c: bool = false,
    integer_type_name: ?[]const u8 = null,
};

pub const ReprTarget = enum {
    struct_type,
    union_type,
    enum_type,
};

pub fn hasAttribute(attributes: []const ast.Attribute, name: []const u8) bool {
    return findAttribute(attributes, name) != null;
}

pub fn hasBareAttribute(attributes: []const ast.Attribute, name: []const u8) bool {
    const attribute = findUniqueAttribute(attributes, name) orelse return false;
    return attribute.isBare();
}

pub fn findAttribute(attributes: []const ast.Attribute, name: []const u8) ?ast.Attribute {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return attribute;
    }
    return null;
}

pub fn keyedArgument(attribute: ast.Attribute, key: []const u8) ?ast.AttributeArgument {
    for (attribute.arguments()) |argument| {
        const argument_key = argument.key orelse continue;
        if (std.mem.eql(u8, argument_key, key)) return argument;
    }
    return null;
}

pub fn positionalArgument(attribute: ast.Attribute, index: usize) ?ast.AttributeArgument {
    var positional_index: usize = 0;
    for (attribute.arguments()) |argument| {
        if (argument.key != null) continue;
        if (positional_index == index) return argument;
        positional_index += 1;
    }
    return null;
}

pub fn positionalArgumentCount(attribute: ast.Attribute) usize {
    var count: usize = 0;
    for (attribute.arguments()) |argument| {
        if (argument.key == null) count += 1;
    }
    return count;
}

pub fn keyedArgumentCount(attribute: ast.Attribute) usize {
    var count: usize = 0;
    for (attribute.arguments()) |argument| {
        if (argument.key != null) count += 1;
    }
    return count;
}

pub fn boundaryKind(attributes: []const ast.Attribute) ?BoundaryKind {
    const attribute = findUniqueAttribute(attributes, "boundary") orelse return null;
    if (keyedArgumentCount(attribute) != 0) return null;
    if (positionalArgumentCount(attribute) != 1) return null;
    const argument = positionalArgument(attribute, 0) orelse return null;
    const value = switch (argument.value) {
        .identifier => |identifier| identifier,
        else => return null,
    };
    if (std.mem.eql(u8, value, "api")) return .api;
    if (std.mem.eql(u8, value, "value")) return .value;
    if (std.mem.eql(u8, value, "capability")) return .capability;
    return null;
}

pub fn reprInfoForTarget(attributes: []const ast.Attribute, target: ReprTarget) ReprInfo {
    const attribute = findUniqueAttribute(attributes, "repr") orelse return .{};
    return parseReprInfo(attribute, target) orelse .{};
}

pub fn parseExportName(attributes: []const ast.Attribute) ?[]const u8 {
    return parseSingleNameArgument(attributes, "export");
}

pub fn parseLinkName(attributes: []const ast.Attribute) ?[]const u8 {
    return parseSingleNameArgument(attributes, "link");
}

fn parseSingleNameArgument(attributes: []const ast.Attribute, attribute_name: []const u8) ?[]const u8 {
    const attribute = findUniqueAttribute(attributes, attribute_name) orelse return null;
    if (attribute.arguments().len != 1) return null;
    const argument = attribute.arguments()[0];
    if (argument.key == null or !std.mem.eql(u8, argument.key.?, "name")) return null;
    return switch (argument.value) {
        .string_literal => |value| if (value.len != 0) value else null,
        else => null,
    };
}

fn findUniqueAttribute(attributes: []const ast.Attribute, name: []const u8) ?ast.Attribute {
    var result: ?ast.Attribute = null;
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, name)) continue;
        if (result != null) return null;
        result = attribute;
    }
    return result;
}

fn parseReprInfo(attribute: ast.Attribute, target: ReprTarget) ?ReprInfo {
    if (attribute.invalidKind() != null) return null;
    if (attribute.isBare()) return null;
    if (keyedArgumentCount(attribute) != 0) return null;

    const first = positionalArgument(attribute, 0) orelse return null;
    const repr_marker = switch (first.value) {
        .identifier => |identifier| identifier,
        else => return null,
    };
    if (!std.mem.eql(u8, repr_marker, "c")) return null;

    return switch (target) {
        .struct_type, .union_type => if (positionalArgumentCount(attribute) == 1)
            .{ .has_c = true }
        else
            null,
        .enum_type => blk: {
            if (positionalArgumentCount(attribute) != 2) break :blk null;
            const second = positionalArgument(attribute, 1) orelse break :blk null;
            const type_name = switch (second.value) {
                .type_text => |type_text| type_text,
                else => break :blk null,
            };
            if (!isValidReprIntegerTypeName(type_name)) break :blk null;
            break :blk .{
                .has_c = true,
                .integer_type_name = type_name,
            };
        },
    };
}

fn isValidReprIntegerTypeName(type_name: []const u8) bool {
    const builtin = types.Builtin.fromName(type_name);
    if (builtin.isInteger()) return true;
    const alias = types.CAbiAlias.fromName(type_name) orelse return false;
    return switch (alias) {
        .c_bool, .c_void => false,
        else => true,
    };
}

pub fn isAllowedAttribute(name: []const u8) bool {
    return std.mem.eql(u8, name, "unsafe") or
        std.mem.eql(u8, name, "reflect") or
        std.mem.eql(u8, name, "domain_root") or
        std.mem.eql(u8, name, "domain_context") or
        std.mem.eql(u8, name, "boundary") or
        std.mem.eql(u8, name, "repr") or
        std.mem.eql(u8, name, "test") or
        std.mem.eql(u8, name, "link") or
        std.mem.eql(u8, name, "export");
}

pub fn symbolNameFor(allocator: Allocator, symbol_prefix: []const u8, module_path: []const u8, item: hir.Item) ![]const u8 {
    if (item.kind == .module_decl or item.kind == .use_decl or item.name.len == 0) return allocator.dupe(u8, "");

    var rendered = std.array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();

    var first = true;
    if (symbol_prefix.len != 0) {
        try rendered.appendSlice(symbol_prefix);
        first = false;
    }

    var parts = std.mem.splitScalar(u8, module_path, '.');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try rendered.appendSlice("__");
        first = false;
        try rendered.appendSlice(part);
    }
    if (!first) try rendered.appendSlice("__");
    try rendered.appendSlice(item.name);
    return rendered.toOwnedSlice();
}

pub fn symbolNameForSyntheticName(allocator: Allocator, symbol_prefix: []const u8, module_path: []const u8, name: []const u8) ![]const u8 {
    var rendered = std.array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();

    var first = true;
    if (symbol_prefix.len != 0) {
        try rendered.appendSlice(symbol_prefix);
        first = false;
    }

    var parts = std.mem.splitScalar(u8, module_path, '.');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try rendered.appendSlice("__");
        first = false;
        try rendered.appendSlice(part);
    }
    if (!first) try rendered.appendSlice("__");
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') {
            try rendered.append(byte);
        } else {
            try rendered.append('_');
        }
    }
    return rendered.toOwnedSlice();
}

test "parse export name requires one keyed string argument" {
    const span = @import("source/root.zig").Span{ .file_id = 0, .start = 0, .end = 0 };
    const args = try std.testing.allocator.dupe(ast.AttributeArgument, &.{
        .{
            .span = span,
            .key = "name",
            .value = .{ .string_literal = "runa_add" },
        },
    });
    defer std.testing.allocator.free(args);

    const attributes = [_]ast.Attribute{
        .{
            .name = "export",
            .span = span,
            .form = .{ .args = args },
        },
    };

    try std.testing.expectEqualStrings("runa_add", parseExportName(attributes[0..]).?);
}

test "bare attribute activation ignores argument-bearing attributes" {
    const span = @import("source/root.zig").Span{ .file_id = 0, .start = 0, .end = 0 };
    const args = [_]ast.AttributeArgument{
        .{
            .value = .{ .identifier = "full" },
            .span = span,
        },
    };
    const attributes = [_]ast.Attribute{
        .{
            .name = "reflect",
            .span = span,
            .form = .{ .args = args[0..] },
        },
    };

    try std.testing.expect(!hasBareAttribute(attributes[0..], "reflect"));
}

test "duplicate attributes do not activate semantic helpers" {
    const span = @import("source/root.zig").Span{ .file_id = 0, .start = 0, .end = 0 };
    const export_args = [_]ast.AttributeArgument{
        .{
            .key = "name",
            .value = .{ .string_literal = "one" },
            .span = span,
        },
    };
    const attributes = [_]ast.Attribute{
        .{
            .name = "reflect",
            .span = span,
            .form = .bare,
        },
        .{
            .name = "reflect",
            .span = span,
            .form = .bare,
        },
        .{
            .name = "export",
            .span = span,
            .form = .{ .args = export_args[0..] },
        },
        .{
            .name = "export",
            .span = span,
            .form = .{ .args = export_args[0..] },
        },
    };

    try std.testing.expect(!hasBareAttribute(attributes[0..], "reflect"));
    try std.testing.expect(parseExportName(attributes[0..]) == null);
}

test "repr info requires exact target-specific shapes" {
    const span = @import("source/root.zig").Span{ .file_id = 0, .start = 0, .end = 0 };
    const struct_args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
    };
    const enum_args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
        .{ .value = .{ .type_text = "CInt" }, .span = span },
    };
    const invalid_enum_args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
        .{ .value = .{ .type_text = "Bool" }, .span = span },
    };
    const extra_struct_args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
        .{ .value = .{ .type_text = "I32" }, .span = span },
    };

    const struct_attribute = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = struct_args[0..] },
        },
    };
    const enum_attribute = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = enum_args[0..] },
        },
    };
    const invalid_enum_attribute = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = invalid_enum_args[0..] },
        },
    };
    const extra_struct_attribute = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = extra_struct_args[0..] },
        },
    };

    try std.testing.expect(reprInfoForTarget(struct_attribute[0..], .struct_type).has_c);
    try std.testing.expect(!reprInfoForTarget(struct_attribute[0..], .enum_type).has_c);
    try std.testing.expect(reprInfoForTarget(enum_attribute[0..], .enum_type).has_c);
    try std.testing.expectEqualStrings("CInt", reprInfoForTarget(enum_attribute[0..], .enum_type).integer_type_name.?);
    try std.testing.expect(!reprInfoForTarget(invalid_enum_attribute[0..], .enum_type).has_c);
    try std.testing.expect(!reprInfoForTarget(extra_struct_attribute[0..], .struct_type).has_c);
}

test "boundary kind requires identifier argument" {
    const span = @import("source/root.zig").Span{ .file_id = 0, .start = 0, .end = 0 };
    const quoted_args = [_]ast.AttributeArgument{
        .{ .value = .{ .string_literal = "api" }, .span = span },
    };
    const quoted_attribute = [_]ast.Attribute{
        .{
            .name = "boundary",
            .span = span,
            .form = .{ .args = quoted_args[0..] },
        },
    };

    try std.testing.expect(boundaryKind(quoted_attribute[0..]) == null);
}
