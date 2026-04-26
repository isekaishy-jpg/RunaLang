const std = @import("std");
const array_list = std.array_list;
const diag = @import("../diag/root.zig");
const mir = @import("../mir/root.zig");
const runtime = @import("../runtime/root.zig");
const source = @import("../source/root.zig");
const callable_types = @import("../typed/callable_types.zig");
const typed_text = @import("../typed/text.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const parseCallableTypeName = callable_types.parseCallableTypeName;
const shallowTypeRefFromName = callable_types.shallowTypeRefFromName;

pub const summary = "MIR-stage lowering to the stage0 C backend.";
pub const backend = "c";

pub const OutputKind = enum {
    bin,
    cdylib,
};

pub fn emitCModule(
    allocator: Allocator,
    product_name: []const u8,
    module: *const mir.Module,
    kind: OutputKind,
    diagnostics: *diag.Bag,
) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("/* stage0 generated C backend for product: ");
    try out.appendSlice(product_name);
    try out.appendSlice(" */\n");
    try out.appendSlice("#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <stdlib.h>\n\n");
    try out.appendSlice("#if defined(_WIN32)\n#define RUNA_EXPORT __declspec(dllexport)\n#else\n#define RUNA_EXPORT\n#endif\n\n");
    const abort_support = try runtime.abort.renderAbortSupport(allocator);
    defer allocator.free(abort_support);
    try out.appendSlice(abort_support);

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
            .function => |function| try emitFunctionPrototype(allocator, &out, module, &item, &function, diagnostics),
            else => {},
        }
    }

    if (hasFunctionItems(module)) try out.appendSlice("\n");

    for (module.items.items) |item| {
        switch (item.payload) {
            .function => |function| try emitFunctionDefinition(allocator, &out, module, &item, &function, diagnostics),
            else => {},
        }
    }

    switch (kind) {
        .bin => try emitMainWrapper(allocator, &out, module, diagnostics),
        .cdylib => {},
    }

    return out.toOwnedSlice();
}

fn emitConstDefinition(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    item: *const mir.Item,
    const_item: *const mir.ConstData,
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
    module: *const mir.Module,
    expr: *const mir.ConstExpr,
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
            try out.appendSlice(conversion.target_type.cName());
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
    value: mir.ConstValue,
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
    module: *const mir.Module,
    item: *const mir.Item,
    function: *const mir.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    _ = allocator;
    if (function.foreign) {
        try out.appendSlice("extern ");
    } else if (function.export_name != null) {
        try out.appendSlice("RUNA_EXPORT ");
    } else {
        try out.appendSlice("static ");
    }

    try emitValueTypeName(out, module, function.return_type, diagnostics, item.span);
    try out.appendSlice(" ");
    try appendFunctionSymbol(out, item, function);
    try out.appendSlice("(");
    try emitParameterList(out, module, function, diagnostics, item.span);
    try out.appendSlice(");\n");
}

fn emitFunctionDefinition(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    item: *const mir.Item,
    function: *const mir.FunctionData,
    diagnostics: *diag.Bag,
) !void {
    if (function.foreign) return;

    if (function.export_name != null) {
        try out.appendSlice("RUNA_EXPORT ");
    } else {
        try out.appendSlice("static ");
    }
    try emitValueTypeName(out, module, function.return_type, diagnostics, item.span);
    try out.appendSlice(" ");
    try appendFunctionSymbol(out, item, function);
    try out.appendSlice("(");
    try emitParameterList(out, module, function, diagnostics, item.span);
    try out.appendSlice(") {\n");
    try emitBlockStatements(allocator, out, module, &function.body, function.parameters, &.{}, &.{}, false, diagnostics, item.span, 1);
    try out.appendSlice("}\n\n");
}

fn emitMainWrapper(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
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

    switch (function.return_type) {
        .builtin => |builtin| switch (builtin) {
            .unit, .i32 => {},
            else => {
                try diagnostics.add(.@"error", "codegen.main.return", item.span, "stage0 entry 'main' must return Unit or I32", .{});
                return error.CodegenFailed;
            },
        },
        else => {
            try diagnostics.add(.@"error", "codegen.main.return", item.span, "stage0 entry 'main' must return Unit or I32", .{});
            return error.CodegenFailed;
        },
    }

    const wrapper_return_type = switch (function.return_type) {
        .builtin => |builtin| builtin,
        else => unreachable,
    };

    var symbol = array_list.Managed(u8).init(allocator);
    defer symbol.deinit();
    try appendFunctionSymbol(&symbol, item, function);
    const wrapper = try runtime.entry.renderMainWrapper(allocator, symbol.items, wrapper_return_type);
    defer allocator.free(wrapper);
    try out.appendSlice(wrapper);
}

fn emitParameterList(
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    function: *const mir.FunctionData,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    for (function.parameters, 0..) |parameter, index| {
        if (index != 0) try out.appendSlice(", ");
        try emitParameterTypeName(out, module, parameter, diagnostics, span);
        try out.appendSlice(" ");
        try out.appendSlice(parameter.name);
    }
    if (function.parameters.len == 0) try out.appendSlice("void");
}

fn emitParameterTypeName(
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    parameter: mir.Parameter,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    try emitValueTypeName(out, module, parameter.ty, diagnostics, span);
    switch (parameter.mode) {
        .read, .edit => try out.appendSlice("*"),
        .owned, .take => {},
    }
}

fn isBorrowParameter(parameters: []const mir.Parameter, name: []const u8) bool {
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    expr: *const mir.Expr,
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
        .field => {
            try out.appendSlice("&(");
            try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
            try out.appendSlice(")");
        },
        else => {
            try diagnostics.add(.@"error", "codegen.call.borrow_arg", span, "borrow arguments must be plain locals or field projections in stage0", .{});
            return error.CodegenFailed;
        },
    }
}

fn emitRenderedAssignTarget(out: *array_list.Managed(u8), rendered_name: []const u8, parameter_context: []const mir.Parameter) !void {
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

fn emitCallableBindingDecl(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    ty: types.TypeRef,
    name: []const u8,
    expr: *const mir.Expr,
    is_const: bool,
    parameter_context: []const mir.Parameter,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) !bool {
    const callable_type_name = switch (ty) {
        .named => |type_name| type_name,
        else => return false,
    };
    const callable = try parseCallableTypeName(callable_type_name, allocator) orelse return false;

    try appendIndent(out, indent_level);
    try emitValueTypeName(out, module, shallowTypeRefFromName(callable.output_type_name), diagnostics, span);
    try out.appendSlice(" (*");
    if (is_const) try out.appendSlice("const ");
    try out.appendSlice(name);
    try out.appendSlice(")(");
    try emitCallableInputParameterList(allocator, out, module, callable.input_type_name, diagnostics, span);
    try out.appendSlice(") = ");
    try emitExpr(allocator, out, module, parameter_context, expr, false, diagnostics, span);
    try out.appendSlice(";\n");
    return true;
}

fn emitCallableInputParameterList(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    input_type_name: []const u8,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    const parts = try callableInputTypeParts(allocator, input_type_name);
    defer allocator.free(parts);
    if (parts.len == 0) {
        try out.appendSlice("void");
        return;
    }
    for (parts, 0..) |part, index| {
        if (index != 0) try out.appendSlice(", ");
        try emitValueTypeName(out, module, shallowTypeRefFromName(part), diagnostics, span);
    }
}

fn callableInputTypeParts(allocator: Allocator, input_type_name: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, input_type_name, " \t");
    if (std.mem.eql(u8, trimmed, "Unit")) return allocator.alloc([]const u8, 0);

    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        const inside = trimmed[1 .. trimmed.len - 1];
        if (hasTopLevelComma(inside)) return typed_text.splitTopLevelCommaParts(allocator, inside);
    }

    const parts = try allocator.alloc([]const u8, 1);
    parts[0] = trimmed;
    return parts;
}

fn hasTopLevelComma(raw: []const u8) bool {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (raw) |byte| {
        switch (byte) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn emitExpr(
    allocator: Allocator,
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    expr: *const mir.Expr,
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
            const callable = switch (expr.ty) {
                .named => |type_name| try parseCallableTypeName(type_name, allocator),
                else => null,
            };
            if (callable != null) {
                if (findNamedFunction(module, name)) |target| {
                    try appendFunctionSymbol(out, target.item, target.function);
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
            if (findNamedFunction(module, call.callee)) |target| {
                try appendFunctionSymbol(out, target.item, target.function);
                try out.appendSlice("(");
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try out.appendSlice(", ");
                    const mode = if (index < target.function.parameters.len)
                        target.function.parameters[index].mode
                    else
                        typed.ParameterMode.owned;
                    switch (mode) {
                        .read, .edit => try emitBorrowArgument(allocator, out, module, parameter_context, arg, diagnostics, span),
                        .owned, .take => try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span),
                    }
                }
            } else if (findImportedFunction(module, call.callee)) |binding| {
                try appendFunctionSymbolName(out, binding.target_symbol);
                try out.appendSlice("(");
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try out.appendSlice(", ");
                    const mode = if (binding.function_parameter_modes) |modes|
                        if (index < modes.len) modes[index] else typed.ParameterMode.owned
                    else
                        typed.ParameterMode.owned;
                    switch (mode) {
                        .read, .edit => try emitBorrowArgument(allocator, out, module, parameter_context, arg, diagnostics, span),
                        .owned, .take => try emitExpr(allocator, out, module, parameter_context, arg, false, diagnostics, span),
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    deferred: []const *const mir.Expr,
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    select_data: *const mir.Statement.SelectData,
    return_deferred: []const *const mir.Expr,
    loop_deferred: []const *const mir.Expr,
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
    module: *const mir.Module,
    block: *const mir.Block,
    parameter_context: []const mir.Parameter,
    return_deferred: []const *const mir.Expr,
    loop_deferred: []const *const mir.Expr,
    in_loop: bool,
    diagnostics: *diag.Bag,
    span: ?source.Span,
    indent_level: usize,
) anyerror!void {
    var scoped_deferred = array_list.Managed(*const mir.Expr).init(allocator);
    defer scoped_deferred.deinit();

    for (block.statements.items) |statement| {
        switch (statement) {
            .placeholder => {
                try appendIndent(out, indent_level);
                try out.appendSlice("runa_abort();\n");
            },
            .let_decl => |binding| {
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    loop_data: *const mir.Statement.LoopData,
    return_deferred: []const *const mir.Expr,
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    deferred: []const *const mir.Expr,
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
    outer: []const *const mir.Expr,
    local: []const *const mir.Expr,
) ![]const *const mir.Expr {
    const combined = try allocator.alloc(*const mir.Expr, outer.len + local.len);
    @memcpy(combined[0..outer.len], outer);
    @memcpy(combined[outer.len..], local);
    return combined;
}

fn appendFunctionSymbol(out: *array_list.Managed(u8), item: *const mir.Item, function: *const mir.FunctionData) !void {
    if (function.foreign) {
        try out.appendSlice(item.name);
        return;
    }
    if (function.export_name) |name| {
        try out.appendSlice(name);
        return;
    }
    try appendFunctionSymbolName(out, item.symbol_name);
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
    module: *const mir.Module,
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

fn structFieldsReady(module: *const mir.Module, emitted: *const std.StringHashMap(void), fields: []const mir.StructField) bool {
    for (fields) |field| {
        switch (field.ty) {
            .builtin, .unsupported => {},
            .named => |name| {
                const item = findStructType(module, name) orelse findEnumType(module, name) orelse findOpaqueType(module, name) orelse return false;
                if (!emitted.contains(item.symbol_name)) return false;
            },
        }
    }
    return true;
}

fn enumVariantsReady(module: *const mir.Module, emitted: *const std.StringHashMap(void), variants: []const mir.EnumVariant) bool {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |field| {
                    switch (field.ty) {
                        .builtin, .unsupported => {},
                        .named => |name| {
                            const item = findStructType(module, name) orelse findEnumType(module, name) orelse findOpaqueType(module, name) orelse return false;
                            if (!emitted.contains(item.symbol_name)) return false;
                        },
                    }
                }
            },
            .named_fields => |named_fields| {
                if (!structFieldsReady(module, emitted, named_fields)) return false;
            },
        }
    }
    return true;
}

fn emitBuiltinTypeName(out: *array_list.Managed(u8), ty: types.Builtin) !void {
    try out.appendSlice(ty.cName());
}

fn emitValueTypeName(
    out: *array_list.Managed(u8),
    module: *const mir.Module,
    ty: types.TypeRef,
    diagnostics: *diag.Bag,
    span: ?source.Span,
) !void {
    switch (ty) {
        .builtin => |builtin| try emitBuiltinTypeName(out, builtin),
        .named => |name| {
            const item = findStructType(module, name) orelse findEnumType(module, name) orelse findOpaqueType(module, name) orelse {
                try diagnostics.add(.@"error", "codegen.type.named", span, "stage0 codegen only emits locally declared nominal value types; missing '{s}'", .{baseTypeName(name)});
                return error.CodegenFailed;
            };
            try appendStructTypeName(out, item.symbol_name);
        },
        .unsupported => {
            try diagnostics.add(.@"error", "codegen.type.unsupported", span, "cannot emit unsupported stage0 value type", .{});
            return error.CodegenFailed;
        },
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
    module: *const mir.Module,
    parameter_context: []const mir.Parameter,
    enum_symbol: []const u8,
    variant_name: []const u8,
    maybe_args: ?[]*mir.Expr,
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

fn hasConstItems(module: *const mir.Module) bool {
    for (module.items.items) |item| {
        switch (item.payload) {
            .const_item => return true,
            else => {},
        }
    }
    return false;
}

fn hasNominalItems(module: *const mir.Module) bool {
    return countNominalItems(module) != 0;
}

fn enumHasPayload(variants: []const mir.EnumVariant) bool {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            else => return true,
        }
    }
    return false;
}

fn countNominalItems(module: *const mir.Module) usize {
    return countStructItems(module) + countEnumItems(module) + countOpaqueItems(module);
}

fn countStructItems(module: *const mir.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .struct_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn countEnumItems(module: *const mir.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .enum_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn countOpaqueItems(module: *const mir.Module) usize {
    var count: usize = 0;
    for (module.items.items) |item| {
        switch (item.payload) {
            .opaque_type => count += 1,
            else => {},
        }
    }
    return count;
}

fn hasFunctionItems(module: *const mir.Module) bool {
    for (module.items.items) |item| {
        switch (item.payload) {
            .function => return true,
            else => {},
        }
    }
    return false;
}

const FunctionMatch = struct {
    item: *const mir.Item,
    function: *const mir.FunctionData,
};

fn findNamedFunction(module: *const mir.Module, name: []const u8) ?FunctionMatch {
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

fn findConstItem(module: *const mir.Module, name: []const u8) ?*const mir.Item {
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

fn findStructType(module: *const mir.Module, name: []const u8) ?*const mir.Item {
    const base_name = baseTypeName(name);
    for (module.items.items) |*item| {
        switch (item.payload) {
            .struct_type => {
                if (std.mem.eql(u8, item.name, base_name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findEnumType(module: *const mir.Module, name: []const u8) ?*const mir.Item {
    const base_name = baseTypeName(name);
    for (module.items.items) |*item| {
        switch (item.payload) {
            .enum_type => {
                if (std.mem.eql(u8, item.name, base_name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findOpaqueType(module: *const mir.Module, name: []const u8) ?*const mir.Item {
    const base_name = baseTypeName(name);
    for (module.items.items) |*item| {
        switch (item.payload) {
            .opaque_type => {
                if (std.mem.eql(u8, item.name, base_name)) return item;
            },
            else => {},
        }
    }
    return null;
}

fn findEnumTypeBySymbol(module: *const mir.Module, symbol_name: []const u8) ?*const mir.Item {
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

fn baseTypeName(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        return std.mem.trim(u8, trimmed[0..open_index], " \t");
    }
    return trimmed;
}

fn findImportedConst(module: *const mir.Module, name: []const u8) ?mir.ImportedBinding {
    for (module.imports.items) |binding| {
        if (binding.const_type == null) continue;
        if (std.mem.eql(u8, binding.local_name, name)) return binding;
    }
    return null;
}

fn findImportedFunction(module: *const mir.Module, name: []const u8) ?mir.ImportedBinding {
    for (module.imports.items) |binding| {
        if (binding.function_return_type == null) continue;
        if (std.mem.eql(u8, binding.local_name, name)) return binding;
    }
    return null;
}
