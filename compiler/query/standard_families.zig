const std = @import("std");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");

pub const Family = enum {
    option,
    result,

    pub fn name(self: Family) []const u8 {
        return switch (self) {
            .option => "Option",
            .result => "Result",
        };
    }
};

pub const VariantInfo = struct {
    family: Family,
    concrete_type_name: []const u8,
    family_name: []const u8,
    variant_name: []const u8,
    tag: i32,
    payload_type_name: ?[]const u8 = null,
    payload_field_name: ?[]const u8 = null,
};

pub fn familyFromName(name: []const u8) ?Family {
    if (std.mem.eql(u8, name, "Option")) return .option;
    if (std.mem.eql(u8, name, "Result")) return .result;
    return null;
}

pub fn variantForExpected(
    allocator: std.mem.Allocator,
    expected_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    const concrete_type_name = switch (expected_type) {
        .named => |name| name,
        else => return null,
    };
    return variantForConcrete(allocator, concrete_type_name, family_name, variant_name);
}

pub fn variantForSubject(
    allocator: std.mem.Allocator,
    subject_type: types.TypeRef,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    return variantForExpected(allocator, subject_type, family_name, variant_name);
}

pub fn variantForConcrete(
    allocator: std.mem.Allocator,
    concrete_type_name: []const u8,
    family_name: []const u8,
    variant_name: []const u8,
) !?VariantInfo {
    const family = familyFromName(family_name) orelse return null;
    const args = (try applicationArgs(allocator, concrete_type_name, family)) orelse return null;
    defer allocator.free(args);

    switch (family) {
        .option => {
            if (args.len != 1) return null;
            if (std.mem.eql(u8, variant_name, "None")) return .{
                .family = .option,
                .concrete_type_name = concrete_type_name,
                .family_name = family.name(),
                .variant_name = "None",
                .tag = 0,
            };
            if (std.mem.eql(u8, variant_name, "Some")) return .{
                .family = .option,
                .concrete_type_name = concrete_type_name,
                .family_name = family.name(),
                .variant_name = "Some",
                .tag = 1,
                .payload_type_name = args[0],
                .payload_field_name = "value",
            };
        },
        .result => {
            if (args.len != 2) return null;
            if (std.mem.eql(u8, variant_name, "Ok")) return .{
                .family = .result,
                .concrete_type_name = concrete_type_name,
                .family_name = family.name(),
                .variant_name = "Ok",
                .tag = 0,
                .payload_type_name = args[0],
                .payload_field_name = "value",
            };
            if (std.mem.eql(u8, variant_name, "Err")) return .{
                .family = .result,
                .concrete_type_name = concrete_type_name,
                .family_name = family.name(),
                .variant_name = "Err",
                .tag = 1,
                .payload_type_name = args[1],
                .payload_field_name = "error",
            };
        },
    }
    return null;
}

pub fn helperVariant(concrete_type_name: []const u8, method_name: []const u8) ?[]const u8 {
    const family = familyFromName(typed_text.baseTypeName(concrete_type_name)) orelse return null;
    return switch (family) {
        .option => {
            if (std.mem.eql(u8, method_name, "is_some")) return "Some";
            if (std.mem.eql(u8, method_name, "is_none")) return "None";
            return null;
        },
        .result => {
            if (std.mem.eql(u8, method_name, "is_ok")) return "Ok";
            if (std.mem.eql(u8, method_name, "is_err")) return "Err";
            return null;
        },
    };
}

pub fn typeRefFromName(raw: []const u8) types.TypeRef {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    const builtin = types.Builtin.fromName(name);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = name };
}

pub fn exhaustiveVariantNames(allocator: std.mem.Allocator, raw_type_name: []const u8) !?[]const []const u8 {
    const family = familyFromName(typed_text.baseTypeName(raw_type_name)) orelse return null;
    const args = (try applicationArgs(allocator, raw_type_name, family)) orelse return null;
    defer allocator.free(args);
    return switch (family) {
        .option => if (args.len == 1) &[_][]const u8{ "None", "Some" } else null,
        .result => if (args.len == 2) &[_][]const u8{ "Ok", "Err" } else null,
    };
}

pub fn applicationArgs(allocator: std.mem.Allocator, raw_type_name: []const u8, family: Family) !?[]const []const u8 {
    const name = std.mem.trim(u8, raw_type_name, " \t\r\n");
    const open_index = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    const close_index = typed_text.findMatchingDelimiter(name, open_index, '[', ']') orelse return null;
    if (std.mem.trim(u8, name[close_index + 1 ..], " \t\r\n").len != 0) return null;
    const base_name = std.mem.trim(u8, name[0..open_index], " \t\r\n");
    if (!std.mem.eql(u8, base_name, family.name())) return null;
    const args = try typed_text.splitTopLevelCommaParts(allocator, name[open_index + 1 .. close_index]);
    return args;
}
