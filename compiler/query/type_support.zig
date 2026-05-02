const std = @import("std");
const c_va_list = @import("../abi/c/va_list.zig");
const typed_decls = @import("../typed/declarations.zig");
const typed_expr = @import("../typed/expr.zig");
const typed_signatures = @import("signatures.zig");
const typed_text = @import("text.zig");
const tuple_types = @import("tuple_types.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const genericParamExists = typed_signatures.genericParamExists;

pub const Expr = typed_expr.Expr;
pub const Parameter = typed_decls.Parameter;
pub const GenericParam = typed_signatures.GenericParam;

pub const BoundaryTypeKind = enum {
    value,
    ephemeral_read,
    ephemeral_edit,
    retained_read,
    retained_edit,
};

pub const BoundaryType = struct {
    kind: BoundaryTypeKind,
    inner_type_name: []const u8,
    lifetime_name: ?[]const u8 = null,

    pub fn isBoundary(self: BoundaryType) bool {
        return self.kind != .value;
    }
};

pub fn builtinOfTypeRef(ty: types.TypeRef) types.Builtin {
    return switch (ty) {
        .builtin => |builtin| builtin,
        else => .unsupported,
    };
}

pub fn typeRefRawName(ty: types.TypeRef) []const u8 {
    return switch (ty) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| name,
        .unsupported => "Unsupported",
    };
}

pub fn parseBoundaryType(raw: []const u8) BoundaryType {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{
        .kind = .value,
        .inner_type_name = trimmed,
    };

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse return .{
            .kind = .value,
            .inner_type_name = trimmed,
        };
        const lifetime_name = std.mem.trim(u8, trimmed["hold[".len..close_index], " \t");
        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return .{
            .kind = .retained_read,
            .inner_type_name = std.mem.trim(u8, rest["read ".len..], " \t"),
            .lifetime_name = lifetime_name,
        };
        if (std.mem.startsWith(u8, rest, "edit ")) return .{
            .kind = .retained_edit,
            .inner_type_name = std.mem.trim(u8, rest["edit ".len..], " \t"),
            .lifetime_name = lifetime_name,
        };
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return .{
        .kind = .ephemeral_read,
        .inner_type_name = std.mem.trim(u8, trimmed["read ".len..], " \t"),
    };
    if (std.mem.startsWith(u8, trimmed, "edit ")) return .{
        .kind = .ephemeral_edit,
        .inner_type_name = std.mem.trim(u8, trimmed["edit ".len..], " \t"),
    };

    return .{
        .kind = .value,
        .inner_type_name = trimmed,
    };
}

pub fn returnTypeStructurallyCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    if (actual.eql(expected)) return true;
    if (actual.isUnsupported() or expected.isUnsupported()) return false;
    if (typeRefsTupleCompatible(actual, expected)) return true;

    const expected_boundary = parseBoundaryType(typeRefRawName(expected));
    if (!expected_boundary.isBoundary()) return false;

    const actual_boundary = parseBoundaryType(typeRefRawName(actual));
    return std.mem.eql(u8, actual_boundary.inner_type_name, expected_boundary.inner_type_name);
}

pub fn duplicateParameterTypeNames(allocator: Allocator, parameters: []const Parameter) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, parameters.len);
    for (parameters, 0..) |parameter, index| {
        names[index] = parameter.ty.displayName();
    }
    return names;
}

pub fn inferExprBoundaryTypeInScope(scope: anytype, expr: *const Expr) BoundaryType {
    const direct = parseBoundaryType(typeRefRawName(expr.ty));
    if (direct.isBoundary()) return direct;

    const current_inner = typeRefRawName(expr.ty);
    return switch (expr.node) {
        .identifier => |name| scope.getOrigin(name) orelse direct,
        .field => |field| inheritBoundaryFromBase(scope, field.base, current_inner),
        .method_target => |target| inheritBoundaryFromBase(scope, target.base, current_inner),
        .index => |index| inheritBoundaryFromBase(scope, index.base, current_inner),
        else => direct,
    };
}

fn inheritBoundaryFromBase(scope: anytype, base: *const Expr, current_inner: []const u8) BoundaryType {
    const base_boundary = inferExprBoundaryTypeInScope(scope, base);
    if (!base_boundary.isBoundary()) return .{
        .kind = .value,
        .inner_type_name = current_inner,
    };

    return .{
        .kind = base_boundary.kind,
        .inner_type_name = current_inner,
        .lifetime_name = base_boundary.lifetime_name,
    };
}

pub fn boundaryAccessCompatible(actual: BoundaryType, expected: BoundaryType) bool {
    return switch (expected.kind) {
        .ephemeral_read, .retained_read => actual.kind == .ephemeral_read or actual.kind == .retained_read,
        .ephemeral_edit, .retained_edit => actual.kind == .ephemeral_edit or actual.kind == .retained_edit,
        .value => actual.kind == .value,
    };
}

pub fn boundaryInnerTypeCompatible(
    actual_inner: []const u8,
    expected_inner: []const u8,
    generic_params: []const GenericParam,
    allow_self: bool,
) bool {
    if (allow_self and std.mem.eql(u8, expected_inner, "Self")) return true;
    if (genericParamExists(generic_params, expected_inner, .type_param)) return true;
    return std.mem.eql(u8, actual_inner, expected_inner);
}

pub fn callArgumentTypeCompatible(
    actual: types.TypeRef,
    expected: types.TypeRef,
    expected_type_name: []const u8,
    generic_params: []const GenericParam,
    allow_self: bool,
) bool {
    if (actual.eql(expected)) return true;
    if (actual.isUnsupported() or expected.isUnsupported()) return false;
    if (rawPointerCompatible(actual, expected)) return true;
    if (typeRefCompatibleWithName(actual, expected_type_name, generic_params, allow_self)) return true;

    const expected_boundary = parseBoundaryType(expected_type_name);
    if (expected_boundary.isBoundary()) {
        const actual_boundary = parseBoundaryType(typeRefRawName(actual));
        const actual_inner = if (actual_boundary.isBoundary()) actual_boundary.inner_type_name else typeRefRawName(actual);
        return boundaryInnerTypeCompatible(actual_inner, expected_boundary.inner_type_name, generic_params, allow_self);
    }

    const trimmed_expected = std.mem.trim(u8, expected_type_name, " \t");
    if (allow_self and std.mem.eql(u8, trimmed_expected, "Self")) return true;
    if (genericParamExists(generic_params, trimmed_expected, .type_param)) return true;
    return false;
}

fn typeRefsTupleCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    const actual_name = switch (actual) {
        .named => |name| name,
        else => return false,
    };
    const expected_name = switch (expected) {
        .named => |name| name,
        else => return false,
    };
    return tuple_types.typeNamesStructurallyEqual(std.heap.page_allocator, actual_name, expected_name) catch false;
}

fn typeRefCompatibleWithName(
    actual: types.TypeRef,
    expected_type_name: []const u8,
    generic_params: []const GenericParam,
    allow_self: bool,
) bool {
    _ = generic_params;
    _ = allow_self;
    const actual_name = switch (actual) {
        .named => |name| name,
        .builtin => |builtin| builtin.displayName(),
        .unsupported => return false,
    };
    const expected_trimmed = std.mem.trim(u8, expected_type_name, " \t\r\n");
    return tuple_types.typeNamesStructurallyEqual(std.heap.page_allocator, actual_name, expected_trimmed) catch false;
}

fn rawPointerCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    const actual_name = switch (actual) {
        .named => |name| name,
        else => return false,
    };
    const expected_name = switch (expected) {
        .named => |name| name,
        else => return false,
    };
    const actual_pointer = parseRawPointer(actual_name) orelse return false;
    const expected_pointer = parseRawPointer(expected_name) orelse return false;
    if (!std.mem.eql(u8, actual_pointer.pointee, expected_pointer.pointee)) return false;
    return actual_pointer.access == expected_pointer.access or
        (actual_pointer.access == .edit and expected_pointer.access == .read);
}

const RawPointerAccess = enum {
    read,
    edit,
};

const RawPointer = struct {
    access: RawPointerAccess,
    pointee: []const u8,
};

fn parseRawPointer(raw: []const u8) ?RawPointer {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "*read ")) return .{
        .access = .read,
        .pointee = std.mem.trim(u8, trimmed["*read ".len..], " \t\r\n"),
    };
    if (std.mem.startsWith(u8, trimmed, "*edit ")) return .{
        .access = .edit,
        .pointee = std.mem.trim(u8, trimmed["*edit ".len..], " \t\r\n"),
    };
    return null;
}

pub fn cVariadicTailIndex(parameter_type_names: []const []const u8) ?usize {
    if (parameter_type_names.len == 0) return null;
    const last_index = parameter_type_names.len - 1;
    const tail_name = std.mem.trim(u8, parameter_type_names[last_index], " \t\r\n");
    if (std.mem.eql(u8, tail_name, "CVaList")) return last_index;
    if (std.mem.startsWith(u8, tail_name, "...")) return last_index;
    return null;
}

pub fn cVariadicFixedParameterCount(parameter_count: usize, parameter_type_names: []const []const u8) usize {
    if (cVariadicTailIndex(parameter_type_names)) |tail_index| {
        if (tail_index < parameter_count) return tail_index;
    }
    return parameter_count;
}

pub fn cVariadicCallArityValid(arg_count: usize, parameter_count: usize, parameter_type_names: []const []const u8) bool {
    if (cVariadicTailIndex(parameter_type_names)) |tail_index| {
        if (tail_index >= parameter_count) return arg_count == parameter_count;
        return arg_count >= tail_index;
    }
    return arg_count == parameter_count;
}

pub fn cVariadicArgumentTypeSupported(ty: types.TypeRef) bool {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .i32, .u32, .index, .isize => true,
            .unit, .bool, .str, .unsupported => false,
        },
        .named => |name| cVariadicArgumentTypeNameSupported(name),
        .unsupported => false,
    };
}

pub fn cVariadicArgumentTypeNameSupported(raw_name: []const u8) bool {
    return c_va_list.variadicValueTypeNameSupported(raw_name);
}

pub fn boundaryFromParameter(parameter: Parameter) BoundaryType {
    const retained = parseBoundaryType(parameter.ty.displayName());
    if (retained.kind == .retained_read or retained.kind == .retained_edit) return retained;

    return switch (parameter.mode) {
        .read => .{
            .kind = .ephemeral_read,
            .inner_type_name = parameter.ty.displayName(),
        },
        .edit => .{
            .kind = .ephemeral_edit,
            .inner_type_name = parameter.ty.displayName(),
        },
        .owned, .take => boundaryFromTypeRef(parameter.ty),
    };
}

pub fn boundaryFromTypeRef(ty: types.TypeRef) BoundaryType {
    return parseBoundaryType(typeRefRawName(ty));
}

fn SliceElem(comptime SliceType: type) type {
    const info = @typeInfo(SliceType);
    if (info != .pointer or info.pointer.size != .slice) {
        @compileError("expected a slice type");
    }
    return info.pointer.child;
}

pub fn findPrototype(prototypes: anytype, name: []const u8) ?SliceElem(@TypeOf(prototypes)) {
    for (prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype;
    }
    return null;
}

pub fn findMethodPrototype(method_prototypes: anytype, target_type: []const u8, method_name: []const u8) ?SliceElem(@TypeOf(method_prototypes)) {
    for (method_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.target_type, target_type) and std.mem.eql(u8, prototype.method_name, method_name)) {
            return prototype;
        }
    }
    return null;
}

pub fn findStructPrototype(struct_prototypes: anytype, name: []const u8) ?SliceElem(@TypeOf(struct_prototypes)) {
    for (struct_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype;
    }
    return null;
}

pub fn findEnumPrototype(enum_prototypes: anytype, name: []const u8) ?SliceElem(@TypeOf(enum_prototypes)) {
    for (enum_prototypes) |prototype| {
        if (std.mem.eql(u8, prototype.name, name)) return prototype;
    }
    return null;
}

pub fn findEnumVariant(prototype: anytype, name: []const u8) ?SliceElem(@TypeOf(prototype.variants)) {
    for (prototype.variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}
