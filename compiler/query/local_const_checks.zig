const std = @import("std");
const const_ir = @import("const_ir.zig");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const typed_text = @import("../typed/text.zig");
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
pub const AssociatedResolver = *const fn (active: *session.Session, module_id: session.ModuleId, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value;

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
    resolve_associated_const: AssociatedResolver,

    fn init(
        allocator: std.mem.Allocator,
        active: *session.Session,
        body: query_types.CheckedBody,
        resolve_identifier: Resolver,
        resolve_associated_const: AssociatedResolver,
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
            .resolve_associated_const = resolve_associated_const,
        };
    }

    fn deinit(self: *LocalEnv) void {
        for (self.decls) |*decl| {
            if (decl.value) |*value| const_ir.deinitValue(self.allocator, value);
        }
        self.allocator.free(self.decls);
    }

    fn findDeclIndex(self: *const LocalEnv, name: []const u8, scope_id: usize, before_statement: usize) ?usize {
        var maybe_scope: ?usize = scope_id;
        while (maybe_scope) |current_scope| {
            var index = self.decls.len;
            while (index > 0) {
                index -= 1;
                const decl = self.decls[index];
                if (decl.site.statement_index >= before_statement) continue;
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
    resolve_associated_const: AssociatedResolver,
) !Summary {
    var env = try LocalEnv.init(active.allocator, active, body, resolve_identifier, resolve_associated_const);
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

    if (!constSafeType(env, site.ty)) {
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
    var value = evalLocalConst(env, site.length_expr, site.scope_id, site.statement_index) catch |err| {
        summary.rejected_array_repetition_lengths += 1;
        try reportArrayRepetitionLengthError(diagnostics, site.span, err);
        return;
    };
    defer const_ir.deinitValue(env.allocator, &value);
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
    if (!site.explicit_type or !constSafeType(env, site.ty)) {
        env.decls[decl_index].state = .failed;
        env.decls[decl_index].err = error.UnsupportedConstExpr;
        return error.UnsupportedConstExpr;
    }

    env.decls[decl_index].state = .in_progress;
    const value = evalLocalConst(env, site.expr, site.scope_id, site.statement_index) catch |err| {
        env.decls[decl_index].state = .failed;
        env.decls[decl_index].err = err;
        return err;
    };

    env.decls[decl_index].state = .complete;
    env.decls[decl_index].value = value;
    return value;
}

fn evalLocalConst(env: *LocalEnv, expr: *const typed.Expr, scope_id: usize, statement_index: usize) anyerror!const_ir.Value {
    var arena = std.heap.ArenaAllocator.init(env.allocator);
    defer arena.deinit();

    const lowered = try const_ir.lowerExpr(arena.allocator(), expr);
    return const_ir.evalExpr(env.allocator, EvalContext{
        .env = env,
        .scope_id = scope_id,
        .statement_index = statement_index,
    }, lowered, resolveIdentifier);
}

const EvalContext = struct {
    env: *LocalEnv,
    scope_id: usize,
    statement_index: usize,

    pub fn structFieldName(self: EvalContext, type_name: []const u8, index: usize) ?[]const u8 {
        const item = typeItem(self.env, type_name) orelse return null;
        return switch (item.payload) {
            .struct_type => |struct_type| if (index < struct_type.fields.len) struct_type.fields[index].name else null,
            else => null,
        };
    }

    pub fn enumPayloadFieldName(self: EvalContext, enum_name: []const u8, variant_name: []const u8, index: usize) ?[]const u8 {
        const item = typeItem(self.env, enum_name) orelse return null;
        const enum_type = switch (item.payload) {
            .enum_type => |enum_type| enum_type,
            else => return null,
        };
        const variant = findEnumVariant(enum_type.variants, variant_name) orelse return null;
        return switch (variant.payload) {
            .none => null,
            .tuple_fields => |fields| if (index < fields.len) tuplePayloadFieldName(index) else null,
            .named_fields => |fields| if (index < fields.len) fields[index].name else null,
        };
    }

    pub fn enumVariantTag(self: EvalContext, enum_name: []const u8, variant_name: []const u8) ?i32 {
        const item = typeItem(self.env, enum_name) orelse return null;
        const enum_type = switch (item.payload) {
            .enum_type => |enum_type| enum_type,
            else => return null,
        };
        for (enum_type.variants, 0..) |variant, index| {
            if (std.mem.eql(u8, variant.name, variant_name)) return @intCast(index);
        }
        return null;
    }

    pub fn resolveAssociatedConst(self: EvalContext, owner_name: []const u8, const_name: []const u8) anyerror!const_ir.Value {
        return self.env.resolve_associated_const(self.env.active, self.env.module_id, owner_name, const_name);
    }
};

fn resolveIdentifier(context: EvalContext, name: []const u8) anyerror!const_ir.Value {
    if (context.env.findDeclIndex(name, context.scope_id, context.statement_index)) |decl_index| {
        return evalLocalDecl(decl_index, context.env);
    }
    return context.env.resolve_identifier(context.env.active, context.env.module_id, name);
}

fn typeItem(env: *LocalEnv, type_name: []const u8) ?*const typed.Item {
    for (env.active.semantic_index.items.items, 0..) |entry, index| {
        if (entry.module_id.index != env.module_id.index) continue;
        const item = env.active.item(.{ .index = index });
        if (item.category != .type_decl) continue;
        if (std.mem.eql(u8, item.name, type_name)) return item;
    }
    const module = env.active.module(env.module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, type_name)) continue;
        for (env.active.semantic_index.items.items, 0..) |_, index| {
            const item = env.active.item(.{ .index = index });
            if (item.category != .type_decl) continue;
            if (std.mem.eql(u8, item.symbol_name, binding.target_symbol)) return item;
        }
    }
    return null;
}

fn findEnumVariant(variants: []const typed.EnumVariant, name: []const u8) ?typed.EnumVariant {
    for (variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

fn tuplePayloadFieldName(index: usize) []const u8 {
    return switch (index) {
        0 => "_0",
        1 => "_1",
        2 => "_2",
        3 => "_3",
        4 => "_4",
        5 => "_5",
        6 => "_6",
        7 => "_7",
        8 => "_8",
        9 => "_9",
        else => "_overflow",
    };
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
        error.AmbiguousAssociatedConst => try diagnostics.add(
            .@"error",
            "type.const.associated_ambiguous",
            site.span,
            "local const '{s}' references an ambiguous associated const",
            .{site.name},
        ),
        error.InvalidConversion => try diagnostics.add(
            .@"error",
            "type.const.conversion",
            site.span,
            "local const '{s}' uses an invalid compile-time conversion",
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
        error.InvalidConversion => try diagnostics.add(
            .@"error",
            "type.const.conversion",
            span,
            "array repetition length uses an invalid compile-time conversion",
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

fn constSafeType(env: *LocalEnv, ty: types.TypeRef) bool {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .bool, .i32, .u32, .index, .str => true,
            .unit, .unsupported => false,
        },
        .named => |name| constSafeNamedType(env, name),
        .unsupported => false,
    };
}

fn constSafeNamedType(env: *LocalEnv, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.mem.startsWith(u8, trimmed, "[")) return constSafeArrayType(env, trimmed);
    if (constSafeKnownNominalType(env, trimmed)) |is_safe| return is_safe;
    const item = typeItem(env, name) orelse return false;
    return switch (item.payload) {
        .struct_type => |struct_type| blk: {
            for (struct_type.fields) |field| {
                if (!constSafeType(env, field.ty)) break :blk false;
            }
            break :blk true;
        },
        .enum_type => |enum_type| blk: {
            for (enum_type.variants) |variant| switch (variant.payload) {
                .none => {},
                .tuple_fields => |fields| for (fields) |field| {
                    if (!constSafeType(env, field.ty)) break :blk false;
                },
                .named_fields => |fields| for (fields) |field| {
                    if (!constSafeType(env, field.ty)) break :blk false;
                },
            };
            break :blk true;
        },
        else => false,
    };
}

fn constSafeKnownNominalType(env: *LocalEnv, name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "ConvertError")) return true;

    const open_index = std.mem.indexOfScalar(u8, name, '[') orelse {
        if (std.mem.eql(u8, name, "Option") or std.mem.eql(u8, name, "Result")) return false;
        return null;
    };
    const close_index = typed_text.findMatchingDelimiter(name, open_index, '[', ']') orelse return false;
    if (std.mem.trim(u8, name[close_index + 1 ..], " \t").len != 0) return false;

    const base_name = std.mem.trim(u8, name[0..open_index], " \t");
    const args = name[open_index + 1 .. close_index];
    if (std.mem.eql(u8, base_name, "Option")) {
        if (typed_text.findTopLevelHeaderScalar(args, ',') != null) return false;
        return constSafeTypeName(env, args);
    }
    if (std.mem.eql(u8, base_name, "Result")) {
        const separator = typed_text.findTopLevelHeaderScalar(args, ',') orelse return false;
        const ok_type = args[0..separator];
        const err_type = args[separator + 1 ..];
        return constSafeTypeName(env, ok_type) and constSafeTypeName(env, err_type);
    }
    return null;
}

fn constSafeTypeName(env: *LocalEnv, raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return false;
    const builtin = types.Builtin.fromName(trimmed);
    if (builtin != .unsupported) return constSafeType(env, types.TypeRef.fromBuiltin(builtin));
    return constSafeNamedType(env, trimmed);
}

fn constSafeArrayType(env: *LocalEnv, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    const close_index = typed_text.findMatchingDelimiter(trimmed, 0, '[', ']') orelse return false;
    const inner = trimmed[1..close_index];
    const separator = typed_text.findTopLevelHeaderScalar(inner, ';') orelse return false;
    const element = std.mem.trim(u8, inner[0..separator], " \t");
    const builtin = types.Builtin.fromName(element);
    const element_ty = if (builtin != .unsupported) types.TypeRef.fromBuiltin(builtin) else types.TypeRef{ .named = element };
    return constSafeType(env, element_ty);
}
