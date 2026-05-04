const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const trait_solver = @import("trait_solver.zig");
const types = @import("../types/root.zig");

pub const Summary = struct {
    rejected_callable_count: usize = 0,
    rejected_input_count: usize = 0,
    rejected_output_count: usize = 0,
};

pub fn analyzeBody(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    callable_resolver: anytype,
) !Summary {
    var summary = Summary{};
    _ = callable_resolver;

    for (body.spawn_sites) |site| {
        if (!site.worker_crossing) continue;

        if (site.callable_arg_type) |arg_type| {
            if (!typeIsSend(active, body, arg_type)) {
                summary.rejected_callable_count += 1;
                try diagnostics.add(
                    .@"error",
                    "type.send.spawn_callable",
                    body.item.span,
                    "worker-crossing spawn '{s}' requires a Send callable value",
                    .{site.callee_name},
                );
            }
        }
        if (site.input_arg_type) |input_type| {
            if (!typeIsSend(active, body, input_type)) {
                summary.rejected_input_count += 1;
                try diagnostics.add(
                    .@"error",
                    "type.send.spawn_input",
                    body.item.span,
                    "worker-crossing spawn '{s}' requires Send input state",
                    .{site.callee_name},
                );
            }
        }
        if (!site.detached) {
            if (site.callable_output_type) |output_type| {
                if (!typeIsSend(active, body, output_type)) {
                    summary.rejected_output_count += 1;
                    try diagnostics.add(
                        .@"error",
                        "type.send.spawn_output",
                        body.item.span,
                        "worker-crossing spawn '{s}' requires Send task output",
                        .{site.callee_name},
                    );
                }
            }
        }
    }
    return summary;
}

fn typeIsSend(active: *session.Session, body: query_types.CheckedBody, ty: types.TypeRef) bool {
    return trait_solver.typeRefIsSendInEnvironment(
        active,
        body.module_id,
        ty,
        body.function.where_predicates,
    );
}
