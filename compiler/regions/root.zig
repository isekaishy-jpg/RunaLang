const std = @import("std");
const array_list = std.array_list;
const checked_body = @import("../query/checked_body.zig");
const diag = @import("../diag/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Region-aware lifetime validation over merged typed control flow.";
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
        return .{
            .values = array_list.Managed(BoundaryType).init(allocator),
        };
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

    fn count(self: *const OriginSet) usize {
        return self.values.items.len;
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

pub const BodySummary = struct {
    statements_seen: usize = 0,
    blocks_seen: usize = 0,
    return_statements_checked: usize = 0,
    rejected_returns: usize = 0,
    checked_place_count: usize = 0,
    cfg_edge_count: usize = 0,
    effect_site_count: usize = 0,
    invalid_cfg_edges: usize = 0,
    invalid_effect_sites: usize = 0,
};

const LoopCondition = enum {
    never_enters,
    may_skip,
    must_enter_may_exit_via_break_only,
};

pub fn analyzeCheckedBody(
    allocator: Allocator,
    body: anytype,
    diagnostics: *diag.Bag,
) anyerror!BodySummary {
    var summary_data = BodySummary{
        .checked_place_count = body.places.len,
        .cfg_edge_count = body.cfg_edges.len,
        .effect_site_count = body.effect_sites.len,
    };
    try validateCheckedFacts(body.summary.statement_count, body.cfg_edges, body.effect_sites, diagnostics, &summary_data);

    var state = OriginState.init(allocator);
    defer state.deinit();
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        const parameter_index = place.parameter_index orelse continue;
        if (parameter_index >= body.parameters.len) continue;
        try state.putSingle(place.name, boundaryFromParameter(body.parameters[parameter_index]));
    }

    var result = try analyzeBlock(allocator, body, &state, body.root_block_id, diagnostics, &summary_data);
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
        try diagnostics.add(.@"error", "region.cfg.invalid", null, "checked region CFG contains an invalid edge", .{});
    }
    for (effect_sites) |site| {
        if (site.statement_index < statement_count) continue;
        summary_data.invalid_effect_sites += 1;
        try diagnostics.add(.@"error", "region.effect.invalid", null, "checked region effect site refers to an invalid statement", .{});
    }
}

fn analyzeBlock(
    allocator: Allocator,
    body: anytype,
    initial_state: *const OriginState,
    block_id: usize,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    if (block_id >= body.block_sites.len) {
        var empty = FlowResult.init(allocator);
        empty.fallthrough = true;
        try empty.fallthrough_state.mergeFrom(initial_state);
        return empty;
    }

    const block = body.block_sites[block_id];
    summary_data.blocks_seen += 1;
    summary_data.statements_seen += block.statement_indices.len;

    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    var current_state = try initial_state.clone();
    defer current_state.deinit();

    var reachable = true;
    for (block.statement_indices) |statement_index| {
        if (!reachable) break;
        if (statement_index >= body.statement_sites.len) continue;
        const statement = body.statement_sites[statement_index];

        var effect = try analyzeStatement(allocator, body, &current_state, statement, diagnostics, summary_data);
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

        current_state.deinit();
        current_state = try effect.fallthrough_state.clone();
    }

    if (reachable) {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(&current_state);
    }

    return result;
}

fn analyzeStatement(
    allocator: Allocator,
    body: anytype,
    state: *const OriginState,
    statement: checked_body.StatementSite,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    switch (statement.kind) {
        .let_decl, .const_decl => {
            var next_state = try state.clone();
            defer next_state.deinit();
            if (statement.binding_name) |name| {
                if (statement.binding_expr) |expr| {
                    var origins = try inferExprOrigins(allocator, state, expr);
                    defer origins.deinit();
                    try next_state.putSet(name, &origins);
                }
            }
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_state);
        },
        .assign_stmt => {
            var next_state = try state.clone();
            defer next_state.deinit();

            if (statement.assign_op == null) {
                const name = statement.assign_name orelse {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeFrom(&next_state);
                    return result;
                };
                if (std.mem.indexOfScalar(u8, name, '.')) |_| {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeFrom(&next_state);
                    return result;
                }
                if (statement.assign_expr) |expr| {
                    var origins = try inferExprOrigins(allocator, state, expr);
                    defer origins.deinit();
                    try next_state.putSet(name, &origins);
                }
            }

            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_state);
        },
        .select_stmt => {
            var subject_origins = OriginSet.init(allocator);
            defer subject_origins.deinit();

            if (statement.select_subject) |subject| {
                subject_origins = try inferExprOrigins(allocator, state, subject);
            }

            for (statement.select_arms) |arm| {
                var arm_state = try state.clone();
                defer arm_state.deinit();

                if (statement.select_subject_temp_name) |name| {
                    try arm_state.putSet(name, &subject_origins);
                }

                for (arm.bindings) |binding| {
                    var binding_origins = try inferExprOrigins(allocator, &arm_state, binding.expr);
                    defer binding_origins.deinit();
                    try arm_state.putSet(binding.name, &binding_origins);
                }

                var arm_result = try analyzeBlock(allocator, body, &arm_state, arm.body_block_id, diagnostics, summary_data);
                defer arm_result.deinit();

                if (arm_result.fallthrough) {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeFrom(&arm_result.fallthrough_state);
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
                var else_state = try state.clone();
                defer else_state.deinit();

                var else_result = try analyzeBlock(allocator, body, &else_state, else_block_id, diagnostics, summary_data);
                defer else_result.deinit();

                if (else_result.fallthrough) {
                    result.fallthrough = true;
                    try result.fallthrough_state.mergeFrom(&else_result.fallthrough_state);
                }
                if (else_result.has_break) {
                    result.has_break = true;
                    try result.break_state.mergeFrom(&else_result.break_state);
                }
                if (else_result.has_continue) {
                    result.has_continue = true;
                    try result.continue_state.mergeFrom(&else_result.continue_state);
                }
            } else {
                result.fallthrough = true;
                try result.fallthrough_state.mergeFrom(state);
            }
        },
        .loop_stmt => {
            var loop_result = try analyzeLoop(allocator, body, state, statement, diagnostics, summary_data);
            defer loop_result.deinit();

            if (loop_result.fallthrough) {
                result.fallthrough = true;
                try result.fallthrough_state.mergeFrom(&loop_result.fallthrough_state);
            }
        },
        .unsafe_block => {
            if (statement.unsafe_block_id) |unsafe_block_id| {
                var block_result = try analyzeBlock(allocator, body, state, unsafe_block_id, diagnostics, summary_data);
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
            }
        },
        .break_stmt => {
            result.has_break = true;
            try result.break_state.mergeFrom(state);
        },
        .continue_stmt => {
            result.has_continue = true;
            try result.continue_state.mergeFrom(state);
        },
        .return_stmt => {
            if (statement.expr) |expr| {
                summary_data.return_statements_checked += 1;
                summary_data.rejected_returns += try validateReturnExpr(body.item, body.function, state, expr, diagnostics);
            }
        },
        .placeholder,
        .defer_stmt,
        .expr_stmt,
        => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(state);
        },
    }

    return result;
}

fn analyzeLoop(
    allocator: Allocator,
    body: anytype,
    state: *const OriginState,
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
            try result.fallthrough_state.mergeFrom(state);
            return result;
        },
        .may_skip => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(state);
        },
        .must_enter_may_exit_via_break_only => {},
    }

    var iteration_state = try state.clone();
    defer iteration_state.deinit();

    const loop_body_id = statement.loop_body_block_id orelse {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(state);
        return result;
    };

    var iteration_count: usize = 0;
    while (iteration_count < 8) : (iteration_count += 1) {
        var body_result = try analyzeBlock(allocator, body, &iteration_state, loop_body_id, diagnostics, summary_data);
        defer body_result.deinit();

        if (body_result.has_break) {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&body_result.break_state);
        }

        var carried_state = OriginState.init(allocator);
        defer carried_state.deinit();

        if (body_result.fallthrough) try carried_state.mergeFrom(&body_result.fallthrough_state);
        if (body_result.has_continue) try carried_state.mergeFrom(&body_result.continue_state);

        if (carried_state.isEmpty()) break;

        if (condition == .may_skip) {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&carried_state);
        }

        var next_iteration = try iteration_state.clone();
        errdefer next_iteration.deinit();
        try next_iteration.mergeFrom(&carried_state);
        if (next_iteration.eql(&iteration_state)) {
            next_iteration.deinit();
            break;
        }

        iteration_state.deinit();
        iteration_state = next_iteration;
    }

    return result;
}

fn validateReturnExpr(
    item: *const typed.Item,
    function: *const typed.FunctionData,
    state: *const OriginState,
    expr: *const typed.Expr,
    diagnostics: *diag.Bag,
) !usize {
    const expected = boundaryFromRawType(function.return_type.displayName());
    if (expected.kind != .retained) return 0;

    var actual_set = try inferExprOrigins(diagnostics.allocator, state, expr);
    defer actual_set.deinit();

    if (actual_set.count() <= 1) return 0;

    var saw_value = false;
    var saw_ephemeral = false;
    var saw_mode_mismatch = false;
    var missing_lifetime = false;
    var failed_outlives: ?[]const u8 = null;

    const expected_lifetime = expected.lifetime_name orelse return 0;
    for (actual_set.values.items) |actual| {
        switch (actual.kind) {
            .value => saw_value = true,
            .ephemeral => saw_ephemeral = true,
            .retained => {
                if (actual.access != expected.access) {
                    saw_mode_mismatch = true;
                    continue;
                }

                const actual_lifetime = actual.lifetime_name orelse {
                    missing_lifetime = true;
                    continue;
                };
                if (!try lifetimeOutlives(diagnostics.allocator, function.where_predicates, actual_lifetime, expected_lifetime)) {
                    failed_outlives = actual_lifetime;
                }
            },
        }
    }

    if (saw_value) {
        try diagnostics.add(.@"error", "region.return.retained_source", item.span, "function '{s}' may return a non-retained value after region merges where a retained borrow is required", .{item.name});
        return 1;
    }
    if (saw_ephemeral) {
        try diagnostics.add(.@"error", "region.return.ephemeral_source", item.span, "function '{s}' may return an ephemeral borrow after region merges where a retained borrow is required", .{item.name});
        return 1;
    }
    if (saw_mode_mismatch) {
        try diagnostics.add(.@"error", "region.return.mode", item.span, "function '{s}' may return the wrong retained access mode after region merges", .{item.name});
        return 1;
    }
    if (missing_lifetime) {
        try diagnostics.add(.@"error", "region.return.retained_source", item.span, "function '{s}' may return a retained borrow without a concrete lifetime source after region merges", .{item.name});
        return 1;
    }
    if (failed_outlives) |actual_lifetime| {
        try diagnostics.add(.@"error", "region.return.outlives", item.span, "function '{s}' may return lifetime '{s}' where '{s}' is required after region merges without an outlives proof", .{
            item.name,
            actual_lifetime,
            expected_lifetime,
        });
        return 1;
    }

    return 0;
}

fn inferExprOrigins(
    allocator: Allocator,
    state: *const OriginState,
    expr: *const typed.Expr,
) anyerror!OriginSet {
    var origins = OriginSet.init(allocator);
    errdefer origins.deinit();

    const direct_boundary = boundaryFromTypeRef(expr.ty);
    if (direct_boundary.kind != .value) {
        try origins.add(direct_boundary);
        return origins;
    }

    switch (expr.node) {
        .identifier => |name| {
            if (state.lookup(name)) |known| {
                try origins.mergeFrom(known);
            } else {
                try origins.add(.{});
            }
        },
        .field => |field| {
            var base_origins = try inferExprOrigins(allocator, state, field.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                try origins.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
            }
        },
        .method_target => |target| {
            var base_origins = try inferExprOrigins(allocator, state, target.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                try origins.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
            }
        },
        .tuple => |tuple| {
            for (tuple.items) |item| {
                var item_origins = try inferExprOrigins(allocator, state, item);
                defer item_origins.deinit();
                try origins.mergeFrom(&item_origins);
            }
        },
        .index => |index| {
            var base_origins = try inferExprOrigins(allocator, state, index.base);
            defer base_origins.deinit();
            for (base_origins.values.items) |base_origin| {
                try origins.add(projectBoundary(base_origin, typeRefRawName(expr.ty)));
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
        => try origins.add(.{}),
    }

    return origins;
}

fn classifyLoopCondition(condition: ?*const typed.Expr) LoopCondition {
    const expr = condition orelse return .must_enter_may_exit_via_break_only;
    return switch (expr.node) {
        .bool_lit => |value| if (value) .must_enter_may_exit_via_break_only else .never_enters,
        else => .may_skip,
    };
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

fn boundaryFromParameter(parameter: typed.Parameter) BoundaryType {
    const retained = boundaryFromRawType(parameter.ty.displayName());
    if (retained.kind == .retained) return retained;

    return switch (parameter.mode) {
        .read => .{
            .kind = .ephemeral,
            .access = .read,
            .inner_type_name = parameter.ty.displayName(),
        },
        .edit => .{
            .kind = .ephemeral,
            .access = .edit,
            .inner_type_name = parameter.ty.displayName(),
        },
        .owned, .take => .{
            .kind = .value,
            .inner_type_name = parameter.ty.displayName(),
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
        const lifetime_name = std.mem.trim(u8, trimmed["hold[".len .. close_index], " \t");
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

fn boundaryEql(a: BoundaryType, b: BoundaryType) bool {
    return a.kind == b.kind and
        a.access == b.access and
        optionalNameEql(a.lifetime_name, b.lifetime_name) and
        std.mem.eql(u8, a.inner_type_name, b.inner_type_name);
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
