const std = @import("std");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const hir = @import("../hir/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub fn parseExportName(attributes: []const ast.Attribute) ?[]const u8 {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "export")) continue;
        return parseNameArgument(attribute.raw) orelse null;
    }
    return null;
}

pub fn parseLinkName(attributes: []const ast.Attribute) ?[]const u8 {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "link")) continue;
        return parseNameArgument(attribute.raw) orelse null;
    }
    return null;
}

pub const DeclarationTarget = enum {
    function,
    suspend_function,
    foreign_function,
    const_item,
    type_alias,
    struct_type,
    union_type,
    enum_type,
    opaque_type,
    trait_type,
    impl_block,
    other,

    fn functionLike(self: DeclarationTarget) bool {
        return switch (self) {
            .function, .suspend_function, .foreign_function => true,
            else => false,
        };
    }

    fn aggregateLike(self: DeclarationTarget) bool {
        return switch (self) {
            .struct_type, .union_type, .enum_type => true,
            else => false,
        };
    }
};

pub fn validateDeclarationAttributes(
    attributes: []const ast.Attribute,
    target: DeclarationTarget,
    has_body: bool,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    var seen = [_]?[]const u8{null} ** 16;
    var seen_count: usize = 0;

    for (attributes) |attribute| {
        if (!isAllowedAttribute(attribute.name)) {
            try diagnostics.add(.@"error", "type.attr.unknown", attribute.span, "unknown attribute '{s}'", .{attribute.name});
            continue;
        }

        for (seen[0..seen_count]) |maybe_name| {
            const name = maybe_name orelse continue;
            if (std.mem.eql(u8, name, attribute.name)) {
                try diagnostics.add(.@"error", "type.attr.duplicate", attribute.span, "duplicate attribute '#{s}'", .{attribute.name});
                break;
            }
        }
        if (seen_count < seen.len) {
            seen[seen_count] = attribute.name;
            seen_count += 1;
        }

        if (std.mem.eql(u8, attribute.name, "export")) {
            _ = try validateNameAttribute(attribute, "export", diagnostics);
            if (!target.functionLike()) {
                try diagnostics.add(.@"error", "type.attr.export.target", span, "#export[...] is valid only on function declarations", .{});
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "link")) {
            _ = try validateNameAttribute(attribute, "link", diagnostics);
            if (target != .foreign_function or has_body) {
                try diagnostics.add(.@"error", "type.attr.link.target", span, "#link[...] is valid only on imported foreign declarations", .{});
            }
            continue;
        }
        if (std.mem.eql(u8, attribute.name, "repr") and !target.aggregateLike()) {
            try diagnostics.add(.@"error", "type.attr.repr.target", span, "#repr[...] is valid only on struct, union, and enum declarations", .{});
        }
        if (std.mem.eql(u8, attribute.name, "unsafe") and !target.functionLike()) {
            try diagnostics.add(.@"error", "type.attr.unsafe.target", span, "#unsafe declaration attributes are valid only on functions", .{});
        }
        if (std.mem.eql(u8, attribute.name, "test")) {
            if (!std.mem.eql(u8, std.mem.trim(u8, attribute.raw, " \t\r\n"), "#test")) {
                try diagnostics.add(.@"error", "type.test.args", attribute.span, "#test is a bare attribute and does not take arguments", .{});
            }
            if (target != .function or !has_body) {
                try diagnostics.add(.@"error", "type.test.target", span, "#test is valid only on module-level ordinary function declarations with bodies", .{});
            }
        }
    }

    if (hasAttribute(attributes, "link") and hasAttribute(attributes, "export")) {
        try diagnostics.add(.@"error", "type.attr.conflict", span, "a declaration may not carry both #link[...] and #export[...]", .{});
    }
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

pub fn hasAttribute(attributes: []const ast.Attribute, name: []const u8) bool {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return true;
    }
    return false;
}

fn validateNameAttribute(attribute: ast.Attribute, attribute_name: []const u8, diagnostics: *diag.Bag) !?[]const u8 {
    const parsed = try parseNameAttribute(attribute.raw, attribute.span, attribute_name, diagnostics);
    if (parsed == null) {
        try diagnostics.add(.@"error", "type.attr.args", attribute.span, "#{s}[...] requires exactly one keyed string argument: name = \"...\"", .{attribute_name});
    }
    return parsed;
}

fn parseNameArgument(raw: []const u8) ?[]const u8 {
    const open_index = std.mem.indexOfScalar(u8, raw, '[') orelse return null;
    const close_index = std.mem.lastIndexOfScalar(u8, raw, ']') orelse return null;
    if (close_index <= open_index) return null;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t\r\n").len != 0) return null;
    const inside = raw[open_index + 1 .. close_index];
    var parts = std.mem.splitScalar(u8, inside, ',');
    var result: ?[]const u8 = null;
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
        const key = std.mem.trim(u8, trimmed[0..eq_index], " \t\r\n");
        if (!std.mem.eql(u8, key, "name")) return null;
        if (result != null) return null;
        const value = parseQuotedString(std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r\n")) orelse return null;
        if (value.len == 0) return null;
        result = value;
    }
    return result;
}

fn parseNameAttribute(
    raw: []const u8,
    span: source.Span,
    attribute_name: []const u8,
    diagnostics: *diag.Bag,
) !?[]const u8 {
    const open_index = std.mem.indexOfScalar(u8, raw, '[') orelse return null;
    const close_index = std.mem.lastIndexOfScalar(u8, raw, ']') orelse return null;
    if (close_index <= open_index) return null;
    if (std.mem.trim(u8, raw[close_index + 1 ..], " \t\r\n").len != 0) return null;

    const inside = raw[open_index + 1 .. close_index];
    var parts = std.mem.splitScalar(u8, inside, ',');
    var result: ?[]const u8 = null;
    var saw_name = false;
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            try diagnostics.add(.@"error", "type.attr.positional", span, "#{s}[...] does not accept positional arguments", .{attribute_name});
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..eq_index], " \t\r\n");
        if (!std.mem.eql(u8, key, "name")) {
            try diagnostics.add(.@"error", "type.attr.key", span, "unknown #{s}[...] key '{s}'", .{ attribute_name, key });
            continue;
        }
        if (saw_name) {
            try diagnostics.add(.@"error", "type.attr.key_duplicate", span, "duplicate key 'name' in #{s}[...]", .{attribute_name});
            continue;
        }
        saw_name = true;
        const value_text = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r\n");
        const value = parseQuotedString(value_text) orelse {
            try diagnostics.add(.@"error", "type.attr.value", span, "#{s}[name = ...] requires a string literal", .{attribute_name});
            continue;
        };
        if (value.len == 0) {
            try diagnostics.add(.@"error", "type.attr.value", span, "#{s}[name = ...] requires a non-empty string literal", .{attribute_name});
            continue;
        }
        result = value;
    }
    return result;
}

fn parseQuotedString(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}
