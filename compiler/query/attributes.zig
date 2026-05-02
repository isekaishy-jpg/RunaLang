const std = @import("std");
const ast = @import("../ast/root.zig");
const attribute_support = @import("../attribute_support.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");

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

    pub fn functionLike(self: DeclarationTarget) bool {
        return switch (self) {
            .function, .suspend_function, .foreign_function => true,
            else => false,
        };
    }

    pub fn aggregateLike(self: DeclarationTarget) bool {
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
        if (!attribute_support.isAllowedAttribute(attribute.name)) {
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

        if (attribute.invalidKind()) |kind| {
            switch (kind) {
                .unexpected_trailing_text => try diagnostics.add(.@"error", "type.attr.form", attribute.span, "attribute '#{s}' must use '#{s}' or '#{s}[...]' form", .{ attribute.name, attribute.name, attribute.name }),
                .unterminated_args => try diagnostics.add(.@"error", "type.attr.form", attribute.span, "attribute '#{s}[...]' is missing a closing ']'", .{attribute.name}),
                .trailing_after_args => try diagnostics.add(.@"error", "type.attr.form", attribute.span, "attribute '#{s}[...]' may not have trailing text after ']'", .{attribute.name}),
                .empty_argument => try diagnostics.add(.@"error", "type.attr.form", attribute.span, "attribute '#{s}[...]' may not contain empty arguments", .{attribute.name}),
            }
            continue;
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
        if (std.mem.eql(u8, attribute.name, "repr")) {
            const repr_target = reprTargetForDeclarationTarget(target);
            if (repr_target) |owned_target| {
                try validateReprAttribute(attribute, owned_target, diagnostics);
            } else {
                try diagnostics.add(.@"error", "type.attr.repr.target", span, "#repr[...] is valid only on struct, union, and enum declarations", .{});
            }
        }
        if (std.mem.eql(u8, attribute.name, "unsafe")) {
            if (!attribute.isBare()) {
                try diagnostics.add(.@"error", "type.attr.bare", attribute.span, "#unsafe is a bare attribute and does not take arguments", .{});
            }
            if (!target.functionLike()) {
                try diagnostics.add(.@"error", "type.attr.unsafe.target", span, "#unsafe declaration attributes are valid only on functions", .{});
            }
        }
        if (std.mem.eql(u8, attribute.name, "test")) {
            if (!attribute.isBare()) {
                try diagnostics.add(.@"error", "type.test.args", attribute.span, "#test is a bare attribute and does not take arguments", .{});
            }
            if (target != .function or !has_body) {
                try diagnostics.add(.@"error", "type.test.target", span, "#test is valid only on module-level ordinary function declarations with bodies", .{});
            }
        }
        if (std.mem.eql(u8, attribute.name, "reflect") and !attribute.isBare()) {
            try diagnostics.add(.@"error", "type.reflect.args", attribute.span, "#reflect is a bare attribute and does not take arguments", .{});
        }
        if (std.mem.eql(u8, attribute.name, "domain_root") and !attribute.isBare()) {
            try diagnostics.add(.@"error", "type.domain_root.args", attribute.span, "#domain_root is a bare attribute and does not take arguments", .{});
        }
        if (std.mem.eql(u8, attribute.name, "domain_context") and !attribute.isBare()) {
            try diagnostics.add(.@"error", "type.domain_context.args", attribute.span, "#domain_context is a bare attribute and does not take arguments", .{});
        }
    }

    if (attribute_support.hasAttribute(attributes, "link") and attribute_support.hasAttribute(attributes, "export")) {
        try diagnostics.add(.@"error", "type.attr.conflict", span, "a declaration may not carry both #link[...] and #export[...]", .{});
    }
}

fn reprTargetForDeclarationTarget(target: DeclarationTarget) ?attribute_support.ReprTarget {
    return switch (target) {
        .struct_type => .struct_type,
        .union_type => .union_type,
        .enum_type => .enum_type,
        else => null,
    };
}

fn validateReprAttribute(
    attribute: ast.Attribute,
    target: attribute_support.ReprTarget,
    diagnostics: *diag.Bag,
) !void {
    if (attribute.isBare()) {
        try diagnostics.add(.@"error", "type.attr.repr.args", attribute.span, "#repr requires explicit arguments", .{});
        return;
    }
    if (attribute_support.keyedArgumentCount(attribute) != 0) {
        try diagnostics.add(.@"error", "type.attr.repr.args", attribute.span, "#repr[...] does not accept keyed arguments", .{});
    }

    const positional_count = attribute_support.positionalArgumentCount(attribute);
    const expected_positional_count: usize = switch (target) {
        .struct_type, .union_type => 1,
        .enum_type => 2,
    };
    if (positional_count != expected_positional_count) {
        try diagnostics.add(.@"error", "type.attr.repr.args", attribute.span, "{s}", .{reprShapeMessage(target)});
        return;
    }

    const first = attribute_support.positionalArgument(attribute, 0) orelse {
        try diagnostics.add(.@"error", "type.attr.repr.args", attribute.span, "{s}", .{reprShapeMessage(target)});
        return;
    };
    const first_value = switch (first.value) {
        .identifier => |identifier| identifier,
        else => null,
    };
    if (first_value == null or !std.mem.eql(u8, first_value.?, "c")) {
        try diagnostics.add(.@"error", "type.attr.repr.args", first.span, "#repr must start with the positional marker 'c'", .{});
        return;
    }

    if (target != .enum_type) return;

    const second = attribute_support.positionalArgument(attribute, 1) orelse {
        try diagnostics.add(.@"error", "type.attr.repr.args", attribute.span, "{s}", .{reprShapeMessage(target)});
        return;
    };
    const attribute_slice = [_]ast.Attribute{attribute};
    if (!attribute_support.reprInfoForTarget(attribute_slice[0..], .enum_type).has_c) {
        try diagnostics.add(.@"error", "type.attr.repr.value", second.span, "#repr[c, IntType] requires an integer builtin or C ABI integer alias", .{});
    }
}

fn reprShapeMessage(target: attribute_support.ReprTarget) []const u8 {
    return switch (target) {
        .struct_type, .union_type => "#repr[...] on struct and union declarations must be exactly #repr[c]",
        .enum_type => "#repr[...] on enum declarations must be exactly #repr[c, IntType]",
    };
}

fn validateNameAttribute(attribute: ast.Attribute, attribute_name: []const u8, diagnostics: *diag.Bag) !?[]const u8 {
    var result: ?[]const u8 = null;
    var saw_name = false;

    if (attribute.isBare()) {
        try diagnostics.add(.@"error", "type.attr.args", attribute.span, "#{s}[...] requires exactly one keyed string argument: name = \"...\"", .{attribute_name});
        return null;
    }

    for (attribute.arguments()) |argument| {
        if (argument.key == null) {
            try diagnostics.add(.@"error", "type.attr.positional", argument.span, "#{s}[...] does not accept positional arguments", .{attribute_name});
            continue;
        }

        const key = argument.key.?;
        if (!std.mem.eql(u8, key, "name")) {
            try diagnostics.add(.@"error", "type.attr.key", argument.span, "unknown #{s}[...] key '{s}'", .{ attribute_name, key });
            continue;
        }
        if (saw_name) {
            try diagnostics.add(.@"error", "type.attr.key_duplicate", argument.span, "duplicate key 'name' in #{s}[...]", .{attribute_name});
            continue;
        }
        saw_name = true;

        switch (argument.value) {
            .string_literal => |value| {
                if (value.len == 0) {
                    try diagnostics.add(.@"error", "type.attr.value", argument.span, "#{s}[name = ...] requires a non-empty string literal", .{attribute_name});
                    continue;
                }
                result = value;
            },
            else => try diagnostics.add(.@"error", "type.attr.value", argument.span, "#{s}[name = ...] requires a string literal", .{attribute_name}),
        }
    }

    if (!saw_name or result == null or attribute.arguments().len != 1) {
        if (!saw_name or attribute.arguments().len != 1) {
            try diagnostics.add(.@"error", "type.attr.args", attribute.span, "#{s}[...] requires exactly one keyed string argument: name = \"...\"", .{attribute_name});
        }
        return null;
    }
    return result;
}

test "validate export attribute rejects positional arguments" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const span = source.Span{ .file_id = 0, .start = 0, .end = 12 };
    const args = try std.testing.allocator.dupe(ast.AttributeArgument, &.{
        .{
            .value = .{ .identifier = "foo" },
            .span = span,
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

    try validateDeclarationAttributes(attributes[0..], .function, true, span, &diagnostics);
    try std.testing.expect(diagnostics.hasErrors());
}

test "validate repr attribute enforces exact target law" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const span = source.Span{ .file_id = 0, .start = 0, .end = 16 };
    const args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
        .{ .value = .{ .type_text = "I32" }, .span = span },
    };
    const attributes = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = args[0..] },
        },
    };

    try validateDeclarationAttributes(attributes[0..], .struct_type, false, span, &diagnostics);
    try std.testing.expect(diagnostics.hasErrors());
}

test "validate repr enum rejects non-integer representation types" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const span = source.Span{ .file_id = 0, .start = 0, .end = 18 };
    const args = [_]ast.AttributeArgument{
        .{ .value = .{ .identifier = "c" }, .span = span },
        .{ .value = .{ .type_text = "Bool" }, .span = span },
    };
    const attributes = [_]ast.Attribute{
        .{
            .name = "repr",
            .span = span,
            .form = .{ .args = args[0..] },
        },
    };

    try validateDeclarationAttributes(attributes[0..], .enum_type, false, span, &diagnostics);
    try std.testing.expect(diagnostics.hasErrors());
}
