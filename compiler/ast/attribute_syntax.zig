const std = @import("std");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    identifier: []const u8,
    string_literal: []const u8,
    type_text: []const u8,

    pub fn text(self: Value) []const u8 {
        return switch (self) {
            .identifier => |value| value,
            .string_literal => |value| value,
            .type_text => |value| value,
        };
    }
};

pub const Argument = struct {
    key: ?[]const u8 = null,
    value: Value,
    span: source.Span,
};

pub const InvalidKind = enum {
    unexpected_trailing_text,
    unterminated_args,
    trailing_after_args,
    empty_argument,
};

pub const Form = union(enum) {
    bare,
    args: []Argument,
    invalid: InvalidKind,

    pub fn deinit(self: *Form, allocator: Allocator) void {
        switch (self.*) {
            .args => |args| allocator.free(args),
            .bare, .invalid => {},
        }
        self.* = .bare;
    }

    pub fn clone(self: Form, allocator: Allocator) !Form {
        return switch (self) {
            .bare => .bare,
            .args => |args| .{ .args = try allocator.dupe(Argument, args) },
            .invalid => |kind| .{ .invalid = kind },
        };
    }

    pub fn arguments(self: Form) []const Argument {
        return switch (self) {
            .bare => &.{},
            .args => |args| args,
            .invalid => &.{},
        };
    }
};

pub const Attribute = struct {
    name: []const u8,
    span: source.Span,
    form: Form = .bare,

    pub fn deinit(self: *Attribute, allocator: Allocator) void {
        self.form.deinit(allocator);
    }

    pub fn clone(self: Attribute, allocator: Allocator) !Attribute {
        return .{
            .name = self.name,
            .span = self.span,
            .form = try self.form.clone(allocator),
        };
    }

    pub fn arguments(self: Attribute) []const Argument {
        return self.form.arguments();
    }

    pub fn isBare(self: Attribute) bool {
        return switch (self.form) {
            .bare => true,
            .args, .invalid => false,
        };
    }

    pub fn invalidKind(self: Attribute) ?InvalidKind {
        return switch (self.form) {
            .invalid => |kind| kind,
            .bare, .args => null,
        };
    }
};

pub fn cloneAttributes(allocator: Allocator, attributes: []const Attribute) ![]Attribute {
    const cloned = try allocator.alloc(Attribute, attributes.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*attribute| attribute.deinit(allocator);
        allocator.free(cloned);
    }

    for (attributes, 0..) |attribute, index| {
        cloned[index] = try attribute.clone(allocator);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitAttributes(allocator: Allocator, attributes: []Attribute) void {
    for (attributes) |*attribute| attribute.deinit(allocator);
    allocator.free(attributes);
}

test "clone attributes duplicates argument storage" {
    const span = source.Span{ .file_id = 0, .start = 0, .end = 14 };
    const args = try std.testing.allocator.dupe(Argument, &.{
        .{
            .key = "name",
            .value = .{ .string_literal = "runa_add" },
            .span = span,
        },
    });
    var attribute = Attribute{
        .name = "export",
        .span = span,
        .form = .{ .args = args },
    };
    defer attribute.deinit(std.testing.allocator);
    const attributes = [_]Attribute{attribute};

    const cloned = try cloneAttributes(std.testing.allocator, attributes[0..]);
    defer deinitAttributes(std.testing.allocator, cloned);

    try std.testing.expect(cloned.ptr != attributes[0..].ptr);
    try std.testing.expect(cloned[0].arguments().ptr != attribute.arguments().ptr);
    try std.testing.expectEqualStrings("runa_add", cloned[0].arguments()[0].value.text());
}
