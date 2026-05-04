const std = @import("std");
const abi = @import("../abi/root.zig");
const ast = @import("../ast/root.zig");
const c_va_list = @import("../abi/c/va_list.zig");
const layout = @import("../layout/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const standard_families = @import("standard_families.zig");
const types = @import("../types/root.zig");

const array_list = std.array_list;

pub const Resolvers = struct {
    canonical_type_expression: *const fn (*session.Session, session.ModuleId, []const u8) anyerror!types.CanonicalTypeId,
    canonical_type_ref: *const fn (*session.Session, session.ModuleId, types.TypeRef) anyerror!types.CanonicalTypeId,
    canonical_type_syntax: *const fn (*session.Session, session.ModuleId, ast.TypeSyntax) anyerror!types.CanonicalTypeId,
    checked_signature: *const fn (*session.Session, session.ItemId) anyerror!query_types.CheckedSignature,
    layout_for_key: *const fn (*session.Session, layout.LayoutKey) anyerror!layout.LayoutResult,
    abi_type_for_key: *const fn (*session.Session, abi.AbiTypeKey) anyerror!abi.AbiTypeResult,
};

pub fn buildType(active: *session.Session, key: abi.AbiTypeKey, resolvers: Resolvers) !abi.AbiTypeResult {
    const type_layout = try resolvers.layout_for_key(active, .{
        .type_id = key.type_id,
        .target_name = key.target_name,
        .repr_context = try reprContextForType(active, key.type_id, resolvers),
    });
    if (type_layout.status == .unsupported) {
        return abi.unsupportedTypeResult(active.allocator, key, type_layout, "type layout is unsupported");
    }
    if (key.type_id.index >= active.caches.canonical_types.items.len) {
        return abi.unsupportedTypeResult(active.allocator, key, type_layout, "unknown canonical type id");
    }

    const canonical = active.caches.canonical_types.items[key.type_id.index];
    return switch (canonical.key) {
        .builtin_scalar => |scalar| classifyBuiltinScalar(active, key, type_layout, scalar),
        .c_abi_alias => |alias| classifyCAbiAlias(active, key, type_layout, alias),
        .raw_pointer => abi.classifiedTypeResult(active.allocator, key, type_layout, true, true, true, .direct, null),
        .fixed_array => |array_type| classifyFixedArray(active, key, type_layout, array_type, resolvers),
        .nominal => classifyNominal(active, key, type_layout),
        .callable => |callable| classifyCallableType(active, key, type_layout, callable, resolvers),
        .tuple => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "tuples are not C ABI-safe"),
        .generic_param => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "generic parameter ABI requires instantiation"),
        .generic_application => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "generic application ABI is not implemented"),
        .c_va_list => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "CVaList is only valid as a variadic tail binding"),
        .handle => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "handles are not C ABI-safe by default"),
        .option => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "Option is not C ABI-safe"),
        .result => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "Result is not C ABI-safe"),
        .unsupported => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "unsupported canonical type key"),
    };
}

pub fn buildCallable(active: *session.Session, key: abi.AbiCallableKey, resolvers: Resolvers) !abi.AbiCallableResult {
    return switch (key.subject) {
        .item => |item_id| buildItemCallable(active, key, item_id, resolvers),
        .structural_type => |type_id| buildStructuralCallable(active, key, type_id, resolvers),
    };
}

fn reprContextForType(
    active: *session.Session,
    type_id: types.CanonicalTypeId,
    resolvers: Resolvers,
) !layout.ReprContext {
    if (type_id.index >= active.caches.canonical_types.items.len) return .default;
    return switch (active.caches.canonical_types.items[type_id.index].key) {
        .nominal => |nominal| blk: {
            if (nominal.item_index >= active.semantic_index.items.items.len) break :blk .default;
            const checked = try resolvers.checked_signature(active, .{ .index = nominal.item_index });
            break :blk .{ .declared = checked.surface.declared_repr };
        },
        else => .default,
    };
}

fn classifyBuiltinScalar(
    active: *session.Session,
    key: abi.AbiTypeKey,
    type_layout: layout.LayoutResult,
    scalar: types.BuiltinScalar,
) !abi.AbiTypeResult {
    return switch (scalar) {
        .i32, .u32, .index, .isize => abi.classifiedTypeResult(active.allocator, key, type_layout, true, true, true, .direct, null),
        .unit => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "Unit is not C ABI-safe; use CVoid in foreign signatures"),
        .bool => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "Bool is not C ABI-safe; use CBool for foreign layout"),
        .str => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "Str is not C ABI-safe"),
    };
}

fn classifyCAbiAlias(
    active: *session.Session,
    key: abi.AbiTypeKey,
    type_layout: layout.LayoutResult,
    alias: types.CAbiAlias,
) !abi.AbiTypeResult {
    return switch (alias) {
        .c_void => abi.classifiedTypeResult(active.allocator, key, type_layout, true, false, true, .forbidden, "CVoid is return-only and has no parameter storage"),
        else => abi.classifiedTypeResult(active.allocator, key, type_layout, true, true, true, .direct, null),
    };
}

fn classifyFixedArray(
    active: *session.Session,
    key: abi.AbiTypeKey,
    type_layout: layout.LayoutResult,
    array_type: types.FixedArray,
    resolvers: Resolvers,
) !abi.AbiTypeResult {
    const element = try resolvers.abi_type_for_key(active, .{
        .type_id = array_type.element,
        .target_name = key.target_name,
        .family = key.family,
    });
    if (!element.safe) {
        return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "fixed array element is not C ABI-safe");
    }
    return abi.classifiedTypeResult(active.allocator, key, type_layout, true, false, false, .forbidden, "fixed arrays are C-layout safe but not direct ABI parameters or returns");
}

fn classifyNominal(active: *session.Session, key: abi.AbiTypeKey, type_layout: layout.LayoutResult) !abi.AbiTypeResult {
    if (type_layout.foreign_stable) {
        return switch (type_layout.storage) {
            .@"struct", .@"union", .@"enum" => abi.classifiedTypeResult(active.allocator, key, type_layout, true, true, true, .direct, null),
            else => abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "nominal type has no C aggregate layout"),
        };
    }
    return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "nominal type is not foreign-stable");
}

fn classifyCallableType(
    active: *session.Session,
    key: abi.AbiTypeKey,
    type_layout: layout.LayoutResult,
    callable: types.CallableType,
    resolvers: Resolvers,
) !abi.AbiTypeResult {
    if ((key.family == .c and callable.abi != .c) or (key.family == .system and callable.abi != .system)) {
        return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "foreign function pointer convention does not match ABI family");
    }
    if (callable.variadic_tail != null) {
        return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "variadic callback classification is not implemented");
    }
    for (callable.parameters) |parameter| {
        const parameter_type = try resolvers.abi_type_for_key(active, .{
            .type_id = parameter.ty,
            .target_name = key.target_name,
            .family = key.family,
        });
        if (!parameter_type.passable) {
            return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "foreign function pointer parameter is not passable");
        }
    }
    const return_type = try resolvers.abi_type_for_key(active, .{
        .type_id = callable.return_type,
        .target_name = key.target_name,
        .family = key.family,
    });
    if (!return_type.returnable) {
        return abi.classifiedTypeResult(active.allocator, key, type_layout, false, false, false, .forbidden, "foreign function pointer return type is not returnable");
    }
    return abi.classifiedTypeResult(active.allocator, key, type_layout, true, true, true, .direct, null);
}

fn buildItemCallable(
    active: *session.Session,
    key: abi.AbiCallableKey,
    item_id: session.ItemId,
    resolvers: Resolvers,
) !abi.AbiCallableResult {
    const checked = try resolvers.checked_signature(active, item_id);
    const function = switch (checked.facts) {
        .function => |function| function,
        else => return abi.unsupportedCallableResult(active.allocator, key, "ABI callable subject is not a function"),
    };

    var params = array_list.Managed(abi.AbiParameterResult).init(active.allocator);
    defer params.deinit();
    errdefer deinitValueItems(active.allocator, params.items);
    var diagnostics = array_list.Managed(abi.AbiDiagnostic).init(active.allocator);
    defer diagnostics.deinit();
    errdefer deinitDiagnosticItems(active.allocator, diagnostics.items);

    var callable_safe = true;
    const variadic_tail_index = variadicTailIndex(function);
    if (!function.foreign) {
        if (variadic_tail_index) |_| {
            callable_safe = false;
            try appendDiagnostic(active.allocator, &diagnostics, "abi.c.variadic.foreign", "variadic tails are valid only on foreign declarations");
        }
        var result_key = try abi.cloneAbiCallableKey(active.allocator, key);
        errdefer abi.deinitAbiCallableKey(active.allocator, &result_key);
        const diagnostic_slice = try diagnostics.toOwnedSlice();
        errdefer deinitDiagnostics(active.allocator, diagnostic_slice);
        return .{
            .key = result_key,
            .callable_safe = callable_safe,
            .variadic = variadic_tail_index != null,
            .callback = key.role == .callback,
            .diagnostics = diagnostic_slice,
            .reason = if (callable_safe) null else try active.allocator.dupe(u8, "ABI callable is not safe for the requested family"),
        };
    }
    if (!conventionMatches(key.family, function.abi)) {
        callable_safe = false;
        try appendDiagnostic(active.allocator, &diagnostics, "abi.c.convention", "unsupported foreign calling convention");
    }
    if (variadic_tail_index) |tail_index| {
        const tail = function.parameters[tail_index];
        if (!std.mem.eql(u8, tail.name, "...args") or !tail.ty.isNamed(c_va_list.type_name)) {
            callable_safe = false;
            try appendDiagnostic(active.allocator, &diagnostics, "abi.c.variadic.tail", "variadic foreign declarations must end with '...args: CVaList'");
        }
        if (tail_index == 0) {
            callable_safe = false;
            try appendDiagnostic(active.allocator, &diagnostics, "abi.c.variadic.fixed", "stage0 variadic foreign declarations require at least one fixed parameter");
        }
        if (!checked.item.is_unsafe) {
            callable_safe = false;
            try appendDiagnostic(active.allocator, &diagnostics, "abi.c.variadic.unsafe", "variadic foreign declarations must be #unsafe");
        }
    }
    if (checked.item.has_body and function.export_name == null) {
        callable_safe = false;
        try appendDiagnostic(active.allocator, &diagnostics, "abi.c.export.missing", "foreign declarations with bodies require explicit #export[...] symbols");
    }
    if (!checked.item.has_body and !checked.item.is_unsafe) {
        callable_safe = false;
        try appendDiagnostic(active.allocator, &diagnostics, "abi.c.import.unsafe", "imported foreign declarations must be #unsafe");
    }

    for (function.parameters, 0..) |parameter, index| {
        if (variadic_tail_index != null and index == variadic_tail_index.?) continue;
        const parameter_type = try canonicalTypeFromSyntaxOrRef(
            active,
            checked.module_id,
            parameter.type_syntax,
            parameter.ty,
            resolvers,
        );
        const parameter_abi = try resolvers.abi_type_for_key(active, .{
            .type_id = parameter_type,
            .target_name = key.target_name,
            .family = key.family,
        });
        var passable = parameter_abi.passable;
        switch (parameter.mode) {
            .owned, .take => {},
            .read, .edit => {
                passable = false;
                callable_safe = false;
                try appendDiagnostic(active.allocator, &diagnostics, "abi.c.param_mode", "foreign parameters must be owned/take values");
            },
        }
        if (!passable) {
            callable_safe = false;
            try appendDiagnostic(active.allocator, &diagnostics, "abi.c.param_type", "foreign parameter type is not passable");
        }
        try appendValueResult(active.allocator, &params, parameter_type, parameter_abi.safe, passable, parameter_abi.returnable, parameter_abi.pass_mode, parameter_abi.reason);
    }

    const return_type = try canonicalTypeFromSyntaxOrRef(
        active,
        checked.module_id,
        function.return_type_syntax,
        function.return_type,
        resolvers,
    );
    const return_abi = try resolvers.abi_type_for_key(active, .{
        .type_id = return_type,
        .target_name = key.target_name,
        .family = key.family,
    });
    if (key.role == .foreign_export and isResultCanonicalType(active, return_type)) {
        callable_safe = false;
        try appendDiagnostic(active.allocator, &diagnostics, "abi.c.export.failure", "exported foreign functions cannot expose Result failure across the C ABI; translate explicitly or abort loudly");
    }
    if (!return_abi.returnable) {
        callable_safe = false;
        try appendDiagnostic(active.allocator, &diagnostics, "abi.c.return", "foreign return type is not returnable");
    }
    const return_value = try cloneValueResult(active.allocator, return_type, return_abi.safe, return_abi.passable, return_abi.returnable, return_abi.pass_mode, return_abi.reason);
    errdefer deinitValueResult(active.allocator, return_value);

    var result_key = try abi.cloneAbiCallableKey(active.allocator, key);
    errdefer abi.deinitAbiCallableKey(active.allocator, &result_key);
    const param_slice = try params.toOwnedSlice();
    errdefer deinitValueResults(active.allocator, param_slice);
    const diagnostic_slice = try diagnostics.toOwnedSlice();
    errdefer deinitDiagnostics(active.allocator, diagnostic_slice);

    return .{
        .key = result_key,
        .callable_safe = callable_safe,
        .params = param_slice,
        .return_value = return_value,
        .variadic = variadic_tail_index != null,
        .callback = key.role == .callback,
        .no_unwind = key.role == .foreign_import or key.role == .foreign_export or key.role == .callback,
        .failure_policy = if (key.role == .foreign_export) .abort_untranslated_failure else .none,
        .diagnostics = diagnostic_slice,
        .reason = if (callable_safe) null else try active.allocator.dupe(u8, "ABI callable is not safe for the requested family"),
    };
}

fn buildStructuralCallable(
    active: *session.Session,
    key: abi.AbiCallableKey,
    type_id: types.CanonicalTypeId,
    resolvers: Resolvers,
) !abi.AbiCallableResult {
    const type_result = try resolvers.abi_type_for_key(active, .{
        .type_id = type_id,
        .target_name = key.target_name,
        .family = key.family,
    });
    if (!type_result.safe) {
        return abi.unsupportedCallableResult(active.allocator, key, type_result.reason orelse "callable type is not safe for ABI family");
    }
    var result_key = try abi.cloneAbiCallableKey(active.allocator, key);
    errdefer abi.deinitAbiCallableKey(active.allocator, &result_key);
    return .{
        .key = result_key,
        .callable_safe = true,
        .callback = true,
        .no_unwind = true,
    };
}

fn canonicalTypeFromSyntaxOrRef(
    active: *session.Session,
    module_id: session.ModuleId,
    type_syntax: ?ast.TypeSyntax,
    ty: types.TypeRef,
    resolvers: Resolvers,
) !types.CanonicalTypeId {
    if (type_syntax) |syntax_value| return resolvers.canonical_type_syntax(active, module_id, syntax_value);
    return resolvers.canonical_type_ref(active, module_id, ty);
}

fn isResultCanonicalType(active: *const session.Session, type_id: types.CanonicalTypeId) bool {
    return standard_families.familyForCanonicalType(active, type_id) == .result;
}

fn appendValueResult(
    allocator: std.mem.Allocator,
    values: *array_list.Managed(abi.AbiParameterResult),
    type_id: types.CanonicalTypeId,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: abi.PassMode,
    reason: ?[]const u8,
) !void {
    const value = try cloneValueResult(allocator, type_id, safe, passable, returnable, pass_mode, reason);
    errdefer deinitValueResult(allocator, value);
    try values.append(value);
}

fn cloneValueResult(
    allocator: std.mem.Allocator,
    type_id: types.CanonicalTypeId,
    safe: bool,
    passable: bool,
    returnable: bool,
    pass_mode: abi.PassMode,
    reason: ?[]const u8,
) !abi.AbiValueResult {
    return .{
        .type_id = type_id,
        .safe = safe,
        .passable = passable,
        .returnable = returnable,
        .pass_mode = pass_mode,
        .reason = if (reason) |value| try allocator.dupe(u8, value) else null,
    };
}

fn deinitValueResults(allocator: std.mem.Allocator, values: []const abi.AbiValueResult) void {
    deinitValueItems(allocator, values);
    if (values.len != 0) allocator.free(values);
}

fn deinitValueItems(allocator: std.mem.Allocator, values: []const abi.AbiValueResult) void {
    for (values) |value| deinitValueResult(allocator, value);
}

fn deinitValueResult(allocator: std.mem.Allocator, value: abi.AbiValueResult) void {
    if (value.reason) |reason| allocator.free(reason);
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *array_list.Managed(abi.AbiDiagnostic),
    code: []const u8,
    message: []const u8,
) !void {
    const owned_code = try allocator.dupe(u8, code);
    errdefer allocator.free(owned_code);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try diagnostics.append(.{
        .code = owned_code,
        .message = owned_message,
    });
}

fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []const abi.AbiDiagnostic) void {
    deinitDiagnosticItems(allocator, diagnostics);
    if (diagnostics.len != 0) allocator.free(diagnostics);
}

fn deinitDiagnosticItems(allocator: std.mem.Allocator, diagnostics: []const abi.AbiDiagnostic) void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.code.len != 0) allocator.free(diagnostic.code);
        if (diagnostic.message.len != 0) allocator.free(diagnostic.message);
    }
}

fn conventionMatches(family: abi.AbiFamily, convention: ?[]const u8) bool {
    const value = convention orelse return false;
    return switch (family) {
        .c => std.mem.eql(u8, value, "c"),
        .system => std.mem.eql(u8, value, "system"),
    };
}

fn variadicTailIndex(function: query_types.FunctionSignature) ?usize {
    if (function.parameters.len == 0) return null;
    const last_index = function.parameters.len - 1;
    const last = function.parameters[last_index];
    if (std.mem.startsWith(u8, last.name, "...") or last.ty.isNamed(c_va_list.type_name)) return last_index;
    return null;
}
