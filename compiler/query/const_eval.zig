const const_ir = @import("const_ir.zig");
const session = @import("../session/root.zig");

pub const summary = "Query-owned const IR lowering and evaluation.";

pub const Resolver = *const fn (active: *session.Session, module_id: session.ModuleId, name: []const u8) anyerror!const_ir.Value;

pub fn evalExpr(
    active: *session.Session,
    module_id: session.ModuleId,
    expr: *const const_ir.Expr,
    resolve_identifier: Resolver,
) anyerror!const_ir.Value {
    return const_ir.evalExpr(EvalContext{
        .active = active,
        .module_id = module_id,
        .resolve_identifier = resolve_identifier,
    }, expr, resolveIdentifier);
}

const EvalContext = struct {
    active: *session.Session,
    module_id: session.ModuleId,
    resolve_identifier: Resolver,
};

fn resolveIdentifier(context: EvalContext, name: []const u8) anyerror!const_ir.Value {
    return context.resolve_identifier(context.active, context.module_id, name);
}
