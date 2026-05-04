const std = @import("std");
const c_va_list = @import("../abi/c/va_list.zig");
const typed_decls = @import("../typed/declarations.zig");
const typed_expr = @import("../typed/expr.zig");
const typed_signatures = @import("signatures.zig");
const type_forms = @import("type_forms.zig");
const type_lowering = @import("type_lowering.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const genericParamExists = typed_signatures.genericParamExists;

pub const Expr = typed_expr.Expr;
pub const Parameter = typed_decls.Parameter;
pub const GenericParam = typed_signatures.GenericParam;

pub const BoundaryTypeKind = type_forms.BoundaryTypeKind;
pub const BoundaryType = type_forms.BoundaryType;

pub fn builtinOfTypeRef(ty: types.TypeRef) types.Builtin {
    return switch (ty) {
        .builtin => |builtin| builtin,
        else => .unsupported,
    };
}

pub fn typeRefRawName(ty: types.TypeRef) []const u8 {
    return switch (ty) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| type_lowering.displayNameForKey(name) orelse name,
        .unsupported => "Unsupported",
    };
}

pub fn boundaryFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !BoundaryType {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return type_forms.boundaryFromView(view);
}

pub fn returnTypeStructurallyCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    if (actual.eql(expected)) return true;
    if (actual.isUnsupported() or expected.isUnsupported()) return false;
    if (typeRefsTupleCompatible(actual, expected)) return true;

    const expected_boundary = boundaryFromTypeRef(expected);
    if (!expected_boundary.isBoundary()) return false;

    const actual_boundary = boundaryFromTypeRef(actual);
    return typeRefsStructurallyCompatible(actual_boundary.inner_type, expected_boundary.inner_type);
}

pub fn duplicateParameterTypeNames(allocator: Allocator, parameters: []const Parameter) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, parameters.len);
    for (parameters, 0..) |parameter, index| {
        names[index] = typeRefRawName(parameter.ty);
    }
    return names;
}

pub fn inferExprBoundaryTypeInScope(scope: anytype, expr: *const Expr) BoundaryType {
    const direct = boundaryFromTypeRef(expr.ty);
    if (direct.isBoundary()) return direct;

    const current_inner = expr.ty;
    return switch (expr.node) {
        .identifier => |name| scope.getOrigin(name) orelse direct,
        .field => |field| inheritBoundaryFromBase(scope, field.base, current_inner),
        .method_target => |target| inheritBoundaryFromBase(scope, target.base, current_inner),
        .index => |index| inheritBoundaryFromBase(scope, index.base, current_inner),
        else => direct,
    };
}

fn inheritBoundaryFromBase(scope: anytype, base: *const Expr, current_inner: types.TypeRef) BoundaryType {
    const base_boundary = inferExprBoundaryTypeInScope(scope, base);
    if (!base_boundary.isBoundary()) return .{
        .kind = .value,
        .inner_type = current_inner,
    };

    return .{
        .kind = base_boundary.kind,
        .inner_type = current_inner,
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
    actual_inner: types.TypeRef,
    expected_inner: types.TypeRef,
    generic_params: []const GenericParam,
    allow_self: bool,
) bool {
    if (typeAllowsGenericOrSelf(expected_inner, generic_params, allow_self)) return true;
    return typeRefsStructurallyCompatible(actual_inner, expected_inner);
}

pub fn callArgumentTypeCompatible(
    actual: types.TypeRef,
    expected: types.TypeRef,
    generic_params: []const GenericParam,
    allow_self: bool,
) bool {
    if (actual.eql(expected)) return true;
    if (actual.isUnsupported() or expected.isUnsupported()) return false;
    if (rawPointerCompatible(actual, expected)) return true;
    if (typeAllowsGenericOrSelf(expected, generic_params, allow_self)) return true;
    if (typeRefsStructurallyCompatible(actual, expected)) return true;

    const expected_boundary = boundaryFromTypeRef(expected);
    if (expected_boundary.isBoundary()) {
        const actual_boundary = boundaryFromTypeRef(actual);
        const actual_inner = if (actual_boundary.isBoundary()) actual_boundary.inner_type else actual;
        return boundaryInnerTypeCompatible(actual_inner, expected_boundary.inner_type, generic_params, allow_self);
    }

    return false;
}

fn typeRefsTupleCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    return type_forms.typeRefsStructurallyEqual(std.heap.page_allocator, actual, expected) catch false;
}

fn rawPointerCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    var actual_view = type_forms.View.fromTypeRef(std.heap.page_allocator, actual) catch return false;
    defer actual_view.deinit();
    var expected_view = type_forms.View.fromTypeRef(std.heap.page_allocator, expected) catch return false;
    defer expected_view.deinit();
    const actual_pointer = type_forms.rawPointerFromView(actual_view) orelse return false;
    const expected_pointer = type_forms.rawPointerFromView(expected_view) orelse return false;
    if (!actual_pointer.pointee.eql(expected_pointer.pointee)) return false;
    return actual_pointer.access == expected_pointer.access or
        (actual_pointer.access == .edit and expected_pointer.access == .read);
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
    const retained = boundaryFromTypeRef(parameter.ty);
    if (retained.kind == .retained_read or retained.kind == .retained_edit) return retained;

    return switch (parameter.mode) {
        .read => .{
            .kind = .ephemeral_read,
            .inner_type = parameter.ty,
        },
        .edit => .{
            .kind = .ephemeral_edit,
            .inner_type = parameter.ty,
        },
        .owned, .take => boundaryFromTypeRef(parameter.ty),
    };
}

pub fn boundaryFromTypeRef(ty: types.TypeRef) BoundaryType {
    var view = type_forms.View.fromTypeRef(std.heap.page_allocator, ty) catch return .{
        .kind = .value,
        .inner_type = ty,
    };
    defer view.deinit();
    return type_forms.boundaryFromView(view);
}

pub fn fixedArrayElementType(allocator: Allocator, ty: types.TypeRef) !?types.TypeRef {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    const shape = type_forms.fixedArrayShapeFromView(view) orelse return null;
    return shape.element_type;
}

pub fn fixedArrayShapeFromTypeRef(allocator: Allocator, ty: types.TypeRef) !?type_forms.FixedArrayShape {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.fixedArrayShapeFromView(view);
}

pub fn fixedArrayElementTypeFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?types.TypeRef {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    const shape = type_forms.fixedArrayShapeFromView(view) orelse return null;
    return shape.element_type;
}

pub fn rawPointerFromTypeRef(allocator: Allocator, ty: types.TypeRef) !?type_forms.RawPointer {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.rawPointerFromView(view);
}

pub fn rawPointerFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?type_forms.RawPointer {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return type_forms.rawPointerFromView(view);
}

pub fn tupleElementType(allocator: Allocator, ty: types.TypeRef, index: usize) !?types.TypeRef {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.projectionElementType(view, index);
}

pub fn tupleElementTypes(allocator: Allocator, ty: types.TypeRef) !?[]types.TypeRef {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.tupleElementTypeRefs(allocator, view);
}

pub fn tupleElementTypesFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?[]types.TypeRef {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return type_forms.tupleElementTypeRefs(allocator, view);
}

pub fn callableFromTypeRef(allocator: Allocator, ty: types.TypeRef) !?type_forms.Callable {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.callableFromView(view);
}

pub fn callableFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?type_forms.Callable {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return type_forms.callableFromView(view);
}

pub fn foreignCallableFromTypeRef(allocator: Allocator, ty: types.TypeRef) !?type_forms.ForeignCallable {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return try type_forms.foreignCallableFromView(allocator, view);
}

pub fn foreignCallableFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?type_forms.ForeignCallable {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return try type_forms.foreignCallableFromView(allocator, view);
}

pub fn applicationArgsFromTypeRef(
    allocator: Allocator,
    ty: types.TypeRef,
    family_name: []const u8,
) !?[]types.TypeRef {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return try type_forms.applicationArgs(allocator, view, family_name);
}

pub fn applicationArgsFromSyntax(
    allocator: Allocator,
    syntax: @import("../ast/root.zig").TypeSyntax,
    family_name: []const u8,
) !?[]types.TypeRef {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return try type_forms.applicationArgs(allocator, view, family_name);
}

pub fn baseTypeNameFromTypeRef(allocator: Allocator, ty: types.TypeRef) !?[]const u8 {
    var view = type_forms.View.fromTypeRef(allocator, ty) catch return null;
    defer view.deinit();
    return type_forms.baseName(view);
}

pub fn baseTypeNameFromSyntax(allocator: Allocator, syntax: @import("../ast/root.zig").TypeSyntax) !?[]const u8 {
    var view = try type_forms.View.fromSyntax(allocator, syntax);
    defer view.deinit();
    return type_forms.baseName(view);
}

pub fn renderTypeRef(allocator: Allocator, ty: types.TypeRef) ![]const u8 {
    return switch (ty) {
        .builtin => |builtin| allocator.dupe(u8, builtin.displayName()),
        .named => |name| blk: {
            if (try type_lowering.clonedSyntaxForTypeRef(allocator, .{ .named = name })) |syntax| {
                var owned = syntax;
                defer owned.deinit(allocator);
                break :blk @import("../type_syntax_support.zig").render(allocator, owned);
            }
            break :blk allocator.dupe(u8, type_lowering.displayNameForKey(name) orelse name);
        },
        .unsupported => allocator.dupe(u8, "Unsupported"),
    };
}

fn typeAllowsGenericOrSelf(expected: types.TypeRef, generic_params: []const GenericParam, allow_self: bool) bool {
    const syntax = type_lowering.clonedSyntaxForTypeRef(std.heap.page_allocator, expected) catch return false;
    var owned = syntax orelse return false;
    defer owned.deinit(std.heap.page_allocator);
    const plain_name = @import("../type_syntax_support.zig").isPlainName(owned) orelse return false;
    const trimmed = std.mem.trim(u8, plain_name, " \t\r\n");
    if (allow_self and std.mem.eql(u8, trimmed, "Self")) return true;
    return genericParamExists(generic_params, trimmed, .type_param);
}

fn typeRefsStructurallyCompatible(actual: types.TypeRef, expected: types.TypeRef) bool {
    return type_forms.typeRefsStructurallyEqual(std.heap.page_allocator, actual, expected) catch false;
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
