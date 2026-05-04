const std = @import("std");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed_decls = @import("../typed/declarations.zig");
const typed_signatures = @import("signatures.zig");
const type_lowering = @import("type_lowering.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
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
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        self.* = .{
            .generic_params = &.{},
            .where_predicates = &.{},
        };
    }
};

pub const ImplHeaderData = struct {
    generic_params: []GenericParam,
    where_predicates: []WherePredicate,
    target_type_syntax: ast.TypeSyntax,
    target_type: types.TypeRef,
    trait_syntax: ?ast.TypeSyntax = null,
    trait_type: ?types.TypeRef = null,

    pub fn deinit(self: *ImplHeaderData, allocator: Allocator) void {
        if (self.generic_params.len != 0) allocator.free(self.generic_params);
        typed_signatures.deinitWherePredicates(allocator, self.where_predicates);
        self.target_type_syntax.deinit(allocator);
        if (self.trait_syntax) |*trait_syntax| trait_syntax.deinit(allocator);
        self.* = .{
            .generic_params = &.{},
            .where_predicates = &.{},
            .target_type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
            .target_type = .unsupported,
            .trait_syntax = null,
            .trait_type = null,
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
    function.generic_params = try typed_signatures.lowerGenericParams(allocator, signature.generic_params, diagnostics);
    errdefer if (function.generic_params.len != 0) allocator.free(function.generic_params);

    function.where_predicates = try typed_signatures.lowerWherePredicates(
        allocator,
        signature.where_clauses,
        function.generic_params,
        false,
        diagnostics,
    );
    errdefer typed_signatures.deinitWherePredicates(allocator, function.where_predicates);

    for (signature.parameters) |parameter| {
        const name_text = parameter.name orelse {
            try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
            continue;
        };
        const type_text = parameter.ty orelse {
            try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{name_text.text});
            continue;
        };
        if (type_syntax_support.containsInvalid(type_text)) {
            try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{name_text.text});
            continue;
        }
        try function.parameters.append(.{
            .name = std.mem.trim(u8, name_text.text, " \t"),
            .mode = try parseParameterMode(parameter.mode, span, diagnostics),
            .type_syntax = try type_text.clone(allocator),
            .ty = try type_lowering.typeRefFromSyntax(allocator, type_text),
        });
    }

    if (signature.return_type) |return_type| {
        if (!type_syntax_support.containsInvalid(return_type)) {
            function.return_type_syntax = try return_type.clone(allocator);
            function.return_type = try type_lowering.typeRefFromSyntax(allocator, return_type);
        }
    }
}

pub fn parseConstDataFromSyntax(
    allocator: Allocator,
    signature: ast.ConstSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ConstData {
    const type_syntax = signature.ty orelse {
        try diagnostics.add(.@"error", "type.const.syntax", span, "const declarations require an explicit type", .{});
        return .{
            .type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = span.file_id, .start = span.start, .end = span.start },
                },
            },
            .ty = .unsupported,
            .type_ref = .unsupported,
            .initializer_syntax = if (signature.initializer_expr) |expr| try expr.clone(allocator) else null,
            .expr = null,
        };
    };

    const ty = type_syntax_support.builtinFromSyntax(type_syntax);

    return .{
        .type_syntax = try type_syntax.clone(allocator),
        .ty = ty,
        .type_ref = try type_lowering.typeRefFromSyntax(allocator, type_syntax),
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
    _ = span;
    const generic_params = try typed_signatures.lowerGenericParams(allocator, signature.generic_params, diagnostics);
    errdefer if (generic_params.len != 0) allocator.free(generic_params);

    const where_predicates = try typed_signatures.lowerWherePredicates(
        allocator,
        signature.where_clauses,
        generic_params,
        allow_self,
        diagnostics,
    );
    errdefer typed_signatures.deinitWherePredicates(allocator, where_predicates);

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
    const generic_params = try typed_signatures.lowerGenericParams(allocator, signature.generic_params, diagnostics);
    errdefer if (generic_params.len != 0) allocator.free(generic_params);

    const where_predicates = try typed_signatures.lowerWherePredicates(
        allocator,
        signature.where_clauses,
        generic_params,
        false,
        diagnostics,
    );
    errdefer typed_signatures.deinitWherePredicates(allocator, where_predicates);

    if (signature.target_type) |target_type| {
        if (type_syntax_support.containsInvalid(target_type)) {
            try diagnostics.add(.@"error", "type.impl.syntax", span, "impl blocks require a valid target type", .{});
        }
    }
    if (signature.trait_name) |trait_name| {
        if (type_syntax_support.containsInvalid(trait_name)) {
            try diagnostics.add(.@"error", "type.impl.syntax", span, "impl blocks require a valid trait type", .{});
        }
    }

    return .{
        .generic_params = generic_params,
        .where_predicates = where_predicates,
        .target_type_syntax = if (signature.target_type) |target_type|
            if (!type_syntax_support.containsInvalid(target_type))
                try target_type.clone(allocator)
            else
                .{
                    .source = .{
                        .text = "",
                        .span = .{ .file_id = span.file_id, .start = span.start, .end = span.start },
                    },
                }
        else
            .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = span.file_id, .start = span.start, .end = span.start },
                },
            },
        .target_type = if (signature.target_type) |target_type|
            try type_lowering.typeRefFromSyntax(allocator, target_type)
        else
            .unsupported,
        .trait_syntax = if (signature.trait_name) |trait_name|
            if (!type_syntax_support.containsInvalid(trait_name)) try trait_name.clone(allocator) else null
        else
            null,
        .trait_type = if (signature.trait_name) |trait_name|
            try type_lowering.typeRefFromSyntax(allocator, trait_name)
        else
            null,
    };
}

pub fn parseParameterMode(
    mode: ast.ParameterModeSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ParameterMode {
    _ = span;
    return switch (mode) {
        .owned => .owned,
        .take => .take,
        .read => .read,
        .edit => .edit,
        .invalid => |value| blk: {
            try diagnostics.add(.@"error", "type.param.syntax", value.span, "malformed parameter mode '{s}'", .{std.mem.trim(u8, value.text, " \t")});
            break :blk .owned;
        },
    };
}
