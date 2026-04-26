const diag = @import("../diag/root.zig");
const std = @import("std");

pub fn emitAll(diagnostics: *diag.Bag, issues: []const diag.Diagnostic) !usize {
    var emitted: usize = 0;
    for (issues) |issue| {
        try emitOne(diagnostics, issue);
        emitted += 1;
    }
    return emitted;
}

fn emitOne(diagnostics: *diag.Bag, issue: diag.Diagnostic) !void {
    try diagnostics.add(issue.severity, issue.code, issue.span, "{s}", .{issue.message});
}

pub fn isExpressionIssue(code: []const u8) bool {
    return std.mem.startsWith(u8, code, "type.expr.") or
        std.mem.startsWith(u8, code, "parse.expr.") or
        std.mem.startsWith(u8, code, "type.call.") or
        std.mem.startsWith(u8, code, "type.method.") or
        std.mem.startsWith(u8, code, "type.ctor.") or
        std.mem.startsWith(u8, code, "type.enum.") or
        std.mem.startsWith(u8, code, "type.field.") or
        std.mem.startsWith(u8, code, "type.name.") or
        std.mem.startsWith(u8, code, "lifetime.call.") or
        std.mem.startsWith(u8, code, "lifetime.store.");
}
