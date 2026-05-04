const std = @import("std");
const ast = @import("../ast/root.zig");

const Entry = struct {
    key: []const u8,
    display_name: []const u8,
    syntax: ?ast.TypeSyntax,
};

var mutex: std.atomic.Mutex = .unlocked;
var entries: std.ArrayListUnmanaged(Entry) = .empty;

pub fn ensureName(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "";

    lock();
    defer mutex.unlock();

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, trimmed)) return entry.key;
    }

    const owned_name = try std.heap.page_allocator.dupe(u8, trimmed);
    errdefer std.heap.page_allocator.free(owned_name);

    try entries.append(std.heap.page_allocator, .{
        .key = owned_name,
        .display_name = owned_name,
        .syntax = null,
    });
    return owned_name;
}

pub fn ensureSyntax(syntax: ast.TypeSyntax) ![]const u8 {
    const trimmed_text = std.mem.trim(u8, syntax.text(), " \t\r\n");
    if (trimmed_text.len == 0) return "";

    lock();
    defer mutex.unlock();

    for (entries.items) |*entry| {
        const owned_syntax = entry.syntax orelse continue;
        if (syntaxStructurallyEqual(owned_syntax, syntax)) return entry.key;
    }

    if (plainSyntaxKey(syntax)) |plain_name| {
        for (entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.key, plain_name)) continue;
            if (entry.syntax == null) {
                entry.syntax = try cloneSyntaxWithOwnedText(syntax);
            }
            return entry.key;
        }

        const owned_plain_name = try std.heap.page_allocator.dupe(u8, plain_name);
        errdefer std.heap.page_allocator.free(owned_plain_name);
        const owned_syntax = try cloneSyntaxWithOwnedText(syntax);
        errdefer {
            var mutable_syntax = owned_syntax;
            mutable_syntax.deinit(std.heap.page_allocator);
        }
        try entries.append(std.heap.page_allocator, .{
            .key = owned_plain_name,
            .display_name = owned_plain_name,
            .syntax = owned_syntax,
        });
        return entries.items[entries.items.len - 1].key;
    }

    const display_name = try std.heap.page_allocator.dupe(u8, syntax.text());
    errdefer std.heap.page_allocator.free(display_name);
    const owned_key = try std.fmt.allocPrint(std.heap.page_allocator, "<query-type-exact-{d}>", .{entries.items.len});
    errdefer std.heap.page_allocator.free(owned_key);
    const owned_syntax = try cloneSyntaxWithOwnedText(syntax);
    errdefer {
        var mutable_syntax = owned_syntax;
        mutable_syntax.deinit(std.heap.page_allocator);
    }

    try entries.append(std.heap.page_allocator, .{
        .key = owned_key,
        .display_name = display_name,
        .syntax = owned_syntax,
    });
    return owned_key;
}

pub fn registerExact(syntax: ast.TypeSyntax) ![]const u8 {
    return ensureSyntax(syntax);
}

pub fn lookupExact(name: []const u8) ?ast.TypeSyntax {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;

    lock();
    defer mutex.unlock();

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, trimmed)) return entry.syntax orelse null;
    }
    return null;
}

pub fn lookupName(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;

    lock();
    defer mutex.unlock();

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, trimmed)) return entry.key;
    }
    return null;
}

pub fn cloneExact(allocator: std.mem.Allocator, name: []const u8) !?ast.TypeSyntax {
    const syntax = lookupExact(name) orelse return null;
    return try syntax.clone(allocator);
}

pub fn cloneByDisplayName(allocator: std.mem.Allocator, raw: []const u8) !?ast.TypeSyntax {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    lock();
    defer mutex.unlock();

    for (entries.items) |entry| {
        if (!std.mem.eql(u8, entry.display_name, trimmed)) continue;
        const syntax = entry.syntax orelse return null;
        return try syntax.clone(allocator);
    }
    return null;
}

pub fn displayNameForKey(key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, key, " \t\r\n");
    if (trimmed.len == 0) return null;

    lock();
    defer mutex.unlock();

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, trimmed)) return entry.display_name;
    }
    return null;
}

fn cloneSyntaxWithOwnedText(syntax: ast.TypeSyntax) !ast.TypeSyntax {
    const owned_text = try std.heap.page_allocator.dupe(u8, syntax.text());
    errdefer std.heap.page_allocator.free(owned_text);

    var cloned = try syntax.clone(std.heap.page_allocator);
    errdefer cloned.deinit(std.heap.page_allocator);

    rebaseSyntaxText(&cloned, syntax.text(), owned_text);
    return cloned;
}

fn rebaseSyntaxText(syntax: *ast.TypeSyntax, old_text: []const u8, new_text: []const u8) void {
    syntax.source.text = rebaseSlice(old_text, new_text, syntax.source.text);
    for (syntax.nodes) |*node| {
        node.source.text = rebaseSlice(old_text, new_text, node.source.text);
        switch (node.payload) {
            .borrow => |*borrow| {
                if (borrow.lifetime) |*lifetime| lifetime.text = rebaseSlice(old_text, new_text, lifetime.text);
            },
            .assoc => |*assoc| {
                assoc.member.text = rebaseSlice(old_text, new_text, assoc.member.text);
            },
            .fixed_array => |*array| {
                array.length.text = rebaseSlice(old_text, new_text, array.length.text);
            },
            .foreign_callable => |*callable| {
                callable.abi.text = rebaseSlice(old_text, new_text, callable.abi.text);
            },
            else => {},
        }
    }
}

fn rebaseSlice(old_text: []const u8, new_text: []const u8, slice: []const u8) []const u8 {
    if (slice.len == 0) return slice;
    const old_start = @intFromPtr(old_text.ptr);
    const slice_start = @intFromPtr(slice.ptr);
    if (slice_start < old_start) return slice;
    const offset = slice_start - old_start;
    if (offset + slice.len > old_text.len) return slice;
    return new_text[offset .. offset + slice.len];
}

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn plainSyntaxKey(syntax: ast.TypeSyntax) ?[]const u8 {
    if (syntax.isStructured()) {
        const root = syntax.rootNode();
        if (root.payload != .name_ref) return null;
        return std.mem.trim(u8, root.source.text, " \t\r\n");
    }
    const trimmed = std.mem.trim(u8, syntax.text(), " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn syntaxStructurallyEqual(lhs: ast.TypeSyntax, rhs: ast.TypeSyntax) bool {
    if (!lhs.isStructured() or !rhs.isStructured()) {
        return std.mem.eql(u8, std.mem.trim(u8, lhs.text(), " \t\r\n"), std.mem.trim(u8, rhs.text(), " \t\r\n"));
    }
    return nodesStructurallyEqual(lhs, 0, rhs, 0);
}

fn nodesStructurallyEqual(lhs_syntax: ast.TypeSyntax, lhs_index: usize, rhs_syntax: ast.TypeSyntax, rhs_index: usize) bool {
    const lhs = lhs_syntax.nodes[lhs_index];
    const rhs = rhs_syntax.nodes[rhs_index];
    if (std.meta.activeTag(lhs.payload) != std.meta.activeTag(rhs.payload)) return false;

    switch (lhs.payload) {
        .invalid => return false,
        .name_ref, .lifetime => {
            if (!textSliceEqual(lhs.source.text, rhs.source.text)) return false;
        },
        .borrow => |lhs_borrow| {
            const rhs_borrow = rhs.payload.borrow;
            if (lhs_borrow.access != rhs_borrow.access) return false;
            if (!optionalSpanTextEqual(lhs_borrow.lifetime, rhs_borrow.lifetime)) return false;
        },
        .raw_pointer => |lhs_pointer| {
            if (lhs_pointer.access != rhs.payload.raw_pointer.access) return false;
        },
        .assoc => |lhs_assoc| {
            if (!textSliceEqual(lhs_assoc.member.text, rhs.payload.assoc.member.text)) return false;
        },
        .fixed_array => |lhs_array| {
            if (!textSliceEqual(lhs_array.length.text, rhs.payload.fixed_array.length.text)) return false;
        },
        .foreign_callable => |lhs_callable| {
            const rhs_callable = rhs.payload.foreign_callable;
            if (!textSliceEqual(lhs_callable.abi.text, rhs_callable.abi.text)) return false;
            if (lhs_callable.parameter_count != rhs_callable.parameter_count) return false;
            if (lhs_callable.has_variadic_tail != rhs_callable.has_variadic_tail) return false;
        },
        .apply, .tuple => {},
    }

    const lhs_children = lhs_syntax.childNodeIndices(lhs_index);
    const rhs_children = rhs_syntax.childNodeIndices(rhs_index);
    if (lhs_children.len != rhs_children.len) return false;
    for (lhs_children, rhs_children) |lhs_child, rhs_child| {
        if (!nodesStructurallyEqual(lhs_syntax, lhs_child, rhs_syntax, rhs_child)) return false;
    }
    return true;
}

fn optionalSpanTextEqual(lhs: ?ast.SpanText, rhs: ?ast.SpanText) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return textSliceEqual(lhs.?.text, rhs.?.text);
}

fn textSliceEqual(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, lhs, " \t\r\n"), std.mem.trim(u8, rhs, " \t\r\n"));
}
