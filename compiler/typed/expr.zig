const std = @import("std");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    shl,
    shr,
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    bit_and,
    bit_xor,
    bit_or,
    bool_and,
    bool_or,
};

pub const UnaryOp = enum {
    bool_not,
    negate,
    bit_not,
};

pub const Expr = struct {
    ty: types.TypeRef,
    owned_type_name: ?[]u8 = null,
    node: Node,

    pub const Node = union(enum) {
        integer: i64,
        bool_lit: bool,
        string: []const u8,
        identifier: []const u8,
        enum_variant: EnumVariantValue,
        enum_tag: EnumVariantValue,
        enum_constructor_target: EnumVariantValue,
        enum_construct: EnumConstruct,
        call: Call,
        constructor: Constructor,
        method_target: MethodTarget,
        field: Field,
        array_repeat: ArrayRepeat,
        unary: Unary,
        binary: Binary,
    };

    pub const Call = struct {
        callee: []const u8,
        args: []*Expr,
    };

    pub const EnumVariantValue = struct {
        enum_name: []const u8,
        enum_symbol: []const u8,
        variant_name: []const u8,
    };

    pub const EnumConstruct = struct {
        enum_name: []const u8,
        enum_symbol: []const u8,
        variant_name: []const u8,
        args: []*Expr,
    };

    pub const Constructor = struct {
        type_name: []const u8,
        type_symbol: []const u8,
        args: []*Expr,
    };

    pub const MethodTarget = struct {
        base: *Expr,
        target_type: []const u8,
        method_name: []const u8,
    };

    pub const Field = struct {
        base: *Expr,
        field_name: []const u8,
    };

    pub const ArrayRepeat = struct {
        value: *Expr,
        length: *Expr,
    };

    pub const Binary = struct {
        op: BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        if (self.owned_type_name) |owned_type_name| allocator.free(owned_type_name);
        switch (self.node) {
            .enum_construct => |construct| {
                for (construct.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(construct.args);
            },
            .call => |call| {
                for (call.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(call.args);
            },
            .constructor => |constructor| {
                for (constructor.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(constructor.args);
            },
            .method_target => |target| {
                target.base.deinit(allocator);
                allocator.destroy(target.base);
            },
            .field => |field| {
                field.base.deinit(allocator);
                allocator.destroy(field.base);
            },
            .array_repeat => |array_repeat| {
                array_repeat.value.deinit(allocator);
                allocator.destroy(array_repeat.value);
                array_repeat.length.deinit(allocator);
                allocator.destroy(array_repeat.length);
            },
            .unary => |unary| {
                unary.operand.deinit(allocator);
                allocator.destroy(unary.operand);
            },
            .binary => |binary| {
                binary.lhs.deinit(allocator);
                allocator.destroy(binary.lhs);
                binary.rhs.deinit(allocator);
                allocator.destroy(binary.rhs);
            },
            else => {},
        }
    }
};

pub fn cloneExpr(allocator: Allocator, expr: *const Expr) !*Expr {
    const result = try allocator.create(Expr);
    errdefer allocator.destroy(result);

    result.ty = expr.ty;
    result.owned_type_name = if (expr.owned_type_name) |owned_type_name|
        try allocator.dupe(u8, owned_type_name)
    else
        null;
    if (result.owned_type_name) |owned_type_name| {
        result.ty = .{ .named = owned_type_name };
    }
    errdefer if (result.owned_type_name) |owned_type_name| allocator.free(owned_type_name);
    result.node = switch (expr.node) {
        .integer => |value| .{ .integer = value },
        .bool_lit => |value| .{ .bool_lit = value },
        .string => |value| .{ .string = value },
        .identifier => |value| .{ .identifier = value },
        .enum_variant => |value| .{ .enum_variant = value },
        .enum_tag => |value| .{ .enum_tag = value },
        .enum_constructor_target => |value| .{ .enum_constructor_target = value },
        .enum_construct => |construct| blk: {
            const args = try allocator.alloc(*Expr, construct.args.len);
            errdefer allocator.free(args);
            for (construct.args, 0..) |arg, arg_index| {
                args[arg_index] = try cloneExpr(allocator, arg);
            }
            break :blk .{ .enum_construct = .{
                .enum_name = construct.enum_name,
                .enum_symbol = construct.enum_symbol,
                .variant_name = construct.variant_name,
                .args = args,
            } };
        },
        .call => |call| blk: {
            const args = try allocator.alloc(*Expr, call.args.len);
            errdefer allocator.free(args);
            for (call.args, 0..) |arg, arg_index| {
                args[arg_index] = try cloneExpr(allocator, arg);
            }
            break :blk .{ .call = .{
                .callee = call.callee,
                .args = args,
            } };
        },
        .constructor => |constructor| blk: {
            const args = try allocator.alloc(*Expr, constructor.args.len);
            errdefer allocator.free(args);
            for (constructor.args, 0..) |arg, arg_index| {
                args[arg_index] = try cloneExpr(allocator, arg);
            }
            break :blk .{ .constructor = .{
                .type_name = constructor.type_name,
                .type_symbol = constructor.type_symbol,
                .args = args,
            } };
        },
        .method_target => |target| .{ .method_target = .{
            .base = try cloneExpr(allocator, target.base),
            .target_type = target.target_type,
            .method_name = target.method_name,
        } },
        .field => |field| .{ .field = .{
            .base = try cloneExpr(allocator, field.base),
            .field_name = field.field_name,
        } },
        .array_repeat => |array_repeat| .{ .array_repeat = .{
            .value = try cloneExpr(allocator, array_repeat.value),
            .length = try cloneExpr(allocator, array_repeat.length),
        } },
        .binary => |binary| .{ .binary = .{
            .op = binary.op,
            .lhs = try cloneExpr(allocator, binary.lhs),
            .rhs = try cloneExpr(allocator, binary.rhs),
        } },
        .unary => |unary| .{ .unary = .{
            .op = unary.op,
            .operand = try cloneExpr(allocator, unary.operand),
        } },
    };

    return result;
}
