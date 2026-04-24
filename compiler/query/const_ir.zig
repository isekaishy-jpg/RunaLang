const std = @import("std");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Dedicated const IR lowering and deterministic evaluation.";

pub const Value = union(types.Builtin) {
    unit: void,
    bool: bool,
    i32: i32,
    u32: u32,
    index: usize,
    str: []const u8,
    unsupported: void,
};

pub const Expr = struct {
    result_type: types.Builtin,
    node: Node,

    pub const Node = union(enum) {
        literal: Value,
        const_ref: []const u8,
        unary: Unary,
        binary: Binary,
    };

    pub const Unary = struct {
        op: typed.UnaryOp,
        operand: *Expr,
    };

    pub const Binary = struct {
        op: typed.BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    };
};

pub fn destroyExpr(allocator: Allocator, expr: *const Expr) void {
    const mutable_expr = @constCast(expr);
    switch (mutable_expr.node) {
        .literal,
        .const_ref,
        => {},
        .unary => |unary| destroyExpr(allocator, unary.operand),
        .binary => |binary| {
            destroyExpr(allocator, binary.lhs);
            destroyExpr(allocator, binary.rhs);
        },
    }
    allocator.destroy(mutable_expr);
}

pub fn lowerExpr(allocator: Allocator, expr: *const typed.Expr) anyerror!*Expr {
    const lowered = try allocator.create(Expr);
    var root_owned = true;
    errdefer if (root_owned) allocator.destroy(lowered);

    lowered.result_type = switch (expr.ty) {
        .builtin => |builtin| builtin,
        else => .unsupported,
    };
    lowered.node = switch (expr.node) {
        .integer => |value| .{ .literal = try integerLiteralValue(lowered.result_type, value) },
        .bool_lit => |value| .{ .literal = .{ .bool = value } },
        .string => |value| .{ .literal = .{ .str = value } },
        .identifier => |name| .{ .const_ref = name },
        .unary => |unary| .{ .unary = .{
            .op = unary.op,
            .operand = try lowerExpr(allocator, unary.operand),
        } },
        .binary => |binary| blk: {
            const lhs = try lowerExpr(allocator, binary.lhs);
            const rhs = lowerExpr(allocator, binary.rhs) catch |err| {
                destroyExpr(allocator, lhs);
                return err;
            };
            break :blk .{ .binary = .{
                .op = binary.op,
                .lhs = lhs,
                .rhs = rhs,
            } };
        },
        .enum_variant,
        .enum_tag,
        .enum_constructor_target,
        .enum_construct,
        .call,
        .constructor,
        .method_target,
        .field,
        .array_repeat,
        => return error.UnsupportedConstExpr,
    };
    root_owned = false;
    return lowered;
}

pub fn evalExpr(context: anytype, expr: *const Expr, resolve_identifier: anytype) anyerror!Value {
    switch (expr.node) {
        .literal => |value| return value,
        .const_ref => |name| return resolve_identifier(context, name),
        .unary => |unary| {
            const operand = try evalExpr(context, unary.operand, resolve_identifier);
            return evalUnary(expr.result_type, unary.op, operand);
        },
        .binary => |binary| {
            const lhs = try evalExpr(context, binary.lhs, resolve_identifier);
            const rhs = try evalExpr(context, binary.rhs, resolve_identifier);
            return evalBinary(expr.result_type, binary.op, lhs, rhs);
        },
    }
}

pub fn integerLiteralValue(result_type: types.Builtin, value: i64) !Value {
    return switch (result_type) {
        .i32 => blk: {
            if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.ConstOverflow;
            break :blk .{ .i32 = @intCast(value) };
        },
        .u32 => blk: {
            if (value < 0 or value > std.math.maxInt(u32)) return error.ConstOverflow;
            break :blk .{ .u32 = @intCast(value) };
        },
        .index => blk: {
            if (value < 0 or value > std.math.maxInt(usize)) return error.ConstOverflow;
            break :blk .{ .index = @intCast(value) };
        },
        else => error.UnsupportedConstExpr,
    };
}

fn evalUnary(result_type: types.Builtin, op: typed.UnaryOp, operand: Value) anyerror!Value {
    return switch (op) {
        .bool_not => switch (result_type) {
            .bool => .{ .bool = !operand.bool },
            else => error.UnsupportedConstExpr,
        },
        .negate => switch (result_type) {
            .i32 => blk: {
                const negated = @subWithOverflow(@as(i32, 0), operand.i32);
                if (negated[1] != 0) return error.ConstOverflow;
                break :blk .{ .i32 = negated[0] };
            },
            else => error.UnsupportedConstExpr,
        },
        .bit_not => switch (result_type) {
            .i32 => .{ .i32 = ~operand.i32 },
            .u32 => .{ .u32 = ~operand.u32 },
            .index => .{ .index = ~operand.index },
            else => error.UnsupportedConstExpr,
        },
    };
}

fn evalBinary(result_type: types.Builtin, op: typed.BinaryOp, lhs: Value, rhs: Value) anyerror!Value {
    switch (result_type) {
        .i32 => {
            const left = lhs.i32;
            return .{ .i32 = switch (op) {
                .add => try addChecked(i32, left, rhs.i32),
                .sub => try subChecked(i32, left, rhs.i32),
                .mul => try mulChecked(i32, left, rhs.i32),
                .div => try divCheckedI32(left, rhs.i32),
                .mod => try modCheckedI32(left, rhs.i32),
                .shl => try shlChecked(i32, left, rhs.index),
                .shr => try shrChecked(i32, left, rhs.index),
                .bit_and => left & rhs.i32,
                .bit_xor => left ^ rhs.i32,
                .bit_or => left | rhs.i32,
                else => return error.UnsupportedConstExpr,
            } };
        },
        .u32 => {
            const left = lhs.u32;
            return .{ .u32 = switch (op) {
                .add => try addChecked(u32, left, rhs.u32),
                .sub => try subChecked(u32, left, rhs.u32),
                .mul => try mulChecked(u32, left, rhs.u32),
                .div => try divCheckedUnsigned(u32, left, rhs.u32),
                .mod => try modCheckedUnsigned(u32, left, rhs.u32),
                .shl => try shlChecked(u32, left, rhs.index),
                .shr => try shrChecked(u32, left, rhs.index),
                .bit_and => left & rhs.u32,
                .bit_xor => left ^ rhs.u32,
                .bit_or => left | rhs.u32,
                else => return error.UnsupportedConstExpr,
            } };
        },
        .index => {
            const left = lhs.index;
            return .{ .index = switch (op) {
                .add => try addChecked(usize, left, rhs.index),
                .sub => try subChecked(usize, left, rhs.index),
                .mul => try mulChecked(usize, left, rhs.index),
                .div => try divCheckedUnsigned(usize, left, rhs.index),
                .mod => try modCheckedUnsigned(usize, left, rhs.index),
                .shl => try shlChecked(usize, left, rhs.index),
                .shr => try shrChecked(usize, left, rhs.index),
                .bit_and => left & rhs.index,
                .bit_xor => left ^ rhs.index,
                .bit_or => left | rhs.index,
                else => return error.UnsupportedConstExpr,
            } };
        },
        .bool => return .{ .bool = switch (op) {
            .eq => eql(lhs, rhs),
            .ne => !eql(lhs, rhs),
            .lt => compare(lhs, rhs, .lt),
            .lte => compare(lhs, rhs, .lte),
            .gt => compare(lhs, rhs, .gt),
            .gte => compare(lhs, rhs, .gte),
            .bool_and => lhs.bool and rhs.bool,
            .bool_or => lhs.bool or rhs.bool,
            else => return error.UnsupportedConstExpr,
        } },
        else => return error.UnsupportedConstExpr,
    }
}

fn addChecked(comptime T: type, lhs: T, rhs: T) !T {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.ConstOverflow;
    return result[0];
}

fn subChecked(comptime T: type, lhs: T, rhs: T) !T {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.ConstOverflow;
    return result[0];
}

fn mulChecked(comptime T: type, lhs: T, rhs: T) !T {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.ConstOverflow;
    return result[0];
}

fn divCheckedI32(lhs: i32, rhs: i32) !i32 {
    if (rhs == 0) return error.DivideByZero;
    if (lhs == std.math.minInt(i32) and rhs == -1) return error.ConstOverflow;
    return @divTrunc(lhs, rhs);
}

fn modCheckedI32(lhs: i32, rhs: i32) !i32 {
    if (rhs == 0) return error.InvalidRemainder;
    return @mod(lhs, rhs);
}

fn divCheckedUnsigned(comptime T: type, lhs: T, rhs: T) !T {
    if (rhs == 0) return error.DivideByZero;
    return @divTrunc(lhs, rhs);
}

fn modCheckedUnsigned(comptime T: type, lhs: T, rhs: T) !T {
    if (rhs == 0) return error.InvalidRemainder;
    return @mod(lhs, rhs);
}

fn shlChecked(comptime T: type, lhs: T, rhs: usize) !T {
    const bit_count = @bitSizeOf(T);
    if (rhs >= bit_count) return error.InvalidShiftCount;
    const amount: std.math.Log2Int(T) = @intCast(rhs);
    const result = @shlWithOverflow(lhs, amount);
    if (result[1] != 0) return error.ConstOverflow;
    return result[0];
}

fn shrChecked(comptime T: type, lhs: T, rhs: usize) !T {
    const bit_count = @bitSizeOf(T);
    if (rhs >= bit_count) return error.InvalidShiftCount;
    const amount: std.math.Log2Int(T) = @intCast(rhs);
    return lhs >> amount;
}

fn eql(lhs: Value, rhs: Value) bool {
    return switch (lhs) {
        .bool => lhs.bool == rhs.bool,
        .i32 => lhs.i32 == rhs.i32,
        .u32 => lhs.u32 == rhs.u32,
        .index => lhs.index == rhs.index,
        .str => std.mem.eql(u8, lhs.str, rhs.str),
        .unit => true,
        .unsupported => false,
    };
}

fn compare(lhs: Value, rhs: Value, comptime mode: enum { lt, lte, gt, gte }) bool {
    return switch (lhs) {
        .i32 => switch (mode) {
            .lt => lhs.i32 < rhs.i32,
            .lte => lhs.i32 <= rhs.i32,
            .gt => lhs.i32 > rhs.i32,
            .gte => lhs.i32 >= rhs.i32,
        },
        .u32 => switch (mode) {
            .lt => lhs.u32 < rhs.u32,
            .lte => lhs.u32 <= rhs.u32,
            .gt => lhs.u32 > rhs.u32,
            .gte => lhs.u32 >= rhs.u32,
        },
        .index => switch (mode) {
            .lt => lhs.index < rhs.index,
            .lte => lhs.index <= rhs.index,
            .gt => lhs.index > rhs.index,
            .gte => lhs.index >= rhs.index,
        },
        else => false,
    };
}
