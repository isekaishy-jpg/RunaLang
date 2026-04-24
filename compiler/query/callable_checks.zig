const std = @import("std");
const diag = @import("../diag/root.zig");
const typed_text = @import("../typed/text.zig");
const type_support = @import("../typed/type_support.zig");
const types = @import("../types/root.zig");
const checked_body = @import("checked_body.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
    checked_function_value_count: usize = 0,
    rejected_generic_function_values: usize = 0,
    rejected_borrow_parameter_function_values: usize = 0,
    checked_dispatch_count: usize = 0,
    rejected_dispatch_count: usize = 0,
    rejected_arity_count: usize = 0,
    rejected_arg_count: usize = 0,
    rejected_suspend_context_count: usize = 0,
};

pub fn analyzeBody(allocator: std.mem.Allocator, body: query_types.CheckedBody, diagnostics: *diag.Bag) !Summary {
    var summary = Summary{
        .checked_function_value_count = body.function_value_sites.len,
        .checked_dispatch_count = body.callable_dispatch_sites.len,
    };

    for (body.function_value_sites) |site| {
        try validateFunctionValueSite(body, site, diagnostics, &summary);
    }
    for (body.callable_dispatch_sites) |site| {
        try validateDispatchSite(allocator, body, site, diagnostics, &summary);
    }

    return summary;
}

fn validateFunctionValueSite(
    body: query_types.CheckedBody,
    site: checked_body.FunctionValueSite,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    switch (site.issue) {
        .none => {},
        .generic => {
            summary.rejected_generic_function_values += 1;
            try diagnostics.add(
                .@"error",
                "type.callable.function_value.generic",
                body.item.span,
                "function-value formation for '{s}' requires one concrete callable signature",
                .{site.function_name},
            );
        },
        .borrow_parameter => {
            summary.rejected_borrow_parameter_function_values += 1;
            try diagnostics.add(
                .@"error",
                "type.callable.function_value.borrow",
                body.item.span,
                "function-value formation for '{s}' does not support borrow-parameter packing",
                .{site.function_name},
            );
        },
    }
}

fn validateDispatchSite(
    allocator: std.mem.Allocator,
    body: query_types.CheckedBody,
    site: checked_body.CallableDispatchSite,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    switch (site.kind) {
        .non_callable_local => {
            summary.rejected_dispatch_count += 1;
            try diagnostics.add(
                .@"error",
                "type.callable.dispatch",
                body.item.span,
                "local '{s}' does not satisfy a first-wave callable contract",
                .{site.callee_name},
            );
        },
        .local_callable => {
            if (site.is_suspend and !body.function.is_suspend) {
                summary.rejected_suspend_context_count += 1;
                try diagnostics.add(
                    .@"error",
                    "type.call.suspend_context",
                    body.item.span,
                    "call to suspend callable '{s}' requires suspend context or an explicit runtime adapter",
                    .{site.callee_name},
                );
            }

            const input_type_name = site.input_type_name orelse return;
            const input_parts = try callableInputTypeParts(allocator, input_type_name);
            defer allocator.free(input_parts);
            if (site.arg_count != input_parts.len) {
                summary.rejected_arity_count += 1;
                try diagnostics.add(
                    .@"error",
                    "type.callable.arity",
                    body.item.span,
                    "callable '{s}' has wrong arity",
                    .{site.callee_name},
                );
                return;
            }

            for (input_parts, 0..) |expected_type_name, index| {
                const expected_type = shallowTypeRefFromName(expected_type_name);
                const actual_type = site.arg_types[index];
                if (!actual_type.isUnsupported() and !expected_type.isUnsupported() and
                    !type_support.callArgumentTypeCompatible(actual_type, expected_type, expected_type_name, &.{}, false))
                {
                    summary.rejected_arg_count += 1;
                    try diagnostics.add(
                        .@"error",
                        "type.callable.arg",
                        body.item.span,
                        "callable '{s}' argument {d} has wrong type",
                        .{ site.callee_name, index + 1 },
                    );
                }
            }
        },
    }
}

fn callableInputTypeParts(allocator: std.mem.Allocator, input_type_name: []const u8) ![][]const u8 {
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

fn shallowTypeRefFromName(raw: []const u8) types.TypeRef {
    const builtin = types.Builtin.fromName(raw);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    return .{ .named = raw };
}
