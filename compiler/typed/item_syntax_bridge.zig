const std = @import("std");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed_decls = @import("declarations.zig");
const typed_signatures = @import("signatures.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;

pub const ParameterMode = typed_decls.ParameterMode;
pub const Parameter = typed_decls.Parameter;
pub const FunctionData = typed_decls.FunctionData;
pub const ConstData = typed_decls.ConstData;
pub const GenericParam = typed_signatures.GenericParam;
pub const WherePredicate = typed_signatures.WherePredicate;

pub const NamedDeclData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,

    pub fn deinit(self: *NamedDeclData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        self.* = .{
            .generic_params = &.{},
            .where_predicates = &.{},
        };
    }
};

pub const ImplHeaderData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    target_type: []const u8,
    trait_name: ?[]const u8,

    pub fn deinit(self: *ImplHeaderData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        if (self.where_predicates.len != 0) allocator.free(self.where_predicates);
        self.* = .{
            .generic_params = &.{},
            .where_predicates = &.{},
            .target_type = "",
            .trait_name = null,
        };
    }
};

pub fn fillFunctionDataFromSyntax(
    allocator: Allocator,
    function: *FunctionData,
    signature: ast.FunctionSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    function.generic_params = try parseGenericParamsFromSpan(allocator, signature.generic_params, span, diagnostics);
    errdefer if (function.generic_params.len != 0) allocator.free(function.generic_params);

    function.where_predicates = try parseWherePredicatesFromClauses(
        allocator,
        signature.where_clauses,
        function.generic_params,
        false,
        span,
        diagnostics,
    );
    errdefer if (function.where_predicates.len != 0) allocator.free(function.where_predicates);

    for (signature.parameters) |parameter| {
        const name_text = parameter.name orelse {
            try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
            continue;
        };
        const type_text = parameter.ty orelse {
            try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{name_text.text});
            continue;
        };
        const type_name = std.mem.trim(u8, type_text.text, " \t");
        try function.parameters.append(.{
            .name = std.mem.trim(u8, name_text.text, " \t"),
            .mode = try parseParameterMode(parameter.mode, span, diagnostics),
            .type_name = type_name,
            .ty = types.TypeRef.fromBuiltin(types.Builtin.fromName(type_name)),
        });
    }

    if (signature.return_type) |return_type| {
        const return_name = std.mem.trim(u8, return_type.text, " \t");
        if (return_name.len != 0) {
            function.return_type_name = return_name;
            function.return_type = types.TypeRef.fromBuiltin(types.Builtin.fromName(return_name));
        }
    }
}

pub fn parseConstDataFromSyntax(
    allocator: Allocator,
    signature: ast.ConstSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ConstData {
    const type_raw = if (signature.ty) |ty| std.mem.trim(u8, ty.text, " \t") else "";
    const expr_raw = if (signature.initializer) |initializer| std.mem.trim(u8, initializer.text, " \t") else "";

    const ty = types.Builtin.fromName(type_raw);
    _ = diagnostics;
    _ = span;

    return .{
        .type_name = type_raw,
        .ty = ty,
        .type_ref = if (ty == .unsupported) .{ .named = type_raw } else types.TypeRef.fromBuiltin(ty),
        .initializer_source = expr_raw,
        .initializer_syntax = if (signature.initializer_expr) |expr| try expr.clone(allocator) else null,
        .expr = null,
    };
}

pub fn parseNamedDeclData(
    allocator: Allocator,
    signature: ast.NamedDeclSyntax,
    allow_self: bool,
    span: source.Span,
    diagnostics: *diag.Bag,
) !NamedDeclData {
    const generic_params = try parseGenericParamsFromSpan(allocator, signature.generic_params, span, diagnostics);
    errdefer if (generic_params.len != 0) allocator.free(generic_params);

    const where_predicates = try parseWherePredicatesFromClauses(
        allocator,
        signature.where_clauses,
        generic_params,
        allow_self,
        span,
        diagnostics,
    );
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);

    return .{
        .generic_params = generic_params,
        .where_predicates = where_predicates,
    };
}

pub fn parseImplHeaderData(
    allocator: Allocator,
    signature: ast.ImplSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ImplHeaderData {
    const generic_params = try parseGenericParamsFromSpan(allocator, signature.generic_params, span, diagnostics);
    errdefer if (generic_params.len != 0) allocator.free(generic_params);

    const where_predicates = try parseWherePredicatesFromClauses(
        allocator,
        signature.where_clauses,
        generic_params,
        false,
        span,
        diagnostics,
    );
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);

    return .{
        .generic_params = generic_params,
        .where_predicates = where_predicates,
        .target_type = if (signature.target_type) |target_type| std.mem.trim(u8, target_type.text, " \t") else "",
        .trait_name = if (signature.trait_name) |trait_name| std.mem.trim(u8, trait_name.text, " \t") else null,
    };
}

pub fn parseGenericParamsFromSpan(
    allocator: Allocator,
    generic_params: ?ast.SpanText,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]GenericParam {
    const raw = if (generic_params) |value| std.mem.trim(u8, value.text, " \t") else return allocator.alloc(GenericParam, 0);
    if (raw.len == 0) return allocator.alloc(GenericParam, 0);
    if (raw[0] == '[' and raw[raw.len - 1] == ']') {
        return typed_signatures.parseGenericParams(allocator, raw[1 .. raw.len - 1], span, diagnostics);
    }

    const leading = try typed_signatures.parseLeadingGenericParams(allocator, raw, span, diagnostics);
    return leading.generic_params;
}

pub fn parseWherePredicatesFromClauses(
    allocator: Allocator,
    clauses: []const ast.SpanText,
    generic_params: []const GenericParam,
    allow_self: bool,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]WherePredicate {
    var predicates = std.array_list.Managed(WherePredicate).init(allocator);
    errdefer predicates.deinit();

    for (clauses) |clause| {
        const parsed = try typed_signatures.parseWherePredicates(
            allocator,
            std.mem.trim(u8, clause.text, " \t"),
            generic_params,
            allow_self,
            span,
            diagnostics,
        );
        defer if (parsed.len != 0) allocator.free(parsed);
        try predicates.appendSlice(parsed);
    }

    return predicates.toOwnedSlice();
}

fn parseParameterMode(
    mode: ?ast.SpanText,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ParameterMode {
    const raw = if (mode) |value| std.mem.trim(u8, value.text, " \t") else return .owned;
    if (std.mem.eql(u8, raw, "take")) return .take;
    if (std.mem.eql(u8, raw, "read")) return .read;
    if (std.mem.eql(u8, raw, "edit")) return .edit;

    try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter mode '{s}'", .{raw});
    return .owned;
}
