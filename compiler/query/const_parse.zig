const std = @import("std");
const const_ir = @import("const_ir.zig");
const typed = @import("../typed/root.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;

pub const summary = "Query-local const expression parsing into const IR.";

const TokenKind = enum {
    identifier,
    integer,
    string,
    true_kw,
    false_kw,
    l_paren,
    r_paren,
    plus,
    minus,
    star,
    slash,
    percent,
    tilde,
    bang,
    amp,
    pipe,
    caret,
    eq_eq,
    bang_eq,
    lt,
    lte,
    gt,
    gte,
    lt_lt,
    gt_gt,
    amp_amp,
    pipe_pipe,
    eof,
};

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
};

pub fn parseExpr(allocator: Allocator, source: []const u8, result_type: types.Builtin) !*const_ir.Expr {
    var tokens = std.array_list.Managed(Token).init(allocator);
    defer tokens.deinit();
    try tokenize(allocator, source, &tokens);
    try tokens.append(.{ .kind = .eof, .lexeme = "" });

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens.items,
    };
    const expr = try parser.parseExpression(result_type);
    errdefer const_ir.destroyExpr(allocator, expr);
    if (parser.peek().kind != .eof) return error.UnsupportedConstExpr;
    return expr;
}

fn tokenize(allocator: Allocator, source: []const u8, tokens: *std.array_list.Managed(Token)) !void {
    _ = allocator;
    var index: usize = 0;
    while (index < source.len) {
        const ch = source[index];
        if (std.ascii.isWhitespace(ch)) {
            index += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = index;
            index += 1;
            while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '_')) index += 1;
            const lexeme = source[start..index];
            const kind: TokenKind = if (std.mem.eql(u8, lexeme, "true"))
                .true_kw
            else if (std.mem.eql(u8, lexeme, "false"))
                .false_kw
            else
                .identifier;
            try tokens.append(.{ .kind = kind, .lexeme = lexeme });
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            const start = index;
            index += 1;
            while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
            try tokens.append(.{ .kind = .integer, .lexeme = source[start..index] });
            continue;
        }
        if (ch == '"') {
            const start = index;
            index += 1;
            while (index < source.len and source[index] != '"') index += 1;
            if (index >= source.len) return error.UnsupportedConstExpr;
            index += 1;
            try tokens.append(.{ .kind = .string, .lexeme = source[start + 1 .. index - 1] });
            continue;
        }

        if (index + 1 < source.len) {
            const two = source[index .. index + 2];
            const two_kind: ?TokenKind = if (std.mem.eql(u8, two, "=="))
                .eq_eq
            else if (std.mem.eql(u8, two, "!="))
                .bang_eq
            else if (std.mem.eql(u8, two, "<="))
                .lte
            else if (std.mem.eql(u8, two, ">="))
                .gte
            else if (std.mem.eql(u8, two, "<<"))
                .lt_lt
            else if (std.mem.eql(u8, two, ">>"))
                .gt_gt
            else if (std.mem.eql(u8, two, "&&"))
                .amp_amp
            else if (std.mem.eql(u8, two, "||"))
                .pipe_pipe
            else
                null;
            if (two_kind) |kind| {
                try tokens.append(.{ .kind = kind, .lexeme = two });
                index += 2;
                continue;
            }
        }

        const one_kind: ?TokenKind = switch (ch) {
            '(' => .l_paren,
            ')' => .r_paren,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '~' => .tilde,
            '!' => .bang,
            '&' => .amp,
            '|' => .pipe,
            '^' => .caret,
            '<' => .lt,
            '>' => .gt,
            else => null,
        };
        if (one_kind) |kind| {
            try tokens.append(.{ .kind = kind, .lexeme = source[index .. index + 1] });
            index += 1;
            continue;
        }
        return error.UnsupportedConstExpr;
    }
}

const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    index: usize = 0,

    fn parseExpression(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        return self.parseBoolOr(result_type);
    }

    fn parseBoolOr(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseBoolAnd(result_type);
        while (self.match(.pipe_pipe)) {
            const rhs = self.parseBoolAnd(.bool) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, .bool, .bool_or, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseBoolAnd(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseComparison(result_type);
        while (self.match(.amp_amp)) {
            const rhs = self.parseComparison(.bool) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, .bool, .bool_and, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseComparison(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseBitOr(result_type);
        while (comparisonOp(self.peek().kind)) |op| {
            _ = self.advance();
            const rhs = self.parseBitOr(lhs.result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, .bool, op, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseBitOr(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseBitXor(result_type);
        while (self.match(.pipe)) {
            const rhs = self.parseBitXor(result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, .bit_or, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseBitXor(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseBitAnd(result_type);
        while (self.match(.caret)) {
            const rhs = self.parseBitAnd(result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, .bit_xor, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseBitAnd(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseShift(result_type);
        while (self.match(.amp)) {
            const rhs = self.parseShift(result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, .bit_and, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseShift(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseAdd(result_type);
        while (shiftOp(self.peek().kind)) |op| {
            _ = self.advance();
            const rhs = self.parseAdd(.index) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, op, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseAdd(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseMul(result_type);
        while (addOp(self.peek().kind)) |op| {
            _ = self.advance();
            const rhs = self.parseMul(result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, op, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseMul(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        var lhs = try self.parseUnary(result_type);
        while (mulOp(self.peek().kind)) |op| {
            _ = self.advance();
            const rhs = self.parseUnary(result_type) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                return err;
            };
            lhs = makeBinary(self.allocator, result_type, op, lhs, rhs) catch |err| {
                const_ir.destroyExpr(self.allocator, lhs);
                const_ir.destroyExpr(self.allocator, rhs);
                return err;
            };
        }
        return lhs;
    }

    fn parseUnary(self: *Parser, result_type: types.Builtin) anyerror!*const_ir.Expr {
        if (self.match(.bang)) {
            const operand = try self.parseUnary(.bool);
            return makeUnary(self.allocator, .bool, .bool_not, operand) catch |err| {
                const_ir.destroyExpr(self.allocator, operand);
                return err;
            };
        }
        if (self.match(.minus)) {
            const operand = try self.parseUnary(result_type);
            return makeUnary(self.allocator, result_type, .negate, operand) catch |err| {
                const_ir.destroyExpr(self.allocator, operand);
                return err;
            };
        }
        if (self.match(.tilde)) {
            const operand = try self.parseUnary(result_type);
            return makeUnary(self.allocator, result_type, .bit_not, operand) catch |err| {
                const_ir.destroyExpr(self.allocator, operand);
                return err;
            };
        }
        return self.parsePrimary(result_type);
    }

    fn parsePrimary(self: *Parser, result_type: types.Builtin) !*const_ir.Expr {
        const token = self.advance();
        return switch (token.kind) {
            .integer => try makeLiteral(
                self.allocator,
                result_type,
                try const_ir.integerLiteralValue(result_type, try std.fmt.parseInt(i64, token.lexeme, 10)),
            ),
            .true_kw => try makeLiteral(self.allocator, .bool, .{ .bool = true }),
            .false_kw => try makeLiteral(self.allocator, .bool, .{ .bool = false }),
            .string => try makeLiteral(self.allocator, .str, .{ .str = token.lexeme }),
            .identifier => try makeConstRef(self.allocator, result_type, token.lexeme),
            .l_paren => blk: {
                const inner = try self.parseExpression(result_type);
                if (!self.match(.r_paren)) {
                    const_ir.destroyExpr(self.allocator, inner);
                    return error.UnsupportedConstExpr;
                }
                break :blk inner;
            },
            else => error.UnsupportedConstExpr,
        };
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.peek().kind != kind) return false;
        _ = self.advance();
        return true;
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) Token {
        const token = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return token;
    }
};

fn makeLiteral(allocator: Allocator, result_type: types.Builtin, value: const_ir.Value) !*const_ir.Expr {
    const expr = try allocator.create(const_ir.Expr);
    expr.* = .{
        .result_type = result_type,
        .node = .{ .literal = value },
    };
    return expr;
}

fn makeConstRef(allocator: Allocator, result_type: types.Builtin, name: []const u8) !*const_ir.Expr {
    const expr = try allocator.create(const_ir.Expr);
    expr.* = .{
        .result_type = result_type,
        .node = .{ .const_ref = name },
    };
    return expr;
}

fn makeUnary(
    allocator: Allocator,
    result_type: types.Builtin,
    op: typed.UnaryOp,
    operand: *const const_ir.Expr,
) !*const_ir.Expr {
    const expr = try allocator.create(const_ir.Expr);
    expr.* = .{
        .result_type = result_type,
        .node = .{ .unary = .{
            .op = op,
            .operand = @constCast(operand),
        } },
    };
    return expr;
}

fn makeBinary(
    allocator: Allocator,
    result_type: types.Builtin,
    op: typed.BinaryOp,
    lhs: *const const_ir.Expr,
    rhs: *const const_ir.Expr,
) !*const_ir.Expr {
    const expr = try allocator.create(const_ir.Expr);
    expr.* = .{
        .result_type = result_type,
        .node = .{ .binary = .{
            .op = op,
            .lhs = @constCast(lhs),
            .rhs = @constCast(rhs),
        } },
    };
    return expr;
}

fn comparisonOp(kind: TokenKind) ?typed.BinaryOp {
    return switch (kind) {
        .eq_eq => .eq,
        .bang_eq => .ne,
        .lt => .lt,
        .lte => .lte,
        .gt => .gt,
        .gte => .gte,
        else => null,
    };
}

fn shiftOp(kind: TokenKind) ?typed.BinaryOp {
    return switch (kind) {
        .lt_lt => .shl,
        .gt_gt => .shr,
        else => null,
    };
}

fn addOp(kind: TokenKind) ?typed.BinaryOp {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        else => null,
    };
}

fn mulOp(kind: TokenKind) ?typed.BinaryOp {
    return switch (kind) {
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        else => null,
    };
}
