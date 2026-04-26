const std = @import("std");
const conversions = @import("conversions.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Dedicated const IR lowering and deterministic evaluation.";

pub const Value = union(enum) {
    unit: void,
    bool: bool,
    i32: i32,
    u32: u32,
    index: usize,
    str: []const u8,
    array: []Value,
    aggregate: AggregateValue,
    enum_value: EnumValue,
    unsupported: void,
};

pub const FieldValue = struct {
    name: []const u8,
    value: Value,
};

pub const AggregateValue = struct {
    type_name: []const u8,
    fields: []FieldValue,
};

pub const EnumValue = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    tag: i32,
    fields: []FieldValue,
};

pub const Expr = struct {
    result_type: types.Builtin,
    node: Node,

    pub const Node = union(enum) {
        literal: Value,
        const_ref: []const u8,
        associated_const_ref: AssociatedConstRef,
        enum_variant: EnumVariant,
        enum_tag: EnumVariant,
        enum_construct: EnumConstruct,
        constructor: Constructor,
        field: Field,
        array: Array,
        array_repeat: ArrayRepeat,
        index: Index,
        conversion: Conversion,
        unary: Unary,
        binary: Binary,
    };

    pub const EnumVariant = struct {
        enum_name: []const u8,
        variant_name: []const u8,
    };

    pub const AssociatedConstRef = struct {
        owner_name: []const u8,
        const_name: []const u8,
    };

    pub const EnumConstruct = struct {
        enum_name: []const u8,
        variant_name: []const u8,
        args: []*Expr,
    };

    pub const Constructor = struct {
        type_name: []const u8,
        args: []*Expr,
    };

    pub const Field = struct {
        base: *Expr,
        field_name: []const u8,
    };

    pub const Array = struct {
        items: []*Expr,
    };

    pub const ArrayRepeat = struct {
        value: *Expr,
        length: *Expr,
    };

    pub const Index = struct {
        base: *Expr,
        index: *Expr,
    };

    pub const Conversion = struct {
        operand: *Expr,
        mode: typed.ConversionMode,
        target_type: types.Builtin,
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
        .literal => |*value| deinitValue(allocator, value),
        .const_ref,
        .associated_const_ref,
        .enum_variant,
        .enum_tag,
        => {},
        .enum_construct => |construct| {
            for (construct.args) |arg| destroyExpr(allocator, arg);
            allocator.free(construct.args);
        },
        .constructor => |constructor| {
            for (constructor.args) |arg| destroyExpr(allocator, arg);
            allocator.free(constructor.args);
        },
        .field => |field| destroyExpr(allocator, field.base),
        .array => |array| {
            for (array.items) |item| destroyExpr(allocator, item);
            allocator.free(array.items);
        },
        .array_repeat => |array_repeat| {
            destroyExpr(allocator, array_repeat.value);
            destroyExpr(allocator, array_repeat.length);
        },
        .index => |index| {
            destroyExpr(allocator, index.base);
            destroyExpr(allocator, index.index);
        },
        .conversion => |conversion| destroyExpr(allocator, conversion.operand),
        .unary => |unary| destroyExpr(allocator, unary.operand),
        .binary => |binary| {
            destroyExpr(allocator, binary.lhs);
            destroyExpr(allocator, binary.rhs);
        },
    }
    allocator.destroy(mutable_expr);
}

pub fn deinitValue(allocator: Allocator, value: *Value) void {
    switch (value.*) {
        .array => |items| {
            for (items) |*item| deinitValue(allocator, item);
            allocator.free(items);
        },
        .aggregate => |aggregate| {
            for (aggregate.fields) |*field| deinitValue(allocator, &field.value);
            allocator.free(aggregate.fields);
        },
        .enum_value => |enum_value| {
            for (enum_value.fields) |*field| deinitValue(allocator, &field.value);
            allocator.free(enum_value.fields);
        },
        else => {},
    }
    value.* = .unsupported;
}

pub fn cloneValue(allocator: Allocator, value: Value) anyerror!Value {
    return switch (value) {
        .unit => .{ .unit = {} },
        .bool => |payload| .{ .bool = payload },
        .i32 => |payload| .{ .i32 = payload },
        .u32 => |payload| .{ .u32 = payload },
        .index => |payload| .{ .index = payload },
        .str => |payload| .{ .str = payload },
        .unsupported => .{ .unsupported = {} },
        .array => |items| blk: {
            const cloned = try allocator.alloc(Value, items.len);
            var initialized: usize = 0;
            errdefer {
                for (cloned[0..initialized]) |*item| deinitValue(allocator, item);
                allocator.free(cloned);
            }
            for (items, 0..) |item, index| {
                cloned[index] = try cloneValue(allocator, item);
                initialized += 1;
            }
            break :blk .{ .array = cloned };
        },
        .aggregate => |aggregate| blk: {
            const fields = try cloneFields(allocator, aggregate.fields);
            break :blk .{ .aggregate = .{
                .type_name = aggregate.type_name,
                .fields = fields,
            } };
        },
        .enum_value => |enum_value| blk: {
            const fields = try cloneFields(allocator, enum_value.fields);
            break :blk .{ .enum_value = .{
                .enum_name = enum_value.enum_name,
                .variant_name = enum_value.variant_name,
                .tag = enum_value.tag,
                .fields = fields,
            } };
        },
    };
}

fn cloneFields(allocator: Allocator, fields: []const FieldValue) anyerror![]FieldValue {
    const cloned = try allocator.alloc(FieldValue, fields.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*field| deinitValue(allocator, &field.value);
        allocator.free(cloned);
    }
    for (fields, 0..) |field, index| {
        cloned[index] = .{
            .name = field.name,
            .value = try cloneValue(allocator, field.value),
        };
        initialized += 1;
    }
    return cloned;
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
        .enum_variant => |value| .{ .enum_variant = .{
            .enum_name = value.enum_name,
            .variant_name = value.variant_name,
        } },
        .enum_tag => |value| .{ .enum_tag = .{
            .enum_name = value.enum_name,
            .variant_name = value.variant_name,
        } },
        .enum_construct => |construct| .{ .enum_construct = .{
            .enum_name = construct.enum_name,
            .variant_name = construct.variant_name,
            .args = try lowerExprSlice(allocator, construct.args),
        } },
        .constructor => |constructor| .{ .constructor = .{
            .type_name = constructor.type_name,
            .args = try lowerExprSlice(allocator, constructor.args),
        } },
        .field => |field| blk: {
            if (field.base.ty.isUnsupported()) {
                switch (field.base.node) {
                    .identifier => |base_name| break :blk .{ .associated_const_ref = .{
                        .owner_name = base_name,
                        .const_name = field.field_name,
                    } },
                    else => {},
                }
            }
            break :blk .{ .field = .{
                .base = try lowerExpr(allocator, field.base),
                .field_name = field.field_name,
            } };
        },
        .array => |array| .{ .array = .{
            .items = try lowerExprSlice(allocator, array.items),
        } },
        .array_repeat => |array_repeat| .{ .array_repeat = .{
            .value = try lowerExpr(allocator, array_repeat.value),
            .length = try lowerExpr(allocator, array_repeat.length),
        } },
        .index => |index| .{ .index = .{
            .base = try lowerExpr(allocator, index.base),
            .index = try lowerExpr(allocator, index.index),
        } },
        .conversion => |conversion| .{ .conversion = .{
            .operand = try lowerExpr(allocator, conversion.operand),
            .mode = conversion.mode,
            .target_type = switch (conversion.target_type) {
                .builtin => |builtin| builtin,
                else => .unsupported,
            },
        } },
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
        .enum_constructor_target,
        .call,
        .method_target,
        => return error.UnsupportedConstExpr,
    };
    root_owned = false;
    return lowered;
}

fn lowerExprSlice(allocator: Allocator, exprs: anytype) ![]*Expr {
    const lowered = try allocator.alloc(*Expr, exprs.len);
    var initialized: usize = 0;
    errdefer {
        for (lowered[0..initialized]) |item| destroyExpr(allocator, item);
        allocator.free(lowered);
    }
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerExpr(allocator, expr);
        initialized += 1;
    }
    return lowered;
}

pub fn evalExpr(allocator: Allocator, context: anytype, expr: *const Expr, resolve_identifier: anytype) anyerror!Value {
    switch (expr.node) {
        .literal => |value| return cloneValue(allocator, value),
        .const_ref => |name| return cloneValue(allocator, try resolve_identifier(context, name)),
        .associated_const_ref => |ref| return cloneValue(allocator, try resolveAssociatedConst(context, ref.owner_name, ref.const_name)),
        .enum_variant => |variant| return evalEnumValue(allocator, context, variant.enum_name, variant.variant_name, &.{}),
        .enum_tag => |variant| return .{ .i32 = contextEnumVariantTag(context, variant.enum_name, variant.variant_name) orelse return error.UnsupportedConstExpr },
        .enum_construct => |construct| {
            const fields = try evalFieldArgs(
                allocator,
                context,
                construct.args,
                construct.enum_name,
                construct.variant_name,
                enumPayloadFieldNameAt,
                resolve_identifier,
            );
            errdefer {
                for (fields) |*field| deinitValue(allocator, &field.value);
                allocator.free(fields);
            }
            return evalEnumValue(allocator, context, construct.enum_name, construct.variant_name, fields);
        },
        .constructor => |constructor| {
            const fields = try evalFieldArgs(
                allocator,
                context,
                constructor.args,
                constructor.type_name,
                "",
                structFieldNameAt,
                resolve_identifier,
            );
            return .{ .aggregate = .{
                .type_name = constructor.type_name,
                .fields = fields,
            } };
        },
        .field => |field| {
            var base = try evalExpr(allocator, context, field.base, resolve_identifier);
            defer deinitValue(allocator, &base);
            return try projectField(allocator, base, field.field_name);
        },
        .array => |array| {
            const items = try allocator.alloc(Value, array.items.len);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| deinitValue(allocator, item);
                allocator.free(items);
            }
            for (array.items, 0..) |item, index| {
                items[index] = try evalExpr(allocator, context, item, resolve_identifier);
                initialized += 1;
            }
            return .{ .array = items };
        },
        .array_repeat => |array_repeat| {
            var length_value = try evalExpr(allocator, context, array_repeat.length, resolve_identifier);
            defer deinitValue(allocator, &length_value);
            const length = try lengthValue(length_value);
            var repeated = try evalExpr(allocator, context, array_repeat.value, resolve_identifier);
            defer deinitValue(allocator, &repeated);
            const items = try allocator.alloc(Value, length);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| deinitValue(allocator, item);
                allocator.free(items);
            }
            for (items) |*item| {
                item.* = try cloneValue(allocator, repeated);
                initialized += 1;
            }
            return .{ .array = items };
        },
        .index => |index| {
            var base = try evalExpr(allocator, context, index.base, resolve_identifier);
            defer deinitValue(allocator, &base);
            var index_value = try evalExpr(allocator, context, index.index, resolve_identifier);
            defer deinitValue(allocator, &index_value);
            const offset = try lengthValue(index_value);
            return try indexValue(allocator, base, offset);
        },
        .conversion => |conversion| {
            var operand = try evalExpr(allocator, context, conversion.operand, resolve_identifier);
            defer deinitValue(allocator, &operand);
            return switch (conversion.mode) {
                .explicit_infallible => convertScalar(operand, conversion.target_type) orelse error.InvalidConversion,
                .explicit_checked => try checkedConversionResult(allocator, operand, conversion.target_type),
            };
        },
        .unary => |unary| {
            var operand = try evalExpr(allocator, context, unary.operand, resolve_identifier);
            defer deinitValue(allocator, &operand);
            return evalUnary(expr.result_type, unary.op, operand);
        },
        .binary => |binary| {
            var lhs = try evalExpr(allocator, context, binary.lhs, resolve_identifier);
            defer deinitValue(allocator, &lhs);
            var rhs = try evalExpr(allocator, context, binary.rhs, resolve_identifier);
            defer deinitValue(allocator, &rhs);
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

fn evalFieldArgs(
    allocator: Allocator,
    context: anytype,
    args: []*Expr,
    type_name: []const u8,
    variant_name: []const u8,
    comptime fieldNameAt: anytype,
    resolve_identifier: anytype,
) ![]FieldValue {
    const fields = try allocator.alloc(FieldValue, args.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| deinitValue(allocator, &field.value);
        allocator.free(fields);
    }
    for (args, 0..) |arg, index| {
        const field_name = fieldNameAt(context, type_name, variant_name, index) orelse return error.UnsupportedConstExpr;
        fields[index] = .{
            .name = field_name,
            .value = try evalExpr(allocator, context, arg, resolve_identifier),
        };
        initialized += 1;
    }
    return fields;
}

fn evalEnumValue(
    allocator: Allocator,
    context: anytype,
    enum_name: []const u8,
    variant_name: []const u8,
    fields: []FieldValue,
) !Value {
    const tag = contextEnumVariantTag(context, enum_name, variant_name) orelse return error.UnsupportedConstExpr;
    return .{ .enum_value = .{
        .enum_name = enum_name,
        .variant_name = variant_name,
        .tag = tag,
        .fields = if (fields.len == 0) try allocator.alloc(FieldValue, 0) else fields,
    } };
}

fn projectField(allocator: Allocator, base: Value, field_name: []const u8) !Value {
    return switch (base) {
        .aggregate => |aggregate| blk: {
            for (aggregate.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) break :blk try cloneValue(allocator, field.value);
            }
            break :blk error.UnsupportedConstExpr;
        },
        .enum_value => |enum_value| blk: {
            if (std.mem.eql(u8, field_name, "tag")) break :blk .{ .i32 = enum_value.tag };
            if (std.mem.eql(u8, field_name, "payload")) {
                break :blk .{ .aggregate = .{
                    .type_name = enum_value.variant_name,
                    .fields = try cloneFields(allocator, enum_value.fields),
                } };
            }
            for (enum_value.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) break :blk try cloneValue(allocator, field.value);
            }
            break :blk error.UnsupportedConstExpr;
        },
        else => error.UnsupportedConstExpr,
    };
}

fn indexValue(allocator: Allocator, base: Value, offset: usize) !Value {
    return switch (base) {
        .array => |items| blk: {
            if (offset >= items.len) return error.ConstIndexOutOfRange;
            break :blk try cloneValue(allocator, items[offset]);
        },
        else => error.UnsupportedConstExpr,
    };
}

fn lengthValue(value: Value) !usize {
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

fn convertScalar(value: Value, target_type: types.Builtin) ?Value {
    const source_type = valueBuiltin(value) orelse return null;
    if (!conversions.explicitInfallibleScalarAllowed(source_type, target_type)) return null;
    return switch (target_type) {
        .i32 => switch (value) {
            .i32 => |payload| .{ .i32 = payload },
            else => null,
        },
        .u32 => switch (value) {
            .u32 => |payload| .{ .u32 = payload },
            else => null,
        },
        .index => switch (value) {
            .index => |payload| .{ .index = payload },
            .u32 => |payload| .{ .index = @intCast(payload) },
            else => null,
        },
        else => null,
    };
}

fn checkedConversionResult(allocator: Allocator, value: Value, target_type: types.Builtin) !Value {
    const source_type = valueBuiltin(value) orelse return error.InvalidConversion;
    if (!conversions.explicitCheckedScalarAllowed(source_type, target_type)) return error.InvalidConversion;
    if (checkedConvertScalar(value, target_type)) |payload| {
        const fields = try allocator.alloc(FieldValue, 1);
        fields[0] = .{
            .name = "value",
            .value = payload,
        };
        return .{ .enum_value = .{
            .enum_name = "Result",
            .variant_name = "Ok",
            .tag = 0,
            .fields = fields,
        } };
    }

    const error_fields = try allocator.alloc(FieldValue, 0);
    errdefer allocator.free(error_fields);
    const fields = try allocator.alloc(FieldValue, 1);
    fields[0] = .{
        .name = "error",
        .value = .{ .enum_value = .{
            .enum_name = "ConvertError",
            .variant_name = "OutOfRange",
            .tag = 0,
            .fields = error_fields,
        } },
    };
    return .{ .enum_value = .{
        .enum_name = "Result",
        .variant_name = "Err",
        .tag = 1,
        .fields = fields,
    } };
}

fn checkedConvertScalar(value: Value, target_type: types.Builtin) ?Value {
    const source_type = valueBuiltin(value) orelse return null;
    if (!conversions.explicitCheckedScalarAllowed(source_type, target_type)) return null;
    if (convertScalar(value, target_type)) |converted| return converted;
    return switch (target_type) {
        .i32 => switch (value) {
            .u32 => |payload| if (payload <= @as(u32, @intCast(std.math.maxInt(i32)))) .{ .i32 = @intCast(payload) } else null,
            .index => |payload| if (payload <= @as(usize, @intCast(std.math.maxInt(i32)))) .{ .i32 = @intCast(payload) } else null,
            else => null,
        },
        .u32 => switch (value) {
            .i32 => |payload| if (payload >= 0) .{ .u32 = @intCast(payload) } else null,
            .index => |payload| if (payload <= std.math.maxInt(u32)) .{ .u32 = @intCast(payload) } else null,
            else => null,
        },
        .index => switch (value) {
            .i32 => |payload| if (payload >= 0) .{ .index = @intCast(payload) } else null,
            else => null,
        },
        else => null,
    };
}

fn valueBuiltin(value: Value) ?types.Builtin {
    return switch (value) {
        .unit => .unit,
        .bool => .bool,
        .i32 => .i32,
        .u32 => .u32,
        .index => .index,
        .str => .str,
        else => null,
    };
}

fn structFieldNameAt(context: anytype, type_name: []const u8, variant_name: []const u8, index: usize) ?[]const u8 {
    _ = variant_name;
    if (@hasDecl(@TypeOf(context), "structFieldName")) return context.structFieldName(type_name, index);
    return null;
}

fn enumPayloadFieldNameAt(context: anytype, enum_name: []const u8, variant_name: []const u8, index: usize) ?[]const u8 {
    if (@hasDecl(@TypeOf(context), "enumPayloadFieldName")) return context.enumPayloadFieldName(enum_name, variant_name, index);
    return null;
}

fn contextEnumVariantTag(context: anytype, enum_name: []const u8, variant_name: []const u8) ?i32 {
    if (@hasDecl(@TypeOf(context), "enumVariantTag")) return context.enumVariantTag(enum_name, variant_name);
    return null;
}

fn resolveAssociatedConst(context: anytype, owner_name: []const u8, const_name: []const u8) anyerror!Value {
    if (@hasDecl(@TypeOf(context), "resolveAssociatedConst")) return context.resolveAssociatedConst(owner_name, const_name);
    return error.UnknownConst;
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
        .unit => rhs == .unit,
        .array => |items| switch (rhs) {
            .array => |other_items| blk: {
                if (items.len != other_items.len) break :blk false;
                for (items, other_items) |item, other| {
                    if (!eql(item, other)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .aggregate => |aggregate| switch (rhs) {
            .aggregate => |other| fieldsEql(aggregate.fields, other.fields),
            else => false,
        },
        .enum_value => |enum_value| switch (rhs) {
            .enum_value => |other| std.mem.eql(u8, enum_value.enum_name, other.enum_name) and
                std.mem.eql(u8, enum_value.variant_name, other.variant_name) and
                enum_value.tag == other.tag and
                fieldsEql(enum_value.fields, other.fields),
            else => false,
        },
        .unsupported => false,
    };
}

fn fieldsEql(lhs: []const FieldValue, rhs: []const FieldValue) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |field, other| {
        if (!std.mem.eql(u8, field.name, other.name)) return false;
        if (!eql(field.value, other.value)) return false;
    }
    return true;
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
