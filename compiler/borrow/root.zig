const std = @import("std");
const array_list = std.array_list;
const checked_body = @import("../query/checked_body.zig");
const query_type_support = @import("../query/type_support.zig");
const diag = @import("../diag/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");

pub const summary = "Borrow checking and reference validation.";
pub const read_reference = "&read";
pub const edit_reference = "&edit";
pub const take_reference = "&take";
pub const hold_reference = "&hold";
pub const consumable_unique_handle = "&take";

const BoundaryKind = enum {
    value,
    ephemeral,
    retained,
};

const BoundaryAccess = enum {
    read,
    edit,
};

const BoundaryType = struct {
    kind: BoundaryKind = .value,
    access: ?BoundaryAccess = null,
    lifetime_name: ?[]const u8 = null,
    inner_type_name: []const u8 = "",
};

const NamedOrigin = struct {
    name: []const u8,
    origin: BoundaryType,
};

pub const BodySummary = struct {
    borrow_parameter_count: usize = 0,
    is_suspend: bool = false,
    checked_place_count: usize = 0,
    cfg_edge_count: usize = 0,
    effect_site_count: usize = 0,
    invalid_cfg_edges: usize = 0,
    invalid_effect_sites: usize = 0,
    suspension_borrow_count: usize = 0,
    detached_borrow_count: usize = 0,
};

pub fn validateCheckedBody(
    allocator: std.mem.Allocator,
    body: anytype,
    callable_resolver: anytype,
    diagnostics: *diag.Bag,
) !BodySummary {
    var summary_data = BodySummary{
        .is_suspend = body.function.is_suspend,
        .checked_place_count = body.places.len,
        .cfg_edge_count = body.cfg_edges.len,
        .effect_site_count = body.effect_sites.len,
    };
    try validateCheckedFacts(body.summary.statement_count, body.cfg_edges, body.effect_sites, diagnostics, &summary_data);

    var origins = array_list.Managed(NamedOrigin).init(allocator);
    defer origins.deinit();
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        const parameter_index = place.parameter_index orelse continue;
        if (parameter_index >= body.parameters.len) continue;
        const parameter = body.parameters[parameter_index];
        const origin = boundaryFromParameter(parameter);
        if (origin.kind != .value) summary_data.borrow_parameter_count += 1;
        try putOrigin(&origins, place.name, origin);
    }

    var result = try validateBlock(allocator, body, callable_resolver, origins.items, body.root_block_id, diagnostics, &summary_data);
    result.deinit();
    return summary_data;
}

fn validateCheckedFacts(
    statement_count: usize,
    cfg_edges: anytype,
    effect_sites: anytype,
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
    for (effect_sites) |site| {
        if (site.statement_index < statement_count) continue;
        summary_data.invalid_effect_sites += 1;
        try diagnostics.add(.@"error", "borrow.effect.invalid", null, "checked borrow effect site refers to an invalid statement", .{});
    }
}

const FlowResult = struct {
    fallthrough: bool = false,
    fallthrough_state: array_list.Managed(NamedOrigin),
    has_break: bool = false,
    break_state: array_list.Managed(NamedOrigin),
    has_continue: bool = false,
    continue_state: array_list.Managed(NamedOrigin),

    fn init(allocator: std.mem.Allocator) FlowResult {
        return .{
            .fallthrough_state = array_list.Managed(NamedOrigin).init(allocator),
            .break_state = array_list.Managed(NamedOrigin).init(allocator),
            .continue_state = array_list.Managed(NamedOrigin).init(allocator),
        };
    }

    fn deinit(self: *FlowResult) void {
        self.fallthrough_state.deinit();
        self.break_state.deinit();
        self.continue_state.deinit();
    }
};

const LoopCondition = enum {
    never_enters,
    may_skip,
    must_enter_may_exit_via_break_only,
};

fn validateBlock(
    allocator: std.mem.Allocator,
    body: anytype,
    callable_resolver: anytype,
    initial_origins: []const NamedOrigin,
    block_id: usize,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    if (block_id >= body.block_sites.len) {
        var empty = FlowResult.init(allocator);
        empty.fallthrough = true;
        try empty.fallthrough_state.appendSlice(initial_origins);
        return empty;
    }

    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    var current_origins = try cloneOrigins(allocator, initial_origins);
    defer current_origins.deinit();

    var reachable = true;
    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (!reachable) break;
        if (statement_index >= body.statement_sites.len) continue;
        const statement = body.statement_sites[statement_index];

        var effect = try validateStatement(allocator, body, callable_resolver, current_origins.items, statement, diagnostics, summary_data);
        defer effect.deinit();

        if (effect.has_break) {
            result.has_break = true;
            try mergeOrigins(&result.break_state, effect.break_state.items);
        }
        if (effect.has_continue) {
            result.has_continue = true;
            try mergeOrigins(&result.continue_state, effect.continue_state.items);
        }

        if (!effect.fallthrough) {
            reachable = false;
            continue;
        }

        try replaceOrigins(&current_origins, effect.fallthrough_state.items);
    }

    if (reachable) {
        result.fallthrough = true;
        try replaceOrigins(&result.fallthrough_state, current_origins.items);
    }

    return result;
}

fn validateStatement(
    allocator: std.mem.Allocator,
    body: anytype,
    callable_resolver: anytype,
    origins: []const NamedOrigin,
    statement: checked_body.StatementSite,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    try validateStatementEffects(body, callable_resolver, origins, statement.index, diagnostics, summary_data);

    switch (statement.kind) {
        .let_decl, .const_decl => {
            var next_origins = try cloneOrigins(allocator, origins);
            defer next_origins.deinit();
            if (statement.binding_name) |name| {
                if (statement.binding_expr) |expr| {
                    try putOrigin(&next_origins, name, inferExprOrigin(next_origins.items, expr));
                }
            }
            result.fallthrough = true;
            try replaceOrigins(&result.fallthrough_state, next_origins.items);
        },
        .assign_stmt => {
            var next_origins = try cloneOrigins(allocator, origins);
            defer next_origins.deinit();
            if (statement.assign_name) |name| {
                if (statement.assign_expr) |expr| {
                    if (std.mem.indexOfScalar(u8, name, '.')) |_| {
                        result.fallthrough = true;
                        try replaceOrigins(&result.fallthrough_state, next_origins.items);
                        return result;
                    }
                    const next_origin = if (statement.assign_op == null)
                        inferExprOrigin(next_origins.items, expr)
                    else
                        BoundaryType{};
                    try putOrigin(&next_origins, name, next_origin);
                }
            }
            result.fallthrough = true;
            try replaceOrigins(&result.fallthrough_state, next_origins.items);
        },
        .select_stmt => {
            const subject_origin = if (statement.select_subject) |subject|
                inferExprOrigin(origins, subject)
            else
                BoundaryType{};

            var merged = try cloneOrigins(allocator, origins);
            defer merged.deinit();
            var saw_fallthrough = false;

            for (statement.select_arms) |arm| {
                var arm_origins = try cloneOrigins(allocator, origins);
                defer arm_origins.deinit();

                if (statement.select_subject_temp_name) |name| {
                    try putOrigin(&arm_origins, name, subject_origin);
                }
                for (arm.bindings) |binding| {
                    try putOrigin(&arm_origins, binding.name, inferExprOrigin(arm_origins.items, binding.expr));
                }

                var arm_result = try validateBlock(allocator, body, callable_resolver, arm_origins.items, arm.body_block_id, diagnostics, summary_data);
                defer arm_result.deinit();

                if (arm_result.fallthrough) {
                    saw_fallthrough = true;
                    try mergeOrigins(&merged, arm_result.fallthrough_state.items);
                }
                if (arm_result.has_break) {
                    result.has_break = true;
                    try mergeOrigins(&result.break_state, arm_result.break_state.items);
                }
                if (arm_result.has_continue) {
                    result.has_continue = true;
                    try mergeOrigins(&result.continue_state, arm_result.continue_state.items);
                }
            }

            if (statement.select_else_block_id) |else_block_id| {
                var else_result = try validateBlock(allocator, body, callable_resolver, origins, else_block_id, diagnostics, summary_data);
                defer else_result.deinit();

                if (else_result.fallthrough) {
                    saw_fallthrough = true;
                    try mergeOrigins(&merged, else_result.fallthrough_state.items);
                }
                if (else_result.has_break) {
                    result.has_break = true;
                    try mergeOrigins(&result.break_state, else_result.break_state.items);
                }
                if (else_result.has_continue) {
                    result.has_continue = true;
                    try mergeOrigins(&result.continue_state, else_result.continue_state.items);
                }
            } else {
                saw_fallthrough = true;
            }

            if (saw_fallthrough) {
                result.fallthrough = true;
                try replaceOrigins(&result.fallthrough_state, merged.items);
            }
        },
        .loop_stmt => {
            var loop_result = try validateLoop(allocator, body, callable_resolver, origins, statement, diagnostics, summary_data);
            defer loop_result.deinit();
            if (loop_result.fallthrough) {
                result.fallthrough = true;
                try mergeOrigins(&result.fallthrough_state, loop_result.fallthrough_state.items);
            }
            if (loop_result.has_break) {
                result.has_break = true;
                try mergeOrigins(&result.break_state, loop_result.break_state.items);
            }
            if (loop_result.has_continue) {
                result.has_continue = true;
                try mergeOrigins(&result.continue_state, loop_result.continue_state.items);
            }
        },
        .unsafe_block => {
            if (statement.unsafe_block_id) |unsafe_block_id| {
                var block_result = try validateBlock(allocator, body, callable_resolver, origins, unsafe_block_id, diagnostics, summary_data);
                defer block_result.deinit();
                if (block_result.fallthrough) {
                    result.fallthrough = true;
                    try mergeOrigins(&result.fallthrough_state, block_result.fallthrough_state.items);
                }
                if (block_result.has_break) {
                    result.has_break = true;
                    try mergeOrigins(&result.break_state, block_result.break_state.items);
                }
                if (block_result.has_continue) {
                    result.has_continue = true;
                    try mergeOrigins(&result.continue_state, block_result.continue_state.items);
                }
            } else {
                result.fallthrough = true;
                try replaceOrigins(&result.fallthrough_state, origins);
            }
        },
        .break_stmt => {
            result.has_break = true;
            try replaceOrigins(&result.break_state, origins);
        },
        .continue_stmt => {
            result.has_continue = true;
            try replaceOrigins(&result.continue_state, origins);
        },
        .return_stmt => {},
        .placeholder,
        .defer_stmt,
        .expr_stmt,
        => {
            result.fallthrough = true;
            try replaceOrigins(&result.fallthrough_state, origins);
        },
    }

    return result;
}

fn validateLoop(
    allocator: std.mem.Allocator,
    body: anytype,
    callable_resolver: anytype,
    origins: []const NamedOrigin,
    statement: checked_body.StatementSite,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    const condition = classifyLoopCondition(statement.loop_condition);
    switch (condition) {
        .never_enters => {
            result.fallthrough = true;
            try replaceOrigins(&result.fallthrough_state, origins);
            return result;
        },
        .may_skip => {
            result.fallthrough = true;
            try replaceOrigins(&result.fallthrough_state, origins);
        },
        .must_enter_may_exit_via_break_only => {},
    }

    const loop_body_id = statement.loop_body_block_id orelse {
        result.fallthrough = true;
        try replaceOrigins(&result.fallthrough_state, origins);
        return result;
    };

    var iteration_origins = try cloneOrigins(allocator, origins);
    defer iteration_origins.deinit();

    var iteration_count: usize = 0;
    while (iteration_count < 8) : (iteration_count += 1) {
        var body_result = try validateBlock(allocator, body, callable_resolver, iteration_origins.items, loop_body_id, diagnostics, summary_data);
        defer body_result.deinit();

        if (body_result.has_break) {
            if (!result.fallthrough) try replaceOrigins(&result.fallthrough_state, iteration_origins.items);
            result.fallthrough = true;
            try mergeOrigins(&result.fallthrough_state, body_result.break_state.items);
        }

        var carried_origins = try cloneOrigins(allocator, iteration_origins.items);
        defer carried_origins.deinit();
        var has_carried = false;
        if (body_result.fallthrough) {
            try mergeOrigins(&carried_origins, body_result.fallthrough_state.items);
            has_carried = true;
        }
        if (body_result.has_continue) {
            try mergeOrigins(&carried_origins, body_result.continue_state.items);
            has_carried = true;
        }
        if (!has_carried) break;

        if (condition == .may_skip) {
            result.fallthrough = true;
            try mergeOrigins(&result.fallthrough_state, carried_origins.items);
        }

        var next_iteration = try cloneOrigins(allocator, iteration_origins.items);
        errdefer next_iteration.deinit();
        try mergeOrigins(&next_iteration, carried_origins.items);
        if (originsEql(next_iteration.items, iteration_origins.items)) {
            next_iteration.deinit();
            break;
        }

        iteration_origins.deinit();
        iteration_origins = next_iteration;
    }

    return result;
}

fn validateStatementEffects(
    body: anytype,
    callable_resolver: anytype,
    origins: []const NamedOrigin,
    statement_index: usize,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    _ = callable_resolver;

    if (body.function.is_suspend) {
        for (body.suspension_sites) |site| {
            if (site.statement_index != statement_index) continue;
            for (origins) |origin| {
                if (origin.origin.kind != .ephemeral) continue;
                summary_data.suspension_borrow_count += 1;
                try diagnostics.add(
                    .@"error",
                    "borrow.suspend",
                    body.item.span,
                    "suspend point in function '{s}' cannot keep ephemeral borrow '{s}' live across suspension",
                    .{ body.item.name, origin.name },
                );
            }
        }
    }

    for (body.spawn_sites) |spawn_site| {
        if (spawn_site.statement_index != statement_index or !spawn_site.detached) continue;
        for (body.call_argument_sites) |arg_site| {
            if (arg_site.statement_index != statement_index) continue;
            if (!std.mem.eql(u8, arg_site.callee_name, spawn_site.callee_name)) continue;
            if (arg_site.arg_index == 0) continue;
            if (!originEscapesDetached(inferExprOrigin(origins, arg_site.arg_expr))) continue;
            summary_data.detached_borrow_count += 1;
            try diagnostics.add(
                .@"error",
                "borrow.detached",
                body.item.span,
                "detached task call '{s}' cannot capture borrowed value in argument {d}",
                .{ spawn_site.callee_name, arg_site.arg_index },
            );
        }
    }
}

fn originEscapesDetached(origin: BoundaryType) bool {
    return switch (origin.kind) {
        .value => false,
        .ephemeral => true,
        .retained => !std.mem.eql(u8, origin.lifetime_name orelse "", "'static"),
    };
}

fn classifyLoopCondition(condition: ?*const typed.Expr) LoopCondition {
    const expr = condition orelse return .must_enter_may_exit_via_break_only;
    return switch (expr.node) {
        .bool_lit => |value| if (value) .must_enter_may_exit_via_break_only else .never_enters,
        else => .may_skip,
    };
}

fn boundaryFromParameter(parameter: typed.Parameter) BoundaryType {
    const type_name = typeRefRawName(parameter.ty);
    const retained = boundaryFromRawType(type_name);
    if (retained.kind == .retained) return retained;

    return switch (parameter.mode) {
        .read => .{
            .kind = .ephemeral,
            .access = .read,
            .inner_type_name = type_name,
        },
        .edit => .{
            .kind = .ephemeral,
            .access = .edit,
            .inner_type_name = type_name,
        },
        .owned, .take => .{
            .kind = .value,
            .inner_type_name = type_name,
        },
    };
}

fn boundaryFromTypeRef(ty: types.TypeRef) BoundaryType {
    return boundaryFromRawType(typeRefRawName(ty));
}

fn boundaryFromRawType(raw: []const u8) BoundaryType {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{ .inner_type_name = trimmed };

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = std.mem.indexOfScalarPos(u8, trimmed, "hold[".len, ']') orelse return .{
            .kind = .value,
            .inner_type_name = trimmed,
        };
        const lifetime_name = std.mem.trim(u8, trimmed["hold[".len..close_index], " \t");
        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) return .{
            .kind = .retained,
            .access = .read,
            .lifetime_name = lifetime_name,
            .inner_type_name = std.mem.trim(u8, rest["read ".len..], " \t"),
        };
        if (std.mem.startsWith(u8, rest, "edit ")) return .{
            .kind = .retained,
            .access = .edit,
            .lifetime_name = lifetime_name,
            .inner_type_name = std.mem.trim(u8, rest["edit ".len..], " \t"),
        };
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) return .{
        .kind = .ephemeral,
        .access = .read,
        .inner_type_name = std.mem.trim(u8, trimmed["read ".len..], " \t"),
    };
    if (std.mem.startsWith(u8, trimmed, "edit ")) return .{
        .kind = .ephemeral,
        .access = .edit,
        .inner_type_name = std.mem.trim(u8, trimmed["edit ".len..], " \t"),
    };

    return .{
        .kind = .value,
        .inner_type_name = trimmed,
    };
}

fn inferExprOrigin(origins: []const NamedOrigin, expr: *const typed.Expr) BoundaryType {
    const direct_boundary = boundaryFromTypeRef(expr.ty);
    if (direct_boundary.kind != .value) return direct_boundary;

    return switch (expr.node) {
        .identifier => |name| lookupOrigin(origins, name),
        .field => |field| inferProjectedOrigin(origins, field.base),
        .method_target => |target| inferProjectedOrigin(origins, target.base),
        .integer,
        .bool_lit,
        .string,
        .enum_variant,
        .enum_tag,
        .enum_constructor_target,
        .enum_construct,
        .call,
        .constructor,
        .tuple,
        .array,
        .array_repeat,
        .index,
        .conversion,
        .unary,
        .binary,
        => BoundaryType{},
    };
}

fn inferProjectedOrigin(origins: []const NamedOrigin, base: *const typed.Expr) BoundaryType {
    const base_origin = inferExprOrigin(origins, base);
    return switch (base_origin.kind) {
        .ephemeral, .retained => base_origin,
        .value => BoundaryType{},
    };
}

fn lookupOrigin(origins: []const NamedOrigin, name: []const u8) BoundaryType {
    for (origins) |origin| {
        if (std.mem.eql(u8, origin.name, name)) return origin.origin;
    }
    return .{};
}

fn putOrigin(origins: *array_list.Managed(NamedOrigin), name: []const u8, origin: BoundaryType) !void {
    for (origins.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.origin = origin;
            return;
        }
    }
    try origins.append(.{
        .name = name,
        .origin = origin,
    });
}

fn mergeOrigins(origins: *array_list.Managed(NamedOrigin), incoming: []const NamedOrigin) !void {
    for (incoming) |origin| {
        for (origins.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, origin.name)) continue;
            entry.origin = mergeBoundary(entry.origin, origin.origin);
            break;
        } else {
            try origins.append(origin);
        }
    }
}

fn replaceOrigins(origins: *array_list.Managed(NamedOrigin), replacement: []const NamedOrigin) !void {
    origins.clearRetainingCapacity();
    try origins.appendSlice(replacement);
}

fn mergeBoundary(lhs: BoundaryType, rhs: BoundaryType) BoundaryType {
    if (lhs.kind == .ephemeral or rhs.kind == .ephemeral) {
        if (lhs.kind == .ephemeral) return lhs;
        return rhs;
    }
    if (lhs.kind == .retained or rhs.kind == .retained) {
        if (lhs.kind == .retained) return lhs;
        return rhs;
    }
    return lhs;
}

fn cloneOrigins(allocator: std.mem.Allocator, origins: []const NamedOrigin) !array_list.Managed(NamedOrigin) {
    var cloned = array_list.Managed(NamedOrigin).init(allocator);
    errdefer cloned.deinit();
    try cloned.appendSlice(origins);
    return cloned;
}

fn originsEql(lhs: []const NamedOrigin, rhs: []const NamedOrigin) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs) |origin| {
        var found = false;
        for (rhs) |other| {
            if (!std.mem.eql(u8, origin.name, other.name)) continue;
            if (!boundaryEql(origin.origin, other.origin)) return false;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn boundaryEql(lhs: BoundaryType, rhs: BoundaryType) bool {
    return lhs.kind == rhs.kind and
        lhs.access == rhs.access and
        optionalNameEql(lhs.lifetime_name, rhs.lifetime_name) and
        std.mem.eql(u8, lhs.inner_type_name, rhs.inner_type_name);
}

fn optionalNameEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn typeRefRawName(ty: types.TypeRef) []const u8 {
    return query_type_support.typeRefRawName(ty);
}
