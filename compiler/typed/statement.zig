const std = @import("std");
const ast = @import("../ast/root.zig");
const typed_expr = @import("expr.zig");
const source = @import("../source/root.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const BinaryOp = typed_expr.BinaryOp;
pub const Expr = typed_expr.Expr;

pub const Statement = union(enum) {
    placeholder,
    let_decl: BindingDecl,
    const_decl: BindingDecl,
    assign_stmt: AssignData,
    select_stmt: *SelectData,
    loop_stmt: *LoopData,
    unsafe_block: *Block,
    defer_stmt: *Expr,
    break_stmt,
    continue_stmt,
    return_stmt: ?*Expr,
    expr_stmt: *Expr,

    pub const BindingDecl = struct {
        name: []const u8,
        ty: types.TypeRef,
        declared_type_syntax: ?ast.TypeSyntax = null,
        explicit_type: bool = false,
        span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 },
        expr: *Expr,

        pub fn deinit(self: *BindingDecl, allocator: Allocator) void {
            if (self.declared_type_syntax) |*declared_type_syntax| declared_type_syntax.deinit(allocator);
            self.expr.deinit(allocator);
            allocator.destroy(self.expr);
            self.* = .{
                .name = "",
                .ty = .unsupported,
                .declared_type_syntax = null,
                .explicit_type = false,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
                .expr = undefined,
            };
        }
    };

    pub const AssignData = struct {
        name: []const u8,
        owns_name: bool = false,
        ty: types.TypeRef,
        op: ?BinaryOp,
        expr: *Expr,
    };

    pub const SelectBinding = struct {
        name: []const u8,
        ty: types.TypeRef,
        expr: *Expr,

        pub fn deinit(self: SelectBinding, allocator: Allocator) void {
            self.expr.deinit(allocator);
            allocator.destroy(self.expr);
        }
    };

    pub const PatternDiagnostic = struct {
        code: []const u8,
        message: []const u8,
        span: source.Span,

        pub fn deinit(self: PatternDiagnostic, allocator: Allocator) void {
            allocator.free(self.message);
        }
    };

    pub const SelectArm = struct {
        condition: *Expr,
        bindings: []SelectBinding,
        body: *Block,
        pattern_irrefutable: bool = false,

        fn deinit(self: SelectArm, allocator: Allocator) void {
            self.condition.deinit(allocator);
            allocator.destroy(self.condition);
            for (self.bindings) |binding| binding.deinit(allocator);
            allocator.free(self.bindings);
            self.body.deinit(allocator);
            allocator.destroy(self.body);
        }
    };

    pub const SelectData = struct {
        subject: ?*Expr = null,
        subject_temp_name: ?[]const u8 = null,
        arms: []SelectArm,
        else_body: ?*Block = null,
        pattern_diagnostics: []PatternDiagnostic = &.{},

        pub fn deinit(self: *SelectData, allocator: Allocator) void {
            if (self.subject) |subject| {
                subject.deinit(allocator);
                allocator.destroy(subject);
            }
            if (self.subject_temp_name) |name| allocator.free(name);
            for (self.arms) |arm| arm.deinit(allocator);
            allocator.free(self.arms);
            if (self.else_body) |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            }
            for (self.pattern_diagnostics) |pattern_diagnostic| pattern_diagnostic.deinit(allocator);
            allocator.free(self.pattern_diagnostics);
        }
    };

    pub const LoopData = struct {
        condition: ?*Expr = null,
        body: *Block,
        iteration_type: ?types.TypeRef = null,

        pub fn deinit(self: *LoopData, allocator: Allocator) void {
            if (self.condition) |condition| {
                condition.deinit(allocator);
                allocator.destroy(condition);
            }
            self.body.deinit(allocator);
            allocator.destroy(self.body);
        }
    };

    pub fn deinit(self: Statement, allocator: Allocator) void {
        switch (self) {
            .let_decl, .const_decl => |value| {
                var owned = value;
                owned.deinit(allocator);
            },
            .assign_stmt => |assign| {
                if (assign.owns_name) allocator.free(assign.name);
                assign.expr.deinit(allocator);
                allocator.destroy(assign.expr);
            },
            .select_stmt => |select_data| {
                select_data.deinit(allocator);
                allocator.destroy(select_data);
            },
            .loop_stmt => |loop_data| {
                loop_data.deinit(allocator);
                allocator.destroy(loop_data);
            },
            .unsafe_block => |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            },
            .defer_stmt => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .return_stmt => |maybe_expr| {
                if (maybe_expr) |expr| {
                    expr.deinit(allocator);
                    allocator.destroy(expr);
                }
            },
            .expr_stmt => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .placeholder, .break_stmt, .continue_stmt => {},
        }
    }
};

pub const Block = struct {
    statements: std.array_list.Managed(Statement),

    pub fn init(allocator: Allocator) Block {
        return .{
            .statements = std.array_list.Managed(Statement).init(allocator),
        };
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        for (self.statements.items) |statement| statement.deinit(allocator);
        self.statements.deinit();
    }
};
