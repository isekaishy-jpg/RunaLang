const std = @import("std");
const array_list = std.array_list;
const checked_body = @import("../query/checked_body.zig");
const diag = @import("../diag/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");

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

const NamedOrigin = struct {
    name: []const u8,
    origin: BoundaryType,
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

    var origins = array_list.Managed(NamedOrigin).init(allocator);
    defer origins.deinit();
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        const parameter_index = place.parameter_index orelse continue;
        if (parameter_index >= body.parameters.len) continue;
        try putOrigin(&origins, place.name, boundaryFromParameter(body.parameters[parameter_index]));
    }

    try validateBlock(allocator, body, &origins, body.root_block_id, diagnostics, &summary_data);
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
    allocator: std.mem.Allocator,
    body: anytype,
    origins: *array_list.Managed(NamedOrigin),
    block_id: usize,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    if (block_id >= body.block_sites.len) return;
    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (statement_index >= body.statement_sites.len) continue;
        const statement = body.statement_sites[statement_index];
        switch (statement.kind) {
            .let_decl, .const_decl => {
                const name = statement.binding_name orelse continue;
                const expr = statement.binding_expr orelse continue;
                try putOrigin(origins, name, inferExprOrigin(origins.items, expr));
            },
            .assign_stmt => {
                const name = statement.assign_name orelse continue;
                const expr = statement.assign_expr orelse continue;
                if (std.mem.indexOfScalar(u8, name, '.')) |_| continue;
                const next_origin = if (statement.assign_op == null)
                    inferExprOrigin(origins.items, expr)
                else
                    BoundaryType{};
                try putOrigin(origins, name, next_origin);
            },
            .select_stmt => {
                const subject_origin = if (statement.select_subject) |subject|
                    inferExprOrigin(origins.items, subject)
                else
                    BoundaryType{};

                for (statement.select_arms) |arm| {
                    var arm_origins = try cloneOrigins(allocator, origins.items);
                    defer arm_origins.deinit();

                    if (statement.select_subject_temp_name) |name| {
                        try putOrigin(&arm_origins, name, subject_origin);
                    }
                    for (arm.bindings) |binding| {
                        try putOrigin(&arm_origins, binding.name, inferExprOrigin(arm_origins.items, binding.expr));
                    }
                    try validateBlock(allocator, body, &arm_origins, arm.body_block_id, diagnostics, summary_data);
                }

                if (statement.select_else_block_id) |else_block_id| {
                    var else_origins = try cloneOrigins(allocator, origins.items);
                    defer else_origins.deinit();
                    try validateBlock(allocator, body, &else_origins, else_block_id, diagnostics, summary_data);
                }
            },
            .loop_stmt => {
                var loop_origins = try cloneOrigins(allocator, origins.items);
                defer loop_origins.deinit();
                if (statement.loop_body_block_id) |loop_body_id| {
                    try validateBlock(allocator, body, &loop_origins, loop_body_id, diagnostics, summary_data);
                }
            },
            .unsafe_block => {
                var unsafe_origins = try cloneOrigins(allocator, origins.items);
                defer unsafe_origins.deinit();
                if (statement.unsafe_block_id) |unsafe_block_id| {
                    try validateBlock(allocator, body, &unsafe_origins, unsafe_block_id, diagnostics, summary_data);
                }
            },
            .return_stmt => {
                if (statement.expr) |expr| {
                    summary_data.return_statements_checked += 1;
                    summary_data.rejected_returns += try validateReturnExpr(body.item, body.function, origins.items, expr, diagnostics);
                }
            },
            .placeholder,
            .defer_stmt,
            .break_stmt,
            .continue_stmt,
            .expr_stmt,
            => {},
        }
    }
}

fn validateReturnExpr(
    item: *const typed.Item,
    function: *const typed.FunctionData,
    origins: []const NamedOrigin,
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
            const actual = inferExprOrigin(origins, expr);
            switch (actual.kind) {
                .value => {
                    try diagnostics.add(.@"error", "lifetime.return.retained_source", item.span, "function '{s}' returns a retained borrow but the returned expression is not retained", .{item.name});
                    return 1;
                },
                .ephemeral => {
                    try diagnostics.add(.@"error", "lifetime.return.ephemeral_source", item.span, "function '{s}' returns a retained borrow derived only from an ephemeral boundary borrow", .{item.name});
                    return 1;
                },
                .retained => {
                    if (actual.access != expected.access) {
                        try diagnostics.add(.@"error", "lifetime.return.mode", item.span, "function '{s}' returns a retained borrow with the wrong access mode", .{item.name});
                        return 1;
                    }

                    const actual_lifetime = actual.lifetime_name orelse {
                        try diagnostics.add(.@"error", "lifetime.return.retained_source", item.span, "function '{s}' returns a retained borrow without a concrete lifetime source", .{item.name});
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
                    return 0;
                },
            }
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
        .array_repeat,
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

fn cloneOrigins(allocator: std.mem.Allocator, origins: []const NamedOrigin) !array_list.Managed(NamedOrigin) {
    var cloned = array_list.Managed(NamedOrigin).init(allocator);
    errdefer cloned.deinit();
    try cloned.appendSlice(origins);
    return cloned;
}

fn lifetimeOutlives(
    allocator: std.mem.Allocator,
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
