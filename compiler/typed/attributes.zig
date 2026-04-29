const std = @import("std");
const ast = @import("../ast/root.zig");
const hir = @import("../hir/root.zig");
const Allocator = std.mem.Allocator;

pub fn parseExportName(attributes: []const ast.Attribute) ?[]const u8 {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "export")) continue;
        const name_index = std.mem.indexOf(u8, attribute.raw, "name") orelse return null;
        const quote_start = std.mem.indexOfScalarPos(u8, attribute.raw, name_index, '"') orelse return null;
        const quote_end = std.mem.indexOfScalarPos(u8, attribute.raw, quote_start + 1, '"') orelse return null;
        return attribute.raw[quote_start + 1 .. quote_end];
    }
    return null;
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
