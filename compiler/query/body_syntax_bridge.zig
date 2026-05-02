const std = @import("std");
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const item_syntax_bridge = @import("item_syntax_bridge.zig");
const typed_decls = @import("../typed/declarations.zig");
const signatures = @import("signatures.zig");
const typed_text = @import("text.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const GenericParam = signatures.GenericParam;
const WherePredicate = signatures.WherePredicate;
const FunctionData = typed_decls.FunctionData;
const StructField = typed_decls.StructField;
const TupleField = typed_decls.TupleField;
const EnumVariant = typed_decls.EnumVariant;
const TraitMethod = typed_decls.TraitMethod;
const TraitAssociatedType = typed_decls.TraitAssociatedType;
const TraitAssociatedConst = typed_decls.TraitAssociatedConst;
const TraitAssociatedTypeBinding = typed_decls.TraitAssociatedTypeBinding;
const TraitAssociatedConstBinding = typed_decls.TraitAssociatedConstBinding;
const ParameterMode = typed_decls.ParameterMode;
const isPlainIdentifier = typed_text.isPlainIdentifier;

pub const ParsedTraitBody = struct {
    methods: []TraitMethod,
    associated_types: []TraitAssociatedType,
    associated_consts: []TraitAssociatedConst,

    pub fn deinit(self: *ParsedTraitBody, allocator: Allocator) void {
        for (self.methods) |*method| method.deinit(allocator);
        allocator.free(self.methods);
        allocator.free(self.associated_types);
        for (self.associated_consts) |*associated_const| associated_const.deinit(allocator);
        allocator.free(self.associated_consts);
    }
};

pub const ParsedExecutableMethod = struct {
    method_name: []const u8,
    receiver_mode: ParameterMode,
    function: FunctionData,
};

pub fn parseFieldsFromSyntax(
    allocator: Allocator,
    fields: []const ast.FieldDeclSyntax,
    item_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]StructField {
    var lowered = std.array_list.Managed(StructField).init(allocator);
    defer lowered.deinit();

    for (fields) |field| {
        const name = field.name orelse {
            try diagnostics.add(.@"error", "type.struct.field", span, "malformed field declaration", .{});
            continue;
        };
        const ty = field.ty orelse {
            try diagnostics.add(.@"error", "type.struct.field", span, "malformed field declaration '{s}'", .{name.text});
            continue;
        };
        if (!isPlainIdentifier(name.text) or std.mem.trim(u8, ty.text(), " \t").len == 0) {
            try diagnostics.add(.@"error", "type.struct.field", span, "malformed field declaration '{s}'", .{name.text});
            continue;
        }

        var duplicate = false;
        for (lowered.items) |existing| {
            if (std.mem.eql(u8, existing.name, name.text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.struct.field_duplicate", span, "duplicate field '{s}' in struct '{s}'", .{
                name.text,
                item_name,
            });
            continue;
        }

        try lowered.append(.{
            .name = name.text,
            .visibility = field.visibility,
            .type_name = std.mem.trim(u8, ty.text(), " \t"),
        });
    }

    return try lowered.toOwnedSlice();
}

pub fn parseEnumVariantsFromSyntax(
    allocator: Allocator,
    variants: []const ast.EnumVariantSyntax,
    item_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]EnumVariant {
    var lowered = std.array_list.Managed(EnumVariant).init(allocator);
    errdefer {
        for (lowered.items) |*variant| variant.deinit(allocator);
        lowered.deinit();
    }

    for (variants) |variant| {
        const name = variant.name orelse {
            try diagnostics.add(.@"error", "type.enum.variant", span, "malformed enum variant", .{});
            continue;
        };
        if (!isPlainIdentifier(name.text)) {
            try diagnostics.add(.@"error", "type.enum.variant", span, "malformed enum variant '{s}'", .{name.text});
            continue;
        }

        var lowered_variant = EnumVariant{
            .name = name.text,
            .payload = .none,
            .discriminant = if (variant.discriminant) |discriminant| std.mem.trim(u8, discriminant.text, " \t") else null,
        };
        errdefer lowered_variant.deinit(allocator);

        if (variant.discriminant) |discriminant| {
            if (std.mem.trim(u8, discriminant.text, " \t").len == 0) {
                try diagnostics.add(.@"error", "type.enum.discriminant", span, "enum variant '{s}' has an empty discriminant", .{name.text});
            }
        }

        if (variant.tuple_payload) |tuple_payload| {
            if (tuple_payload.invalid_kind != null) {
                try diagnostics.add(.@"error", "type.enum.variant", tuple_payload.span, "malformed enum tuple payload for variant '{s}'", .{name.text});
            } else {
                var tuple_fields = std.array_list.Managed(TupleField).init(allocator);
                errdefer tuple_fields.deinit();
                for (tuple_payload.types) |field_type| {
                    const trimmed = std.mem.trim(u8, field_type.text(), " \t");
                    if (trimmed.len == 0) {
                        try diagnostics.add(.@"error", "type.enum.variant", tuple_payload.span, "malformed enum tuple payload for variant '{s}'", .{name.text});
                        continue;
                    }
                    try tuple_fields.append(.{ .type_name = trimmed });
                }
                lowered_variant.payload = .{ .tuple_fields = try tuple_fields.toOwnedSlice() };
            }
        } else if (variant.named_fields.len != 0) {
            lowered_variant.payload = .{
                .named_fields = try parseFieldsFromSyntax(allocator, variant.named_fields, name.text, span, diagnostics),
            };
        }

        var duplicate = false;
        for (lowered.items) |existing| {
            if (std.mem.eql(u8, existing.name, lowered_variant.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.enum.variant_duplicate", span, "duplicate variant '{s}' in enum '{s}'", .{
                lowered_variant.name,
                item_name,
            });
            continue;
        }

        try lowered.append(lowered_variant);
    }

    return try lowered.toOwnedSlice();
}

pub fn parseTraitBodyFromSyntax(
    allocator: Allocator,
    inherited_generic_params: []const GenericParam,
    body: ast.TraitBodySyntax,
    item_name: []const u8,
    span: source.Span,
    diagnostics: *diag.Bag,
) !ParsedTraitBody {
    var methods = std.array_list.Managed(TraitMethod).init(allocator);
    errdefer {
        for (methods.items) |*method| method.deinit(allocator);
        methods.deinit();
    }
    var associated_types = std.array_list.Managed(TraitAssociatedType).init(allocator);
    errdefer associated_types.deinit();
    var associated_consts = std.array_list.Managed(TraitAssociatedConst).init(allocator);
    errdefer {
        for (associated_consts.items) |*associated_const| associated_const.deinit(allocator);
        associated_consts.deinit();
    }

    for (body.associated_types) |associated_type| {
        const name = associated_type.name orelse {
            try diagnostics.add(.@"error", "type.trait.associated_type", span, "malformed trait associated type", .{});
            continue;
        };
        if (associated_type.value != null) {
            try diagnostics.add(.@"error", "type.trait.associated_type_default", span, "trait associated type '{s}' cannot define a default in v1", .{name.text});
            continue;
        }
        if (!isPlainIdentifier(name.text)) {
            try diagnostics.add(.@"error", "type.trait.associated_type", span, "malformed trait associated type '{s}'", .{name.text});
            continue;
        }
        var duplicate = false;
        for (associated_types.items) |existing| {
            if (std.mem.eql(u8, existing.name, name.text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.trait.associated_type_duplicate", span, "duplicate associated type '{s}' in trait '{s}'", .{
                name.text,
                item_name,
            });
            continue;
        }
        try associated_types.append(.{ .name = name.text });
    }

    for (body.associated_consts) |associated_const| {
        const name = associated_const.name orelse {
            try diagnostics.add(.@"error", "type.trait.associated_const", span, "malformed trait associated const", .{});
            continue;
        };
        if (associated_const.initializer != null) {
            try diagnostics.add(.@"error", "type.trait.associated_const_default", span, "trait associated const '{s}' cannot define a default in v1", .{name.text});
            continue;
        }
        const type_text = associated_const.ty orelse {
            try diagnostics.add(.@"error", "type.trait.associated_const", span, "trait associated const '{s}' requires an explicit type", .{name.text});
            continue;
        };

        const name_text = std.mem.trim(u8, name.text, " \t");
        const type_name = std.mem.trim(u8, type_text.text(), " \t");
        if (!isPlainIdentifier(name_text) or type_name.len == 0) {
            try diagnostics.add(.@"error", "type.trait.associated_const", span, "malformed trait associated const '{s}'", .{name.text});
            continue;
        }
        var duplicate = false;
        for (associated_consts.items) |existing| {
            if (std.mem.eql(u8, existing.name, name_text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.trait.associated_const_duplicate", span, "duplicate associated const '{s}' in trait '{s}'", .{
                name_text,
                item_name,
            });
            continue;
        }
        const builtin = types.Builtin.fromName(type_name);
        try associated_consts.append(.{
            .name = name_text,
            .type_syntax = try type_text.clone(allocator),
            .ty = builtin,
            .type_ref = try type_syntax_support.typeRefFromSyntax(allocator, type_text),
        });
    }

    for (body.methods) |method| {
        var lowered = try parseTraitMethodFromSyntax(allocator, inherited_generic_params, method, span, diagnostics);
        errdefer lowered.deinit(allocator);

        var duplicate = false;
        for (methods.items) |existing| {
            if (std.mem.eql(u8, existing.name, lowered.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.trait.method_duplicate", span, "duplicate method '{s}' in trait '{s}'", .{
                lowered.name,
                item_name,
            });
            continue;
        }

        try methods.append(lowered);
    }

    return .{
        .methods = try methods.toOwnedSlice(),
        .associated_types = try associated_types.toOwnedSlice(),
        .associated_consts = try associated_consts.toOwnedSlice(),
    };
}

pub fn parseImplMethodsFromSyntax(
    allocator: Allocator,
    inherited_generic_params: []const GenericParam,
    body: ast.ImplBodySyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]TraitMethod {
    var methods = std.array_list.Managed(TraitMethod).init(allocator);
    errdefer {
        for (methods.items) |*method| method.deinit(allocator);
        methods.deinit();
    }

    for (body.methods) |method| {
        try methods.append(try parseTraitMethodFromSyntax(allocator, inherited_generic_params, method, span, diagnostics));
    }

    return try methods.toOwnedSlice();
}

pub fn parseImplAssociatedTypesFromSyntax(
    allocator: Allocator,
    associated_types: []const ast.AssociatedTypeDeclSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]TraitAssociatedTypeBinding {
    var lowered = std.array_list.Managed(TraitAssociatedTypeBinding).init(allocator);
    errdefer lowered.deinit();

    for (associated_types) |associated_type| {
        const name = associated_type.name orelse {
            try diagnostics.add(.@"error", "type.impl.associated_type", span, "malformed impl associated type binding", .{});
            continue;
        };
        const value = associated_type.value orelse {
            try diagnostics.add(.@"error", "type.impl.associated_type", span, "impl associated type '{s}' requires '= Type'", .{name.text});
            continue;
        };

        const name_text = std.mem.trim(u8, name.text, " \t");
        const value_text = std.mem.trim(u8, value.text(), " \t");
        if (!isPlainIdentifier(name_text) or value_text.len == 0) {
            try diagnostics.add(.@"error", "type.impl.associated_type", span, "malformed impl associated type binding '{s}'", .{name.text});
            continue;
        }

        var duplicate = false;
        for (lowered.items) |existing| {
            if (std.mem.eql(u8, existing.name, name_text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.impl.associated_duplicate", span, "duplicate associated type binding '{s}' in impl", .{name_text});
            continue;
        }

        try lowered.append(.{
            .name = name_text,
            .value_type_syntax = try value.clone(allocator),
            .value_type = try type_syntax_support.typeRefFromSyntax(allocator, value),
        });
    }

    return lowered.toOwnedSlice();
}

pub fn parseImplAssociatedConstsFromSyntax(
    allocator: Allocator,
    associated_consts: []const ast.ConstSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]TraitAssociatedConstBinding {
    var lowered = std.array_list.Managed(TraitAssociatedConstBinding).init(allocator);
    errdefer {
        for (lowered.items) |*binding| binding.deinit(allocator);
        lowered.deinit();
    }

    for (associated_consts) |associated_const| {
        const name = associated_const.name orelse {
            try diagnostics.add(.@"error", "type.impl.associated_const", span, "malformed impl associated const binding", .{});
            continue;
        };
        const type_text = associated_const.ty orelse {
            try diagnostics.add(.@"error", "type.impl.associated_const", span, "impl associated const '{s}' requires an explicit type", .{name.text});
            continue;
        };
        if (associated_const.initializer == null) {
            try diagnostics.add(.@"error", "type.impl.associated_const", span, "impl associated const '{s}' requires a const initializer", .{name.text});
            continue;
        }

        const name_text = std.mem.trim(u8, name.text, " \t");
        const type_name = std.mem.trim(u8, type_text.text(), " \t");
        if (!isPlainIdentifier(name_text) or type_name.len == 0) {
            try diagnostics.add(.@"error", "type.impl.associated_const", span, "malformed impl associated const binding '{s}'", .{name.text});
            continue;
        }

        var duplicate = false;
        for (lowered.items) |existing| {
            if (std.mem.eql(u8, existing.name, name_text)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.impl.associated_const_duplicate", span, "duplicate associated const binding '{s}' in impl", .{name_text});
            continue;
        }

        var const_data = try item_syntax_bridge.parseConstDataFromSyntax(allocator, associated_const, span, diagnostics);
        errdefer const_data.deinit(allocator);
        try lowered.append(.{
            .name = name_text,
            .const_data = const_data,
        });
    }

    return lowered.toOwnedSlice();
}

pub fn parseExecutableMethodFromSyntax(
    allocator: Allocator,
    target_type: []const u8,
    inherited_generic_params: []const GenericParam,
    method: ast.MethodDeclSyntax,
    diagnostics: *diag.Bag,
) !?ParsedExecutableMethod {
    const block = method.block_syntax orelse return null;
    const signature_name = method.signature.name orelse {
        try diagnostics.add(.@"error", "type.impl.member", method.span, "unsupported impl member", .{});
        return null;
    };

    var function = FunctionData.init(allocator, method.is_suspend, false);
    errdefer function.deinit(allocator);

    const local_generic_params = try signatures.lowerGenericParams(allocator, method.signature.generic_params, diagnostics);
    errdefer if (local_generic_params.len != 0) allocator.free(local_generic_params);

    function.generic_params = try signatures.mergeGenericParams(
        allocator,
        inherited_generic_params,
        local_generic_params,
        method.span,
        diagnostics,
    );
    if (local_generic_params.len != 0) allocator.free(local_generic_params);

    function.where_predicates = try signatures.lowerWherePredicates(
        allocator,
        method.signature.where_clauses,
        function.generic_params,
        true,
        diagnostics,
    );

    if (method.signature.parameters.len == 0) {
        try diagnostics.add(.@"error", "type.method.receiver", method.span, "inherent methods require an explicit self receiver", .{});
        return null;
    }

    const receiver = try parseMethodReceiverFromSyntax(
        allocator,
        target_type,
        method.signature.parameters[0],
        method.span,
        diagnostics,
    ) orelse return null;
    try function.parameters.append(receiver);

    if (method.signature.parameters.len > 1) {
        for (method.signature.parameters[1..]) |parameter| {
            if (try parseOrdinaryParameterFromSyntax(allocator, parameter, method.span, diagnostics)) |lowered| {
                try function.parameters.append(lowered);
            }
        }
    }

    if (method.signature.return_type) |return_type| {
        if (!type_syntax_support.containsInvalid(return_type)) {
            function.return_type_syntax = try return_type.clone(allocator);
            function.return_type = try type_syntax_support.typeRefFromSyntax(allocator, return_type);
        }
    }

    function.block_syntax = try block.clone(allocator);
    return .{
        .method_name = signature_name.text,
        .receiver_mode = receiver.mode,
        .function = function,
    };
}

pub fn parseExecutableMethodFromTraitMethod(
    allocator: Allocator,
    target_type: []const u8,
    inherited_generic_params: []const GenericParam,
    method: typed_decls.TraitMethod,
    diagnostics: *diag.Bag,
) !?ParsedExecutableMethod {
    const syntax = method.syntax orelse return null;
    return parseExecutableMethodFromSyntax(allocator, target_type, inherited_generic_params, syntax, diagnostics);
}

fn parseTraitMethodFromSyntax(
    allocator: Allocator,
    inherited_generic_params: []const GenericParam,
    method: ast.MethodDeclSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !TraitMethod {
    const signature_name = method.signature.name orelse {
        try diagnostics.add(.@"error", "type.trait.member", span, "unsupported trait member", .{});
        return .{
            .name = "",
            .is_suspend = method.is_suspend,
            .has_default_body = method.block_syntax != null,
        };
    };
    var method_syntax = try method.clone(allocator);
    errdefer method_syntax.deinit(allocator);

    const local_generic_params = try signatures.lowerGenericParams(allocator, method.signature.generic_params, diagnostics);
    errdefer if (local_generic_params.len != 0) allocator.free(local_generic_params);
    const combined_generic_params = try signatures.mergeGenericParams(allocator, inherited_generic_params, local_generic_params, span, diagnostics);
    defer if (combined_generic_params.len != 0) allocator.free(combined_generic_params);

    const where_predicates = try signatures.lowerWherePredicates(
        allocator,
        method.signature.where_clauses,
        combined_generic_params,
        true,
        diagnostics,
    );
    errdefer signatures.deinitWherePredicates(allocator, where_predicates);

    return .{
        .name = signature_name.text,
        .is_suspend = method.is_suspend,
        .has_default_body = method.block_syntax != null,
        .generic_params = local_generic_params,
        .where_predicates = where_predicates,
        .syntax = method_syntax,
    };
}

pub fn parseMethodReceiverFromSyntax(
    allocator: Allocator,
    target_type: []const u8,
    parameter: ast.ParameterSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !?typed_decls.Parameter {
    const name = parameter.name orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
        return null;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, name.text, " \t"), "self")) {
        try diagnostics.add(.@"error", "type.method.receiver", span, "inherent methods require an explicit self receiver", .{});
        return null;
    }

    const mode = try item_syntax_bridge.parseParameterMode(parameter.mode, span, diagnostics);
    const maybe_type_syntax = parameter.ty;
    if (maybe_type_syntax == null) {
        return switch (mode) {
            .take, .read, .edit => .{
                .name = "self",
                .mode = mode,
                .type_syntax = null,
                .ty = .{ .named = target_type },
            },
            .owned => {
                try diagnostics.add(.@"error", "type.method.receiver", span, "unsupported method receiver form", .{});
                return null;
            },
        };
    }

    const type_syntax = maybe_type_syntax.?;
    if (mode == .take and type_syntax_support.borrowedSelfAccess(type_syntax) != null)
    {
        return .{
            .name = "self",
            .mode = .take,
            .type_syntax = try type_syntax.clone(allocator),
            .ty = try type_syntax_support.typeRefFromSyntax(allocator, type_syntax),
        };
    }

    try diagnostics.add(.@"error", "type.method.receiver", span, "unsupported method receiver form", .{});
    return null;
}

pub fn parseOrdinaryParameterFromSyntax(
    allocator: Allocator,
    parameter: ast.ParameterSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) !?typed_decls.Parameter {
    const name = parameter.name orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter in function signature", .{});
        return null;
    };
    const ty = parameter.ty orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{name.text});
        return null;
    };

    return .{
        .name = std.mem.trim(u8, name.text, " \t"),
        .mode = try item_syntax_bridge.parseParameterMode(parameter.mode, span, diagnostics),
        .type_syntax = try ty.clone(allocator),
        .ty = try type_syntax_support.typeRefFromSyntax(allocator, ty),
    };
}

test "executable trait method parsing uses structured typed syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var method = TraitMethod{
        .name = "bump",
        .is_suspend = false,
        .has_default_body = true,
        .syntax = .{
            .span = .{ .file_id = 0, .start = 0, .end = 46 },
            .signature = .{
                .name = .{ .text = "bump", .span = .{ .file_id = 0, .start = 0, .end = 4 } },
                .parameters = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
                    .{
                        .mode = .{ .edit = .{ .file_id = 0, .start = 5, .end = 9 } },
                        .name = .{ .text = "self", .span = .{ .file_id = 0, .start = 10, .end = 14 } },
                    },
                }),
                .return_type = .{ .source = .{ .text = "I32", .span = .{ .file_id = 0, .start = 19, .end = 22 } } },
            },
            .block_syntax = .{
                .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
                    .{
                        .text = .{ .text = "return 1", .span = .{ .file_id = 0, .start = 38, .end = 46 } },
                    },
                }),
            },
        },
    };
    defer method.deinit(std.testing.allocator);

    const maybe_parsed = try parseExecutableMethodFromTraitMethod(
        std.testing.allocator,
        "Counter",
        &.{},
        method,
        &diagnostics,
    );
    try std.testing.expect(maybe_parsed != null);

    var parsed = maybe_parsed.?;
    defer parsed.function.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(ParameterMode.edit, parsed.receiver_mode);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.parameters.items.len);
    try std.testing.expectEqualStrings("self", parsed.function.parameters.items[0].name);
    try std.testing.expect(parsed.function.parameters.items[0].type_syntax == null);
    try std.testing.expect(parsed.function.return_type_syntax != null);
    try std.testing.expectEqualStrings("I32", parsed.function.return_type_syntax.?.text());
    try std.testing.expect(parsed.function.block_syntax != null);
    try std.testing.expectEqualStrings("return 1", parsed.function.block_syntax.?.lines[0].text.text);
}
