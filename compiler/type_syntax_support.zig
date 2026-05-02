const std = @import("std");
const ast = @import("ast/root.zig");
const types = @import("types/root.zig");
const Allocator = std.mem.Allocator;

pub const BorrowedSelfAccess = enum {
    read,
    edit,
};

pub fn containsInvalid(syntax: ast.TypeSyntax) bool {
    if (!syntax.isStructured()) return syntax.text().len == 0;
    for (syntax.nodes) |node| {
        switch (node.payload) {
            .invalid => return true,
            else => {},
        }
    }
    return false;
}

pub fn isPlainName(syntax: ast.TypeSyntax) ?[]const u8 {
    if (!syntax.isStructured()) return if (syntax.text().len == 0) null else syntax.text();
    return switch (syntax.rootNode().payload) {
        .name_ref => syntax.rootNode().source.text,
        else => null,
    };
}

pub fn builtinFromSyntax(syntax: ast.TypeSyntax) types.Builtin {
    const name = isPlainName(syntax) orelse return .unsupported;
    return types.Builtin.fromName(name);
}

pub fn typeRefFromSyntax(allocator: Allocator, syntax: ast.TypeSyntax) !types.TypeRef {
    _ = allocator;
    if (containsInvalid(syntax)) return .unsupported;
    const builtin = builtinFromSyntax(syntax);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = syntax.text() };
}

pub fn borrowedSelfAccess(syntax: ast.TypeSyntax) ?BorrowedSelfAccess {
    if (!syntax.isStructured()) return null;
    const root = syntax.rootNode();
    return switch (root.payload) {
        .borrow => |borrow| switch (borrow.access) {
            .hold => blk: {
                const child_indices = syntax.childNodeIndices(0);
                if (child_indices.len == 0) break :blk null;
                const inner = syntax.nodes[child_indices[child_indices.len - 1]];
                switch (inner.payload) {
                    .name_ref => {
                        if (!std.mem.eql(u8, inner.source.text, "Self")) break :blk null;
                    },
                    else => break :blk null,
                }
                const tail = tokenBorrowTail(root.source.text);
                if (std.mem.eql(u8, tail, "read")) break :blk .read;
                if (std.mem.eql(u8, tail, "edit")) break :blk .edit;
                break :blk null;
            },
            else => null,
        },
        else => null,
    };
}

pub fn render(allocator: Allocator, syntax: ast.TypeSyntax) ![]const u8 {
    if (!syntax.isStructured()) return allocator.dupe(u8, syntax.text());
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try appendRendered(&out, syntax, 0);
    return out.toOwnedSlice();
}

fn appendRendered(out: *std.array_list.Managed(u8), syntax: ast.TypeSyntax, node_index: usize) !void {
    const node = syntax.nodes[node_index];
    switch (node.payload) {
        .invalid, .name_ref, .lifetime => try out.appendSlice(node.source.text),
        .apply => {
            const child_indices = syntax.childNodeIndices(node_index);
            if (child_indices.len == 0) {
                try out.appendSlice(node.source.text);
                return;
            }
            try appendRendered(out, syntax, child_indices[0]);
            try out.append('[');
            for (child_indices[1..], 0..) |child_index, index| {
                if (index != 0) try out.appendSlice(", ");
                try appendRendered(out, syntax, child_index);
            }
            try out.append(']');
        },
        .borrow => |borrow| {
            switch (borrow.access) {
                .hold => {
                    try out.appendSlice("hold[");
                    if (borrow.lifetime) |lifetime| try out.appendSlice(lifetime.text);
                    try out.appendSlice("] ");
                    try out.appendSlice(tokenBorrowTail(node.source.text));
                    if (tokenBorrowTail(node.source.text).len != 0) try out.append(' ');
                },
                .read => try out.appendSlice("read "),
                .edit => try out.appendSlice("edit "),
            }
            const child_indices = syntax.childNodeIndices(node_index);
            if (child_indices.len != 0) try appendRendered(out, syntax, child_indices[child_indices.len - 1]);
        },
        .raw_pointer => |pointer| {
            try out.append('*');
            try out.appendSlice(switch (pointer.access) {
                .read => "read ",
                .edit => "edit ",
            });
            const child_indices = syntax.childNodeIndices(node_index);
            if (child_indices.len != 0) try appendRendered(out, syntax, child_indices[child_indices.len - 1]);
        },
        .assoc => |assoc| {
            const child_indices = syntax.childNodeIndices(node_index);
            if (child_indices.len != 0) try appendRendered(out, syntax, child_indices[0]);
            try out.append('.');
            try out.appendSlice(assoc.member.text);
        },
    }
}

fn tokenBorrowTail(raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "] read ")) |_| return "read";
    if (std.mem.indexOf(u8, raw, "] edit ")) |_| return "edit";
    return "";
}
