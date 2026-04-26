const std = @import("std");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const checked_body = @import("checked_body.zig");
const query_types = @import("types.zig");
const domain_state_checks = @import("domain_state_checks.zig");

pub const Summary = struct {
    rejected_returns: usize = 0,
    rejected_storage: usize = 0,
    rejected_boundary_arguments: usize = 0,
    rejected_task_arguments: usize = 0,
    rejected_detached_task_arguments: usize = 0,
    rejected_suspensions: usize = 0,
    cfg_edge_count: usize = 0,
    effect_site_count: usize = 0,
    lifetime_return_statements_checked: usize = 0,
    invalid_cfg_edges: usize = 0,
    invalid_effect_sites: usize = 0,
};

pub fn analyzeBody(
    active: *session.Session,
    body: query_types.CheckedBody,
    lifetime_summary: anytype,
    diagnostics: *diag.Bag,
) !Summary {
    var summary = Summary{
        .cfg_edge_count = body.cfg_edges.len,
        .effect_site_count = body.effect_sites.len,
        .lifetime_return_statements_checked = lifetime_summary.return_statements_checked,
    };
    try validateCheckedFacts(body.summary.statement_count, body.cfg_edges, body.effect_sites, diagnostics, &summary);
    try analyzeReturnSites(active, body, diagnostics, &summary);
    try analyzeCallArgumentSites(active, body, diagnostics, &summary);
    try analyzeConstructorArgumentSites(active, body, diagnostics, &summary);
    try analyzeAssignmentWriteSites(active, body, diagnostics, &summary);
    return summary;
}

fn validateCheckedFacts(
    statement_count: usize,
    cfg_edges: []const checked_body.CfgEdge,
    effect_sites: []const checked_body.EffectSite,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (cfg_edges) |edge| {
        const from_valid = edge.from_statement < statement_count;
        const to_valid = edge.to_statement < statement_count or edge.to_statement == checked_body.exit_statement;
        if (from_valid and to_valid) continue;
        summary.invalid_cfg_edges += 1;
        try diagnostics.add(.@"error", "type.domain_state.cfg.invalid", null, "checked domain-state CFG contains an invalid edge", .{});
    }
    for (effect_sites) |site| {
        if (site.statement_index < statement_count) continue;
        summary.invalid_effect_sites += 1;
        try diagnostics.add(.@"error", "type.domain_state.effect.invalid", null, "checked domain-state effect site refers to an invalid statement", .{});
    }
}

fn analyzeReturnSites(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
) anyerror!void {
    for (body.return_value_sites) |site| {
        if (domain_state_checks.classifyTypeRef(active, body.module_id, site.value_type)) |domain_ref| {
            summary.rejected_returns += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_state.return",
                body.item.span,
                "function '{s}' may not return {s} value '{s}'",
                .{
                    body.item.name,
                    kindLabel(domain_ref.kind),
                    active.item(domain_ref.item_id).name,
                },
            );
        }
    }
}

fn analyzeCallArgumentSites(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
) anyerror!void {
    for (body.call_argument_sites) |site| {
        const domain_ref = domain_state_checks.classifyTypeRef(active, body.module_id, site.arg_type) orelse continue;

        if (domain_state_checks.resolveBoundaryApiFunction(active, body.module_id, site.callee_name)) |_| {
            summary.rejected_boundary_arguments += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_state.boundary_call",
                body.item.span,
                "function '{s}' may not pass {s} value '{s}' through boundary API call '{s}'",
                .{
                    body.item.name,
                    kindLabel(domain_ref.kind),
                    active.item(domain_ref.item_id).name,
                    site.callee_name,
                },
            );
        }

        if (checkedBodyMarksSuspension(body, site.statement_index, site.callee_name)) {
            summary.rejected_suspensions += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_state.suspension_arg",
                body.item.span,
                "function '{s}' may not pass {s} value '{s}' across suspension call '{s}'",
                .{
                    body.item.name,
                    kindLabel(domain_ref.kind),
                    active.item(domain_ref.item_id).name,
                    site.callee_name,
                },
            );
        }

        if (domain_state_checks.isSpawnHelper(site.callee_name) and site.arg_index > 0) {
            const detached = checkedBodyMarksDetachedSpawn(body, site.statement_index, site.callee_name);
            if (detached) {
                summary.rejected_detached_task_arguments += 1;
                try diagnostics.add(
                    .@"error",
                    "type.domain_state.detached_task_arg",
                    body.item.span,
                    "function '{s}' may not detach {s} value '{s}' through unsupported domain-state transfer call '{s}'",
                    .{
                        body.item.name,
                        kindLabel(domain_ref.kind),
                        active.item(domain_ref.item_id).name,
                        site.callee_name,
                    },
                );
            } else {
                summary.rejected_task_arguments += 1;
                try diagnostics.add(
                    .@"error",
                    "type.domain_state.task_arg",
                    body.item.span,
                    "function '{s}' may not pass {s} value '{s}' into task creation call '{s}'",
                    .{
                        body.item.name,
                        kindLabel(domain_ref.kind),
                        active.item(domain_ref.item_id).name,
                        site.callee_name,
                    },
                );
            }
        }
    }
}

fn analyzeConstructorArgumentSites(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (body.constructor_argument_sites) |site| {
        if (site.kind == .struct_constructor and
            domain_state_checks.classifyTypeName(active, body.module_id, site.target_type_name) != null)
        {
            continue;
        }
        const domain_ref = domain_state_checks.classifyTypeRef(active, body.module_id, site.arg_type) orelse continue;
        summary.rejected_storage += 1;
        try diagnostics.add(
            .@"error",
            "type.domain_state.storage",
            body.item.span,
            "function '{s}' may not store {s} value '{s}' inside non-domain value '{s}'",
            .{
                body.item.name,
                kindLabel(domain_ref.kind),
                active.item(domain_ref.item_id).name,
                site.target_type_name,
            },
        );
    }
}

fn analyzeAssignmentWriteSites(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    for (body.assignment_write_sites) |site| {
        const domain_ref = domain_state_checks.classifyTypeRef(active, body.module_id, site.value_type) orelse continue;
        if (site.target_base_type) |base_type| {
            if (domain_state_checks.classifyTypeRef(active, body.module_id, base_type) != null) continue;
            summary.rejected_storage += 1;
            try diagnostics.add(
                .@"error",
                "type.domain_state.storage",
                body.item.span,
                "function '{s}' may not store {s} value '{s}' inside non-domain value '{s}'",
                .{
                    body.item.name,
                    kindLabel(domain_ref.kind),
                    active.item(domain_ref.item_id).name,
                    base_type.displayName(),
                },
            );
            continue;
        }

        if (domain_state_checks.classifyTypeRef(active, body.module_id, site.target_type) != null) continue;
        summary.rejected_storage += 1;
        try diagnostics.add(
            .@"error",
            "type.domain_state.storage",
            body.item.span,
            "function '{s}' may not store {s} value '{s}' inside non-domain value '{s}'",
            .{
                body.item.name,
                kindLabel(domain_ref.kind),
                active.item(domain_ref.item_id).name,
                site.target_type.displayName(),
            },
        );
    }
}

fn checkedBodyMarksSuspension(body: query_types.CheckedBody, statement_index: usize, callee_name: []const u8) bool {
    for (body.suspension_sites) |site| {
        if (site.statement_index == statement_index and std.mem.eql(u8, site.callee_name, callee_name)) return true;
    }
    return false;
}

fn checkedBodyMarksDetachedSpawn(body: query_types.CheckedBody, statement_index: usize, callee_name: []const u8) bool {
    for (body.spawn_sites) |site| {
        if (site.statement_index == statement_index and std.mem.eql(u8, site.callee_name, callee_name)) return site.detached;
    }
    return false;
}

fn kindLabel(kind: domain_state_checks.DomainTypeRef.Kind) []const u8 {
    return switch (kind) {
        .root => "#domain_root",
        .context => "#domain_context",
    };
}
