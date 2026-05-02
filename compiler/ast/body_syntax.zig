const std = @import("std");
const item_syntax = @import("item_syntax.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const SpanText = item_syntax.SpanText;
pub const TypeSyntax = item_syntax.TypeSyntax;

pub const AssignOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    shl,
    shr,
    bit_and,
    bit_xor,
    bit_or,
};

pub const Expr = struct {
    span: source.Span,
    force_unsafe: bool = false,
    node: Node,

    pub const Unary = struct {
        operator: SpanText,
        operand: *Expr,
    };

    pub const RawPointer = struct {
        mode: SpanText,
        place: *Expr,
    };

    pub const Binary = struct {
        operator: SpanText,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const Field = struct {
        base: *Expr,
        field_name: SpanText,
    };

    pub const Index = struct {
        base: *Expr,
        index: *Expr,
    };

    pub const ArrayRepeat = struct {
        value: *Expr,
        length: *Expr,
    };

    pub const Call = struct {
        callee: *Expr,
        args: []*Expr,
    };

    pub const Node = union(enum) {
        @"error": SpanText,
        name: SpanText,
        integer: SpanText,
        string: SpanText,
        group: *Expr,
        tuple: []*Expr,
        array: []*Expr,
        array_repeat: ArrayRepeat,
        raw_pointer: RawPointer,
        unary: Unary,
        binary: Binary,
        field: Field,
        index: Index,
        call: Call,
        method_call: Call,
    };

    pub fn clone(self: *const Expr, allocator: Allocator) anyerror!*Expr {
        const cloned = try allocator.create(Expr);
        errdefer allocator.destroy(cloned);

        cloned.* = .{
            .span = self.span,
            .force_unsafe = self.force_unsafe,
            .node = switch (self.node) {
                .@"error" => |value| .{ .@"error" = value },
                .name => |value| .{ .name = value },
                .integer => |value| .{ .integer = value },
                .string => |value| .{ .string = value },
                .group => |group| .{ .group = try group.clone(allocator) },
                .tuple => |items| .{ .tuple = try cloneExprSlice(allocator, items) },
                .array => |items| .{ .array = try cloneExprSlice(allocator, items) },
                .array_repeat => |array_repeat| .{ .array_repeat = .{
                    .value = try array_repeat.value.clone(allocator),
                    .length = try array_repeat.length.clone(allocator),
                } },
                .raw_pointer => |raw_pointer| .{ .raw_pointer = .{
                    .mode = raw_pointer.mode,
                    .place = try raw_pointer.place.clone(allocator),
                } },
                .unary => |unary| .{ .unary = .{
                    .operator = unary.operator,
                    .operand = try unary.operand.clone(allocator),
                } },
                .binary => |binary| .{ .binary = .{
                    .operator = binary.operator,
                    .lhs = try binary.lhs.clone(allocator),
                    .rhs = try binary.rhs.clone(allocator),
                } },
                .field => |field| .{ .field = .{
                    .base = try field.base.clone(allocator),
                    .field_name = field.field_name,
                } },
                .index => |index| .{ .index = .{
                    .base = try index.base.clone(allocator),
                    .index = try index.index.clone(allocator),
                } },
                .call => |call| .{ .call = .{
                    .callee = try call.callee.clone(allocator),
                    .args = try cloneExprSlice(allocator, call.args),
                } },
                .method_call => |call| .{ .method_call = .{
                    .callee = try call.callee.clone(allocator),
                    .args = try cloneExprSlice(allocator, call.args),
                } },
            },
        };

        return cloned;
    }

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.node) {
            .group => |group| destroyExpr(allocator, group),
            .tuple => |items| freeExprSlice(allocator, items),
            .array => |items| freeExprSlice(allocator, items),
            .array_repeat => |array_repeat| {
                destroyExpr(allocator, array_repeat.value);
                destroyExpr(allocator, array_repeat.length);
            },
            .raw_pointer => |raw_pointer| destroyExpr(allocator, raw_pointer.place),
            .unary => |unary| destroyExpr(allocator, unary.operand),
            .binary => |binary| {
                destroyExpr(allocator, binary.lhs);
                destroyExpr(allocator, binary.rhs);
            },
            .field => |field| destroyExpr(allocator, field.base),
            .index => |index| {
                destroyExpr(allocator, index.base);
                destroyExpr(allocator, index.index);
            },
            .call, .method_call => |call| {
                destroyExpr(allocator, call.callee);
                freeExprSlice(allocator, call.args);
            },
            .@"error", .name, .integer, .string => {},
        }
        self.* = undefined;
    }
};

pub const Pattern = struct {
    span: source.Span,
    node: Node,

    pub const Field = struct {
        name: SpanText,
        pattern: *Pattern,
    };

    pub const AggregatePayload = union(enum) {
        none,
        tuple: []*Pattern,
        fields: []Field,

        pub fn clone(self: AggregatePayload, allocator: Allocator) anyerror!AggregatePayload {
            return switch (self) {
                .none => .none,
                .tuple => |items| .{ .tuple = try clonePatternSlice(allocator, items) },
                .fields => |items| .{ .fields = try clonePatternFieldSlice(allocator, items) },
            };
        }

        pub fn deinit(self: *AggregatePayload, allocator: Allocator) void {
            switch (self.*) {
                .none => {},
                .tuple => |items| freePatternSlice(allocator, items),
                .fields => |items| freePatternFieldSlice(allocator, items),
            }
            self.* = .none;
        }
    };

    pub const Aggregate = struct {
        name: SpanText,
        payload: AggregatePayload = .none,
    };

    pub const Node = union(enum) {
        @"error": SpanText,
        wildcard,
        binding: SpanText,
        integer: SpanText,
        string: SpanText,
        tuple: []*Pattern,
        struct_pattern: Aggregate,
        variant_pattern: Aggregate,
    };

    pub fn clone(self: *const Pattern, allocator: Allocator) anyerror!*Pattern {
        const cloned = try allocator.create(Pattern);
        errdefer allocator.destroy(cloned);

        cloned.* = .{
            .span = self.span,
            .node = switch (self.node) {
                .@"error" => |value| .{ .@"error" = value },
                .wildcard => .wildcard,
                .binding => |value| .{ .binding = value },
                .integer => |value| .{ .integer = value },
                .string => |value| .{ .string = value },
                .tuple => |items| .{ .tuple = try clonePatternSlice(allocator, items) },
                .struct_pattern => |aggregate| .{ .struct_pattern = .{
                    .name = aggregate.name,
                    .payload = try aggregate.payload.clone(allocator),
                } },
                .variant_pattern => |aggregate| .{ .variant_pattern = .{
                    .name = aggregate.name,
                    .payload = try aggregate.payload.clone(allocator),
                } },
            },
        };

        return cloned;
    }

    pub fn deinit(self: *Pattern, allocator: Allocator) void {
        switch (self.node) {
            .tuple => |items| freePatternSlice(allocator, items),
            .struct_pattern => |*aggregate| aggregate.payload.deinit(allocator),
            .variant_pattern => |*aggregate| aggregate.payload.deinit(allocator),
            .@"error", .wildcard, .binding, .integer, .string => {},
        }
        self.* = undefined;
    }
};

pub const Block = struct {
    statements: []Statement = &.{},

    pub fn clone(self: Block, allocator: Allocator) anyerror!Block {
        if (self.statements.len == 0) return .{};

        const cloned = try allocator.alloc(Statement, self.statements.len);
        errdefer allocator.free(cloned);

        for (self.statements, 0..) |statement, index| {
            cloned[index] = try statement.clone(allocator);
        }

        return .{
            .statements = cloned,
        };
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        if (self.statements.len != 0) allocator.free(self.statements);
        self.* = .{};
    }
};

pub const Statement = union(enum) {
    placeholder: SpanText,
    let_decl: BindingDecl,
    const_decl: BindingDecl,
    assign_stmt: AssignStmt,
    select_stmt: *SelectStmt,
    repeat_stmt: *RepeatStmt,
    unsafe_block: *Block,
    defer_stmt: *Expr,
    break_stmt,
    continue_stmt,
    return_stmt: ?*Expr,
    expr_stmt: *Expr,

    pub const BindingDecl = struct {
        name: SpanText,
        declared_type: ?TypeSyntax = null,
        expr: *Expr,
    };

    pub const AssignStmt = struct {
        target: *Expr,
        op: ?AssignOp = null,
        expr: *Expr,
    };

    pub const SelectHead = union(enum) {
        guard: *Expr,
        pattern: *Pattern,

        pub fn clone(self: SelectHead, allocator: Allocator) anyerror!SelectHead {
            return switch (self) {
                .guard => |expr| .{ .guard = try expr.clone(allocator) },
                .pattern => |pattern| .{ .pattern = try pattern.clone(allocator) },
            };
        }

        pub fn deinit(self: *SelectHead, allocator: Allocator) void {
            switch (self.*) {
                .guard => |expr| destroyExpr(allocator, expr),
                .pattern => |pattern| destroyPattern(allocator, pattern),
            }
        }
    };

    pub const SelectArm = struct {
        head: SelectHead,
        body: *Block,

        pub fn clone(self: SelectArm, allocator: Allocator) anyerror!SelectArm {
            const cloned_body = try allocator.create(Block);
            errdefer allocator.destroy(cloned_body);
            cloned_body.* = try self.body.clone(allocator);

            return .{
                .head = try self.head.clone(allocator),
                .body = cloned_body,
            };
        }

        pub fn deinit(self: *SelectArm, allocator: Allocator) void {
            self.head.deinit(allocator);
            self.body.deinit(allocator);
            allocator.destroy(self.body);
        }
    };

    pub const SelectStmt = struct {
        subject: ?*Expr = null,
        arms: []SelectArm = &.{},
        else_body: ?*Block = null,

        pub fn clone(self: SelectStmt, allocator: Allocator) anyerror!SelectStmt {
            const subject = if (self.subject) |expr| try expr.clone(allocator) else null;
            errdefer if (subject) |expr| destroyExpr(allocator, expr);

            const arms = try cloneSelectArmSlice(allocator, self.arms);
            errdefer freeSelectArmSlice(allocator, arms);

            const else_body = if (self.else_body) |body| blk: {
                const cloned = try allocator.create(Block);
                errdefer allocator.destroy(cloned);
                cloned.* = try body.clone(allocator);
                break :blk cloned;
            } else null;
            errdefer if (else_body) |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            };

            return .{
                .subject = subject,
                .arms = arms,
                .else_body = else_body,
            };
        }

        pub fn deinit(self: *SelectStmt, allocator: Allocator) void {
            if (self.subject) |expr| destroyExpr(allocator, expr);
            freeSelectArmSlice(allocator, self.arms);
            if (self.else_body) |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            }
            self.* = .{};
        }
    };

    pub const RepeatHeader = union(enum) {
        infinite,
        while_condition: *Expr,
        iteration: Iteration,
        invalid: SpanText,

        pub const Iteration = struct {
            binding: *Pattern,
            iterable: *Expr,
        };

        pub fn clone(self: RepeatHeader, allocator: Allocator) anyerror!RepeatHeader {
            return switch (self) {
                .infinite => .infinite,
                .while_condition => |expr| .{ .while_condition = try expr.clone(allocator) },
                .iteration => |iteration| .{ .iteration = .{
                    .binding = try iteration.binding.clone(allocator),
                    .iterable = try iteration.iterable.clone(allocator),
                } },
                .invalid => |value| .{ .invalid = value },
            };
        }

        pub fn deinit(self: *RepeatHeader, allocator: Allocator) void {
            switch (self.*) {
                .while_condition => |expr| destroyExpr(allocator, expr),
                .iteration => |iteration| {
                    destroyPattern(allocator, iteration.binding);
                    destroyExpr(allocator, iteration.iterable);
                },
                .infinite, .invalid => {},
            }
            self.* = .infinite;
        }
    };

    pub const RepeatStmt = struct {
        header: RepeatHeader = .infinite,
        body: *Block,

        pub fn clone(self: RepeatStmt, allocator: Allocator) anyerror!RepeatStmt {
            const body = try allocator.create(Block);
            errdefer allocator.destroy(body);
            body.* = try self.body.clone(allocator);

            return .{
                .header = try self.header.clone(allocator),
                .body = body,
            };
        }

        pub fn deinit(self: *RepeatStmt, allocator: Allocator) void {
            self.header.deinit(allocator);
            self.body.deinit(allocator);
            allocator.destroy(self.body);
            self.* = undefined;
        }
    };

    pub fn clone(self: Statement, allocator: Allocator) anyerror!Statement {
        return switch (self) {
            .placeholder => |value| .{ .placeholder = value },
            .let_decl => |binding| .{ .let_decl = .{
                .name = binding.name,
                .declared_type = if (binding.declared_type) |declared_type| try declared_type.clone(allocator) else null,
                .expr = try binding.expr.clone(allocator),
            } },
            .const_decl => |binding| .{ .const_decl = .{
                .name = binding.name,
                .declared_type = if (binding.declared_type) |declared_type| try declared_type.clone(allocator) else null,
                .expr = try binding.expr.clone(allocator),
            } },
            .assign_stmt => |assign| .{ .assign_stmt = .{
                .target = try assign.target.clone(allocator),
                .op = assign.op,
                .expr = try assign.expr.clone(allocator),
            } },
            .select_stmt => |select_stmt| blk: {
                const cloned = try allocator.create(SelectStmt);
                errdefer allocator.destroy(cloned);
                cloned.* = try select_stmt.clone(allocator);
                break :blk .{ .select_stmt = cloned };
            },
            .repeat_stmt => |repeat_stmt| blk: {
                const cloned = try allocator.create(RepeatStmt);
                errdefer allocator.destroy(cloned);
                cloned.* = try repeat_stmt.clone(allocator);
                break :blk .{ .repeat_stmt = cloned };
            },
            .unsafe_block => |body| blk: {
                const cloned = try allocator.create(Block);
                errdefer allocator.destroy(cloned);
                cloned.* = try body.clone(allocator);
                break :blk .{ .unsafe_block = cloned };
            },
            .defer_stmt => |expr| .{ .defer_stmt = try expr.clone(allocator) },
            .break_stmt => .break_stmt,
            .continue_stmt => .continue_stmt,
            .return_stmt => |maybe_expr| .{ .return_stmt = if (maybe_expr) |expr| try expr.clone(allocator) else null },
            .expr_stmt => |expr| .{ .expr_stmt = try expr.clone(allocator) },
        };
    }

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .let_decl => |*binding| {
                if (binding.declared_type) |*declared_type| declared_type.deinit(allocator);
                destroyExpr(allocator, binding.expr);
            },
            .const_decl => |*binding| {
                if (binding.declared_type) |*declared_type| declared_type.deinit(allocator);
                destroyExpr(allocator, binding.expr);
            },
            .assign_stmt => |assign| {
                destroyExpr(allocator, assign.target);
                destroyExpr(allocator, assign.expr);
            },
            .select_stmt => |select_stmt| {
                select_stmt.deinit(allocator);
                allocator.destroy(select_stmt);
            },
            .repeat_stmt => |repeat_stmt| {
                repeat_stmt.deinit(allocator);
                allocator.destroy(repeat_stmt);
            },
            .unsafe_block => |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            },
            .defer_stmt => |expr| destroyExpr(allocator, expr),
            .return_stmt => |maybe_expr| if (maybe_expr) |expr| destroyExpr(allocator, expr),
            .expr_stmt => |expr| destroyExpr(allocator, expr),
            .placeholder, .break_stmt, .continue_stmt => {},
        }
        self.* = .{ .placeholder = .{
            .text = "",
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        } };
    }
};

fn cloneExprSlice(allocator: Allocator, items: []*Expr) anyerror![]*Expr {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(*Expr, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| cloned[index] = try item.clone(allocator);
    return cloned;
}

fn freeExprSlice(allocator: Allocator, items: []*Expr) void {
    for (items) |item| destroyExpr(allocator, item);
    if (items.len != 0) allocator.free(items);
}

fn destroyExpr(allocator: Allocator, expr: *Expr) void {
    expr.deinit(allocator);
    allocator.destroy(expr);
}

fn clonePatternSlice(allocator: Allocator, items: []*Pattern) anyerror![]*Pattern {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(*Pattern, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| cloned[index] = try item.clone(allocator);
    return cloned;
}

fn freePatternSlice(allocator: Allocator, items: []*Pattern) void {
    for (items) |item| destroyPattern(allocator, item);
    if (items.len != 0) allocator.free(items);
}

fn clonePatternFieldSlice(allocator: Allocator, items: []const Pattern.Field) anyerror![]Pattern.Field {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(Pattern.Field, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| {
        cloned[index] = .{
            .name = item.name,
            .pattern = try item.pattern.clone(allocator),
        };
    }
    return cloned;
}

fn freePatternFieldSlice(allocator: Allocator, items: []Pattern.Field) void {
    for (items) |item| destroyPattern(allocator, item.pattern);
    if (items.len != 0) allocator.free(items);
}

fn destroyPattern(allocator: Allocator, pattern: *Pattern) void {
    pattern.deinit(allocator);
    allocator.destroy(pattern);
}

fn cloneSelectArmSlice(allocator: Allocator, items: []const Statement.SelectArm) anyerror![]Statement.SelectArm {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc(Statement.SelectArm, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| cloned[index] = try item.clone(allocator);
    return cloned;
}

fn freeSelectArmSlice(allocator: Allocator, items: []Statement.SelectArm) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len != 0) allocator.free(items);
}
