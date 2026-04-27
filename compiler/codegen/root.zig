const std = @import("std");
const array_list = std.array_list;
const c_va_list = @import("../abi/c/va_list.zig");
const backend_contract = @import("../backend_contract/root.zig");
const diag = @import("../diag/root.zig");
const runtime = @import("../runtime/root.zig");
const dynamic_library = runtime.dynamic_library;
const raw_pointer = @import("../raw_pointer/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;
const program = backend_contract.program;

pub const summary = "Backend-contract lowering to the stage0 C backend.";
pub const backend = "c";

pub const OutputKind = enum {
    bin,
    cdylib,
};

pub fn emitCModule(
    allocator: Allocator,
    product_name: []const u8,
    lowered_module: *const backend_contract.LoweredModule,
    kind: OutputKind,
    diagnostics: *diag.Bag,
) ![]const u8 {
    const module = if (lowered_module.program) |*program_descriptors| program_descriptors else {
        try diagnostics.add(.@"error", "codegen.contract.program", null, "backend contract is missing lowered program descriptors", .{});
        return error.CodegenFailed;
    };

    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("/* stage0 generated C backend for product: ");
    try out.appendSlice(product_name);
    try out.appendSlice(" */\n");
    try out.appendSlice("#include <stdarg.h>\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <stdlib.h>\n\n");
    try out.appendSlice("#if defined(_WIN32)\n#define RUNA_EXPORT __declspec(dllexport)\n#else\n#define RUNA_EXPORT\n#endif\n\n");
    const abort_support = try runtime.abort.renderAbortSupport(allocator);
    defer allocator.free(abort_support);
    try out.appendSlice(abort_support);
    if (runtimeRequirementEnabled(lowered_module, .dynamic_library_hooks)) {
        const dynamic_support = try dynamic_library.renderSupport(allocator);
        defer allocator.free(dynamic_support);
        try out.appendSlice(dynamic_support);
    }

    try emitNominalDefinitions(allocator, &out, module, diagnostics);
    if (hasNominalItems(module)) try out.appendSlice("\n");

    for (module.items.items) |item| {
        switch (item.payload) {
            .const_item => |const_item| try emitConstDefinition(allocator, &out, module, &item, &const_item, diagnostics),
            else => {},
        }
    }
    if (hasConstItems(module)) try out.appendSlice("\n");

    for (module.items.items) |item| {
        switch (item.payload) {
            .function => |function| try emitFunctionPrototype(allocator, &out, lowered_module, module, &item, &function, diagnostics),
            else => {},
        }
    }

    if (hasFunctionItems(module)) try out.appendSlice("\n");

    for (module.items.items) |item| {
        switch (item.payload) {
            .function => |function| try emitFunctionDefinition(allocator, &out, lowered_module, module, &item, &function, diagnostics),
            else => {},
        }
    }

    switch (kind) {
        .bin => try emitMainWrapper(allocator, &out, lowered_module, module, diagnostics),
        .cdylib => {},
    }

    return out.toOwnedSlice();
}

fn emitConstDefinition(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    item: *const program.Item,
    const_item: *const program.ConstData,
    diagnostics: *diag.Bag,
) !void {
    try out.appendSlice("static const ");
    try emitValueTypeName(out, module, const_item.type_ref, diagnostics, item.span);
    try out.appendSlice(" ");
    try appendConstSymbol(out, item.symbol_name);
    try out.appendSlice(" = ");
    try emitConstExpr(allocator, out, module, const_item.expr, diagnostics, item.span);
    try out.appendSlice(";\n");
}

fn emitConstExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    expr: *const program.ConstExpr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    switch (expr.node) {
        .literal => |value| try emitConstValue(allocator, out, value, diagnostics, span),
        .const_ref => |name| {
            if (findConstItem(module, name)) |target| {
                try appendConstSymbol(out, target.symbol_name);
            } else if (findImportedConst(module, name)) |binding| {
                try appendConstSymbol(out, binding.target_symbol);
            } else {
                try diagnostics.add(.@"error", "codegen.const.ref", span, "stage0 const initializer references unknown const '{s}'", .{name});
                return error.CodegenFailed;
            }
        },
        .associated_const_ref => return emitUnsupportedConstExpr(diagnostics, span, "associated const reference"),
        .enum_variant,
        .enum_tag,
        .enum_construct,
        => return emitUnsupportedConstExpr(diagnostics, span, "enum const expression"),
        .constructor => |constructor| {
            try out.appendSlice("{");
            for (constructor.args, 0..) |arg, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitConstExpr(allocator, out, module, arg, diagnostics, span);
            }
            try out.appendSlice("}");
        },
        .field => |field| {
            try out.appendSlice("(");
            try emitConstExpr(allocator, out, module, field.base, diagnostics, span);
            try out.appendSlice(".");
            try out.appendSlice(field.field_name);
            try out.appendSlice(")");
        },
        .array => |array| {
            try out.appendSlice("{");
            for (array.items, 0..) |item, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitConstExpr(allocator, out, module, item, diagnostics, span);
            }
            try out.appendSlice("}");
        },
        .array_repeat => return emitUnsupportedConstExpr(diagnostics, span, "array repetition const expression"),
        .index => |index| {
            try out.appendSlice("(");
            try emitConstExpr(allocator, out, module, index.base, diagnostics, span);
            try out.appendSlice("[");
            try emitConstExpr(allocator, out, module, index.index, diagnostics, span);
            try out.appendSlice("])");
        },
        .conversion => |conversion| {
            if (conversion.mode == .explicit_checked) return emitUnsupportedConstExpr(diagnostics, span, "checked conversion const expression");
            try out.appendSlice("((");
            try out.appendSlice(backend_contract.cBuiltinTypeName(conversion.target_type));
            try out.appendSlice(")");
            try emitConstExpr(allocator, out, module, conversion.operand, diagnostics, span);
            try out.appendSlice(")");
        },
        .unary => |unary| {
            try out.appendSlice("(");
            try out.appendSlice(switch (unary.op) {
                .bool_not => "!",
                .negate => "-",
                .bit_not => "~",
            });
            try emitConstExpr(allocator, out, module, unary.operand, diagnostics, span);
            try out.appendSlice(")");
        },
        .binary => |binary| {
            try out.appendSlice("(");
            try emitConstExpr(allocator, out, module, binary.lhs, diagnostics, span);
            try out.appendSlice(" ");
            try out.appendSlice(switch (binary.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .mod => "%",
                .shl => "<<",
                .shr => ">>",
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .lte => "<=",
                .gt => ">",
                .gte => ">=",
                .bit_and => "&",
                .bit_xor => "^",
                .bit_or => "|",
                .bool_and => "&&",
                .bool_or => "||",
            });
            try out.appendSlice(" ");
            try emitConstExpr(allocator, out, module, binary.rhs, diagnostics, span);
            try out.appendSlice(")");
        },
    }
}

fn emitUnsupportedConstExpr(diagnostics: *diag.Bag, span: ?source.Span, label: []const u8) anyerror!void {
    try diagnostics.add(.@"error", "codegen.const.expr", span, "C codegen does not support {s}", .{label});
    return error.CodegenFailed;
}

fn emitConstValue(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    value: program.ConstValue,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    switch (value) {
        .bool => |bool_value| try out.appendSlice(if (bool_value) "true" else "false"),
        .i32 => |int_value| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{int_value});
            defer allocator.free(rendered);
            try out.appendSlice(rendered);
        },
        .u32 => |int_value| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{int_value});
            defer allocator.free(rendered);
            try out.appendSlice(rendered);
        },
        .index => |int_value| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{int_value});
            defer allocator.free(rendered);
            try out.appendSlice(rendered);
        },
        .str => |string_value| try appendEscapedCString(out, string_value),
        .array,
        .aggregate,
        .enum_value,
        .unit,
        .unsupported,
        => {
            try diagnostics.add(.@"error", "codegen.const.literal", span, "stage0 const initializer uses an unsupported literal", .{});
            return error.CodegenFailed;
        },
    }
}

fn emitFunctionPrototype(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    lowered: *const backend_contract.LoweredModule,
    module: *const program.Module,
    item: *const program.Item,
    function: *const program.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    const linkage = functionLinkage(lowered, item.name);
    if (linkage == .foreign_import) {
        try out.appendSlice("extern ");
    } else if (linkage == .foreign_export) {
        try out.appendSlice("RUNA_EXPORT ");
    } else {
        try out.appendSlice("static ");
    }

    try emitValueTypeName(out, module, function.return_type, diagnostics, item.span);
    try out.appendSlice(" ");
    try appendFunctionSymbol(out, item, linkage);
    try out.appendSlice("(");
    try emitParameterList(allocator, out, module, function, diagnostics, item.span);
    try out.appendSlice(");\n");
}

fn emitFunctionDefinition(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    lowered: *const backend_contract.LoweredModule,
    module: *const program.Module,
    item: *const program.Item,
    function: *const program.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    const linkage = functionLinkage(lowered, item.name);
    if (linkage == .foreign_import) return;

    if (linkage == .foreign_export) {
        try out.appendSlice("RUNA_EXPORT ");
    } else {
        try out.appendSlice("static ");
    }
    try emitValueTypeName(out, module, function.return_type, diagnostics, item.span);
    try out.appendSlice(" ");
    try appendFunctionSymbol(out, item, linkage);
    try out.appendSlice("(");
    try emitParameterList(allocator, out, module, function, diagnostics, item.span);
    try out.appendSlice(") {\n");
    try emitVariadicPrelude(out, function);
    try emitBlockStatements(allocator, out, module, &function.body, function.parameters, &.{}, &.{}, false, diagnostics, item.span, 1);
    try out.appendSlice("}\n\n");
}

fn emitVariadicPrelude(out: *array_list.Managed(u8), function: *const program.FunctionData) !void {
    const tail_index = variadicTailIndex(function) orelse return;
    if (tail_index == 0) return;
    const tail = function.parameters[tail_index];
    const local_name = c_va_list.localName(tail.name);
    const anchor = function.parameters[tail_index - 1].name;
    try out.appendSlice("    va_list ");
    try out.appendSlice(local_name);
    try out.appendSlice(";\n    va_start(");
    try out.appendSlice(local_name);
    try out.appendSlice(", ");
    try out.appendSlice(anchor);
    try out.appendSlice(");\n");
}

fn emitMainWrapper(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    lowered: *const backend_contract.LoweredModule,
    module: *const program.Module,
    diagnostics: *diag.Bag,
) !void {
    const entry = findNamedFunction(module, "main") orelse {
        try diagnostics.add(.@"error", "codegen.main.missing", null, "bin products require a top-level 'main' function", .{});
        return error.CodegenFailed;
    };

    const item = entry.item;
    const function = entry.function;
    if (function.is_suspend) {
        try diagnostics.add(.@"error", "codegen.main.suspend", item.span, "stage0 bin entry 'main' must be an ordinary function; suspend entry requires an explicit runtime adapter", .{});
        return error.CodegenFailed;
    }
    if (function.parameters.len != 0) {
        try diagnostics.add(.@"error", "codegen.main.params", item.span, "stage0 entry 'main' must not take parameters", .{});
        return error.CodegenFailed;
    }

    const wrapper_return_type = function.return_type.builtin orelse {
        try diagnostics.add(.@"error", "codegen.main.return", item.span, "stage0 entry 'main' must return Unit or I32", .{});
        return error.CodegenFailed;
    };
    switch (wrapper_return_type) {
        .unit, .i32 => {},
        else => {
            try diagnostics.add(.@"error", "codegen.main.return", item.span, "stage0 entry 'main' must return Unit or I32", .{});
            return error.CodegenFailed;
        },
    }

    var symbol = array_list.Managed(u8).init(allocator);
    defer symbol.deinit();
    try appendFunctionSymbol(&symbol, item, functionLinkage(lowered, item.name));
    const wrapper = try runtime.entry.renderMainWrapper(allocator, symbol.items, wrapper_return_type);
    defer allocator.free(wrapper);
    try out.appendSlice(wrapper);
}

fn emitParameterList(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    function: *const program.FunctionData,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    _ = allocator;
    const tail_index = variadicTailIndex(function);
    var emitted_count: usize = 0;
    for (function.parameters, 0..) |parameter, index| {
        if (tail_index != null and index == tail_index.?) continue;
        if (emitted_count != 0) try out.appendSlice(", ");
        if (isCallableValueType(parameter.ty)) {
            try emitCallableDeclarator(out, parameter.ty, parameter.name);
            emitted_count += 1;
            continue;
        }
        try emitParameterTypeName(out, module, parameter, diagnostics, span);
        try out.appendSlice(" ");
        try out.appendSlice(parameter.name);
        emitted_count += 1;
    }
    if (tail_index != null) {
        if (emitted_count != 0) try out.appendSlice(", ");
        try out.appendSlice("...");
    } else if (emitted_count == 0) {
        try out.appendSlice("void");
    }
}

fn variadicTailIndex(function: *const program.FunctionData) ?usize {
    if (function.parameters.len == 0) return null;
    const last_index = function.parameters.len - 1;
    const last = function.parameters[last_index];
    if (std.mem.startsWith(u8, last.name, "...")) return last_index;
    return null;
}

fn emitParameterTypeName(
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter: program.Parameter,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    try emitValueTypeName(out, module, parameter.ty, diagnostics, span);
    switch (parameter.mode) {
        .read, .edit => try out.appendSlice("*"),
        .owned, .take => {},
    }
}

fn isBorrowParameter(parameters: []const program.Parameter, name: []const u8) bool {
    for (parameters) |parameter| {
        if (!std.mem.eql(u8, parameter.name, name)) continue;
        return switch (parameter.mode) {
            .read, .edit => true,
            .owned, .take => false,
        };
    }
    return false;
}

fn emitBorrowArgument(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    expr: *const program.Expr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    switch (expr.node) {
        .identifier => |name| {
            if (findConstItem(module, name) != null or findImportedConst(module, name) != null) {
                try diagnostics.add(.@"error", "codegen.call.borrow_const", span, "borrow arguments must come from addressable locals or fields in stage0", .{});
                return error.CodegenFailed;
            }
            if (isBorrowParameter(parameter_context, name)) {
                try out.appendSlice(name);
            } else {
                try out.appendSlice("&");
                try out.appendSlice(name);
            }
        },
        .field, .index => {
            try out.appendSlice("&(");
            try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
            try out.appendSlice(")");
        },
        else => {
            try diagnostics.add(.@"error", "codegen.call.borrow_arg", span, "borrow arguments must be plain locals, fields, or array element projections in stage0", .{});
            return error.CodegenFailed;
        },
    }
}

fn emitRenderedAssignTarget(out: *array_list.Managed(u8), rendered_name: []const u8, parameter_context: []const program.Parameter) !void {
    if (std.mem.indexOfScalar(u8, rendered_name, '.')) |dot_index| {
        const base_name = rendered_name[0..dot_index];
        if (isBorrowParameter(parameter_context, base_name)) {
            try out.appendSlice("((*");
            try out.appendSlice(base_name);
            try out.appendSlice(").");
            try out.appendSlice(rendered_name[dot_index + 1 ..]);
            try out.appendSlice(")");
            return;
        }
    } else if (isBorrowParameter(parameter_context, rendered_name)) {
        try out.appendSlice("(*");
        try out.appendSlice(rendered_name);
        try out.appendSlice(")");
        return;
    }
    try out.appendSlice(rendered_name);
}

fn isCVaListCopyExpr(expr: *const program.Expr) bool {
    return switch (expr.node) {
        .call => |call| std.mem.eql(u8, call.callee, c_va_list.copy_callee),
        else => false,
    };
}

fn emitCVaListCopyBinding(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    ty: program.ValueType,
    name: []const u8,
    expr: *const program.Expr,
    parameter_context: []const program.Parameter,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) !bool {
    if (ty.kind != .c_va_list) return false;
    if (!isCVaListCopyExpr(expr)) return false;
    const call = expr.node.call;
    if (call.args.len != 1) {
        try diagnostics.add(.@"error", "codegen.valist.copy_arity", span, "CVaList.copy expects one source list", .{});
        return error.CodegenFailed;
    }
    try appendIndent(out, indent_level);
    try out.appendSlice("va_list ");
    try out.appendSlice(name);
    try out.appendSlice(";\n");
    try appendIndent(out, indent_level);
    try out.appendSlice("va_copy(");
    try out.appendSlice(name);
    try out.appendSlice(", ");
    try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
    try out.appendSlice(");\n");
    return true;
}

fn isCallableValueType(ty: program.ValueType) bool {
    return ty.callable != null;
}

fn emitCallableDeclarator(
    out: *array_list.Managed(u8),
    ty: program.ValueType,
    name: []const u8,
) !void {
    const callable = ty.callable orelse return error.CodegenFailed;
    try emitValueTypeName(out, null, callable.return_type.*, null, null);
    try out.appendSlice(" (*");
    try out.appendSlice(name);
    try out.appendSlice(")(");
    try emitCallableParameterList(out, callable);
    try out.appendSlice(")");
}

fn emitCallableCast(
    out: *array_list.Managed(u8),
    ty: program.ValueType,
) !bool {
    const callable = ty.callable orelse return false;
    try out.appendSlice("((");
    try emitValueTypeName(out, null, callable.return_type.*, null, null);
    try out.appendSlice(" (*)(");
    try emitCallableParameterList(out, callable);
    try out.appendSlice("))");
    return true;
}

fn emitCallableBindingDecl(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    ty: program.ValueType,
    name: []const u8,
    expr: *const program.Expr,
    is_const: bool,
    parameter_context: []const program.Parameter,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) !bool {
    if (!isCallableValueType(ty)) return false;
    try appendIndent(out, indent_level);
    const rendered_name = if (is_const) try std.fmt.allocPrint(allocator, "const {s}", .{name}) else name;
    defer if (is_const) allocator.free(rendered_name);
    try emitCallableDeclarator(out, ty, rendered_name);
    try out.appendSlice(" = ");
    try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
    try out.appendSlice(";\n");
    return true;
}

fn emitCallableParameterList(
    out: *array_list.Managed(u8),
    callable: program.CallableType,
) !void {
    if (callable.parameters.len == 0 and !callable.variadic) {
        try out.appendSlice("void");
        return;
    }
    for (callable.parameters, 0..) |parameter_type, index| {
        if (index != 0) try out.appendSlice(", ");
        try emitValueTypeName(out, null, parameter_type, null, null);
    }
    if (callable.variadic) {
        if (callable.parameters.len != 0) try out.appendSlice(", ");
        try out.appendSlice("...");
    }
}

fn emitCVaListOperationExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    expr: *const program.Expr,
    call: program.Expr.Call,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    if (std.mem.eql(u8, call.callee, c_va_list.next_callee)) {
        if (call.args.len != 1) {
            try diagnostics.add(.@"error", "codegen.valist.next_arity", span, "CVaList.next expects one source list", .{});
            return error.CodegenFailed;
        }
        try out.appendSlice("va_arg(");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(", ");
        try emitValueTypeName(out, module, expr.ty, diagnostics, span);
        try out.appendSlice(")");
        return;
    }
    if (std.mem.eql(u8, call.callee, c_va_list.finish_callee)) {
        if (call.args.len != 1) {
            try diagnostics.add(.@"error", "codegen.valist.finish_arity", span, "CVaList.finish expects one source list", .{});
            return error.CodegenFailed;
        }
        try out.appendSlice("va_end(");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(")");
        return;
    }
    try diagnostics.add(.@"error", "codegen.valist.copy_expr", span, "CVaList.copy must bind to a local in stage0", .{});
    return error.CodegenFailed;
}

fn emitDynamicLibraryExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    expr: *const program.Expr,
    call: program.Expr.Call,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!bool {
    if (!dynamic_library.isLeafCallee(call.callee)) return false;

    if (std.mem.eql(u8, call.callee, dynamic_library.lookup_callee)) {
        if (call.args.len != 2) {
            try diagnostics.add(.@"error", "codegen.dynamic.lookup_arity", span, "lookup_symbol expects a library and symbol name", .{});
            return error.CodegenFailed;
        }
        if (!try emitCallableCast(out, expr.ty)) {
            if (expr.ty.kind == .raw_pointer) {
                try out.appendSlice("((");
                try emitValueTypeName(out, module, expr.ty, diagnostics, span);
                try out.appendSlice(")");
            } else {
                try diagnostics.add(.@"error", "codegen.dynamic.lookup_type", span, "lookup_symbol result must be a foreign function pointer or raw pointer", .{});
                return error.CodegenFailed;
            }
        }
        try out.appendSlice(dynamic_library.lookup_callee);
        try out.appendSlice("(");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(", ");
        try emitExpr(allocator, out, module, parameter_context, call.args[1], false, diagnostics, span);
        try out.appendSlice(")");
        try out.appendSlice(")");
        return true;
    }

    try out.appendSlice(call.callee);
    try out.appendSlice("(");
    for (call.args, 0..) |arg, index| {
        if (index != 0) try out.appendSlice(", ");
        try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
    }
    try out.appendSlice(")");
    return true;
}

fn emitRawPointerExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    expr: *const program.Expr,
    call: program.Expr.Call,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!bool {
    if (!raw_pointer.isLeafCallee(call.callee)) return false;
    if (std.mem.eql(u8, call.callee, raw_pointer.address_read_callee) or
        std.mem.eql(u8, call.callee, raw_pointer.address_edit_callee))
    {
        if (call.args.len != 1) {
            try diagnostics.add(.@"error", "codegen.raw_pointer.address_arity", span, "raw pointer formation expects one place", .{});
            return error.CodegenFailed;
        }
        try out.appendSlice("(&");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(")");
        return true;
    }
    if (std.mem.eql(u8, call.callee, raw_pointer.is_null_callee)) {
        if (call.args.len != 1) return error.CodegenFailed;
        try out.appendSlice("(");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(" == NULL)");
        return true;
    }
    if (std.mem.eql(u8, call.callee, raw_pointer.cast_callee)) {
        if (call.args.len != 1) return error.CodegenFailed;
        try out.appendSlice("((");
        try emitValueTypeName(out, module, expr.ty, diagnostics, span);
        try out.appendSlice(")");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(")");
        return true;
    }
    if (std.mem.eql(u8, call.callee, raw_pointer.offset_callee)) {
        if (call.args.len != 2) return error.CodegenFailed;
        try out.appendSlice("(");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(" + ");
        try emitExpr(allocator, out, module, parameter_context, call.args[1], false, diagnostics, span);
        try out.appendSlice(")");
        return true;
    }
    if (std.mem.eql(u8, call.callee, raw_pointer.load_callee)) {
        if (call.args.len != 1) return error.CodegenFailed;
        try out.appendSlice("(*");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(")");
        return true;
    }
    if (std.mem.eql(u8, call.callee, raw_pointer.store_callee)) {
        if (call.args.len != 2) return error.CodegenFailed;
        try out.appendSlice("(*");
        try emitExpr(allocator, out, module, parameter_context, call.args[0], false, diagnostics, span);
        try out.appendSlice(" = ");
        try emitExpr(allocator, out, module, parameter_context, call.args[1], false, diagnostics, span);
        try out.appendSlice(")");
        return true;
    }
    return false;
}

fn emitExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    expr: *const program.Expr,
    global_const_context: bool,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    switch (expr.node) {
        .integer => |value| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(rendered);
            try out.appendSlice(rendered);
        },
        .bool_lit => |value| try out.appendSlice(if (value) "true" else "false"),
        .string => |value| try appendEscapedCString(out, value),
        .identifier => |name| {
            if (isCallableValueType(expr.ty)) {
                if (findNamedFunction(module, name)) |target| {
                    try appendFunctionSymbol(out, target.item, target.function.linkage);
                    return;
                }
                if (findImportedFunction(module, name)) |binding| {
                    try appendFunctionSymbolName(out, binding.target_symbol);
                    return;
                }
            }
            if (findConstItem(module, name) != null) {
                try appendConstSymbol(out, findConstItem(module, name).?.symbol_name);
            } else if (findImportedConst(module, name)) |binding| {
                try appendConstSymbol(out, binding.target_symbol);
            } else if (isBorrowParameter(parameter_context, name)) {
                try out.appendSlice("(*");
                try out.appendSlice(name);
                try out.appendSlice(")");
            } else {
                try out.appendSlice(name);
            }
        },
        .enum_variant => |value| try emitEnumValueLiteral(allocator, out, module, parameter_context, value.enum_symbol, value.variant_name, null, diagnostics, span),
        .enum_tag => |value| try appendEnumVariantTagName(out, value.enum_symbol, value.variant_name),
        .enum_constructor_target => {
            try diagnostics.add(.@"error", "codegen.enum.ctor_target", span, "internal stage0 error: enum constructor target reached codegen", .{});
            return error.CodegenFailed;
        },
        .enum_construct => |construct| try emitEnumValueLiteral(allocator, out, module, parameter_context, construct.enum_symbol, construct.variant_name, construct.args, diagnostics, span),
        .constructor => |constructor| {
            if (global_const_context) {
                try diagnostics.add(.@"error", "codegen.const.constructor", span, "stage0 const initializers do not support constructor expressions in generated C", .{});
                return error.CodegenFailed;
            }
            try out.appendSlice("((");
            try appendStructTypeName(out, constructor.type_symbol);
            try out.appendSlice("){");
            for (constructor.args, 0..) |arg, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
            }
            try out.appendSlice("})");
        },
        .field => |field| {
            try out.appendSlice("(");
            try emitExpr(allocator, out, module, parameter_context, field.base, global_const_context, diagnostics, span);
            try out.appendSlice(".");
            try out.appendSlice(field.field_name);
            try out.appendSlice(")");
        },
        .tuple => {
            try diagnostics.add(.@"error", "codegen.tuple.expr", span, "stage0 C codegen does not emit tuple expressions yet", .{});
            return error.CodegenFailed;
        },
        .array => |array| {
            try out.appendSlice("{");
            for (array.items, 0..) |item, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitExpr(allocator, out, module, parameter_context, item, global_const_context, diagnostics, span);
            }
            try out.appendSlice("}");
        },
        .array_repeat => {
            try diagnostics.add(.@"error", "codegen.array.repeat", span, "stage0 codegen does not emit array repetition expressions", .{});
            return error.CodegenFailed;
        },
        .index => |index| {
            try out.appendSlice("(");
            try emitExpr(allocator, out, module, parameter_context, index.base, global_const_context, diagnostics, span);
            try out.appendSlice("[");
            try emitExpr(allocator, out, module, parameter_context, index.index, global_const_context, diagnostics, span);
            try out.appendSlice("])");
        },
        .conversion => |conversion| {
            if (conversion.mode == .explicit_checked) {
                try diagnostics.add(.@"error", "codegen.conversion.checked", span, "stage0 codegen does not emit checked conversion expressions", .{});
                return error.CodegenFailed;
            }
            try out.appendSlice("((");
            try emitValueTypeName(out, module, conversion.target_type, diagnostics, span);
            try out.appendSlice(")");
            try emitExpr(allocator, out, module, parameter_context, conversion.operand, global_const_context, diagnostics, span);
            try out.appendSlice(")");
        },
        .unary => |unary| {
            try out.appendSlice("(");
            try out.appendSlice(switch (unary.op) {
                .bool_not => "!",
                .negate => "-",
                .bit_not => "~",
            });
            try emitExpr(allocator, out, module, parameter_context, unary.operand, global_const_context, diagnostics, span);
            try out.appendSlice(")");
        },
        .call => |call| {
            if (global_const_context) {
                try diagnostics.add(.@"error", "codegen.const.call", span, "stage0 const initializers do not support call expressions in generated C", .{});
                return error.CodegenFailed;
            }
            if (try emitDynamicLibraryExpr(allocator, out, module, parameter_context, expr, call, diagnostics, span)) {
                return;
            }
            if (try emitRawPointerExpr(allocator, out, module, parameter_context, expr, call, diagnostics, span)) {
                return;
            }
            if (c_va_list.isOperationCallee(call.callee)) {
                try emitCVaListOperationExpr(allocator, out, module, parameter_context, expr, call, diagnostics, span);
                return;
            }
            if (findNamedFunction(module, call.callee)) |target| {
                try appendFunctionSymbol(out, target.item, target.function.linkage);
                try out.appendSlice("(");
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try out.appendSlice(", ");
                    if (index < target.function.parameters.len) {
                        switch (target.function.parameters[index].mode) {
                            .read, .edit => try emitBorrowArgument(allocator, out, module, parameter_context, arg, diagnostics, span),
                            .owned, .take => try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span),
                        }
                    } else {
                        try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
                    }
                }
            } else if (findImportedFunction(module, call.callee)) |binding| {
                try appendFunctionSymbolName(out, binding.target_symbol);
                try out.appendSlice("(");
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try out.appendSlice(", ");
                    if (binding.function_parameter_modes) |modes| {
                        if (index < modes.len) {
                            switch (modes[index]) {
                                .read, .edit => try emitBorrowArgument(allocator, out, module, parameter_context, arg, diagnostics, span),
                                .owned, .take => try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span),
                            }
                        } else {
                            try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
                        }
                    } else {
                        try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
                    }
                }
            } else {
                try out.appendSlice(call.callee);
                try out.appendSlice("(");
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try out.appendSlice(", ");
                    try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
                }
            }
            try out.appendSlice(")");
        },
        .binary => |binary| {
            try out.appendSlice("(");
            try emitExpr(allocator, out, module, parameter_context, binary.lhs, global_const_context, diagnostics, span);
            try out.appendSlice(" ");
            try out.appendSlice(switch (binary.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .mod => "%",
                .shl => "<<",
                .shr => ">>",
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .lte => "<=",
                .gt => ">",
                .gte => ">=",
                .bit_and => "&",
                .bit_xor => "^",
                .bit_or => "|",
                .bool_and => "&&",
                .bool_or => "||",
            });
            try out.appendSlice(" ");
            try emitExpr(allocator, out, module, parameter_context, binary.rhs, global_const_context, diagnostics, span);
            try out.appendSlice(")");
        },
    }
}

fn emitDeferredExprs(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    deferred: []const *const program.Expr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    var index = deferred.len;
    while (index > 0) {
        index -= 1;
        try out.appendSlice("    ");
        try emitExpr(allocator, out, module, parameter_context, deferred[index], false, diagnostics, span);
        try out.appendSlice(";\n");
    }
}

fn emitSelectStatement(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    select_data: *const program.Statement.SelectData,
    return_deferred: []const *const program.Expr,
    loop_deferred: []const *const program.Expr,
    in_loop: bool,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) anyerror!void {
    if (select_data.subject) |subject_expr| {
        if (select_data.subject_temp_name) |subject_temp_name| {
            try appendIndent(out, indent_level);
            try emitValueTypeName(out, module, subject_expr.ty, diagnostics, span);
            try out.appendSlice(" ");
            try out.appendSlice(subject_temp_name);
            try out.appendSlice(" = ");
            try emitExpr(allocator, out, module, parameter_context, subject_expr, false, diagnostics, span);
            try out.appendSlice(";\n");
        }
    }

    for (select_data.arms, 0..) |arm, index| {
        try appendIndent(out, indent_level);
        if (index == 0) {
            try out.appendSlice("if (");
        } else {
            try out.appendSlice("else if (");
        }
        try emitExpr(allocator, out, module, parameter_context, arm.condition, false, diagnostics, span);
        try out.appendSlice(") {\n");
        for (arm.bindings) |binding| {
            try appendIndent(out, indent_level + 1);
            try out.appendSlice("const ");
            try emitValueTypeName(out, module, binding.ty, diagnostics, span);
            try out.appendSlice(" ");
            try out.appendSlice(binding.name);
            try out.appendSlice(" = ");
            try emitExpr(allocator, out, module, parameter_context, binding.expr, false, diagnostics, span);
            try out.appendSlice(";\n");
        }
        try emitBlockStatements(allocator, out, module, arm.body, parameter_context, return_deferred, loop_deferred, in_loop, diagnostics, span, indent_level + 1);
        try appendIndent(out, indent_level);
        try out.appendSlice("}\n");
    }

    if (select_data.else_body) |else_body| {
        try appendIndent(out, indent_level);
        try out.appendSlice("else {\n");
        try emitBlockStatements(allocator, out, module, else_body, parameter_context, return_deferred, loop_deferred, in_loop, diagnostics, span, indent_level + 1);
        try appendIndent(out, indent_level);
        try out.appendSlice("}\n");
    }
}

fn emitBlockStatements(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    block: *const program.Block,
    parameter_context: []const program.Parameter,
    return_deferred: []const *const program.Expr,
    loop_deferred: []const *const program.Expr,
    in_loop: bool,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) anyerror!void {
    var scoped_deferred = array_list.Managed(*const program.Expr).init(allocator);
    defer scoped_deferred.deinit();

    for (block.statements.items) |statement| {
        switch (statement) {
            .placeholder => {
                try appendIndent(out, indent_level);
                try out.appendSlice("runa_abort();\n");
            },
            .let_decl => |binding| {
                if (try emitCVaListCopyBinding(allocator, out, module, binding.ty, binding.name, binding.expr, parameter_context, diagnostics, span, indent_level)) {
                    continue;
                }
                if (try emitCallableBindingDecl(allocator, out, module, binding.ty, binding.name, binding.expr, false, parameter_context, diagnostics, span, indent_level)) {
                    continue;
                }
                try appendIndent(out, indent_level);
                try emitValueTypeName(out, module, binding.ty, diagnostics, span);
                try out.appendSlice(" ");
                try out.appendSlice(binding.name);
                try out.appendSlice(" = ");
                try emitExpr(allocator, out, module, parameter_context, binding.expr, false, diagnostics, span);
                try out.appendSlice(";\n");
            },
            .const_decl => |binding| {
                if (isCVaListCopyExpr(binding.expr)) {
                    try diagnostics.add(.@"error", "codegen.valist.const_copy", span, "CVaList.copy must bind to a mutable local in stage0", .{});
                    return error.CodegenFailed;
                }
                if (try emitCallableBindingDecl(allocator, out, module, binding.ty, binding.name, binding.expr, true, parameter_context, diagnostics, span, indent_level)) {
                    continue;
                }
                try appendIndent(out, indent_level);
                try out.appendSlice("const ");
                try emitValueTypeName(out, module, binding.ty, diagnostics, span);
                try out.appendSlice(" ");
                try out.appendSlice(binding.name);
                try out.appendSlice(" = ");
                try emitExpr(allocator, out, module, parameter_context, binding.expr, false, diagnostics, span);
                try out.appendSlice(";\n");
            },
            .assign_stmt => |assign| {
                try appendIndent(out, indent_level);
                try emitRenderedAssignTarget(out, assign.name, parameter_context);
                try out.appendSlice(" ");
                if (assign.op) |op| {
                    try out.appendSlice(switch (op) {
                        .add => "+=",
                        .sub => "-=",
                        .mul => "*=",
                        .div => "/=",
                        .mod => "%=",
                        .shl => "<<=",
                        .shr => ">>=",
                        .bit_and => "&=",
                        .bit_xor => "^=",
                        .bit_or => "|=",
                        else => {
                            try diagnostics.add(.@"error", "codegen.assign.compound", span, "unsupported compound assignment operator in stage0 codegen", .{});
                            return error.CodegenFailed;
                        },
                    });
                } else {
                    try out.appendSlice("=");
                }
                try out.appendSlice(" ");
                try emitExpr(allocator, out, module, parameter_context, assign.expr, false, diagnostics, span);
                try out.appendSlice(";\n");
            },
            .select_stmt => |child| {
                const combined_return = try combineDeferredExprs(allocator, return_deferred, scoped_deferred.items);
                defer allocator.free(combined_return);

                const combined_loop = if (in_loop)
                    try combineDeferredExprs(allocator, loop_deferred, scoped_deferred.items)
                else
                    &.{};
                defer if (in_loop) allocator.free(combined_loop);

                try emitSelectStatement(allocator, out, module, parameter_context, child, combined_return, combined_loop, in_loop, diagnostics, span, indent_level);
            },
            .loop_stmt => |loop_data| {
                const combined_return = try combineDeferredExprs(allocator, return_deferred, scoped_deferred.items);
                defer allocator.free(combined_return);
                try emitLoopStatement(allocator, out, module, parameter_context, loop_data, combined_return, diagnostics, span, indent_level);
            },
            .unsafe_block => |body| {
                try appendIndent(out, indent_level);
                try out.appendSlice("{\n");
                try emitBlockStatements(allocator, out, module, body, parameter_context, return_deferred, loop_deferred, in_loop, diagnostics, span, indent_level + 1);
                try appendIndent(out, indent_level);
                try out.appendSlice("}\n");
            },
            .defer_stmt => |expr| {
                try scoped_deferred.append(expr);
            },
            .break_stmt => {
                if (!in_loop) {
                    try diagnostics.add(.@"error", "codegen.loop.break", span, "break is only valid inside repeat", .{});
                    return error.CodegenFailed;
                }
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, scoped_deferred.items, diagnostics, span, indent_level);
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, loop_deferred, diagnostics, span, indent_level);
                try appendIndent(out, indent_level);
                try out.appendSlice("break;\n");
            },
            .continue_stmt => {
                if (!in_loop) {
                    try diagnostics.add(.@"error", "codegen.loop.continue", span, "continue is only valid inside repeat", .{});
                    return error.CodegenFailed;
                }
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, scoped_deferred.items, diagnostics, span, indent_level);
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, loop_deferred, diagnostics, span, indent_level);
                try appendIndent(out, indent_level);
                try out.appendSlice("continue;\n");
            },
            .return_stmt => |maybe_expr| {
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, scoped_deferred.items, diagnostics, span, indent_level);
                try emitDeferredExprsIndented(allocator, out, module, parameter_context, return_deferred, diagnostics, span, indent_level);
                try appendIndent(out, indent_level);
                if (maybe_expr) |expr| {
                    try out.appendSlice("return ");
                    try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
                    try out.appendSlice(";\n");
                } else {
                    try out.appendSlice("return;\n");
                }
            },
            .expr_stmt => |expr| {
                try appendIndent(out, indent_level);
                try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
                try out.appendSlice(";\n");
            },
        }
    }

    try emitDeferredExprsIndented(allocator, out, module, parameter_context, scoped_deferred.items, diagnostics, span, indent_level);
}

fn emitLoopStatement(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    loop_data: *const program.Statement.LoopData,
    return_deferred: []const *const program.Expr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) anyerror!void {
    try appendIndent(out, indent_level);
    if (loop_data.condition) |condition| {
        try out.appendSlice("while (");
        try emitExpr(allocator, out, module, parameter_context, condition, false, diagnostics, span);
        try out.appendSlice(") {\n");
    } else {
        try out.appendSlice("for (;;) {\n");
    }

    try emitBlockStatements(allocator, out, module, loop_data.body, parameter_context, return_deferred, &.{}, true, diagnostics, span, indent_level + 1);
    try appendIndent(out, indent_level);
    try out.appendSlice("}\n");
}

fn emitDeferredExprsIndented(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    deferred: []const *const program.Expr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) anyerror!void {
    var index = deferred.len;
    while (index > 0) {
        index -= 1;
        try appendIndent(out, indent_level);
        try emitExpr(allocator, out, module, parameter_context, deferred[index], false, diagnostics, span);
        try out.appendSlice(";\n");
    }
}

fn appendIndent(out: *array_list.Managed(u8), indent_level: usize) !void {
    var index: usize = 0;
    while (index < indent_level) : (index += 1) {
        try out.appendSlice("    ");
    }
}

fn combineDeferredExprs(
    allocator: Allocator,
    outer: []const *const program.Expr,
    local: []const *const program.Expr,
) ![]const *const program.Expr {
    const combined = try allocator.alloc(*const program.Expr, outer.len + local.len);
    @memcpy(combined[0..outer.len], outer);
    @memcpy(combined[outer.len..], local);
    return combined;
}

fn appendFunctionSymbol(out: *array_list.Managed(u8), item: *const program.Item, linkage: FunctionLinkage) !void {
    switch (linkage) {
        .foreign_import => try out.appendSlice(item.name),
        .foreign_export => |name| try out.appendSlice(name),
        .internal => try appendFunctionSymbolName(out, item.symbol_name),
    }
}

fn appendFunctionSymbolName(out: *array_list.Managed(u8), symbol_name: []const u8) !void {
    try out.appendSlice("runa_fn_");
    try out.appendSlice(symbol_name);
}

fn appendConstSymbol(out: *array_list.Managed(u8), symbol_name: []const u8) !void {
    try out.appendSlice("runa_const_");
    try out.appendSlice(symbol_name);
}

fn appendEscapedCString(out: *array_list.Managed(u8), value: []const u8) !void {
    try out.appendSlice("\"");
    for (value) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(byte),
        }
    }
    try out.appendSlice("\"");
}

fn emitNominalDefinitions(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    diagnostics: *diag.Bag,
) !void {
    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();

    var remaining = countNominalItems(module);
    while (remaining > 0) {
        var progress = false;
        for (module.items.items) |*item| {
            if (emitted.contains(item.symbol_name)) continue;

            switch (item.payload) {
                .struct_type => |*struct_type| {
                    if (!structFieldsReady(module, &emitted, struct_type.fields)) continue;

                    try out.appendSlice("typedef struct ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(" {\n");
                    for (struct_type.fields) |field| {
                        try out.appendSlice("    ");
                        if (isCallableValueType(field.ty)) {
                            try emitCallableDeclarator(out, field.ty, field.name);
                            try out.appendSlice(";\n");
                            continue;
                        }
                        try emitValueTypeName(out, module, field.ty, diagnostics, item.span);
                        try out.appendSlice(" ");
                        try out.appendSlice(field.name);
                        try out.appendSlice(";\n");
                    }
                    try out.appendSlice("} ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(";\n");
                    try emitted.put(item.symbol_name, {});
                    remaining -= 1;
                    progress = true;
                },
                .enum_type => |*enum_type| {
                    if (!enumVariantsReady(module, &emitted, enum_type.variants)) continue;

                    try out.appendSlice("typedef enum ");
                    try appendEnumTagTypeName(out, item.symbol_name);
                    try out.appendSlice(" {\n");
                    for (enum_type.variants) |variant| {
                        try out.appendSlice("    ");
                        try appendEnumVariantTagName(out, item.symbol_name, variant.name);
                        try out.appendSlice(",\n");
                    }
                    try out.appendSlice("} ");
                    try appendEnumTagTypeName(out, item.symbol_name);
                    try out.appendSlice(";\n");

                    try out.appendSlice("typedef struct ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(" {\n    ");
                    try appendEnumTagTypeName(out, item.symbol_name);
                    try out.appendSlice(" tag;\n");

                    if (enumHasPayload(enum_type.variants)) {
                        try out.appendSlice("    union {\n");
                        for (enum_type.variants) |variant| {
                            switch (variant.payload) {
                                .none => {},
                                .tuple_fields => |tuple_fields| {
                                    try out.appendSlice("        struct {\n");
                                    for (tuple_fields, 0..) |field, index| {
                                        try out.appendSlice("            ");
                                        try emitValueTypeName(out, module, field.ty, diagnostics, item.span);
                                        const field_name = try std.fmt.allocPrint(allocator, "_{d}", .{index});
                                        defer allocator.free(field_name);
                                        try out.appendSlice(" ");
                                        try out.appendSlice(field_name);
                                        try out.appendSlice(";\n");
                                    }
                                    try out.appendSlice("        } ");
                                    try out.appendSlice(variant.name);
                                    try out.appendSlice(";\n");
                                },
                                .named_fields => |named_fields| {
                                    try out.appendSlice("        struct {\n");
                                    for (named_fields) |field| {
                                        try out.appendSlice("            ");
                                        try emitValueTypeName(out, module, field.ty, diagnostics, item.span);
                                        try out.appendSlice(" ");
                                        try out.appendSlice(field.name);
                                        try out.appendSlice(";\n");
                                    }
                                    try out.appendSlice("        } ");
                                    try out.appendSlice(variant.name);
                                    try out.appendSlice(";\n");
                                },
                            }
                        }
                        try out.appendSlice("    } payload;\n");
                    }

                    try out.appendSlice("} ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(";\n");
                    try emitted.put(item.symbol_name, {});
                    remaining -= 1;
                    progress = true;
                },
                .opaque_type => {
                    try out.appendSlice("typedef struct ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(" {\n    void* runa_opaque_handle;\n} ");
                    try appendStructTypeName(out, item.symbol_name);
                    try out.appendSlice(";\n");
                    try emitted.put(item.symbol_name, {});
                    remaining -= 1;
                    progress = true;
                },
                else => {},
            }
        }

        if (progress) continue;
        try diagnostics.add(.@"error", "codegen.nominal.dependencies", null, "stage0 nominal type emission requires acyclic local by-value dependencies", .{});
        return error.CodegenFailed;
    }
}

fn structFieldsReady(module: *const program.Module, emitted: *const std.StringHashMap(void), fields: []const program.StructField) bool {
    for (fields) |field| {
        if (valueTypeReady(field.ty)) continue;
        if (field.ty.kind == .nominal) {
            const item = findNominalTypeByCName(module, field.ty.c_name) orelse return false;
            if (!emitted.contains(item.symbol_name)) return false;
            continue;
        }
        return false;
    }
    return true;
}

fn enumVariantsReady(module: *const program.Module, emitted: *const std.StringHashMap(void), variants: []const program.EnumVariant) bool {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |field| {
                    if (valueTypeReady(field.ty)) continue;
                    if (field.ty.kind == .nominal) {
                        const item = findNominalTypeByCName(module, field.ty.c_name) orelse return false;
                        if (!emitted.contains(item.symbol_name)) return false;
                        continue;
                    }
                    return false;
                }
            },
            .named_fields => |named_fields| {
                if (!structFieldsReady(module, emitted, named_fields)) return false;
            },
        }
    }
    return true;
}

fn valueTypeReady(ty: program.ValueType) bool {
    return switch (ty.kind) {
        .builtin, .c_abi_alias, .raw_pointer, .callable, .foreign_callable, .dynamic_library, .c_va_list => true,
        .nominal, .tuple, .unsupported => false,
    };
}

fn emitValueTypeName(
    out: *array_list.Managed(u8),
    module: ?*const program.Module,
    ty: program.ValueType,
    diagnostics: ?*diag.Bag,
    span: ?source.Span,
) !void {
    switch (ty.kind) {
        .tuple => {
            if (diagnostics) |bag| try bag.add(.@"error", "codegen.type.tuple", span, "stage0 C codegen does not emit tuple value types yet", .{});
            return error.CodegenFailed;
        },
        .unsupported => {
            if (diagnostics) |bag| try bag.add(.@"error", "codegen.type.unsupported", span, "cannot emit unsupported stage0 value type", .{});
            return error.CodegenFailed;
        },
        .nominal => if (module) |program_module| {
            if (findNominalTypeByCName(program_module, ty.c_name) == null) {
                if (diagnostics) |bag| try bag.add(.@"error", "codegen.type.named", span, "stage0 codegen only emits lowered nominal value types; missing '{s}'", .{ty.c_name});
                return error.CodegenFailed;
            }
            try out.appendSlice(ty.c_name);
        } else {
            try out.appendSlice(ty.c_name);
        },
        else => try out.appendSlice(ty.c_name),
    }
}

fn appendStructTypeName(out: *array_list.Managed(u8), symbol_name: []const u8) !void {
    try out.appendSlice("runa_type_");
    try out.appendSlice(symbol_name);
}

fn appendEnumTagTypeName(out: *array_list.Managed(u8), symbol_name: []const u8) !void {
    try out.appendSlice("runa_tagtype_");
    try out.appendSlice(symbol_name);
}

fn appendEnumVariantTagName(out: *array_list.Managed(u8), enum_symbol: []const u8, variant_name: []const u8) !void {
    try out.appendSlice("runa_tag_");
    try out.appendSlice(enum_symbol);
    try out.appendSlice("_");
    try out.appendSlice(variant_name);
}

fn emitEnumValueLiteral(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const program.Module,
    parameter_context: []const program.Parameter,
    enum_symbol: []const u8,
    variant_name: []const u8,
    maybe_args: ?[]*program.Expr,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) anyerror!void {
    const item = findEnumTypeBySymbol(module, enum_symbol) orelse {
        try diagnostics.add(.@"error", "codegen.enum.missing", span, "cannot emit enum value for unknown symbol '{s}'", .{enum_symbol});
        return error.CodegenFailed;
    };
    const enum_type = switch (item.payload) {
        .enum_type => |*enum_type| enum_type,
        else => unreachable,
    };

    const variant = for (enum_type.variants) |*variant| {
        if (std.mem.eql(u8, variant.name, variant_name)) break variant;
    } else {
        try diagnostics.add(.@"error", "codegen.enum.variant_unknown", span, "cannot emit unknown enum variant '{s}'", .{variant_name});
        return error.CodegenFailed;
    };

    try out.appendSlice("((");
    try appendStructTypeName(out, enum_symbol);
    try out.appendSlice("){ .tag = ");
    try appendEnumVariantTagName(out, enum_symbol, variant_name);

    switch (variant.payload) {
        .none => {
            if (maybe_args) |args| {
                if (args.len != 0) {
                    try diagnostics.add(.@"error", "codegen.enum.ctor_unit", span, "unit enum variants do not take constructor arguments", .{});
                    return error.CodegenFailed;
                }
            }
        },
        .tuple_fields => |tuple_fields| {
            const args = maybe_args orelse {
                try diagnostics.add(.@"error", "codegen.enum.ctor_payload", span, "payload enum variant requires constructor args", .{});
                return error.CodegenFailed;
            };
            if (args.len != tuple_fields.len) {
                try diagnostics.add(.@"error", "codegen.enum.ctor_arity", span, "payload enum constructor has wrong arity in codegen", .{});
                return error.CodegenFailed;
            }

            try out.appendSlice(", .payload = { .");
            try out.appendSlice(variant_name);
            try out.appendSlice(" = { ");
            for (args, 0..) |arg, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
            }
            try out.appendSlice(" } }");
        },
        .named_fields => {
            const args = maybe_args orelse {
                try diagnostics.add(.@"error", "codegen.enum.ctor_payload", span, "payload enum variant requires constructor args", .{});
                return error.CodegenFailed;
            };
            const named_fields = switch (variant.payload) {
                .named_fields => |fields| fields,
                else => unreachable,
            };
            if (args.len != named_fields.len) {
                try diagnostics.add(.@"error", "codegen.enum.ctor_arity", span, "payload enum constructor has wrong arity in codegen", .{});
                return error.CodegenFailed;
            }

            try out.appendSlice(", .payload = { .");
            try out.appendSlice(variant_name);
            try out.appendSlice(" = { ");
            for (args, 0..) |arg, index| {
                if (index != 0) try out.appendSlice(", ");
                try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span);
            }
            try out.appendSlice(" } }");
        },
    }

    try out.appendSlice("})");
}

fn hasConstItems(module: *const program.Module) bool {
    for (module.items.items) |item| {
        switch (item.payload) {
            .const_item => return true,
            else => {},
        }
    }
    return false;
}

fn hasNominalItems(module: *const program.Module) bool {
    return countNominalItems(module) != 0;
}

fn enumHasPayload(variants: []const program.EnumVariant) bool {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            else => return true,
        }
    }
    return false;
}

fn countNominalItems(module: *const program.Module) usize {
    return countStructItems(module) + countEnumItems(module) + countOpaqueItems(module);
}

fn countStructItems(module: *const program.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .struct_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn countEnumItems(module: *const program.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .enum_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn countOpaqueItems(module: *const program.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .opaque_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn hasFunctionItems(module: *const program.Module) bool {
    for (module.items.items) |item| {
        switch (item.payload) {
            .function => return true,
            else => {},
        }
    }
    return false;
}

fn runtimeRequirementEnabled(
    lowered: *const backend_contract.LoweredModule,
    kind: backend_contract.RuntimeRequirementKind,
) bool {
    for (lowered.runtime_requirements) |requirement| {
        if (requirement.kind == kind) return requirement.required and requirement.supported;
    }
    return false;
}

const FunctionLinkage = program.FunctionLinkage;

const FunctionMatch = struct {
    item: *const program.Item,
    function: *const program.FunctionData,
};

fn functionLinkage(lowered: *const backend_contract.LoweredModule, local_name: []const u8) FunctionLinkage {
    for (lowered.imports) |import_desc| {
        if (std.mem.eql(u8, import_desc.name, local_name)) return .foreign_import;
    }
    for (lowered.exports) |export_desc| {
        if (std.mem.eql(u8, export_desc.local_name, local_name)) return .{ .foreign_export = export_desc.name };
    }
    return .internal;
}

fn findNamedFunction(module: *const program.Module, name: []const u8) ?FunctionMatch {
    for (module.items.items) |*item| {
        switch (item.payload) {
            .function => |*function| {
                if (std.mem.eql(u8, item.name, name)) {
                    return .{
                        .item = item,
                        .function = function,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn findConstItem(module: *const program.Module, name: []const u8) ?*const program.Item {
    for (module.items.items) |*item| {
        switch (item.payload) {
            .const_item => {
                if (std.mem.eql(u8, item.name, name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findNominalTypeByCName(module: *const program.Module, c_name: []const u8) ?*const program.Item {
    const prefix = "runa_type_";
    if (!std.mem.startsWith(u8, c_name, prefix)) return null;
    const symbol_name = c_name[prefix.len..];
    for (module.items.items) |*item| {
        switch (item.payload) {
            .struct_type, .enum_type, .opaque_type => {
                if (std.mem.eql(u8, item.symbol_name, symbol_name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findEnumTypeBySymbol(module: *const program.Module, symbol_name: []const u8) ?*const program.Item {
    for (module.items.items) |*item| {
        switch (item.payload) {
            .enum_type => {
                if (std.mem.eql(u8, item.symbol_name, symbol_name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findImportedConst(module: *const program.Module, name: []const u8) ?program.ImportedBinding {
    for (module.imports.items) |binding| {
        if (binding.const_type == null) continue;
        if (std.mem.eql(u8, binding.local_name, name)) return binding;
    }
    return null;
}

fn findImportedFunction(module: *const program.Module, name: []const u8) ?program.ImportedBinding {
    for (module.imports.items) |binding| {
        if (binding.function_return_type == null) continue;
        if (std.mem.eql(u8, binding.local_name, name)) return binding;
    }
    return null;
}
