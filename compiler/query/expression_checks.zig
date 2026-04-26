const diag = @import("../diag/root.zig");
const conversions = @import("conversions.zig");
const prepared_issues = @import("prepared_issues.zig");
const query_types = @import("types.zig");
const types = @import("../types/root.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Summary = struct {
    checked_expression_count: usize = 0,
    prepared_issue_count: usize = 0,
    checked_conversion_count: usize = 0,
    rejected_conversion_count: usize = 0,
};

pub const Result = struct {
    summary: Summary,
    conversion_facts: []const query_types.CheckedConversionFact,
};

pub fn analyzeBody(allocator: Allocator, body: query_types.CheckedBody, diagnostics: *diag.Bag) !Result {
    var summary = Summary{
        .checked_expression_count = body.expression_sites.len,
    };

    summary.prepared_issue_count = try prepared_issues.emitExpressions(diagnostics, body.item.prepared_body_issues);

    var conversion_facts = std.array_list.Managed(query_types.CheckedConversionFact).init(allocator);
    errdefer conversion_facts.deinit();

    for (body.expression_sites) |site| {
        if (site.kind != .conversion) continue;
        const mode = queryConversionMode(site.conversion_mode orelse continue);
        const status = conversionStatus(mode, site.source_type, site.target_type);
        const diagnostic_code: ?[]const u8 = if (status == .rejected)
            "type.expr.conversion"
        else
            null;
        try conversion_facts.append(.{
            .expression_id = site.id,
            .mode = mode,
            .source_type = site.source_type,
            .target_type = site.target_type,
            .result_type = site.ty,
            .status = status,
            .diagnostic_code = diagnostic_code,
        });
        summary.checked_conversion_count += 1;
        if (status == .rejected) {
            summary.rejected_conversion_count += 1;
            try diagnostics.add(
                .@"error",
                diagnostic_code.?,
                body.item.span,
                "conversion from '{s}' to '{s}' is not valid in this conversion mode",
                .{ site.source_type.displayName(), site.target_type.displayName() },
            );
        }
    }

    return .{
        .summary = summary,
        .conversion_facts = try conversion_facts.toOwnedSlice(),
    };
}

fn queryConversionMode(mode: @import("../typed/root.zig").ConversionMode) query_types.ConversionMode {
    return switch (mode) {
        .explicit_infallible => .explicit_infallible,
        .explicit_checked => .explicit_checked,
    };
}

fn conversionStatus(mode: query_types.ConversionMode, source_type: types.TypeRef, target_type: types.TypeRef) query_types.ConversionStatus {
    const shared_mode: conversions.Mode = switch (mode) {
        .implicit => .implicit,
        .explicit_infallible => .explicit_infallible,
        .explicit_checked => .explicit_checked,
    };
    return if (conversions.allowed(shared_mode, source_type, target_type)) .accepted else .rejected;
}
