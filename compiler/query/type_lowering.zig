const std = @import("std");
const ast = @import("../ast/root.zig");
const type_registry = @import("type_registry.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;

pub fn typeRefFromSyntax(allocator: Allocator, syntax: ast.TypeSyntax) !types.TypeRef {
    _ = allocator;
    if (type_syntax_support.containsInvalid(syntax)) return .unsupported;

    const builtin = type_syntax_support.builtinFromSyntax(syntax);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = try type_registry.ensureSyntax(syntax) };
}

pub fn clonedSyntaxForTypeRef(allocator: Allocator, ty: types.TypeRef) !?ast.TypeSyntax {
    return switch (ty) {
        .builtin => |builtin| .{
            .source = .{
                .text = builtin.displayName(),
                .span = .{ .file_id = 0, .start = 0, .end = builtin.displayName().len },
            },
        },
        .named => |name| blk: {
            if (try type_registry.cloneExact(allocator, name)) |syntax| break :blk syntax;
            break :blk null;
        },
        .unsupported => null,
    };
}

pub fn lookupRegisteredSyntax(name: []const u8) ?ast.TypeSyntax {
    return type_registry.lookupExact(name);
}

pub fn displayNameForKey(name: []const u8) ?[]const u8 {
    return type_registry.displayNameForKey(name);
}
