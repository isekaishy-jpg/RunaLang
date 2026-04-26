const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const hir = @import("../hir/root.zig");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed_attributes = @import("attributes.zig");
const body_syntax_bridge = @import("body_syntax_bridge.zig");
const typed_decls = @import("declarations.zig");
const item_syntax_bridge = @import("item_syntax_bridge.zig");
const signatures = @import("signatures.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const baseTypeName = typed_text.baseTypeName;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const genericParamExists = signatures.genericParamExists;
const isLifetimeName = signatures.isLifetimeName;
const isPlainIdentifier = typed_text.isPlainIdentifier;
const mergeGenericParams = signatures.mergeGenericParams;
const parseExportName = typed_attributes.parseExportName;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;
const validateLifetimeReference = signatures.validateLifetimeReference;

pub const ParameterMode = typed_decls.ParameterMode;
pub const Parameter = typed_decls.Parameter;
pub const FunctionData = typed_decls.FunctionData;
pub const ConstData = typed_decls.ConstData;
pub const StructField = typed_decls.StructField;
pub const TupleField = typed_decls.TupleField;
pub const StructData = typed_decls.StructData;
pub const UnionData = typed_decls.UnionData;
pub const EnumVariant = typed_decls.EnumVariant;
pub const EnumData = typed_decls.EnumData;
pub const OpaqueTypeData = typed_decls.OpaqueTypeData;
pub const TraitMethod = typed_decls.TraitMethod;
pub const TraitAssociatedType = typed_decls.TraitAssociatedType;
pub const TraitAssociatedTypeBinding = typed_decls.TraitAssociatedTypeBinding;
pub const TraitAssociatedConst = typed_decls.TraitAssociatedConst;
pub const TraitAssociatedConstBinding = typed_decls.TraitAssociatedConstBinding;
pub const TraitData = typed_decls.TraitData;
pub const ImplData = typed_decls.ImplData;
pub const GenericParam = signatures.GenericParam;
pub const WherePredicate = signatures.WherePredicate;

pub const MethodReceiverMode = enum {
    take,
    read,
    edit,
};

pub const BodyLine = struct {
    raw: []const u8,
    trimmed: []const u8,
    indent: usize,
};

pub const ParsedMethodReceiver = struct {
    receiver_mode: MethodReceiverMode,
    parameter: Parameter,
};

fn contextAllowSelf(context: anytype) bool {
    if (@hasField(@TypeOf(context), "allow_self")) return context.allow_self;
    return false;
}

fn contextGenericParams(context: anytype) []const GenericParam {
    if (@hasField(@TypeOf(context), "generic_params")) return context.generic_params;
    return &.{};
}

fn contextSelfTypeName(context: anytype) ?[]const u8 {
    if (@hasField(@TypeOf(context), "self_type_name")) return context.self_type_name;
    return null;
}

pub fn validateSimpleTypeName(name: []const u8, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    if (name.len == 0) {
        try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type name", .{});
        return;
    }
    if (types.Builtin.fromName(name) != .unsupported) return;
    if (isCompilerKnownNominalType(name)) return;
    if (contextAllowSelf(context) and std.mem.eql(u8, name, "Self")) return;
    if (genericParamExists(contextGenericParams(context), name, .type_param)) return;
    if (context.type_scope.contains(name)) return;
    try diagnostics.add(.@"error", "type.name.unknown_type", span, "unknown type name '{s}'", .{name});
}

fn isCompilerKnownNominalType(name: []const u8) bool {
    return std.mem.eql(u8, name, "Option") or
        std.mem.eql(u8, name, "Result") or
        std.mem.eql(u8, name, "ConvertError");
}

pub fn validateTypeExpression(raw: []const u8, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) {
        try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type name", .{});
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "hold[")) {
        const close_index = findMatchingDelimiter(trimmed, "hold[".len - 1, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed retained-borrow syntax '{s}'", .{trimmed});
            return;
        };
        const lifetime_name = std.mem.trim(u8, trimmed["hold[".len..close_index], " \t");
        try validateLifetimeReference(lifetime_name, contextGenericParams(context), span, diagnostics);

        const rest = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "read ")) {
            try validateTypeExpression(rest["read ".len..], context, span, diagnostics);
            return;
        }
        if (std.mem.startsWith(u8, rest, "edit ")) {
            try validateTypeExpression(rest["edit ".len..], context, span, diagnostics);
            return;
        }
        if (std.mem.startsWith(u8, rest, "take ")) {
            try diagnostics.add(.@"error", "type.lifetime.hold_take", span, "retained borrows do not support 'hold[...] take T'", .{});
            return;
        }
        try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed retained-borrow syntax '{s}'", .{trimmed});
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) {
        try validateTypeExpression(trimmed["read ".len..], context, span, diagnostics);
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "edit ")) {
        try validateTypeExpression(trimmed["edit ".len..], context, span, diagnostics);
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.array.syntax", span, "malformed fixed array type '{s}'", .{trimmed});
            return;
        };
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) {
            try diagnostics.add(.@"error", "type.array.syntax", span, "malformed fixed array type '{s}'", .{trimmed});
            return;
        }
        const inner = trimmed[1..close_index];
        const separator = findTopLevelHeaderScalar(inner, ';') orelse {
            try diagnostics.add(.@"error", "type.array.syntax", span, "fixed array type '{s}' requires '[T; N]'", .{trimmed});
            return;
        };
        const element_type = std.mem.trim(u8, inner[0..separator], " \t");
        const length_expr = std.mem.trim(u8, inner[separator + 1 ..], " \t");
        if (element_type.len == 0 or length_expr.len == 0) {
            try diagnostics.add(.@"error", "type.array.syntax", span, "fixed array type '{s}' requires '[T; N]'", .{trimmed});
            return;
        }
        try validateTypeExpression(element_type, context, span, diagnostics);
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
            return;
        };
        if (std.mem.trim(u8, trimmed[close_index + 1 ..], " \t").len != 0) {
            try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
            return;
        }
        const base_name = std.mem.trim(u8, trimmed[0..open_index], " \t");
        try validateSimpleTypeName(base_name, context, span, diagnostics);
        const args = try splitTopLevelCommaParts(context.type_scope.allocator, trimmed[open_index + 1 .. close_index]);
        defer context.type_scope.allocator.free(args);
        for (args) |arg| {
            if (arg.len == 0) {
                try diagnostics.add(.@"error", "type.name.syntax", span, "malformed type application '{s}'", .{trimmed});
                continue;
            }
            if (isLifetimeName(arg)) {
                try validateLifetimeReference(arg, contextGenericParams(context), span, diagnostics);
            } else {
                try validateTypeExpression(arg, context, span, diagnostics);
            }
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        var parts = std.mem.splitScalar(u8, trimmed, '.');
        var part_index: usize = 0;
        while (parts.next()) |part| : (part_index += 1) {
            if (part_index == 0) {
                try validateSimpleTypeName(part, context, span, diagnostics);
            } else if (!isPlainIdentifier(part)) {
                try diagnostics.add(.@"error", "type.name.syntax", span, "malformed associated type reference '{s}'", .{trimmed});
            }
        }
        return;
    }

    try validateSimpleTypeName(trimmed, context, span, diagnostics);
}

pub fn resolveValueTypeWithContext(
    type_name: []const u8,
    context: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !types.TypeRef {
    const trimmed = std.mem.trim(u8, type_name, " \t");
    try validateTypeExpression(trimmed, context, span, diagnostics);

    const builtin = types.Builtin.fromName(trimmed);
    if (builtin != .unsupported) return types.TypeRef.fromBuiltin(builtin);
    if (contextSelfTypeName(context)) |self_type_name| {
        if (std.mem.eql(u8, trimmed, "Self")) return .{ .named = self_type_name };
    }
    return .{ .named = trimmed };
}

pub fn parseFunctionSignature(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !FunctionData {
    var function = FunctionData.init(allocator, item.kind == .suspend_function, item.kind == .foreign_function);
    errdefer function.deinit(allocator);
    function.block_syntax = if (item.block_syntax) |block| try block.clone(allocator) else null;

    function.export_name = parseExportName(item.attributes);
    function.abi = item.foreign_abi;

    const signature = switch (item.syntax) {
        .function => |signature| signature,
        else => return error.InvalidParse,
    };
    try item_syntax_bridge.fillFunctionDataFromSyntax(allocator, &function, signature, item.span, diagnostics);

    if (item.kind == .foreign_function and function.export_name != null) {
        try diagnostics.add(.@"error", "type.foreign.export", item.span, "foreign declarations do not combine with #export in stage0", .{});
    }

    return function;
}

pub fn parseConstDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !ConstData {
    return switch (item.syntax) {
        .const_item => |signature| item_syntax_bridge.parseConstDataFromSyntax(allocator, signature, item.span, diagnostics),
        else => error.InvalidParse,
    };
}

pub fn parseStructDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !StructData {
    const signature_data = try parseNamedDeclarationHeader(allocator, item, "struct ", false, diagnostics);
    const generic_params = signature_data.generic_params;
    errdefer if (generic_params.len != 0) allocator.free(generic_params);
    const where_predicates = signature_data.where_predicates;
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);

    return switch (item.body_syntax) {
        .struct_fields => |fields| .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .fields = try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, item.name, item.span, diagnostics),
        },
        .none => .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .fields = try allocator.alloc(StructField, 0),
        },
        else => error.InvalidParse,
    };
}

pub fn parseUnionDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !UnionData {
    if (!hasReprC(item.attributes)) {
        try diagnostics.add(.@"error", "type.union.repr_c", item.span, "union declarations require #repr[c] in stage0", .{});
    }

    return switch (item.body_syntax) {
        .union_fields => |fields| blk: {
            const lowered_fields = try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, item.name, item.span, diagnostics);
            for (lowered_fields) |field| {
                if (!fieldTypeLooksCAbiSafe(field.type_name)) {
                    try diagnostics.add(.@"error", "type.union.field_c_abi", item.span, "stage0 union fields must use C ABI-safe types", .{});
                }
            }
            break :blk .{ .fields = lowered_fields };
        },
        .none => .{ .fields = try allocator.alloc(StructField, 0) },
        else => error.InvalidParse,
    };
}

pub fn parseEnumDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !EnumData {
    const signature_data = try parseNamedDeclarationHeader(allocator, item, "enum ", false, diagnostics);
    const generic_params = signature_data.generic_params;
    errdefer if (generic_params.len != 0) allocator.free(generic_params);
    const where_predicates = signature_data.where_predicates;
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);

    return switch (item.body_syntax) {
        .enum_variants => |variants| .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .variants = try body_syntax_bridge.parseEnumVariantsFromSyntax(allocator, variants, item.name, item.span, diagnostics),
        },
        .none => .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .variants = try allocator.alloc(EnumVariant, 0),
        },
        else => error.InvalidParse,
    };
}

pub fn parseOpaqueTypeDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !OpaqueTypeData {
    const named_header = switch (item.syntax) {
        .named_decl => |signature| try item_syntax_bridge.parseNamedDeclData(allocator, signature, false, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    return .{
        .generic_params = named_header.generic_params,
        .where_predicates = named_header.where_predicates,
    };
}

pub fn parseTraitDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !TraitData {
    const signature_data = try parseNamedDeclarationHeader(allocator, item, "trait ", true, diagnostics);
    const generic_params = signature_data.generic_params;
    errdefer if (generic_params.len != 0) allocator.free(generic_params);
    const where_predicates = signature_data.where_predicates;
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);

    return switch (item.body_syntax) {
        .trait_body => |body| blk: {
            var parsed_body = try body_syntax_bridge.parseTraitBodyFromSyntax(allocator, generic_params, body, item.name, item.span, diagnostics);
            errdefer parsed_body.deinit(allocator);
            break :blk .{
                .generic_params = generic_params,
                .where_predicates = where_predicates,
                .methods = parsed_body.methods,
                .associated_types = parsed_body.associated_types,
                .associated_consts = parsed_body.associated_consts,
            };
        },
        .none => .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .methods = try allocator.alloc(TraitMethod, 0),
            .associated_types = try allocator.alloc(TraitAssociatedType, 0),
            .associated_consts = try allocator.alloc(TraitAssociatedConst, 0),
        },
        else => error.InvalidParse,
    };
}

pub fn parseImplDeclaration(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !ImplData {
    const header_data = try parseImplHeader(allocator, item, diagnostics);
    const generic_params = header_data.generic_params;
    errdefer if (generic_params.len != 0) allocator.free(generic_params);
    const where_predicates = header_data.where_predicates;
    errdefer if (where_predicates.len != 0) allocator.free(where_predicates);
    const target_type = header_data.target_type;
    const trait_name = header_data.trait_name;

    return switch (item.body_syntax) {
        .impl_body => |body| blk: {
            break :blk .{
                .generic_params = generic_params,
                .where_predicates = where_predicates,
                .target_type = target_type,
                .trait_name = trait_name,
                .associated_types = try parseImplAssociatedTypes(allocator, body.associated_types, item.span, diagnostics),
                .associated_consts = try parseImplAssociatedConsts(allocator, body.associated_consts, item.span, diagnostics),
                .methods = try body_syntax_bridge.parseImplMethodsFromSyntax(allocator, generic_params, body, item.span, diagnostics),
            };
        },
        .none => .{
            .generic_params = generic_params,
            .where_predicates = where_predicates,
            .target_type = target_type,
            .trait_name = trait_name,
            .associated_types = try allocator.alloc(TraitAssociatedTypeBinding, 0),
            .associated_consts = try allocator.alloc(TraitAssociatedConstBinding, 0),
            .methods = try allocator.alloc(TraitMethod, 0),
        },
        else => error.InvalidParse,
    };
}

fn parseImplAssociatedTypes(
    allocator: Allocator,
    associated_types: []const ast.AssociatedTypeDeclSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]TraitAssociatedTypeBinding {
    var lowered = array_list.Managed(TraitAssociatedTypeBinding).init(allocator);
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
        const value_text = std.mem.trim(u8, value.text, " \t");
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
            .value_type_name = value_text,
            .value_type = types.TypeRef.fromBuiltin(types.Builtin.fromName(value_text)),
        });
    }

    return lowered.toOwnedSlice();
}

fn parseImplAssociatedConsts(
    allocator: Allocator,
    associated_consts: []const ast.ConstSignatureSyntax,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]TraitAssociatedConstBinding {
    var lowered = array_list.Managed(TraitAssociatedConstBinding).init(allocator);
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
        const type_name = std.mem.trim(u8, type_text.text, " \t");
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

fn parseNamedDeclarationHeader(
    allocator: Allocator,
    item: hir.Item,
    prefix: []const u8,
    allow_self: bool,
    diagnostics: *diag.Bag,
) !item_syntax_bridge.NamedDeclData {
    _ = prefix;
    return switch (item.syntax) {
        .named_decl => |signature| item_syntax_bridge.parseNamedDeclData(allocator, signature, allow_self, item.span, diagnostics),
        else => error.InvalidParse,
    };
}

fn parseImplHeader(
    allocator: Allocator,
    item: hir.Item,
    diagnostics: *diag.Bag,
) !item_syntax_bridge.ImplHeaderData {
    return switch (item.syntax) {
        .impl_block => |signature| item_syntax_bridge.parseImplHeaderData(allocator, signature, item.span, diagnostics),
        else => error.InvalidParse,
    };
}

test "function signature parsing uses structured item syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const parameter_syntax = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
        .{
            .mode = .{ .text = "take", .span = .{ .file_id = 0, .start = 0, .end = 4 } },
            .name = .{ .text = "value", .span = .{ .file_id = 0, .start = 5, .end = 10 } },
            .ty = .{ .text = "T", .span = .{ .file_id = 0, .start = 12, .end = 13 } },
        },
    });
    const where_syntax = try std.testing.allocator.dupe(ast.SpanText, &.{
        .{ .text = "where T: Send", .span = .{ .file_id = 0, .start = 20, .end = 33 } },
    });
    var item: hir.Item = .{
        .kind = .function,
        .name = try std.testing.allocator.dupe(u8, "choose"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 40 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{
            .function = .{
                .name = .{ .text = "choose", .span = .{ .file_id = 0, .start = 0, .end = 6 } },
                .generic_params = .{ .text = "[T]", .span = .{ .file_id = 0, .start = 6, .end = 9 } },
                .parameters = parameter_syntax,
                .return_type = .{ .text = "Unit", .span = .{ .file_id = 0, .start = 15, .end = 19 } },
                .where_clauses = where_syntax,
            },
        },
    };
    defer item.deinit(std.testing.allocator);

    var function = try parseFunctionSignature(std.testing.allocator, item, &diagnostics);
    defer function.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), function.generic_params.len);
    try std.testing.expectEqual(@as(usize, 1), function.where_predicates.len);
    try std.testing.expectEqual(@as(usize, 1), function.parameters.items.len);
    try std.testing.expectEqualStrings("value", function.parameters.items[0].name);
    try std.testing.expectEqual(ParameterMode.take, function.parameters.items[0].mode);
    try std.testing.expectEqualStrings("T", function.parameters.items[0].type_name);
    try std.testing.expectEqualStrings("Unit", function.return_type_name);
}

test "struct declaration parsing uses structured item syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const where_syntax = try std.testing.allocator.dupe(ast.SpanText, &.{
        .{ .text = "where T: Clone", .span = .{ .file_id = 0, .start = 10, .end = 24 } },
    });
    var item: hir.Item = .{
        .kind = .struct_type,
        .name = try std.testing.allocator.dupe(u8, "Box"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 30 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{
            .named_decl = .{
                .name = .{ .text = "Box", .span = .{ .file_id = 0, .start = 0, .end = 3 } },
                .generic_params = .{ .text = "[T]", .span = .{ .file_id = 0, .start = 3, .end = 6 } },
                .where_clauses = where_syntax,
            },
        },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseStructDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), data.generic_params.len);
    try std.testing.expectEqual(@as(usize, 1), data.where_predicates.len);
    try std.testing.expectEqual(@as(usize, 1), data.fields.len);
    try std.testing.expectEqualStrings("value", data.fields[0].name);
    try std.testing.expectEqualStrings("T", data.fields[0].type_name);
}

test "impl declaration parsing uses structured item syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const where_syntax = try std.testing.allocator.dupe(ast.SpanText, &.{
        .{ .text = "where T: Clone", .span = .{ .file_id = 0, .start = 15, .end = 29 } },
    });
    var item: hir.Item = .{
        .kind = .impl_block,
        .name = try std.testing.allocator.dupe(u8, ""),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 30 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{
            .impl_block = .{
                .generic_params = .{ .text = "[T]", .span = .{ .file_id = 0, .start = 0, .end = 3 } },
                .trait_name = .{ .text = "Clone", .span = .{ .file_id = 0, .start = 4, .end = 9 } },
                .target_type = .{ .text = "Box[T]", .span = .{ .file_id = 0, .start = 14, .end = 20 } },
                .where_clauses = where_syntax,
            },
        },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseImplDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), data.generic_params.len);
    try std.testing.expectEqual(@as(usize, 1), data.where_predicates.len);
    try std.testing.expectEqualStrings("Box[T]", data.target_type);
    try std.testing.expectEqualStrings("Clone", data.trait_name.?);
}

test "struct declaration parsing uses structured body syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const fields = try std.testing.allocator.dupe(ast.FieldDeclSyntax, &.{
        .{
            .visibility = .pub_item,
            .name = .{ .text = "value", .span = .{ .file_id = 0, .start = 0, .end = 5 } },
            .ty = .{ .text = "I32", .span = .{ .file_id = 0, .start = 7, .end = 10 } },
        },
    });
    var item: hir.Item = .{
        .kind = .struct_type,
        .name = try std.testing.allocator.dupe(u8, "Box"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 20 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{ .named_decl = .{ .name = .{ .text = "Box", .span = .{ .file_id = 0, .start = 0, .end = 3 } } } },
        .body_syntax = .{ .struct_fields = fields },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseStructDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), data.fields.len);
    try std.testing.expectEqual(ast.Visibility.pub_item, data.fields[0].visibility);
    try std.testing.expectEqualStrings("value", data.fields[0].name);
    try std.testing.expectEqualStrings("I32", data.fields[0].type_name);
}

test "enum declaration parsing uses structured body syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const named_fields = try std.testing.allocator.dupe(ast.FieldDeclSyntax, &.{
        .{
            .name = .{ .text = "code", .span = .{ .file_id = 0, .start = 0, .end = 4 } },
            .ty = .{ .text = "I32", .span = .{ .file_id = 0, .start = 6, .end = 9 } },
        },
    });
    const variants = try std.testing.allocator.dupe(ast.EnumVariantSyntax, &.{
        .{
            .name = .{ .text = "Some", .span = .{ .file_id = 0, .start = 0, .end = 4 } },
            .tuple_payload = .{ .text = "(I32)", .span = .{ .file_id = 0, .start = 4, .end = 9 } },
        },
        .{
            .name = .{ .text = "None", .span = .{ .file_id = 0, .start = 10, .end = 14 } },
            .named_fields = named_fields,
        },
    });
    var item: hir.Item = .{
        .kind = .enum_type,
        .name = try std.testing.allocator.dupe(u8, "Choice"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 20 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{ .named_decl = .{ .name = .{ .text = "Choice", .span = .{ .file_id = 0, .start = 0, .end = 6 } } } },
        .body_syntax = .{ .enum_variants = variants },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseEnumDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 2), data.variants.len);
    try std.testing.expectEqualStrings("Some", data.variants[0].name);
    try std.testing.expectEqualStrings("I32", data.variants[0].payload.tuple_fields[0].type_name);
    try std.testing.expectEqualStrings("code", data.variants[1].payload.named_fields[0].name);
}

test "trait declaration parsing uses structured body syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const methods = try std.testing.allocator.dupe(ast.MethodDeclSyntax, &.{
        .{
            .span = .{ .file_id = 0, .start = 0, .end = 58 },
            .signature = .{
                .name = .{ .text = "read", .span = .{ .file_id = 0, .start = 3, .end = 7 } },
                .parameters = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
                    .{
                        .mode = .{ .text = "read", .span = .{ .file_id = 0, .start = 8, .end = 12 } },
                        .name = .{ .text = "self", .span = .{ .file_id = 0, .start = 13, .end = 17 } },
                        .ty = .{ .text = "Buffer", .span = .{ .file_id = 0, .start = 19, .end = 25 } },
                    },
                }),
                .return_type = .{ .text = "Item", .span = .{ .file_id = 0, .start = 30, .end = 34 } },
            },
            .block_syntax = .{
                .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
                    .{
                        .text = .{ .text = "return item", .span = .{ .file_id = 0, .start = 40, .end = 51 } },
                    },
                }),
            },
        },
    });
    const associated_types = try std.testing.allocator.dupe(ast.AssociatedTypeDeclSyntax, &.{
        .{ .name = .{ .text = "Item", .span = .{ .file_id = 0, .start = 0, .end = 4 } } },
    });
    var item: hir.Item = .{
        .kind = .trait_type,
        .name = try std.testing.allocator.dupe(u8, "Buffer"),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 60 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{ .named_decl = .{ .name = .{ .text = "Buffer", .span = .{ .file_id = 0, .start = 0, .end = 6 } } } },
        .body_syntax = .{ .trait_body = .{ .methods = methods, .associated_types = associated_types } },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseTraitDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), data.methods.len);
    try std.testing.expectEqual(@as(usize, 1), data.associated_types.len);
    try std.testing.expectEqualStrings("read", data.methods[0].name);
    try std.testing.expect(data.methods[0].has_default_body);
    try std.testing.expect(data.methods[0].syntax != null);
    try std.testing.expectEqualStrings("Item", data.associated_types[0].name);
}

test "impl declaration parsing uses structured body syntax" {
    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    const methods = try std.testing.allocator.dupe(ast.MethodDeclSyntax, &.{
        .{
            .span = .{ .file_id = 0, .start = 0, .end = 64 },
            .signature = .{
                .name = .{ .text = "read", .span = .{ .file_id = 0, .start = 3, .end = 7 } },
                .parameters = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
                    .{
                        .mode = .{ .text = "read", .span = .{ .file_id = 0, .start = 8, .end = 12 } },
                        .name = .{ .text = "self", .span = .{ .file_id = 0, .start = 13, .end = 17 } },
                        .ty = .{ .text = "Box[T]", .span = .{ .file_id = 0, .start = 19, .end = 25 } },
                    },
                }),
                .return_type = .{ .text = "T", .span = .{ .file_id = 0, .start = 30, .end = 31 } },
            },
            .block_syntax = .{
                .lines = try std.testing.allocator.dupe(ast.LineSyntax, &.{
                    .{
                        .text = .{ .text = "return self.value", .span = .{ .file_id = 0, .start = 40, .end = 57 } },
                    },
                }),
            },
        },
    });
    var item: hir.Item = .{
        .kind = .impl_block,
        .name = try std.testing.allocator.dupe(u8, ""),
        .visibility = .private,
        .attributes = try std.testing.allocator.dupe(ast.Attribute, &.{}),
        .span = .{ .file_id = 0, .start = 0, .end = 70 },
        .has_body = true,
        .foreign_abi = null,
        .syntax = .{
            .impl_block = .{
                .generic_params = .{ .text = "[T]", .span = .{ .file_id = 0, .start = 0, .end = 3 } },
                .target_type = .{ .text = "Box[T]", .span = .{ .file_id = 0, .start = 10, .end = 16 } },
            },
        },
        .body_syntax = .{ .impl_body = .{ .methods = methods, .associated_types = &.{} } },
    };
    defer item.deinit(std.testing.allocator);

    var data = try parseImplDeclaration(std.testing.allocator, item, &diagnostics);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try std.testing.expectEqual(@as(usize, 1), data.methods.len);
    try std.testing.expectEqualStrings("read", data.methods[0].name);
    try std.testing.expect(data.methods[0].has_default_body);
    try std.testing.expect(data.methods[0].syntax != null);
}

test "trait method validation uses structured method syntax" {
    const MockItems = struct {
        items: []const hir.Item = &.{},
    };
    const MockModule = struct {
        items: MockItems = .{},
    };
    const MockTypeScope = struct {
        allocator: Allocator,

        pub fn contains(self: *const @This(), name: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, name, "Item");
        }
    };

    var diagnostics = diag.Bag.init(std.testing.allocator);
    defer diagnostics.deinit();

    var method = TraitMethod{
        .name = "read",
        .is_suspend = false,
        .has_default_body = false,
        .syntax = .{
            .span = .{ .file_id = 0, .start = 0, .end = 31 },
            .signature = .{
                .name = .{ .text = "read", .span = .{ .file_id = 0, .start = 0, .end = 4 } },
                .parameters = try std.testing.allocator.dupe(ast.ParameterSyntax, &.{
                    .{
                        .mode = .{ .text = "read", .span = .{ .file_id = 0, .start = 5, .end = 9 } },
                        .name = .{ .text = "self", .span = .{ .file_id = 0, .start = 10, .end = 14 } },
                    },
                }),
                .return_type = .{ .text = "MissingType", .span = .{ .file_id = 0, .start = 20, .end = 31 } },
            },
        },
    };
    defer method.deinit(std.testing.allocator);

    var type_scope = MockTypeScope{ .allocator = std.testing.allocator };
    try validateTraitMethodSignature(
        std.testing.allocator,
        MockModule{},
        &method,
        &.{},
        &.{},
        &type_scope,
        .{ .file_id = 0, .start = 0, .end = 32 },
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 1), diagnostics.errorCount());
}

pub fn parseOrdinaryParameterPart(
    part: []const u8,
    diagnostics: *diag.Bag,
    span: source.Span,
) !?Parameter {
    const colon_index = std.mem.indexOfScalar(u8, part, ':') orelse {
        try diagnostics.add(.@"error", "type.param.syntax", span, "malformed parameter '{s}'", .{part});
        return null;
    };

    const left = std.mem.trim(u8, part[0..colon_index], " \t");
    const type_raw = std.mem.trim(u8, part[colon_index + 1 ..], " \t");

    var mode: ParameterMode = .owned;
    var name = left;
    if (std.mem.startsWith(u8, left, "take ")) {
        mode = .take;
        name = std.mem.trim(u8, left["take ".len..], " \t");
    } else if (std.mem.startsWith(u8, left, "read ")) {
        mode = .read;
        name = std.mem.trim(u8, left["read ".len..], " \t");
    } else if (std.mem.startsWith(u8, left, "edit ")) {
        mode = .edit;
        name = std.mem.trim(u8, left["edit ".len..], " \t");
    }

    return .{
        .name = name,
        .mode = mode,
        .type_name = type_raw,
        .ty = types.TypeRef.fromBuiltin(types.Builtin.fromName(type_raw)),
    };
}

fn parseParameters(
    allocator: Allocator,
    params_raw: []const u8,
    function: *FunctionData,
    diagnostics: *diag.Bag,
    span: source.Span,
) !void {
    const parts = try splitTopLevelCommaParts(allocator, params_raw);
    defer allocator.free(parts);

    for (parts) |part| {
        if (part.len == 0) continue;
        if (try parseOrdinaryParameterPart(part, diagnostics, span)) |parameter| {
            try function.parameters.append(parameter);
        }
    }
}

fn parseEnumVariant(
    allocator: Allocator,
    lines: []const BodyLine,
    index: *usize,
    variant_indent: usize,
    item: hir.Item,
    diagnostics: *diag.Bag,
) !EnumVariant {
    const line = lines[index.*];
    var variant_text = line.trimmed;
    var discriminant: ?[]const u8 = null;
    if (findTopLevelHeaderScalar(line.trimmed, '=')) |equal_index| {
        variant_text = std.mem.trim(u8, line.trimmed[0..equal_index], " \t");
        const raw_discriminant = std.mem.trim(u8, line.trimmed[equal_index + 1 ..], " \t");
        if (raw_discriminant.len == 0) {
            try diagnostics.add(.@"error", "type.enum.discriminant", item.span, "enum variant has an empty discriminant", .{});
        } else {
            discriminant = raw_discriminant;
        }
    }

    if (std.mem.endsWith(u8, variant_text, ":")) {
        const name = std.mem.trim(u8, variant_text[0 .. variant_text.len - 1], " \t");
        if (!isPlainIdentifier(name)) {
            try diagnostics.add(.@"error", "type.enum.variant", item.span, "malformed enum variant '{s}'", .{variant_text});
            index.* += 1;
            return .{ .name = "", .payload = .none, .discriminant = discriminant };
        }

        index.* += 1;
        const field_indent = if (index.* < lines.len) lines[index.*].indent else variant_indent + 4;
        var fields = array_list.Managed(StructField).init(allocator);
        errdefer fields.deinit();

        while (index.* < lines.len) {
            const field_line = lines[index.*];
            if (field_line.trimmed.len == 0) {
                index.* += 1;
                continue;
            }
            if (field_line.indent <= variant_indent) break;
            if (field_line.indent != field_indent) {
                try diagnostics.add(.@"error", "type.enum.variant_indent", item.span, "unexpected indentation in named-field enum variant", .{});
                index.* += 1;
                continue;
            }

            const parsed = parseFieldDeclaration(field_line.trimmed) orelse {
                try diagnostics.add(.@"error", "type.enum.variant_field", item.span, "malformed named-field enum payload field '{s}'", .{field_line.trimmed});
                index.* += 1;
                continue;
            };

            var duplicate = false;
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, parsed.name)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                try diagnostics.add(.@"error", "type.enum.variant_field_duplicate", item.span, "duplicate named payload field '{s}' in variant '{s}'", .{
                    parsed.name,
                    name,
                });
                index.* += 1;
                continue;
            }

            try fields.append(parsed);
            index.* += 1;
        }

        return .{
            .name = name,
            .payload = .{ .named_fields = try fields.toOwnedSlice() },
            .discriminant = discriminant,
        };
    }

    if (std.mem.indexOfScalar(u8, variant_text, '(')) |open_index| {
        const close_index = std.mem.lastIndexOfScalar(u8, variant_text, ')') orelse {
            try diagnostics.add(.@"error", "type.enum.variant", item.span, "malformed tuple-payload enum variant '{s}'", .{variant_text});
            index.* += 1;
            return .{ .name = "", .payload = .none, .discriminant = discriminant };
        };
        const name = std.mem.trim(u8, variant_text[0..open_index], " \t");
        const inner = std.mem.trim(u8, variant_text[open_index + 1 .. close_index], " \t");
        if (!isPlainIdentifier(name)) {
            try diagnostics.add(.@"error", "type.enum.variant", item.span, "malformed enum variant '{s}'", .{variant_text});
            index.* += 1;
            return .{ .name = "", .payload = .none, .discriminant = discriminant };
        }

        var tuple_fields = array_list.Managed(TupleField).init(allocator);
        errdefer tuple_fields.deinit();
        var parts = std.mem.splitScalar(u8, inner, ',');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (part.len == 0) continue;
            try tuple_fields.append(.{
                .type_name = part,
            });
        }

        index.* += 1;
        return .{
            .name = name,
            .payload = .{ .tuple_fields = try tuple_fields.toOwnedSlice() },
            .discriminant = discriminant,
        };
    }

    const name = std.mem.trim(u8, variant_text, " \t");
    if (!isPlainIdentifier(name)) {
        try diagnostics.add(.@"error", "type.enum.variant", item.span, "malformed enum variant '{s}'", .{variant_text});
    }
    index.* += 1;
    return .{
        .name = name,
        .payload = .none,
        .discriminant = discriminant,
    };
}

fn parseFieldDeclaration(raw: []const u8) ?StructField {
    var visibility: ast.Visibility = .private;
    var field = raw;

    if (std.mem.startsWith(u8, field, "pub(package) ")) {
        visibility = .pub_package;
        field = std.mem.trim(u8, field["pub(package) ".len..], " \t");
    } else if (std.mem.startsWith(u8, field, "pub ")) {
        visibility = .pub_item;
        field = std.mem.trim(u8, field["pub ".len..], " \t");
    }

    const colon_index = std.mem.indexOfScalar(u8, field, ':') orelse return null;
    const name = std.mem.trim(u8, field[0..colon_index], " \t");
    const type_name = std.mem.trim(u8, field[colon_index + 1 ..], " \t");
    if (!isPlainIdentifier(name) or type_name.len == 0) return null;

    return .{
        .name = name,
        .visibility = visibility,
        .type_name = type_name,
    };
}

fn fieldTypeLooksCAbiSafe(type_name: []const u8) bool {
    const builtin = types.Builtin.fromName(type_name);
    return builtin != .unsupported and builtin.isCAbiSafe();
}

fn hasReprC(attributes: []const ast.Attribute) bool {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name, "repr")) continue;
        if (std.mem.indexOf(u8, attribute.raw, "[c]") != null) return true;
        if (std.mem.indexOf(u8, attribute.raw, "[c,") != null) return true;
    }
    return false;
}

pub fn validateStructFieldsWithContext(fields: []const StructField, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    for (fields) |field| {
        try validateTypeExpression(field.type_name, context, span, diagnostics);
    }
}

pub fn resolveStructFieldsWithContext(fields: []StructField, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    for (fields) |*field| {
        field.ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
    }
}

pub fn validateEnumVariantsWithContext(variants: []const EnumVariant, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    for (variants) |variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |field| {
                    try validateTypeExpression(field.type_name, context, span, diagnostics);
                }
            },
            .named_fields => |named_fields| {
                try validateStructFieldsWithContext(named_fields, context, span, diagnostics);
            },
        }
    }
}

pub fn resolveEnumVariantsWithContext(variants: []EnumVariant, context: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    for (variants) |*variant| {
        switch (variant.payload) {
            .none => {},
            .tuple_fields => |tuple_fields| {
                for (tuple_fields) |*field| {
                    field.ty = try resolveValueTypeWithContext(field.type_name, context, span, diagnostics);
                }
            },
            .named_fields => |named_fields| try resolveStructFieldsWithContext(named_fields, context, span, diagnostics),
        }
    }
}

pub fn validateTypeName(type_name: []const u8, type_scope: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    try validateTypeExpression(type_name, .{ .type_scope = type_scope }, span, diagnostics);
}

pub fn validateWherePredicates(
    module: anytype,
    predicates: []const WherePredicate,
    context: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| try validateTypeExpression(bound.contract_name, context, span, diagnostics),
            .projection_equality => |projection| {
                try validateTypeExpression(projection.value_type_name, context, span, diagnostics);
                if (!projectionSubjectHasAssociatedType(module, predicates, projection.subject_name, projection.associated_name)) {
                    try diagnostics.add(.@"error", "type.where.associated", span, "invalid associated-output reference '{s}.{s}'", .{
                        projection.subject_name,
                        projection.associated_name,
                    });
                }
            },
            .lifetime_outlives => |outlives| {
                try validateLifetimeReference(outlives.longer_name, contextGenericParams(context), span, diagnostics);
                try validateLifetimeReference(outlives.shorter_name, contextGenericParams(context), span, diagnostics);
            },
            .type_outlives => |outlives| {
                try validateSimpleTypeName(outlives.type_name, context, span, diagnostics);
                try validateLifetimeReference(outlives.lifetime_name, contextGenericParams(context), span, diagnostics);
            },
        }
    }
}

pub fn validateImplBlock(module: anytype, impl_block: *const ImplData, type_scope: anytype, span: source.Span, diagnostics: *diag.Bag) !void {
    const context = .{
        .type_scope = type_scope,
        .generic_params = impl_block.generic_params,
    };
    try validateTypeExpression(impl_block.target_type, context, span, diagnostics);
    if (impl_block.trait_name) |trait_name| {
        try validateTypeExpression(trait_name, context, span, diagnostics);
    } else if (impl_block.associated_types.len != 0) {
        try diagnostics.add(.@"error", "type.impl.associated_inherent", span, "inherent impls cannot bind associated types", .{});
    }
    for (impl_block.associated_types) |binding| {
        try validateTypeExpression(binding.value_type_name, context, span, diagnostics);
    }
    for (impl_block.associated_consts) |binding| {
        try validateTypeExpression(binding.const_data.type_name, context, span, diagnostics);
    }
    try validateWherePredicates(module, impl_block.where_predicates, context, span, diagnostics);
}

pub fn validateTraitMethodSignature(
    allocator: Allocator,
    module: anytype,
    method: *const TraitMethod,
    trait_generic_params: []const GenericParam,
    associated_types: []const TraitAssociatedType,
    type_scope: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    const generic_params = try mergeGenericParams(allocator, trait_generic_params, method.generic_params, span, diagnostics);
    defer if (generic_params.len != 0) allocator.free(generic_params);

    const context = .{
        .type_scope = type_scope,
        .generic_params = generic_params,
        .associated_types = associated_types,
        .allow_self = true,
        .self_type_name = "Self",
    };

    if (method.syntax) |method_syntax| {
        try validateTraitMethodSignatureFromSyntax(method_syntax.signature, context, span, diagnostics);
        try validateWherePredicates(module, method.where_predicates, context, span, diagnostics);
        return;
    }
    try diagnostics.add(.@"error", "type.method.syntax.missing", span, "trait method '{s}' is missing structured syntax after AST/HIR cutover", .{
        method.name,
    });
}

fn validateTraitMethodSignatureFromSyntax(
    signature: ast.FunctionSignatureSyntax,
    context: anytype,
    span: source.Span,
    diagnostics: *diag.Bag,
) !void {
    var param_index: usize = 0;
    if (signature.parameters.len != 0) {
        const first_parameter = signature.parameters[0];
        if (first_parameter.name) |name| {
            if (std.mem.eql(u8, std.mem.trim(u8, name.text, " \t"), "self")) {
                const receiver = try body_syntax_bridge.parseMethodReceiverFromSyntax("Self", first_parameter, span, diagnostics) orelse return;
                try validateTypeExpression(receiver.type_name, context, span, diagnostics);
                param_index = 1;
            }
        }
    }

    while (param_index < signature.parameters.len) : (param_index += 1) {
        const parameter = try body_syntax_bridge.parseOrdinaryParameterFromSyntax(signature.parameters[param_index], span, diagnostics) orelse continue;
        try validateTypeExpression(parameter.type_name, context, span, diagnostics);
    }

    if (signature.return_type) |return_type| {
        const return_raw = std.mem.trim(u8, return_type.text, " \t");
        if (return_raw.len != 0) try validateTypeExpression(return_raw, context, span, diagnostics);
    }
}

fn traitHasAssociatedType(module: anytype, trait_name: []const u8, associated_name: []const u8) bool {
    for (module.items.items) |*item| {
        if (!std.mem.eql(u8, item.name, trait_name)) continue;
        const trait_data = switch (item.payload) {
            .trait_type => |*trait_type| trait_type,
            else => continue,
        };
        for (trait_data.associated_types) |associated_type| {
            if (std.mem.eql(u8, associated_type.name, associated_name)) return true;
        }
    }
    return false;
}

fn projectionSubjectHasAssociatedType(
    module: anytype,
    predicates: []const WherePredicate,
    subject_name: []const u8,
    associated_name: []const u8,
) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .bound => |bound| {
                if (!std.mem.eql(u8, bound.subject_name, subject_name)) continue;
                if (traitHasAssociatedType(module, baseTypeName(bound.contract_name), associated_name)) return true;
            },
            else => {},
        }
    }
    return false;
}
