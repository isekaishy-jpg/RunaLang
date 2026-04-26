const std = @import("std");
const array_list = std.array_list;
const checked_body = @import("../query/checked_body.zig");
const diag = @import("../diag/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Lifetime checking over typed ownership-aware items.";
pub const explicit_everywhere = true;

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

const OriginSet = struct {
    values: array_list.Managed(BoundaryType),

    fn init(allocator: Allocator) OriginSet {
        return .{ .values = array_list.Managed(BoundaryType).init(allocator) };
    }

    fn deinit(self: *OriginSet) void {
        self.values.deinit();
    }

    fn clone(self: *const OriginSet, allocator: Allocator) !OriginSet {
        var cloned = OriginSet.init(allocator);
        errdefer cloned.deinit();
        try cloned.mergeFrom(self);
        return cloned;
    }

    fn add(self: *OriginSet, origin: BoundaryType) !void {
        if (containsBoundary(self.values.items, origin)) return;
        try self.values.append(origin);
    }

    fn mergeFrom(self: *OriginSet, other: *const OriginSet) !void {
        for (other.values.items) |origin| {
            try self.add(origin);
        }
    }

    fn eql(self: *const OriginSet, other: *const OriginSet) bool {
        if (self.values.items.len != other.values.items.len) return false;
        for (self.values.items) |origin| {
            if (!containsBoundary(other.values.items, origin)) return false;
        }
        return true;
    }
};

const NamedOrigin = struct {
    name: []const u8,
    origins: OriginSet,
};

const OriginState = struct {
    allocator: Allocator,
    entries: array_list.Managed(NamedOrigin),

    fn init(allocator: Allocator) OriginState {
        return .{
            .allocator = allocator,
            .entries = array_list.Managed(NamedOrigin).init(allocator),
        };
    }

    fn deinit(self: *OriginState) void {
        for (self.entries.items) |*entry| entry.origins.deinit();
        self.entries.deinit();
    }

    fn clone(self: *const OriginState) !OriginState {
        var cloned = OriginState.init(self.allocator);
        errdefer cloned.deinit();

        for (self.entries.items) |entry| {
            try cloned.entries.append(.{
                .name = entry.name,
                .origins = try entry.origins.clone(self.allocator),
            });
        }

        return cloned;
    }

    fn isEmpty(self: *const OriginState) bool {
        return self.entries.items.len == 0;
    }

    fn eql(self: *const OriginState, other: *const OriginState) bool {
        if (self.entries.items.len != other.entries.items.len) return false;
        for (self.entries.items) |entry| {
            const other_origins = other.lookup(entry.name) orelse return false;
            if (!entry.origins.eql(other_origins)) return false;
        }
        return true;
    }

    fn lookup(self: *const OriginState, name: []const u8) ?*const OriginSet {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.origins;
        }
        return null;
    }

    fn putSingle(self: *OriginState, name: []const u8, origin: BoundaryType) !void {
        var origins = OriginSet.init(self.allocator);
        defer origins.deinit();
        try origins.add(origin);
        try self.putSet(name, &origins);
    }

    fn putSet(self: *OriginState, name: []const u8, origins: *const OriginSet) !void {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entry.origins.deinit();
            entry.origins = try origins.clone(self.allocator);
            return;
        }

        try self.entries.append(.{
            .name = name,
            .origins = try origins.clone(self.allocator),
        });
    }

    fn mergeOuterBranch(
        self: *OriginState,
        saw_branch: *bool,
        outer_state: *const OriginState,
        branch_state: *const OriginState,
    ) !void {
        if (!saw_branch.*) {
            for (outer_state.entries.items) |outer| {
                const branch_origins = branch_state.lookup(outer.name) orelse &outer.origins;
                try self.putSet(outer.name, branch_origins);
            }
            saw_branch.* = true;
            return;
        }

        for (outer_state.entries.items) |outer| {
            const branch_origins = branch_state.lookup(outer.name) orelse &outer.origins;
            for (self.entries.items) |*existing| {
                if (!std.mem.eql(u8, existing.name, outer.name)) continue;
                try existing.origins.mergeFrom(branch_origins);
                break;
            } else {
                try self.putSet(outer.name, branch_origins);
            }
        }
    }

    fn mergeFrom(self: *OriginState, other: *const OriginState) !void {
        for (other.entries.items) |entry| {
            var found = false;
            for (self.entries.items) |*existing| {
                if (!std.mem.eql(u8, existing.name, entry.name)) continue;
                try existing.origins.mergeFrom(&entry.origins);
                found = true;
                break;
            }
            if (!found) {
                try self.entries.append(.{
                    .name = entry.name,
                    .origins = try entry.origins.clone(self.allocator),
                });
            }
        }
    }
};

const FlowResult = struct {
    fallthrough: bool = false,
    fallthrough_state: OriginState,
    has_break: bool = false,
    break_state: OriginState,
    has_continue: bool = false,
    continue_state: OriginState,

    fn init(allocator: Allocator) FlowResult {
        return .{
            .fallthrough_state = OriginState.init(allocator),
            .break_state = OriginState.init(allocator),
            .continue_state = OriginState.init(allocator),
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

pub const BodySummary = struct {
    return_statements_checked: usize = 0,
    rejected_returns: usize = 0,
    checked_place_count: usize = 0,
    cfg_edge_count: usize = 0,
    effect_site_count: usize = 0,
    invalid_cfg_edges: usize = 0,
    invalid_effect_sites: usize = 0,
};

pub fn validateCheckedBody(
    allocator: std.mem.Allocator,
    body: anytype,
    diagnostics: *diag.Bag,
) !BodySummary {
    var summary_data = BodySummary{
        .checked_place_count = body.places.len,
        .cfg_edge_count = body.cfg_edges.len,
        .effect_site_count = body.effect_sites.len,
    };
    try validateCheckedFacts(body.summary.statement_count, body.cfg_edges, body.effect_sites, diagnostics, &summary_data);

    var origins = OriginState.init(allocator);
    defer origins.deinit();
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        const parameter_index = place.parameter_index orelse continue;
        if (parameter_index >= body.parameters.len) continue;
        try origins.putSingle(place.name, boundaryFromParameter(body.parameters[parameter_index]));
    }

    var result = try validateBlock(allocator, body, &origins, body.root_block_id, diagnostics, &summary_data);
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
        try diagnostics.add(.@"error", "lifetime.cfg.invalid", null, "checked lifetime CFG contains an invalid edge", .{});
    }
    for (effect_sites) |site| {
        if (site.statement_index < statement_count) continue;
        summary_data.invalid_effect_sites += 1;
        try diagnostics.add(.@"error", "lifetime.effect.invalid", null, "checked lifetime effect site refers to an invalid statement", .{});
    }
}

fn validateBlock(
    allocator: Allocator,
    body: anytype,
    initial_origins: *const OriginState,
    block_id: usize,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    if (block_id >= body.block_sites.len) {
        var empty = FlowResult.init(allocator);
        empty.fallthrough = true;
        try empty.fallthrough_state.mergeFrom(initial_origins);
        return empty;
    }

    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    var current_origins = try initial_origins.clone();
    defer current_origins.deinit();

    var reachable = true;
    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (!reachable) break;
        if (statement_index >= body.statement_sites.len) continue;
        const statement = body.statement_sites[statement_index];

        var effect = try validateStatement(allocator, body, &current_origins, statement, diagnostics, summary_data);
        defer effect.deinit();

        if (effect.has_break) {
            result.has_break = true;
            try result.break_state.mergeFrom(&effect.break_state);
        }
        if (effect.has_continue) {
            result.has_continue = true;
            try result.continue_state.mergeFrom(&effect.continue_state);
        }

        if (!effect.fallthrough) {
            reachable = false;
            continue;
        }

        current_origins.deinit();
        current_origins = try effect.fallthrough_state.clone();
    }

    if (reachable) {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(&current_origins);
    }

    return result;
}

fn validateStatement(
    allocator: Allocator,
    body: anytype,
    origins: *const OriginState,
    statement: checked_body.StatementSite,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    switch (statement.kind) {
        .let_decl, .const_decl => {
            var next_origins = try origins.clone();
            defer next_origins.deinit();
            if (statement.binding_name) |name| {
                if (statement.binding_expr) |expr| {
                    var expr_origins = try inferExprOrigins(allocator, origins, expr);
                    defer expr_origins.deinit();
                    try next_origins.putSet(name, &expr_origins);
                }
            }
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_origins);
        },
        .assign_stmt => {
            var next_state = try origins.clone();
            defer next_state.deinit();

            if (statement.assign_name) |name| {
                if (statement.assign_expr) |expr| {
                    if (std.mem.indexOfScalar(u8, name, '.')) |_| {
                        result.fallthrough = true;
                        try result.fallthrough_state.mergeFrom(&next_state);
                        return result;
                    }
                    var next_origins = OriginSet.init(allocator);
                    defer next_origins.deinit();
                    if (statement.assign_op == null) {
                        var expr_origins = try inferExprOrigins(allocator, origins, expr);
                        defer expr_origins.deinit();
                        try next_origins.mergeFrom(&expr_origins);
                    } else {
                        try next_origins.add(.{});
                    }
                    try next_state.putSet(name, &next_origins);
                }
            }

            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_state);
        },
        .select_stmt => {
            var subject_origins = OriginSet.init(allocator);
            defer subject_origins.deinit();
            if (statement.select_subject) |subject| {
                var inferred = try inferExprOrigins(allocator, origins, subject);
                defer inferred.deinit();
                try subject_origins.mergeFrom(&inferred);
            } else {
                try subject_origins.add(.{});
            }

            var outer_origins = try origins.clone();
            defer outer_origins.deinit();

            var saw_fallthrough = false;
            if (statement.select_else_block_id == null) {
                result.fallthrough = true;
                try result.fallthrough_state.mergeOuterBranch(&saw_fallthrough, &outer_origins, &outer_origins);
            }

            for (statement.select_arms) |arm| {
                var arm_origins = try origins.clone();
                defer arm_origins.deinit();

                if (statement.select_subject_temp_name) |name| {
                    try arm_origins.putSet(name, &subject_origins);
                }
                for (arm.bindings) |binding| {
                    var binding_origins = try inferExprOrigins(allocator, &arm_origins, binding.expr);
                    defer binding_origins.deinit();
                    try arm_origins.putSet(binding.name, &binding_origins);
                }

                var arm_result = try validateBlock(allocator, body, &arm_origins, arm.body_block_id, diagnostics, summary_data);
                defer arm_result.deinit();

                if (arm_result.fallthrough) {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeOuterBranch(&saw_fallthrough, &outer_origins, &arm_result.fallthrough_state);
                }
                if (arm_result.has_break) {
                    result.has_break = true;
                    try result.break_state.mergeFrom(&arm_result.break_state);
                }
                if (arm_result.has_continue) {
                    result.has_continue = true;
                    try result.continue_state.mergeFrom(&arm_result.continue_state);
                }
            }

            if (statement.select_else_block_id) |else_block_id| {
                var else_result = try validateBlock(allocator, body, origins, else_block_id, diagnostics, summary_data);
                defer else_result.deinit();

                if (else_result.fallthrough) {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeOuterBranch(&saw_fallthrough, &outer_origins, &else_result.fallthrough_state);
                }
                if (else_result.has_break) {
                    result.has_break = true;
                    try result.break_state.mergeFrom(&else_result.break_state);
                }
                if (else_result.has_continue) {
                    result.has_continue = true;
                    try result.continue_state.mergeFrom(&else_result.continue_state);
                }
            }
        },
        .loop_stmt => {
            var loop_result = try validateLoop(allocator, body, origins, statement, diagnostics, summary_data);
            defer loop_result.deinit();

            if (loop_result.fallthrough) {
                result.fallthrough = true;
                try result.fallthrough_state.mergeFrom(&loop_result.fallthrough_state);
            }
            if (loop_result.has_break) {
                result.has_break = true;
                try result.break_state.mergeFrom(&loop_result.break_state);
            }
            if (loop_result.has_continue) {
                result.has_continue = true;
                try result.continue_state.mergeFrom(&loop_result.continue_state);
            }
        },
        .unsafe_block => {
            if (statement.unsafe_block_id) |unsafe_block_id| {
                var block_result = try validateBlock(allocator, body, origins, unsafe_block_id, diagnostics, summary_data);
                defer block_result.deinit();

                if (block_result.fallthrough) {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeFrom(&block_result.fallthrough_state);
                }
                if (block_result.has_break) {
                    result.has_break = true;
                    try result.break_state.mergeFrom(&block_result.break_state);
                }
                if (block_result.has_continue) {
                    result.has_continue = true;
                    try result.continue_state.mergeFrom(&block_result.continue_state);
                }
            } else {
                result.fallthrough = true;
                try result.fallthrough_state.mergeFrom(origins);
            }
        },
        .return_stmt => {
            if (statement.expr) |expr| {
                summary_data.return_statements_checked += 1;
                summary_data.rejected_returns += try validateReturnExpr(body.item, body.function, origins, expr, diagnostics);
            }
        },
        .break_stmt => {
            result.has_break = true;
            try result.break_state.mergeFrom(origins);
        },
        .continue_stmt => {
            result.has_continue = true;
            try result.continue_state.mergeFrom(origins);
        },
        .placeholder,
        .defer_stmt,
        .expr_stmt,
        => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(origins);
        },
    }

    return result;
}

fn validateLoop(
    allocator: Allocator,
    body: anytype,
    origins: *const OriginState,
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
            try result.fallthrough_state.mergeFrom(origins);
            return result;
        },
        .may_skip => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(origins);
        },
        .must_enter_may_exit_via_break_only => {},
    }

    const loop_body_id = statement.loop_body_block_id orelse {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(origins);
        return result;
    };

    var iteration_origins = try origins.clone();
    defer iteration_origins.deinit();

    var iteration_count: usize = 0;
    while (iteration_count < 8) : (iteration_count += 1) {
        var body_result = try validateBlock(allocator, body, &iteration_origins, loop_body_id, diagnostics, summary_data);
        defer body_result.deinit();

        if (body_result.has_break) {
            if (!result.fallthrough) {
                try result.fallthrough_state.mergeFrom(&iteration_origins);
            }
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&body_result.break_state);
        }

        var carried_origins = OriginState.init(allocator);
        defer carried_origins.deinit();
        if (body_result.fallthrough) try carried_origins.mergeFrom(&body_result.fallthrough_state);
        if (body_result.has_continue) try carried_origins.mergeFrom(&body_result.continue_state);
        if (carried_origins.isEmpty()) break;

        if (condition == .may_skip) {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&carried_origins);
        }

        var next_iteration = try iteration_origins.clone();
        errdefer next_iteration.deinit();
        try next_iteration.mergeFrom(&carried_origins);
        if (next_iteration.eql(&iteration_origins)) {
            next_iteration.deinit();
            break;
        }

        iteration_origins.deinit();
        iteration_origins = next_iteration;
    }

    return result;
}

fn validateReturnExpr(
    item: *const typed.Item,
    function: *const typed.FunctionData,
    origins: *const OriginState,
    expr: *const typed.Expr,
    diagnostics: *diag.Bag,
) !usize {
    const expected = boundaryFromRawType(function.return_type_name);
    switch (expected.kind) {
        .value => return 0,
        .ephemeral => {
            try diagnostics.add(.@"error", "lifetime.return.ephemeral", item.span, "function '{s}' may not return an ephemeral borrow across a boundary", .{item.name});
            return 1;
        },
        .retained => {
            var actual_set = try inferExprOrigins(diagnostics.allocator, origins, expr);
            defer actual_set.deinit();
            if (actual_set.values.items.len == 0) {
                try diagnostics.add(.@"error", "lifetime.return.retained_source", item.span, "function '{s}' returns a retained borrow but the returned expression is not retained", .{item.name});
                return 1;
            }

            for (actual_set.values.items) |actual| {
                switch (actual.kind) {
                    .value => {
                        try diagnostics.add(.@"error", "lifetime.return.retained_source", item.span, "function '{s}' returns a retained borrow but the returned expression is not retained", .{item.name});
                        return 1;
                    },
                    .ephemeral => {
                        try diagnostics.add(.@"error", "lifetime.return.ephemeral_source", item.span, "function '{s}' returns a retained borrow derived only from an ephemeral boundary borrow", .{item.name});
                        return 1;
                    },
                    .retained => {},
                }
            }

            for (actual_set.values.items) |actual| {
                if (actual.kind != .retained) continue;
                if (actual.access != expected.access) {
                    try diagnostics.add(.@"error", "lifetime.return.mode", item.span, "function '{s}' returns a retained borrow with the wrong access mode", .{item.name});
                    return 1;
                }

                const actual_lifetime = actual.lifetime_name orelse {
                    try diagnostics.add(.@"error", "lifetime.return.retained_source", item.span, "function '{s}' returns a retained borrow but the returned expression is not retained", .{item.name});
                    return 1;
                };
                const expected_lifetime = expected.lifetime_name orelse unreachable;
                if (!try lifetimeOutlives(diagnostics.allocator, function.where_predicates, actual_lifetime, expected_lifetime)) {
                    try diagnostics.add(.@"error", "lifetime.return.outlives", item.span, "function '{s}' returns lifetime '{s}' where '{s}' is required without an outlives proof", .{
                        item.name,
                        actual_lifetime,
                        expected_lifetime,
                    });
                    return 1;
                }
            }
            return 0;
        },
    }
}

fn boundaryFromParameter(parameter: typed.Parameter) BoundaryType {
    const retained = boundaryFromRawType(parameter.type_name);
    if (retained.kind == .retained) return retained;

    return switch (parameter.mode) {
        .read => .{
            .kind = .ephemeral,
            .access = .read,
            .inner_type_name = parameter.type_name,
        },
        .edit => .{
            .kind = .ephemeral,
            .access = .edit,
            .inner_type_name = parameter.type_name,
        },
        .owned, .take => .{
            .kind = .value,
            .inner_type_name = parameter.type_name,
        },
    };
}

fn boundaryFromTypeRef(ty: types.TypeRef) BoundaryType {
    return boundaryFromRawType(typeRefRawName(ty));
}

fn classifyLoopCondition(condition: ?*const typed.Expr) LoopCondition {
    const expr = condition orelse return .must_enter_may_exit_via_break_only;
    return switch (expr.node) {
        .bool_lit => |value| if (value) .must_enter_may_exit_via_break_only else .never_enters,
        else => .may_skip,
    };
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

fn inferExprOrigins(
    allocator: Allocator,
    origins: *const OriginState,
    expr: *const typed.Expr,
) !OriginSet {
    var inferred = OriginSet.init(allocator);
    errdefer inferred.deinit();

    const direct_boundary = boundaryFromTypeRef(expr.ty);
    switch (expr.node) {
        .identifier => |name| {
            if (origins.lookup(name)) |known| {
                try inferred.mergeFrom(known);
            } else if (direct_boundary.kind != .value) {
                try inferred.add(direct_boundary);
            } else {
                try inferred.add(.{});
            }
        },
        .field => |field| {
            var base_origins = try inferExprOrigins(allocator, origins, field.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                if (base_origin.kind == .value and direct_boundary.kind != .value) {
                    try inferred.add(direct_boundary);
                } else {
                    try inferred.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
                }
            }
        },
        .method_target => |target| {
            var base_origins = try inferExprOrigins(allocator, origins, target.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                if (base_origin.kind == .value and direct_boundary.kind != .value) {
                    try inferred.add(direct_boundary);
                } else {
                    try inferred.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
                }
            }
        },
        .index => |index| {
            var base_origins = try inferExprOrigins(allocator, origins, index.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                if (base_origin.kind == .value and direct_boundary.kind != .value) {
                    try inferred.add(direct_boundary);
                } else {
                    try inferred.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
                }
            }
        },
        .integer,
        .bool_lit,
        .string,
        .enum_variant,
        .enum_tag,
        .enum_constructor_target,
        .enum_construct,
        .call,
        .constructor,
        .array,
        .array_repeat,
        .conversion,
        .unary,
        .binary,
        => {
            if (direct_boundary.kind != .value) {
                try inferred.add(direct_boundary);
            } else {
                try inferred.add(.{});
            }
        },
    }

    return inferred;
}

fn projectBoundary(origin: BoundaryType, inner_type_name: []const u8) BoundaryType {
    return switch (origin.kind) {
        .value => .{ .inner_type_name = inner_type_name },
        .ephemeral, .retained => .{
            .kind = origin.kind,
            .access = origin.access,
            .lifetime_name = origin.lifetime_name,
            .inner_type_name = inner_type_name,
        },
    };
}

fn lifetimeOutlives(
    allocator: Allocator,
    where_predicates: []const typed.WherePredicate,
    longer_name: []const u8,
    shorter_name: []const u8,
) !bool {
    if (std.mem.eql(u8, longer_name, shorter_name)) return true;
    if (std.mem.eql(u8, longer_name, "'static")) return true;
    if (std.mem.eql(u8, shorter_name, "'static")) return false;

    var seen = array_list.Managed([]const u8).init(allocator);
    defer seen.deinit();
    var queue = array_list.Managed([]const u8).init(allocator);
    defer queue.deinit();

    try seen.append(longer_name);
    try queue.append(longer_name);

    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const current = queue.items[index];
        for (where_predicates) |predicate| {
            switch (predicate) {
                .lifetime_outlives => |outlives| {
                    if (!std.mem.eql(u8, outlives.longer_name, current)) continue;
                    if (std.mem.eql(u8, outlives.shorter_name, shorter_name)) return true;
                    if (containsName(seen.items, outlives.shorter_name)) continue;
                    try seen.append(outlives.shorter_name);
                    try queue.append(outlives.shorter_name);
                },
                else => {},
            }
        }
    }

    return false;
}

fn containsBoundary(values: []const BoundaryType, needle: BoundaryType) bool {
    for (values) |value| {
        if (boundaryEql(value, needle)) return true;
    }
    return false;
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

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn typeRefRawName(ty: types.TypeRef) []const u8 {
    return switch (ty) {
        .builtin => |builtin| builtin.displayName(),
        .named => |name| name,
        .unsupported => "Unsupported",
    };
}
