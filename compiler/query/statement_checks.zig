const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
    checked_statement_count: usize = 0,
    replayed_diagnostic_count: usize = 0,
};

pub fn analyzeBody(body: query_types.CheckedBody, diagnostics: *diag.Bag) !Summary {
    var summary = Summary{
        .checked_statement_count = body.summary.statement_count,
    };

    for (body.diagnostic_sites) |diagnostic| {
        if (diagnostic.expression) continue;
        try replayDiagnostic(diagnostics, diagnostic);
        summary.replayed_diagnostic_count += 1;
    }

    return summary;
}

fn replayDiagnostic(diagnostics: *diag.Bag, diagnostic: @import("checked_body.zig").DiagnosticSite) !void {
    try diagnostics.add(diagnostic.severity, diagnostic.code, diagnostic.span, "{s}", .{diagnostic.message});
}
