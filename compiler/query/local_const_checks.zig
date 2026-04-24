const std = @import("std");
const const_ir = @import("const_ir.zig");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const checked_body = @import("checked_body.zig");
const query_types = @import("types.zig");

pub const Summary = struct {
    checked_count: usize = 0,
    rejected_count: usize = 0,
    checked_array_repetition_lengths: usize = 0,
    rejected_array_repetition_lengths: usize = 0,
};

pub const Resolver = *const fn (active: *session.Session, module_id: session.ModuleId, name: []const u8) anyerror!const_ir.Value;

const LocalConstState = enum {
    not_started,
    in_progress,
    complete,
    failed,
};

const LocalDecl = struct {
    site: checked_body.LocalConstDeclSite,
    state: LocalConstState = .not_started,
    value: ?const_ir.Value = null,
    err: ?anyerror = null,
};

const LocalEnv = struct {
    allocator: std.mem.Allocator,
    active: *session.Session,
    module_id: session.ModuleId,
    body: query_types.CheckedBody,
    decls: []LocalDecl,
    resolve_identifier: Resolver,

    fn init(
        allocator: std.mem.Allocator,
        active: *session.Session,
        body: query_types.CheckedBody,
        resolve_identifier: Resolver,
    ) !LocalEnv {
        const decls = try allocator.alloc(LocalDecl, body.local_const_decl_sites.len);
        errdefer allocator.free(decls);
        for (body.local_const_decl_sites, 0..) |site, index| {
            decls[index] = .{ .site = site };
        }
        return .{
            .allocator = allocator,
            .active = active,
            .module_id = body.module_id,
            .body = body,
            .decls = decls,
            .resolve_identifier = resolve_identifier,
        };
    }

    fn deinit(self: *LocalEnv) void {
        self.allocator.free(self.decls);
    }

    fn findDeclIndex(self: *const LocalEnv, name: []const u8, scope_id: usize) ?usize {
        var maybe_scope: ?usize = scope_id;
        while (maybe_scope) |current_scope| {
            var index = self.decls.len;
            while (index > 0) {
                index -= 1;
                const decl = self.decls[index];
                if (decl.site.scope_id == current_scope and std.mem.eql(u8, decl.site.name, name)) return index;
            }
            maybe_scope = self.scopeParent(current_scope);
        }
        return null;
    }

    fn scopeParent(self: *const LocalEnv, scope_id: usize) ?usize {
        if (scope_id >= self.body.lexical_scopes.len) return null;
        return self.body.lexical_scopes[scope_id].parent;
    }
};

pub fn analyzeBody(
    active: *session.Session,
    body: query_types.CheckedBody,
    diagnostics: *diag.Bag,
    resolve_identifier: Resolver,
) !Summary {
    var env = try LocalEnv.init(active.allocator, active, body, resolve_identifier);
    defer env.deinit();

    var summary = Summary{};
    for (env.decls, 0..) |_, decl_index| {
        try analyzeConstDecl(&env, decl_index, diagnostics, &summary);
    }
    for (body.array_repetition_length_sites) |site| {
        try analyzeArrayRepetitionLength(&env, site, diagnostics, &summary);
    }
    return summary;
}

fn analyzeConstDecl(
    env: *LocalEnv,
    decl_index: usize,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    const site = env.decls[decl_index].site;
    if (!site.explicit_type) {
        summary.rejected_count += 1;
        try diagnostics.add(
            .@"error",
            "type.const.type",
            site.span,
            "local const '{s}' requires an explicit const-safe type",
            .{site.name},
        );
        return;
    }

    if (constSafeBuiltin(site.ty) == null) {
        summary.rejected_count += 1;
        try diagnostics.add(
            .@"error",
            "type.const.type",
            site.span,
            "local const '{s}' uses a non-const-safe type",
            .{site.name},
        );
        return;
    }

    summary.checked_count += 1;
    _ = evalLocalDecl(decl_index, env) catch |err| {
        summary.rejected_count += 1;
        try reportLocalConstEvalError(diagnostics, site, err);
        return;
    };
}

fn analyzeArrayRepetitionLength(
    env: *LocalEnv,
    site: checked_body.ArrayRepetitionLengthSite,
    diagnostics: *diag.Bag,
    summary: *Summary,
) !void {
    summary.checked_array_repetition_lengths += 1;
    const value = evalLocalConst(env, site.length_expr, site.scope_id) catch |err| {
        summary.rejected_array_repetition_lengths += 1;
        try reportArrayRepetitionLengthError(diagnostics, site.span, err);
        return;
    };
    _ = lengthValue(value) catch |err| {
        summary.rejected_array_repetition_lengths += 1;
        try reportArrayRepetitionLengthError(diagnostics, site.span, err);
    };
}

fn evalLocalDecl(decl_index: usize, env: *LocalEnv) anyerror!const_ir.Value {
    const state = env.decls[decl_index].state;
    switch (state) {
        .complete => return env.decls[decl_index].value.?,
        .failed => return env.decls[decl_index].err orelse error.UnsupportedConstExpr,
        .in_progress => {
            env.decls[decl_index].state = .failed;
            env.decls[decl_index].err = error.QueryCycle;
            return error.QueryCycle;
        },
        .not_started => {},
    }

    const site = env.decls[decl_index].site;
    if (!site.explicit_type or constSafeBuiltin(site.ty) == null) {
        env.decls[decl_index].state = .failed;
        env.decls[decl_index].err = error.UnsupportedConstExpr;
        return error.UnsupportedConstExpr;
    }

    env.decls[decl_index].state = .in_progress;
    const value = evalLocalConst(env, site.expr, site.scope_id) catch |err| {
        env.decls[decl_index].state = .failed;
        env.decls[decl_index].err = err;
        return err;
    };

    env.decls[decl_index].state = .complete;
    env.decls[decl_index].value = value;
    return value;
}

fn evalLocalConst(env: *LocalEnv, expr: *const typed.Expr, scope_id: usize) anyerror!const_ir.Value {
    var arena = std.heap.ArenaAllocator.init(env.allocator);
    defer arena.deinit();

    const lowered = try const_ir.lowerExpr(arena.allocator(), expr);
    return const_ir.evalExpr(EvalContext{
        .env = env,
        .scope_id = scope_id,
    }, lowered, resolveIdentifier);
}

const EvalContext = struct {
    env: *LocalEnv,
    scope_id: usize,
};

fn resolveIdentifier(context: EvalContext, name: []const u8) anyerror!const_ir.Value {
    if (context.env.findDeclIndex(name, context.scope_id)) |decl_index| {
        return evalLocalDecl(decl_index, context.env);
    }
    return context.env.resolve_identifier(context.env.active, context.env.module_id, name);
}

fn reportLocalConstEvalError(
    diagnostics: *diag.Bag,
    site: checked_body.LocalConstDeclSite,
    err: anyerror,
) !void {
    switch (err) {
        error.QueryCycle => try diagnostics.add(
            .@"error",
            "type.const.cycle",
            site.span,
            "local const '{s}' participates in cyclic const evaluation",
            .{site.name},
        ),
        error.UnsupportedConstExpr => try diagnostics.add(
            .@"error",
            "type.const.expr",
            site.span,
            "local const '{s}' uses an unsupported const expression",
            .{site.name},
        ),
        error.ConstOverflow => try diagnostics.add(
            .@"error",
            "type.const.overflow",
            site.span,
            "local const '{s}' overflows during compile-time evaluation",
            .{site.name},
        ),
        error.DivideByZero => try diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            site.span,
            "local const '{s}' divides by zero during compile-time evaluation",
            .{site.name},
        ),
        error.InvalidRemainder => try diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            site.span,
            "local const '{s}' uses an invalid remainder operation during compile-time evaluation",
            .{site.name},
        ),
        error.InvalidShiftCount => try diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            site.span,
            "local const '{s}' uses an invalid shift count during compile-time evaluation",
            .{site.name},
        ),
        error.UnknownConst => try diagnostics.add(
            .@"error",
            "type.const.unknown",
            site.span,
            "local const '{s}' references an unknown const item",
            .{site.name},
        ),
        else => {},
    }
}

fn lengthValue(value: const_ir.Value) !usize {
    return switch (value) {
        .index => |length| length,
        .u32 => |length| @intCast(length),
        .i32 => |length| blk: {
            if (length < 0) return error.NegativeArrayLength;
            break :blk @intCast(length);
        },
        else => error.UnsupportedConstExpr,
    };
}

fn reportArrayRepetitionLengthError(diagnostics: *diag.Bag, span: ?source.Span, err: anyerror) !void {
    switch (err) {
        error.NegativeArrayLength => try diagnostics.add(
            .@"error",
            "type.const.array_repetition_length_negative",
            span,
            "array repetition length evaluates to a negative value",
            .{},
        ),
        error.DivideByZero => try diagnostics.add(
            .@"error",
            "type.const.divide_by_zero",
            span,
            "array repetition length divides by zero during compile-time evaluation",
            .{},
        ),
        error.InvalidRemainder => try diagnostics.add(
            .@"error",
            "type.const.invalid_remainder",
            span,
            "array repetition length uses an invalid remainder operation",
            .{},
        ),
        error.InvalidShiftCount => try diagnostics.add(
            .@"error",
            "type.const.invalid_shift",
            span,
            "array repetition length uses an invalid shift count",
            .{},
        ),
        error.ConstOverflow => try diagnostics.add(
            .@"error",
            "type.const.overflow",
            span,
            "array repetition length overflows during compile-time evaluation",
            .{},
        ),
        error.QueryCycle => try diagnostics.add(
            .@"error",
            "type.const.cycle",
            span,
            "array repetition length participates in cyclic const evaluation",
            .{},
        ),
        else => try diagnostics.add(
            .@"error",
            "type.const.array_repetition_length",
            span,
            "array repetition length is not a valid const Index expression",
            .{},
        ),
    }
}

fn constSafeBuiltin(ty: types.TypeRef) ?types.Builtin {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .bool, .i32, .u32, .index, .str => builtin,
            .unit, .unsupported => null,
        },
        .named, .unsupported => null,
    };
}
