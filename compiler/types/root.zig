const std = @import("std");

pub const Builtin = enum {
    unit,
    bool,
    i32,
    u32,
    index,
    str,
    unsupported,

    pub fn fromName(raw: []const u8) Builtin {
        if (std.mem.eql(u8, raw, "Unit")) return .unit;
        if (std.mem.eql(u8, raw, "Bool")) return .bool;
        if (std.mem.eql(u8, raw, "I32")) return .i32;
        if (std.mem.eql(u8, raw, "U32")) return .u32;
        if (std.mem.eql(u8, raw, "Index")) return .index;
        if (std.mem.eql(u8, raw, "Str")) return .str;
        return .unsupported;
    }

    pub fn isNumeric(self: Builtin) bool {
        return switch (self) {
            .i32, .u32, .index => true,
            else => false,
        };
    }

    pub fn isInteger(self: Builtin) bool {
        return switch (self) {
            .i32, .u32, .index => true,
            else => false,
        };
    }

    pub fn isCAbiSafe(self: Builtin) bool {
        return switch (self) {
            .unit, .bool, .i32, .u32, .index => true,
            .str, .unsupported => false,
        };
    }

    pub fn cName(self: Builtin) []const u8 {
        return switch (self) {
            .unit => "void",
            .bool => "bool",
            .i32 => "int32_t",
            .u32 => "uint32_t",
            .index => "size_t",
            .str => "const char*",
            .unsupported => "void*",
        };
    }

    pub fn displayName(self: Builtin) []const u8 {
        return switch (self) {
            .unit => "Unit",
            .bool => "Bool",
            .i32 => "I32",
            .u32 => "U32",
            .index => "Index",
            .str => "Str",
            .unsupported => "Unsupported",
        };
    }
};

pub const TypeRef = union(enum) {
    builtin: Builtin,
    named: []const u8,
    unsupported,

    pub fn fromBuiltin(value: Builtin) TypeRef {
        return if (value == .unsupported) .unsupported else .{ .builtin = value };
    }

    pub fn eql(lhs: TypeRef, rhs: TypeRef) bool {
        return switch (lhs) {
            .builtin => |left_builtin| switch (rhs) {
                .builtin => |right_builtin| left_builtin == right_builtin,
                else => false,
            },
            .named => |left_name| switch (rhs) {
                .named => |right_name| std.mem.eql(u8, left_name, right_name),
                else => false,
            },
            .unsupported => rhs == .unsupported,
        };
    }

    pub fn isUnsupported(self: TypeRef) bool {
        return self == .unsupported;
    }

    pub fn isNumeric(self: TypeRef) bool {
        return switch (self) {
            .builtin => |builtin| builtin.isNumeric(),
            else => false,
        };
    }

    pub fn isInteger(self: TypeRef) bool {
        return switch (self) {
            .builtin => |builtin| builtin.isInteger(),
            else => false,
        };
    }

    pub fn isNamed(self: TypeRef, name: []const u8) bool {
        return switch (self) {
            .named => |existing| std.mem.eql(u8, existing, name),
            else => false,
        };
    }

    pub fn displayName(self: TypeRef) []const u8 {
        return switch (self) {
            .builtin => |builtin| builtin.displayName(),
            .named => |name| name,
            .unsupported => "Unsupported",
        };
    }
};
