const std = @import("std");
const diag = @import("../diag/root.zig");
const type_support = @import("type_support.zig");
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

            const input_type = site.input_type orelse return;
            const input_parts = try callableInputTypes(allocator, input_type);
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

            for (input_parts, 0..) |expected_type, index| {
                const actual_type = site.arg_types[index];
                if (!actual_type.isUnsupported() and !expected_type.isUnsupported() and
                    !type_support.callArgumentTypeCompatible(actual_type, expected_type, &.{}, false))
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

fn callableInputTypes(allocator: std.mem.Allocator, input_type: types.TypeRef) ![]types.TypeRef {
    if (input_type.eql(types.TypeRef.fromBuiltin(.unit))) return allocator.alloc(types.TypeRef, 0);

    if (try type_support.tupleElementTypes(allocator, input_type)) |parts| {
        return parts;
    }

    const parts = try allocator.alloc(types.TypeRef, 1);
    parts[0] = input_type;
    return parts;
}
