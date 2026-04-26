const diag = @import("../diag/root.zig");
const prepared_issues = @import("prepared_issues.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
    checked_statement_count: usize = 0,
    prepared_issue_count: usize = 0,
};

pub fn analyzeBody(body: query_types.CheckedBody, diagnostics: *diag.Bag) !Summary {
    var summary = Summary{
        .checked_statement_count = body.summary.statement_count,
    };

    summary.prepared_issue_count = try prepared_issues.emitStatements(diagnostics, body.item.prepared_body_issues);

    return summary;
}
