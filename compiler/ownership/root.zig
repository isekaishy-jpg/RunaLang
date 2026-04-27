const std = @import("std");
const array_list = std.array_list;
const diag = @import("../diag/root.zig");
const checked_body = @import("../query/checked_body.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");

pub const explicit_by_default = true;
pub const consuming_owner = "take";
pub const stable_owner = "hold";

pub const BodySummary = struct {
    rejected_bindings: usize = 0,
    move_after_take: usize = 0,
    move_only_moves: usize = 0,
    rejected_implicit_copies: usize = 0,
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
        try places.put(place.name, place.ty);
    }

    var result = try validateBlock(allocator, callable_resolver, body, &places, body.root_block_id, body.item.span, diagnostics, &summary_data);
    result.deinit();
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
    ty: types.TypeRef,
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

    fn clone(self: *const PlaceSet, allocator: std.mem.Allocator) !PlaceSet {
        var cloned = PlaceSet.init(allocator);
        errdefer cloned.deinit();
        for (self.places.items) |place| {
            try cloned.places.append(place);
        }
        return cloned;
    }

    fn replaceWith(self: *PlaceSet, replacement: *PlaceSet) void {
        const allocator = self.places.allocator;
        self.deinit();
        self.* = replacement.*;
        replacement.* = PlaceSet.init(allocator);
    }

    fn put(self: *PlaceSet, name: []const u8, ty: types.TypeRef) !void {
        if (self.findIndex(name)) |index| {
            self.places.items[index].ty = ty;
            self.places.items[index].consumed = false;
            return;
        }
        try self.places.append(.{
            .name = name,
            .ty = ty,
        });
    }

    fn contains(self: *const PlaceSet, name: []const u8) bool {
        return self.findIndex(name) != null;
    }

    fn markConsumed(self: *PlaceSet, name: []const u8) void {
        if (self.findIndex(name)) |index| self.places.items[index].consumed = true;
    }

    fn mergeConsumedFrom(self: *PlaceSet, other: *const PlaceSet) void {
        for (other.places.items) |place| {
            if (!place.consumed) continue;
            if (self.findIndex(place.name)) |index| {
                self.places.items[index].consumed = true;
            }
        }
    }

    fn mergeFrom(self: *PlaceSet, other: *const PlaceSet) !void {
        for (other.places.items) |place| {
            if (self.findIndex(place.name)) |index| {
                self.places.items[index].consumed = self.places.items[index].consumed or place.consumed;
            } else {
                try self.places.append(place);
            }
        }
    }

    fn eql(self: *const PlaceSet, other: *const PlaceSet) bool {
        if (self.places.items.len != other.places.items.len) return false;
        for (self.places.items) |place| {
            const other_index = other.findIndex(place.name) orelse return false;
            if (place.consumed != other.places.items[other_index].consumed) return false;
        }
        return true;
    }

    fn isConsumed(self: *const PlaceSet, name: []const u8) bool {
        if (self.findIndex(name)) |index| return self.places.items[index].consumed;
        return false;
    }

    fn typeOf(self: *const PlaceSet, name: []const u8) ?types.TypeRef {
        if (self.findIndex(name)) |index| return self.places.items[index].ty;
        return null;
    }

    fn findIndex(self: *const PlaceSet, name: []const u8) ?usize {
        for (self.places.items, 0..) |place, index| {
            if (std.mem.eql(u8, place.name, name)) return index;
        }
        return null;
    }
};

const FlowResult = struct {
    fallthrough: bool = false,
    fallthrough_state: PlaceSet,
    has_break: bool = false,
    break_state: PlaceSet,
    has_continue: bool = false,
    continue_state: PlaceSet,

    fn init(allocator: std.mem.Allocator) FlowResult {
        return .{
            .fallthrough_state = PlaceSet.init(allocator),
            .break_state = PlaceSet.init(allocator),
            .continue_state = PlaceSet.init(allocator),
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
    callable_resolver: anytype,
    body: anytype,
    initial_places: *const PlaceSet,
    block_id: usize,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    if (block_id >= body.block_sites.len) {
        var empty = FlowResult.init(allocator);
        empty.fallthrough = true;
        try empty.fallthrough_state.mergeFrom(initial_places);
        return empty;
    }

    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    var current_places = try initial_places.clone(allocator);
    defer current_places.deinit();

    var reachable = true;
    for (body.block_sites[block_id].statement_indices) |statement_index| {
        if (!reachable) break;
        if (statement_index >= body.statement_sites.len) continue;
        var effect = try validateStatement(allocator, callable_resolver, body, &current_places, body.statement_sites[statement_index], span, diagnostics, summary_data);
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

        current_places.deinit();
        current_places = try effect.fallthrough_state.clone(allocator);
    }

    if (reachable) {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(&current_places);
    }

    return result;
}

fn validateStatement(
    allocator: std.mem.Allocator,
    callable_resolver: anytype,
    body: anytype,
    places: *const PlaceSet,
    statement: checked_body.StatementSite,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    switch (statement.kind) {
        .let_decl => {
            var next_places = try places.clone(allocator);
            defer next_places.deinit();
            if (statement.binding_expr) |expr| try validateOwnedValueExpr(callable_resolver, &next_places, expr, span, diagnostics, summary_data);
            if (statement.binding_name) |name| try next_places.put(name, statement.binding_ty);
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_places);
        },
        .const_decl => {
            var next_places = try places.clone(allocator);
            defer next_places.deinit();
            if (statement.binding_expr) |expr| try validateOwnedValueExpr(callable_resolver, &next_places, expr, span, diagnostics, summary_data);
            if (statement.binding_name) |name| try next_places.put(name, statement.binding_ty);
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_places);
        },
        .assign_stmt => {
            var next_places = try places.clone(allocator);
            defer next_places.deinit();
            if (statement.assign_expr) |expr| try validateOwnedValueExpr(callable_resolver, &next_places, expr, span, diagnostics, summary_data);
            if (statement.assign_name) |name| try next_places.put(name, statement.assign_ty);
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_places);
        },
        .select_stmt => {
            var select_places = try places.clone(allocator);
            defer select_places.deinit();

            if (statement.select_subject_temp_name) |name| {
                const subject_ty = if (statement.select_subject) |subject| subject.ty else types.TypeRef.unsupported;
                try select_places.put(name, subject_ty);
            }
            if (statement.select_subject) |subject| try validateExpr(callable_resolver, &select_places, subject, span, diagnostics, summary_data);

            var merged_places = try select_places.clone(allocator);
            errdefer merged_places.deinit();
            var saw_fallthrough = false;
            for (statement.select_arms) |arm| {
                var arm_places = try select_places.clone(allocator);
                defer arm_places.deinit();

                try validateExpr(callable_resolver, &arm_places, arm.condition, span, diagnostics, summary_data);
                for (arm.bindings) |binding| {
                    try arm_places.put(binding.name, binding.ty);
                }
                var arm_result = try validateBlock(allocator, callable_resolver, body, &arm_places, arm.body_block_id, span, diagnostics, summary_data);
                defer arm_result.deinit();

                if (arm_result.fallthrough) {
                    saw_fallthrough = true;
                    merged_places.mergeConsumedFrom(&arm_result.fallthrough_state);
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
                var else_places = try select_places.clone(allocator);
                defer else_places.deinit();

                var else_result = try validateBlock(allocator, callable_resolver, body, &else_places, else_block_id, span, diagnostics, summary_data);
                defer else_result.deinit();

                if (else_result.fallthrough) {
                    saw_fallthrough = true;
                    merged_places.mergeConsumedFrom(&else_result.fallthrough_state);
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
                saw_fallthrough = true;
            }
            if (saw_fallthrough) {
                result.fallthrough = true;
                try result.fallthrough_state.mergeFrom(&merged_places);
            }
            merged_places.deinit();
        },
        .loop_stmt => {
            var loop_result = try validateLoop(allocator, callable_resolver, body, places, statement, span, diagnostics, summary_data);
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
                var block_result = try validateBlock(allocator, callable_resolver, body, places, unsafe_block_id, span, diagnostics, summary_data);
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
                try result.fallthrough_state.mergeFrom(places);
            }
        },
        .defer_stmt,
        .expr_stmt,
        => {
            var next_places = try places.clone(allocator);
            defer next_places.deinit();
            if (statement.expr) |expr| try validateExpr(callable_resolver, &next_places, expr, span, diagnostics, summary_data);
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&next_places);
        },
        .return_stmt => {
            var return_places = try places.clone(allocator);
            defer return_places.deinit();
            if (statement.expr) |expr| try validateOwnedValueExpr(callable_resolver, &return_places, expr, span, diagnostics, summary_data);
        },
        .break_stmt => {
            result.has_break = true;
            try result.break_state.mergeFrom(places);
        },
        .continue_stmt => {
            result.has_continue = true;
            try result.continue_state.mergeFrom(places);
        },
        .placeholder,
        => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(places);
        },
    }

    return result;
}

fn validateLoop(
    allocator: std.mem.Allocator,
    callable_resolver: anytype,
    body: anytype,
    places: *const PlaceSet,
    statement: checked_body.StatementSite,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!FlowResult {
    var result = FlowResult.init(allocator);
    errdefer result.deinit();

    var condition_places = try places.clone(allocator);
    defer condition_places.deinit();
    if (statement.loop_condition) |condition| try validateExpr(callable_resolver, &condition_places, condition, span, diagnostics, summary_data);

    const condition = classifyLoopCondition(statement.loop_condition);
    switch (condition) {
        .never_enters => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&condition_places);
            return result;
        },
        .may_skip => {
            result.fallthrough = true;
            try result.fallthrough_state.mergeFrom(&condition_places);
        },
        .must_enter_may_exit_via_break_only => {},
    }

    const loop_body_id = statement.loop_body_block_id orelse {
        result.fallthrough = true;
        try result.fallthrough_state.mergeFrom(&condition_places);
        return result;
    };

    var iteration_places = try condition_places.clone(allocator);
    defer iteration_places.deinit();

    var iteration_count: usize = 0;
    while (iteration_count < 8) : (iteration_count += 1) {
        var body_result = try validateBlock(allocator, callable_resolver, body, &iteration_places, loop_body_id, span, diagnostics, summary_data);
        defer body_result.deinit();

        if (body_result.has_break) {
            if (!result.fallthrough) {
                try result.fallthrough_state.mergeFrom(&iteration_places);
            }
            result.fallthrough = true;
            result.fallthrough_state.mergeConsumedFrom(&body_result.break_state);
        }

        var carried_places = try iteration_places.clone(allocator);
        defer carried_places.deinit();
        var has_carried = false;
        if (body_result.fallthrough) {
            carried_places.mergeConsumedFrom(&body_result.fallthrough_state);
            has_carried = true;
        }
        if (body_result.has_continue) {
            carried_places.mergeConsumedFrom(&body_result.continue_state);
            has_carried = true;
        }
        if (!has_carried) break;

        if (condition == .may_skip) {
            result.fallthrough = true;
            result.fallthrough_state.mergeConsumedFrom(&carried_places);
        }

        var next_iteration = try iteration_places.clone(allocator);
        errdefer next_iteration.deinit();
        next_iteration.mergeConsumedFrom(&carried_places);
        if (next_iteration.eql(&iteration_places)) {
            next_iteration.deinit();
            break;
        }

        iteration_places.deinit();
        iteration_places = next_iteration;
    }

    return result;
}

fn classifyLoopCondition(condition: ?*const typed.Expr) LoopCondition {
    const expr = condition orelse return .must_enter_may_exit_via_break_only;
    return switch (expr.node) {
        .bool_lit => |value| if (value) .must_enter_may_exit_via_break_only else .never_enters,
        else => .may_skip,
    };
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
        .tuple => |tuple| {
            for (tuple.items) |item| try validateExpr(callable_resolver, places, item, span, diagnostics, summary_data);
        },
        .array => |array| {
            for (array.items) |item| try validateExpr(callable_resolver, places, item, span, diagnostics, summary_data);
        },
        .array_repeat => |array_repeat| {
            try validateExpr(callable_resolver, places, array_repeat.value, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, array_repeat.length, span, diagnostics, summary_data);
        },
        .index => |index| {
            try validateExpr(callable_resolver, places, index.base, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, index.index, span, diagnostics, summary_data);
        },
        .conversion => |conversion| try validateExpr(callable_resolver, places, conversion.operand, span, diagnostics, summary_data),
        .call => |call| {
            try validateCallArgumentConflicts(callable_resolver, places, call, span, diagnostics, summary_data);
            for (call.args, 0..) |arg, index| {
                const mode = calleeParameterMode(callable_resolver, call.callee, index) orelse .owned;
                switch (mode) {
                    .take => {
                        try validateOwnedValueExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
                        markTakenPlace(places, arg);
                    },
                    .owned => {
                        if (try callable_resolver.isMoveOnlyType(arg.ty)) {
                            try validateOwnedValueExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
                        } else {
                            try validateExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
                        }
                    },
                    .read, .edit => try validateExpr(callable_resolver, places, arg, span, diagnostics, summary_data),
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

fn validateOwnedValueExpr(
    callable_resolver: anytype,
    places: *PlaceSet,
    expr: *const typed.Expr,
    span: source.Span,
    diagnostics: *diag.Bag,
    summary_data: *BodySummary,
) anyerror!void {
    switch (expr.node) {
        .identifier => |name| {
            try validateUse(places, name, span, diagnostics, summary_data);
            const ty = places.typeOf(name) orelse expr.ty;
            if (try callable_resolver.isMoveOnlyType(ty)) {
                places.markConsumed(name);
                summary_data.move_only_moves += 1;
            }
        },
        .field => |field| {
            try validateExpr(callable_resolver, places, field.base, span, diagnostics, summary_data);
            if (try callable_resolver.isMoveOnlyType(expr.ty)) {
                markTakenPlace(places, expr);
                summary_data.move_only_moves += 1;
            }
        },
        .method_target => |target| {
            try validateExpr(callable_resolver, places, target.base, span, diagnostics, summary_data);
            if (try callable_resolver.isMoveOnlyType(expr.ty)) {
                markTakenPlace(places, expr);
                summary_data.move_only_moves += 1;
            }
        },
        .constructor => |constructor| {
            for (constructor.args) |arg| try validateOwnedValueExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
        },
        .enum_construct => |construct| {
            for (construct.args) |arg| try validateOwnedValueExpr(callable_resolver, places, arg, span, diagnostics, summary_data);
        },
        .tuple => |tuple| {
            for (tuple.items) |item| try validateOwnedValueExpr(callable_resolver, places, item, span, diagnostics, summary_data);
        },
        .array => |array| {
            for (array.items) |item| try validateOwnedValueExpr(callable_resolver, places, item, span, diagnostics, summary_data);
        },
        .array_repeat => |array_repeat| {
            if (try callable_resolver.isMoveOnlyType(array_repeat.value.ty)) {
                switch (array_repeat.length.node) {
                    .integer => |length| if (length > 1) {
                        summary_data.rejected_implicit_copies += 1;
                        try diagnostics.add(.@"error", "ownership.move_only.repeat", span, "array repetition would implicitly duplicate a move-only value", .{});
                    },
                    else => {
                        summary_data.rejected_implicit_copies += 1;
                        try diagnostics.add(.@"error", "ownership.move_only.repeat", span, "array repetition of a move-only value requires an explicit non-duplicating length", .{});
                    },
                }
            }
            try validateOwnedValueExpr(callable_resolver, places, array_repeat.value, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, array_repeat.length, span, diagnostics, summary_data);
        },
        .index => |index| {
            try validateExpr(callable_resolver, places, index.base, span, diagnostics, summary_data);
            try validateExpr(callable_resolver, places, index.index, span, diagnostics, summary_data);
            if (try callable_resolver.isMoveOnlyType(expr.ty)) {
                markTakenPlace(places, expr);
                summary_data.move_only_moves += 1;
            }
        },
        .conversion => |conversion| try validateOwnedValueExpr(callable_resolver, places, conversion.operand, span, diagnostics, summary_data),
        .call => try validateExpr(callable_resolver, places, expr, span, diagnostics, summary_data),
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
        .index => |index| markTakenPlace(places, index.base),
        else => {},
    }
}

fn calleeParameterMode(callable_resolver: anytype, callee_name: []const u8, parameter_index: usize) ?typed.ParameterMode {
    return callable_resolver.parameterMode(callee_name, parameter_index);
}
