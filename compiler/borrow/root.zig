const checked_body = @import("../query/checked_body.zig");
const diag = @import("../diag/root.zig");

pub const summary = "Borrow checking and reference validation.";
pub const read_reference = "&read";
pub const edit_reference = "&edit";
pub const take_reference = "&take";
pub const hold_reference = "&hold";
pub const consumable_unique_handle = "&take";

pub const BodySummary = struct {
    borrow_parameter_count: usize = 0,
    is_suspend: bool = false,
    checked_place_count: usize = 0,
    cfg_edge_count: usize = 0,
    invalid_cfg_edges: usize = 0,
};

pub fn validateCheckedBody(body: anytype, diagnostics: *diag.Bag) !BodySummary {
    var summary_data = BodySummary{
        .is_suspend = body.function.is_suspend,
        .checked_place_count = body.places.len,
        .cfg_edge_count = body.cfg_edges.len,
    };
    try validateCfgFacts(body.summary.statement_count, body.cfg_edges, diagnostics, &summary_data);
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        if (!place.mutable) {
            summary_data.borrow_parameter_count += 1;
            continue;
        }
        const parameter_index = place.parameter_index orelse continue;
        if (parameter_index >= body.parameters.len) continue;
        switch (body.parameters[parameter_index].mode) {
            .read, .edit => summary_data.borrow_parameter_count += 1,
            .owned, .take => {},
        }
    }
    return summary_data;
}

fn validateCfgFacts(
    statement_count: usize,
    cfg_edges: anytype,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    for (cfg_edges) |edge| {
        const from_valid = edge.from_statement < statement_count;
        const to_valid = edge.to_statement < statement_count or edge.to_statement == checked_body.exit_statement;
        if (from_valid and to_valid) continue;
        summary_data.invalid_cfg_edges += 1;
        try diagnostics.add(.@"error", "borrow.cfg.invalid", null, "checked borrow CFG contains an invalid edge", .{});
    }
}
