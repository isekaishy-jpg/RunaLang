const std = @import("std");
const ast = @import("../ast/root.zig");
const body_syntax_bridge = @import("body_syntax_bridge.zig");
const diag = @import("../diag/root.zig");
const hir = @import("../hir/root.zig");
const item_syntax_bridge = @import("item_syntax_bridge.zig");
const query_text = @import("text.zig");
const source = @import("../source/root.zig");
const typed = @import("../typed/root.zig");
const typed_attributes = @import("attributes.zig");
const typed_decls = @import("../typed/declarations.zig");
const types = @import("../types/root.zig");
const Allocator = std.mem.Allocator;
const ConstData = typed_decls.ConstData;
const FunctionData = typed_decls.FunctionData;
const TraitAssociatedConstBinding = typed_decls.TraitAssociatedConstBinding;
const TraitAssociatedTypeBinding = typed_decls.TraitAssociatedTypeBinding;
const isPlainIdentifier = query_text.isPlainIdentifier;

pub fn validateItemSyntax(
    allocator: Allocator,
    item: hir.Item,
    typed_item: *const typed.Item,
    diagnostics: *diag.Bag,
) !void {
    switch (item.kind) {
        .function, .suspend_function, .foreign_function => try validateFunctionSyntax(allocator, item, typed_item, diagnostics),
        .const_item => try validateConstSyntax(allocator, item, diagnostics),
        .struct_type => try validateStructSyntax(allocator, item, diagnostics),
        .union_type => try validateUnionSyntax(allocator, item, diagnostics),
        .enum_type => try validateEnumSyntax(allocator, item, diagnostics),
        .opaque_type => try validateOpaqueTypeSyntax(allocator, item, diagnostics),
        .trait_type => try validateTraitSyntax(allocator, item, diagnostics),
        .impl_block => try validateImplSyntax(allocator, item, diagnostics),
        else => {},
    }
}

fn validateFunctionSyntax(
    allocator: Allocator,
    item: hir.Item,
    typed_item: *const typed.Item,
    diagnostics: *diag.Bag,
) !void {
    _ = typed_item;
    var function = FunctionData.init(allocator, item.kind == .suspend_function, item.kind == .foreign_function);
    defer function.deinit(allocator);

    switch (item.syntax) {
        .function => |signature| try item_syntax_bridge.fillFunctionDataFromSyntax(allocator, &function, signature, item.span, diagnostics),
        else => return error.InvalidParse,
    }

    if (item.kind != .foreign_function) return;
    if (typed_attributes.parseExportName(item.attributes) != null) {
        try diagnostics.add(.@"error", "type.foreign.export", item.span, "foreign declarations do not combine with #export in stage0", .{});
    }
}

fn validateConstSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var const_data = switch (item.syntax) {
        .const_item => |signature| try item_syntax_bridge.parseConstDataFromSyntax(allocator, signature, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer const_data.deinit(allocator);
}

fn validateStructSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var named = switch (item.syntax) {
        .named_decl => |signature| try item_syntax_bridge.parseNamedDeclData(allocator, signature, false, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer named.deinit(allocator);

    switch (item.body_syntax) {
        .struct_fields => |fields| {
            const lowered = try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, item.name, item.span, diagnostics);
            defer allocator.free(lowered);
        },
        .none => {},
        else => return error.InvalidParse,
    }
}

fn validateUnionSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    if (!hasReprC(item.attributes)) {
        try diagnostics.add(.@"error", "type.union.repr_c", item.span, "union declarations require #repr[c] in stage0", .{});
    }

    switch (item.body_syntax) {
        .union_fields => |fields| {
            const lowered = try body_syntax_bridge.parseFieldsFromSyntax(allocator, fields, item.name, item.span, diagnostics);
            defer allocator.free(lowered);
            for (lowered) |field| {
                if (!fieldTypeLooksCAbiSafe(field.type_name)) {
                    try diagnostics.add(.@"error", "type.union.field_c_abi", item.span, "stage0 union fields must use C ABI-safe types", .{});
                }
            }
        },
        .none => {},
        else => return error.InvalidParse,
    }
}

fn validateEnumSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var named = switch (item.syntax) {
        .named_decl => |signature| try item_syntax_bridge.parseNamedDeclData(allocator, signature, false, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer named.deinit(allocator);

    switch (item.body_syntax) {
        .enum_variants => |variants| {
            const lowered = try body_syntax_bridge.parseEnumVariantsFromSyntax(allocator, variants, item.name, item.span, diagnostics);
            defer {
                for (lowered) |*variant| variant.deinit(allocator);
                allocator.free(lowered);
            }
        },
        .none => {},
        else => return error.InvalidParse,
    }
}

fn validateOpaqueTypeSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var named = switch (item.syntax) {
        .named_decl => |signature| try item_syntax_bridge.parseNamedDeclData(allocator, signature, false, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer named.deinit(allocator);
}

fn validateTraitSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var named = switch (item.syntax) {
        .named_decl => |signature| try item_syntax_bridge.parseNamedDeclData(allocator, signature, true, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer named.deinit(allocator);

    switch (item.body_syntax) {
        .trait_body => |body| {
            var parsed = try body_syntax_bridge.parseTraitBodyFromSyntax(allocator, named.generic_params, body, item.name, item.span, diagnostics);
            defer parsed.deinit(allocator);
        },
        .none => {},
        else => return error.InvalidParse,
    }
}

fn validateImplSyntax(allocator: Allocator, item: hir.Item, diagnostics: *diag.Bag) !void {
    var header = switch (item.syntax) {
        .impl_block => |signature| try item_syntax_bridge.parseImplHeaderData(allocator, signature, item.span, diagnostics),
        else => return error.InvalidParse,
    };
    defer header.deinit(allocator);

    switch (item.body_syntax) {
        .impl_body => |body| {
            const associated_types = try parseImplAssociatedTypes(allocator, body.associated_types, item.span, diagnostics);
            defer allocator.free(associated_types);

            const associated_consts = try parseImplAssociatedConsts(allocator, body.associated_consts, item.span, diagnostics);
            defer {
                for (associated_consts) |*binding| binding.deinit(allocator);
                allocator.free(associated_consts);
            }

            const methods = try body_syntax_bridge.parseImplMethodsFromSyntax(allocator, header.generic_params, body, item.span, diagnostics);
            defer {
                for (methods) |*method| method.deinit(allocator);
                allocator.free(methods);
            }

            for (body.methods) |method| {
                const parsed = try body_syntax_bridge.parseExecutableMethodFromSyntax(
                    allocator,
                    header.target_type,
                    header.generic_params,
                    method,
                    diagnostics,
                );
                if (parsed) |owned| {
                    var executable = owned;
                    executable.function.deinit(allocator);
                }
            }
        },
        .none => {},
        else => return error.InvalidParse,
    }
}

fn parseImplAssociatedTypes(
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

        var const_data: ConstData = try item_syntax_bridge.parseConstDataFromSyntax(allocator, associated_const, span, diagnostics);
        errdefer const_data.deinit(allocator);
        try lowered.append(.{
            .name = name_text,
            .const_data = const_data,
        });
    }

    return lowered.toOwnedSlice();
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
