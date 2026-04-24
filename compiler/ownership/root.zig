const std = @import("std");
const array_list = std.array_list;
const diag = @import("../diag/root.zig");
const checked_body = @import("../query/checked_body.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");

pub const explicit_by_default = true;
pub const consuming_owner = "take";
pub const stable_owner = "hold";

pub const BodySummary = struct {
    rejected_bindings: usize = 0,
    move_after_take: usize = 0,
    borrow_conflicts: usize = 0,
    checked_place_count: usize = 0,
    cfg_edge_count: usize = 0,
    invalid_cfg_edges: usize = 0,
};

pub fn validateCheckedBody(
    allocator: std.mem.Allocator,
    body: anytype,
    callable_resolver: anytype,
    diagnostics: *diag.Bag,
) !BodySummary {
    var summary_data = BodySummary{
        .checked_place_count = body.places.len,
        .cfg_edge_count = body.cfg_edges.len,
    };

    try validatePlaceFacts(allocator, body.places, body.item.span, diagnostics, &summary_data);
    try validateCfgFacts(body.summary.statement_count, body.cfg_edges, body.item.span, diagnostics, &summary_data);

    var places = PlaceSet.init(allocator);
    defer places.deinit();
    for (body.places) |place| {
        if (place.kind != .parameter) continue;
        try places.put(place.name);
    }

    try validateBlock(callable_resolver, body, &places, body.root_block_id, body.item.span, diagnostics, &summary_data);
    return summary_data;
}

fn validatePlaceFacts(
    allocator: std.mem.Allocator,
    place_facts: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (place_facts) |place| {
        if (place.kind == .assignment_target) continue;
        if (seen.contains(place.name)) {
            summary_data.rejected_bindings += 1;
            try diagnostics.add(.@"error", "ownership.binding.shadow", span, "stage0 rejects rebinding local name '{s}' in one function scope", .{place.name});
            continue;
        }
        try seen.put(place.name, {});
    }
}

fn validateCfgFacts(
    statement_count: usize,
    cfg_edges: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    for (cfg_edges) |edge| {
        const from_valid = edge.from_statement < statement_count;
        const to_valid = edge.to_statement < statement_count or edge.to_statement == checked_body.exit_statement;
        if (from_valid and to_valid) continue;
        summary_data.invalid_cfg_edges += 1;
        try diagnostics.add(.@"error", "ownership.cfg.invalid", span, "checked ownership CFG contains an invalid edge", .{});
    }
}

const Place = struct {
    name: []const u8,
    consumed: bool = false,
};

const PlaceSet = struct {
    places: array_list.Managed(Place),

    fn init(allocator: std.mem.Allocator) PlaceSet {
        return .{ .places = array_list.Managed(Place).init(allocator) };
    }

    fn deinit(self: *PlaceSet) void {
        self.places.deinit();
    }

    fn put(self: *PlaceSet, name: []const u8) !void {
        if (self.findIndex(name)) |index| {
            self.places.items[index].consumed = false;
            return;
        }
        try self.places.append(.{ .name = name });
    }

    fn contains(self: *const PlaceSet, name: []const u8) bool {
        return self.findIndex(name) != null;
    }

    fn markConsumed(self: *PlaceSet, name: []const u8) void {
        if (self.findIndex(name)) |index| self.places.items[index].consumed = true;
    }

    fn isConsumed(self: *const PlaceSet, name: []const u8) bool {
        if (self.findIndex(name)) |index| return self.places.items[index].consumed;
        return false;
    }

    fn findIndex(self: *const PlaceSet, name: []const u8) ?usize {
        for (self.places.items, 0..) |place, index| {
            if (std.mem.eql(u8, place.name, name)) return index;
        }
        return null;
    }
};

fn validateBlock(
    callable_resolver: anytype,
    body: anytype,
    places: *PlaceSet,
    block_id: usize,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!void {
    if (block_id >= body.block_sites.len) return;
    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (statement_index >= body.statement_sites.len) continue;
        try validateStatement(callable_resolver, body, places, body.statement_sites[statement_index], span, diagnostics, summary_data);
    }
}

fn validateStatement(
    callable_resolver: anytype,
    body: anytype,
    places: *PlaceSet,
    statement: checked_body.StatementSite,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!void {
    switch (statement.kind) {
        .let_decl => {
            if (statement.binding_expr) |expr| try validateExpr(callable_resolver, places, expr, span, diagnostics, summary_data);
            if (statement.binding_name) |name| try places.put(name);
        },
        .const_decl => {
            if (statement.binding_expr) |expr| try validateExpr(callable_resolver, places, expr, span, diagnostics, summary_data);
            if (statement.binding_name) |name| try places.put(name);
        },
        .assign_stmt => {
            if (statement.assign_expr) |expr| try validateExpr(callable_resolver, places, expr, span, diagnostics, summary_data);
            if (statement.assign_name) |name| try places.put(name);
        },
        .select_stmt => {
            if (statement.select_subject_temp_name) |name| {
                try places.put(name);
            }
            if (statement.select_subject) |subject| try validateExpr(callable_resolver, places, subject, span, diagnostics, summary_data);
            for (statement.select_arms) |arm| {
                try validateExpr(callable_resolver, places, arm.condition, span, diagnostics, summary_data);
                for (arm.bindings) |binding| {
                    try places.put(binding.name);
                }
                try validateBlock(callable_resolver, body, places, arm.body_block_id, span, diagnostics, summary_data);
            }
            if (statement.select_else_block_id) |else_block_id| {
                try validateBlock(callable_resolver, body, places, else_block_id, span, diagnostics, summary_data);
            }
        },
        .loop_stmt => {
            if (statement.loop_condition) |condition| try validateExpr(callable_resolver, places, condition, span, diagnostics, summary_data);
            if (statement.loop_body_block_id) |loop_body_id| {
                try validateBlock(callable_resolver, body, places, loop_body_id, span, diagnostics, summary_data);
            }
        },
        .unsafe_block => {
            if (statement.unsafe_block_id) |unsafe_block_id| {
                try validateBlock(callable_resolver, body, places, unsafe_block_id, span, diagnostics, summary_data);
            }
        },
        .defer_stmt,
        .return_stmt,
        .expr_stmt,
        => if (statement.expr) |expr| try validateExpr(callable_resolver, places, expr, span, diagnostics, summary_data),
        .placeholder,
        .break_stmt,
        .continue_stmt,
        => {},
    }
}

fn validateExpr(
    callable_resolver: anytype,
    places: *PlaceSet,
    expr: *const typed.Expr,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!void {
    switch (expr.node) {
        .identifier => |name| try validateUse(places, name, span, diagnostics, summary_data),
        .field => |field| try validateExpr(callable_resolver, places, field.base, span, diagnostics, summary_data),
        .method_target => |target| try validateExpr(callable_resolver, places, target.base, span, diagnostics, summary_data),
        .constructor => |constructor| {
            for (constructor.args) |arg| try validateExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
        },
        .enum_construct => |construct| {
            for (construct.args) |arg| try validateExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
        },
        .array_repeat => |array_repeat| {
            try validateExpr(callable_resolver, places, array_repeat.value, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, array_repeat.length, span, diagnostics, summary_data);
        },
        .call => |call| {
            try validateCallArgumentConflicts(callable_resolver, places, call, span, diagnostics, summary_data);
            for (call.args, 0..) |arg, index| {
                try validateExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
                if (calleeParameterMode(callable_resolver, call.callee, index)) |mode| {
                    if (mode == .take) markTakenPlace(places, arg);
                }
            }
        },
        .unary => |unary| try validateExpr(callable_resolver, places, unary.operand, span, diagnostics, summary_data),
        .binary => |binary| {
            try validateExpr(callable_resolver, places, binary.lhs, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, binary.rhs, span, diagnostics, summary_data);
        },
        .integer,
        .bool_lit,
        .string,
        .enum_variant,
        .enum_tag,
        .enum_constructor_target,
        => {},
    }
}

const CallAccess = enum {
    read,
    edit,
    take,
};

fn validateCallArgumentConflicts(
    callable_resolver: anytype,
    places: *PlaceSet,
    call: typed.Expr.Call,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    _ = places;
    for (call.args, 0..) |lhs, lhs_index| {
        const lhs_access = callAccessForMode(calleeParameterMode(callable_resolver, call.callee, lhs_index) orelse .owned) orelse continue;
        var rhs_index = lhs_index + 1;
        while (rhs_index < call.args.len) : (rhs_index += 1) {
            const rhs = call.args[rhs_index];
            const rhs_access = callAccessForMode(calleeParameterMode(callable_resolver, call.callee, rhs_index) orelse .owned) orelse continue;
            if (!callAccessesConflict(lhs_access, rhs_access)) continue;
            if (!placesOverlap(lhs, rhs)) continue;

            summary_data.borrow_conflicts += 1;
            try diagnostics.add(
                .@"error",
                "ownership.borrow_conflict",
                span,
                "call to '{s}' uses overlapping places with conflicting ownership modes",
                .{call.callee},
            );
        }
    }
}

fn callAccessForMode(mode: typed.ParameterMode) ?CallAccess {
    return switch (mode) {
        .read => .read,
        .edit => .edit,
        .take => .take,
        .owned => null,
    };
}

fn callAccessesConflict(lhs: CallAccess, rhs: CallAccess) bool {
    return switch (lhs) {
        .read => rhs != .read,
        .edit, .take => true,
    };
}

const PlaceProjection = struct {
    root: []const u8,
    field: ?[]const u8 = null,
};

fn placesOverlap(lhs: *const typed.Expr, rhs: *const typed.Expr) bool {
    const lhs_place = placeProjection(lhs) orelse return false;
    const rhs_place = placeProjection(rhs) orelse return false;
    if (!std.mem.eql(u8, lhs_place.root, rhs_place.root)) return false;
    if (lhs_place.field == null or rhs_place.field == null) return true;
    return std.mem.eql(u8, lhs_place.field.?, rhs_place.field.?);
}

fn placeProjection(expr: *const typed.Expr) ?PlaceProjection {
    return switch (expr.node) {
        .identifier => |name| .{ .root = name },
        .field => |field| blk: {
            const root = placeRootName(field.base) orelse break :blk null;
            break :blk .{
                .root = root,
                .field = field.field_name,
            };
        },
        else => null,
    };
}

fn placeRootName(expr: *const typed.Expr) ?[]const u8 {
    return switch (expr.node) {
        .identifier => |name| name,
        .field => |field| placeRootName(field.base),
        else => null,
    };
}

fn validateUse(
    places: *PlaceSet,
    name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) !void {
    if (!places.isConsumed(name)) return;
    summary_data.move_after_take += 1;
    try diagnostics.add(.@"error", "ownership.move_after_take", span, "use of '{s}' after it was consumed by take", .{name});
}

fn markTakenPlace(places: *PlaceSet, expr: *const typed.Expr) void {
    switch (expr.node) {
        .identifier => |name| places.markConsumed(name),
        .field => |field| markTakenPlace(places, field.base),
        else => {},
    }
}

fn calleeParameterMode(callable_resolver: anytype, callee_name: []const u8, parameter_index: usize) ?typed.ParameterMode {
    return callable_resolver.parameterMode(callee_name, parameter_index);
}
