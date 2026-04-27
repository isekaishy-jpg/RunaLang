const std = @import("std");
const layout = @import("../layout/root.zig");
const session_ids = @import("../session/ids.zig");
const types = @import("../types/root.zig");

pub const summary = "Query-owned ABI classification descriptors over canonical types and layout.";
pub const c = @import("c/root.zig");
pub const c_abi_required = true;

pub const AbiFamily = enum {
    c,
    system,
};

pub const PassMode = enum {
    direct,
    indirect,
    forbidden,
};

pub const AbiCallableRole = enum {
    ordinary,
    foreign_import,
    foreign_export,
    callback,
};

pub const ForeignFailurePolicy = enum {
    none,
    abort_untranslated_failure,
};

pub const AbiTypeKey = struct {
    type_id: types.CanonicalTypeId,
    target_name: []const u8,
    family: AbiFamily,

    pub fn eql(lhs: AbiTypeKey, rhs: AbiTypeKey) bool {
        return lhs.type_id.eql(rhs.type_id) and
            std.mem.eql(u8, lhs.target_name, rhs.target_name) and
            lhs.family == rhs.family;
    }
};

pub const CallableSubject = union(enum) {
    item: session_ids.ItemId,
    structural_type: types.CanonicalTypeId,

    pub fn eql(lhs: CallableSubject, rhs: CallableSubject) bool {
        return switch (lhs) {
            .item => |left| switch (rhs) {
                .item => |right| left.index == right.index,
                else => false,
            },
            .structural_type => |left| switch (rhs) {
                .structural_type => |right| left.eql(right),
                else => false,
            },
        };
    }
};

pub const AbiCallableKey = struct {
    subject: CallableSubject,
    target_name: []const u8,
    family: AbiFamily,
    role: AbiCallableRole = .ordinary,

    pub fn eql(lhs: AbiCallableKey, rhs: AbiCallableKey) bool {
        return lhs.subject.eql(rhs.subject) and
            std.mem.eql(u8, lhs.target_name, rhs.target_name) and
            lhs.family == rhs.family and
            lhs.role == rhs.role;
    }
};

pub const AbiTypeResult = struct {
    key: AbiTypeKey,
    layout_status: layout.LayoutStatus,
    layout_storage: layout.StorageShape,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: PassMode,
    reason: ?[]const u8 = null,
};

pub const AbiValueResult = struct {
    type_id: types.CanonicalTypeId,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: PassMode,
    reason: ?[]const u8 = null,
};

pub const AbiParameterResult = AbiValueResult;

pub const VariadicPromotion = struct {
    source_type: types.CanonicalTypeId,
    promoted_type: types.CanonicalTypeId,
};

pub const AbiDiagnostic = struct {
    code: []const u8,
    message: []const u8,
};

pub const AbiCallableResult = struct {
    key: AbiCallableKey,
    callable_safe: bool,
    params: []const AbiParameterResult = &.{},
    return_value: ?AbiValueResult = null,
    variadic: bool = false,
    callback: bool = false,
    no_unwind: bool = false,
    failure_policy: ForeignFailurePolicy = .none,
    diagnostics: []const AbiDiagnostic = &.{},
    reason: ?[]const u8 = null,
};

pub fn classifiedTypeResult(
    allocator: std.mem.Allocator,
    key: AbiTypeKey,
    layout_result: layout.LayoutResult,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: PassMode,
    reason: ?[]const u8,
) !AbiTypeResult {
    var owned_key = try cloneAbiTypeKey(allocator, key);
    errdefer deinitAbiTypeKey(allocator, &owned_key);
    const owned_reason = if (reason) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_reason) |value| allocator.free(value);
    return .{
        .key = owned_key,
        .layout_status = layout_result.status,
        .layout_storage = layout_result.storage,
        .safe = safe,
        .passable = passable,
        .returnable = returnable,
        .pass_mode = pass_mode,
        .reason = owned_reason,
    };
}

pub fn cloneAbiTypeKey(allocator: std.mem.Allocator, key: AbiTypeKey) !AbiTypeKey {
    return .{
        .type_id = key.type_id,
        .target_name = try allocator.dupe(u8, key.target_name),
        .family = key.family,
    };
}

pub fn deinitAbiTypeKey(allocator: std.mem.Allocator, key: *AbiTypeKey) void {
    if (key.target_name.len != 0) allocator.free(key.target_name);
    key.* = .{
        .type_id = .{ .index = 0 },
        .target_name = "",
        .family = .c,
    };
}

pub fn cloneAbiCallableKey(allocator: std.mem.Allocator, key: AbiCallableKey) !AbiCallableKey {
    return .{
        .subject = key.subject,
        .target_name = try allocator.dupe(u8, key.target_name),
        .family = key.family,
        .role = key.role,
    };
}

pub fn deinitAbiCallableKey(allocator: std.mem.Allocator, key: *AbiCallableKey) void {
    if (key.target_name.len != 0) allocator.free(key.target_name);
    key.* = .{
        .subject = .{ .structural_type = .{ .index = 0 } },
        .target_name = "",
        .family = .c,
    };
}

pub fn unsupportedTypeResult(
    allocator: std.mem.Allocator,
    key: AbiTypeKey,
    layout_result: layout.LayoutResult,
    reason: []const u8,
) !AbiTypeResult {
    var owned_key = try cloneAbiTypeKey(allocator, key);
    errdefer deinitAbiTypeKey(allocator, &owned_key);
    return .{
        .key = owned_key,
        .layout_status = layout_result.status,
        .layout_storage = layout_result.storage,
        .safe = false,
        .passable = false,
        .returnable = false,
        .pass_mode = .forbidden,
        .reason = try allocator.dupe(u8, reason),
    };
}

pub fn unsupportedCallableResult(
    allocator: std.mem.Allocator,
    key: AbiCallableKey,
    reason: []const u8,
) !AbiCallableResult {
    var owned_key = try cloneAbiCallableKey(allocator, key);
    errdefer deinitAbiCallableKey(allocator, &owned_key);
    return .{
        .key = owned_key,
        .callable_safe = false,
        .reason = try allocator.dupe(u8, reason),
    };
}

pub fn deinitAbiTypeResult(allocator: std.mem.Allocator, result: *AbiTypeResult) void {
    deinitAbiTypeKey(allocator, &result.key);
    if (result.reason) |reason| allocator.free(reason);
    result.* = .{
        .key = .{
            .type_id = .{ .index = 0 },
            .target_name = "",
            .family = .c,
        },
        .layout_status = .unsupported,
        .layout_storage = .@"opaque",
        .safe = false,
        .passable = false,
        .returnable = false,
        .pass_mode = .forbidden,
    };
}

pub fn deinitAbiCallableResult(allocator: std.mem.Allocator, result: *AbiCallableResult) void {
    deinitAbiCallableKey(allocator, &result.key);
    for (result.params) |param| {
        if (param.reason) |reason| allocator.free(reason);
    }
    if (result.params.len != 0) allocator.free(result.params);
    if (result.return_value) |value| {
        if (value.reason) |reason| allocator.free(reason);
    }
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code.len != 0) allocator.free(diagnostic.code);
        if (diagnostic.message.len != 0) allocator.free(diagnostic.message);
    }
    if (result.diagnostics.len != 0) allocator.free(result.diagnostics);
    if (result.reason) |reason| allocator.free(reason);
    result.* = .{
        .key = .{
            .subject = .{ .structural_type = .{ .index = 0 } },
            .target_name = "",
            .family = .c,
        },
        .callable_safe = false,
    };
}
