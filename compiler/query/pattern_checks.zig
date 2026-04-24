const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
    checked_subject_pattern_count: usize = 0,
    irrefutable_subject_pattern_count: usize = 0,
    rejected_unreachable_pattern_count: usize = 0,
    rejected_structural_pattern_count: usize = 0,
    checked_repeat_iteration_count: usize = 0,
    rejected_repeat_iterable_count: usize = 0,
};

pub fn analyzeBody(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    trait_resolver: anytype,
) !Summary {
    var summary = Summary{
        .checked_subject_pattern_count = body.subject_pattern_sites.len,
        .irrefutable_subject_pattern_count = body.summary.irrefutable_subject_pattern_count,
        .rejected_unreachable_pattern_count = body.unreachable_pattern_sites.len,
        .rejected_structural_pattern_count = body.pattern_diagnostic_sites.len,
        .checked_repeat_iteration_count = body.repeat_iteration_sites.len,
    };

    for (body.unreachable_pattern_sites) |_| {
        try diagnostics.add(
            .@"error",
            "type.select.unreachable",
            body.item.span,
            "later subject-select arms are unreachable after an earlier irrefutable arm",
            .{},
        );
    }
    for (body.pattern_diagnostic_sites) |site| {
        try diagnostics.add(
            .@"error",
            site.code,
            body.item.span,
            "{s}",
            .{site.message},
        );
    }
    for (body.repeat_iteration_sites) |site| {
        if (try repeatIterableSatisfied(active, body, site, trait_resolver)) continue;
        summary.rejected_repeat_iterable_count += 1;
        try diagnostics.add(
            .@"error",
            "type.repeat.iterable",
            body.item.span,
            "type '{s}' does not satisfy repeat iteration",
            .{typeRefLabel(site.iterable_type)},
        );
    }

    return summary;
}

fn repeatIterableSatisfied(
    active: *session.Session,
    body: query_types.CheckedBody,
    site: @import("checked_body.zig").RepeatIterationSite,
    trait_resolver: anytype,
) !bool {
    const type_name = switch (site.iterable_type) {
        .named => |name| name,
        else => return false,
    };
    const result = trait_resolver(active, body.module_id, type_name, "Iterable", body.function.where_predicates) catch return false;
    return result.satisfied;
}

fn typeRefLabel(ty: @import("../types/root.zig").TypeRef) []const u8 {
    return switch (ty) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| name,
        .unsupported => "Unsupported",
    };
}
