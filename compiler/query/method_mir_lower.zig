const std = @import("std");
const mir = @import("../mir/root.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");

const Allocator = std.mem.Allocator;

pub fn lowerExecutableMethod(
    allocator: Allocator,
    name: []const u8,
    symbol_name: []const u8,
    span: source.Span,
    function: *const typed.FunctionData,
    is_entry_candidate: bool,
) !mir.Item {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_symbol_name = try allocator.dupe(u8, symbol_name);
    errdefer allocator.free(owned_symbol_name);

    const params = try allocator.alloc(mir.Parameter, function.parameters.items.len);
    errdefer allocator.free(params);
    for (function.parameters.items, 0..) |parameter, index| {
        params[index] = .{
            .name = parameter.name,
            .mode = parameter.mode,
            .ty = parameter.ty,
        };
    }

    var body = try lowerBlock(allocator, &function.body);
    errdefer body.deinit(allocator);

    return .{
        .name = owned_name,
        .owned_name = owned_name,
        .symbol_name = owned_symbol_name,
        .owned_symbol_name = owned_symbol_name,
        .kind = .value,
        .is_entry_candidate = is_entry_candidate,
        .span = span,
        .payload = .{ .function = .{
            .return_type = function.return_type,
            .parameters = params,
            .body = body,
            .export_name = function.export_name,
            .is_suspend = function.is_suspend,
            .foreign = function.foreign,
        } },
    };
}

fn lowerBlock(allocator: Allocator, block: *const typed.Block) anyerror!mir.Block {
    var lowered = mir.Block.init(allocator);
    errdefer lowered.deinit(allocator);
    for (block.statements.items) |statement| {
        try lowered.statements.append(try lowerStatement(allocator, statement));
    }
    return lowered;
}

fn lowerStatement(allocator: Allocator, statement: typed.Statement) anyerror!mir.Statement {
    return switch (statement) {
        .placeholder => .placeholder,
        .let_decl => |binding| .{ .let_decl = .{
            .name = binding.name,
            .ty = binding.ty,
            .expr = try mir.cloneTypedExpr(allocator, binding.expr),
        } },
        .const_decl => |binding| .{ .const_decl = .{
            .name = binding.name,
            .ty = binding.ty,
            .expr = try mir.cloneTypedExpr(allocator, binding.expr),
        } },
        .assign_stmt => |assign| .{ .assign_stmt = .{
            .name = assign.name,
            .ty = assign.ty,
            .op = assign.op,
            .expr = try mir.cloneTypedExpr(allocator, assign.expr),
        } },
        .select_stmt => |select_data| blk: {
            var arms = try allocator.alloc(mir.Statement.SelectArm, select_data.arms.len);
            errdefer allocator.free(arms);
            for (select_data.arms, 0..) |arm, index| {
                const arm_body = try allocator.create(mir.Block);
                errdefer allocator.destroy(arm_body);
                arm_body.* = try lowerBlock(allocator, arm.body);
                errdefer arm_body.deinit(allocator);

                const bindings = try allocator.alloc(mir.Statement.SelectBinding, arm.bindings.len);
                errdefer allocator.free(bindings);
                for (arm.bindings, 0..) |binding, binding_index| {
                    bindings[binding_index] = .{
                        .name = binding.name,
                        .ty = binding.ty,
                        .expr = try mir.cloneTypedExpr(allocator, binding.expr),
                    };
                }
                arms[index] = .{
                    .condition = try mir.cloneTypedExpr(allocator, arm.condition),
                    .bindings = bindings,
                    .body = arm_body,
                };
            }

            var else_body: ?*mir.Block = null;
            if (select_data.else_body) |body| {
                const lowered_else = try allocator.create(mir.Block);
                errdefer allocator.destroy(lowered_else);
                lowered_else.* = try lowerBlock(allocator, body);
                else_body = lowered_else;
            }

            const result = try allocator.create(mir.Statement.SelectData);
            errdefer allocator.destroy(result);
            result.* = .{
                .subject = if (select_data.subject) |subject| try mir.cloneTypedExpr(allocator, subject) else null,
                .subject_temp_name = if (select_data.subject_temp_name) |value| try allocator.dupe(u8, value) else null,
                .arms = arms,
                .else_body = else_body,
            };
            break :blk .{ .select_stmt = result };
        },
        .loop_stmt => |loop_data| blk: {
            const lowered_body = try allocator.create(mir.Block);
            errdefer allocator.destroy(lowered_body);
            lowered_body.* = try lowerBlock(allocator, loop_data.body);

            const result = try allocator.create(mir.Statement.LoopData);
            errdefer allocator.destroy(result);
            result.* = .{
                .condition = if (loop_data.condition) |condition| try mir.cloneTypedExpr(allocator, condition) else null,
                .body = lowered_body,
            };
            break :blk .{ .loop_stmt = result };
        },
        .unsafe_block => |body| blk: {
            const lowered_body = try allocator.create(mir.Block);
            errdefer allocator.destroy(lowered_body);
            lowered_body.* = try lowerBlock(allocator, body);
            break :blk .{ .unsafe_block = lowered_body };
        },
        .defer_stmt => |expr| .{ .defer_stmt = try mir.cloneTypedExpr(allocator, expr) },
        .break_stmt => .break_stmt,
        .continue_stmt => .continue_stmt,
        .return_stmt => |maybe_expr| .{ .return_stmt = if (maybe_expr) |expr| try mir.cloneTypedExpr(allocator, expr) else null },
        .expr_stmt => |expr| .{ .expr_stmt = try mir.cloneTypedExpr(allocator, expr) },
    };
}
