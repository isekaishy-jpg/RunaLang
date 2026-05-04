const std = @import("std");
const diag = @import("../diag/root.zig");
const query_types = @import("types.zig");
const session = @import("../session/root.zig");
const trait_solver = @import("trait_solver.zig");
const type_forms = @import("type_forms.zig");
const type_lowering = @import("type_lowering.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const type_support = @import("type_support.zig");
const typed = @import("../typed/root.zig");

pub fn validate(active: *session.Session, diagnostics: *diag.Bag) !void {
    for (active.semantic_index.impls.items, 0..) |impl_entry, impl_index| {
        const checked = active.caches.signatures[impl_entry.item_id.index].value orelse continue;
        const impl_signature = switch (checked.facts) {
            .impl_block => |impl_signature| impl_signature,
            else => continue,
        };

        const trait_syntax = impl_signature.trait_syntax orelse continue;
        const trait_head = try trait_solver.canonicalTraitHeadFromSyntax(active, checked.module_id, trait_syntax);
        const type_head = try canonicalImplTypeHead(
            active,
            checked.module_id,
            impl_signature.target_type_syntax,
            impl_signature.generic_params,
            impl_signature.where_predicates,
        );

        switch (trait_head) {
            .builtin_send => try diagnostics.add(
                .@"error",
                "type.impl.send_builtin",
                checked.item.span,
                "user-written impls of built-in marker trait 'Send' are not part of v1",
                .{},
            ),
            else => {},
        }

        const impl_package_index = packageIndexForModule(active, checked.module_id);
        const trait_owner_package = ownerPackageIndexForTraitHead(active, trait_head);
        const type_owner_package = ownerPackageIndexForTypeHead(active, type_head);
        if (!implOwnsCoherenceSide(impl_package_index, trait_owner_package, type_owner_package)) {
            try diagnostics.add(
                .@"error",
                "type.impl.orphan",
                checked.item.span,
                "impl '{s} for {s}' violates the orphan-style coherence rule",
                .{
                    baseNameFromSyntaxOrRef(trait_syntax, impl_signature.trait_type orelse .unsupported),
                    baseNameFromSyntaxOrRef(impl_signature.target_type_syntax, impl_signature.target_type),
                },
            );
        }

        var other_index = impl_index + 1;
        while (other_index < active.semantic_index.impls.items.len) : (other_index += 1) {
            const other_entry = active.semantic_index.impls.items[other_index];
            const other_checked = active.caches.signatures[other_entry.item_id.index].value orelse continue;
            const other_signature = switch (other_checked.facts) {
                .impl_block => |other_signature| other_signature,
                else => continue,
            };
            const other_trait_syntax = other_signature.trait_syntax orelse continue;
            const other_trait_head = try trait_solver.canonicalTraitHeadFromSyntax(active, other_checked.module_id, other_trait_syntax);

            if (!trait_solver.traitHeadsEqual(trait_head, other_trait_head)) continue;
            if (!try implTargetsOverlap(active, checked.module_id, impl_signature, other_checked.module_id, other_signature)) continue;

            try diagnostics.add(
                .@"error",
                "type.impl.overlap",
                other_checked.item.span,
                "overlapping impls are not allowed for trait '{s}' and type '{s}'",
                .{
                    baseNameFromSyntaxOrRef(trait_syntax, impl_signature.trait_type orelse .unsupported),
                    baseNameFromSyntaxOrRef(impl_signature.target_type_syntax, impl_signature.target_type),
                },
            );
        }
    }
}

fn implTargetsOverlap(
    active: *session.Session,
    lhs_module_id: session.ModuleId,
    lhs: query_types.ImplSignature,
    rhs_module_id: session.ModuleId,
    rhs: query_types.ImplSignature,
) !bool {
    return typePatternsOverlap(
        active,
        lhs_module_id,
        lhs.target_type,
        lhs.generic_params,
        lhs.where_predicates,
        rhs_module_id,
        rhs.target_type,
        rhs.generic_params,
        rhs.where_predicates,
    );
}

fn typePatternsOverlap(
    active: *session.Session,
    lhs_module_id: session.ModuleId,
    lhs: @import("../types/root.zig").TypeRef,
    lhs_generics: []const typed.GenericParam,
    lhs_where_predicates: []const typed.WherePredicate,
    rhs_module_id: session.ModuleId,
    rhs: @import("../types/root.zig").TypeRef,
    rhs_generics: []const typed.GenericParam,
    rhs_where_predicates: []const typed.WherePredicate,
) !bool {
    const lhs_head = try canonicalImplTypeHeadFromTypeRef(active, lhs_module_id, lhs, lhs_generics, lhs_where_predicates);
    const rhs_head = try canonicalImplTypeHeadFromTypeRef(active, rhs_module_id, rhs, rhs_generics, rhs_where_predicates);
    if (!typeHeadsCouldOverlap(lhs_head, rhs_head)) return false;

    var arena = std.heap.ArenaAllocator.init(active.allocator);
    defer arena.deinit();

    const lhs_args = try typeApplicationArgs(arena.allocator(), lhs);
    const rhs_args = try typeApplicationArgs(arena.allocator(), rhs);
    if (lhs_args == null and rhs_args == null) return true;
    if (lhs_args == null or rhs_args == null) return true;
    if (lhs_args.?.len != rhs_args.?.len) return false;

    for (lhs_args.?, rhs_args.?) |lhs_arg, rhs_arg| {
        if (!try typePatternsOverlap(
            active,
            lhs_module_id,
            lhs_arg,
            lhs_generics,
            lhs_where_predicates,
            rhs_module_id,
            rhs_arg,
            rhs_generics,
            rhs_where_predicates,
        )) return false;
    }
    return true;
}

fn canonicalImplTypeHead(
    active: *session.Session,
    module_id: session.ModuleId,
    syntax_value: @import("../ast/root.zig").TypeSyntax,
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
) !query_types.CanonicalTypeHead {
    const name = baseNameFromSyntax(syntax_value) orelse return trait_solver.canonicalTypeHeadFromSyntax(active, module_id, syntax_value, where_predicates);
    if (genericParamOwnsName(generic_params, name)) {
        return .{ .generic_param = try active.internName(name) };
    }
    return trait_solver.canonicalTypeHeadFromSyntax(active, module_id, syntax_value, where_predicates);
}

fn canonicalImplTypeHeadFromTypeRef(
    active: *session.Session,
    module_id: session.ModuleId,
    ty: @import("../types/root.zig").TypeRef,
    generic_params: []const typed.GenericParam,
    where_predicates: []const typed.WherePredicate,
) !query_types.CanonicalTypeHead {
    if (try type_lowering.clonedSyntaxForTypeRef(active.allocator, ty)) |syntax_value| {
        var owned = syntax_value;
        defer owned.deinit(active.allocator);
        return canonicalImplTypeHead(active, module_id, owned, generic_params, where_predicates);
    }
    const name = type_support.typeRefRawName(ty);
    if (genericParamOwnsName(generic_params, name)) {
        return .{ .generic_param = try active.internName(name) };
    }
    return trait_solver.canonicalTypeHeadFromTypeRef(active, module_id, ty, where_predicates);
}

fn typeHeadsCouldOverlap(lhs: query_types.CanonicalTypeHead, rhs: query_types.CanonicalTypeHead) bool {
    if (trait_solver.typeHeadsEqual(lhs, rhs)) return true;
    return switch (lhs) {
        .generic_param, .opaque_name => true,
        .builtin, .item => switch (rhs) {
            .generic_param, .opaque_name => true,
            .builtin, .item => false,
        },
    };
}

fn typeApplicationArgs(allocator: std.mem.Allocator, ty: @import("../types/root.zig").TypeRef) !?[]@import("../types/root.zig").TypeRef {
    const base_name = try type_support.baseTypeNameFromTypeRef(allocator, ty) orelse return null;
    return try type_support.applicationArgsFromTypeRef(allocator, ty, base_name);
}

fn baseNameFromSyntax(syntax_value: @import("../ast/root.zig").TypeSyntax) ?[]const u8 {
    var view = type_forms.View.fromSyntax(std.heap.page_allocator, syntax_value) catch return null;
    defer view.deinit();
    return type_forms.baseName(view);
}

fn baseNameFromSyntaxOrRef(
    syntax_value: @import("../ast/root.zig").TypeSyntax,
    fallback: @import("../types/root.zig").TypeRef,
) []const u8 {
    return baseNameFromSyntax(syntax_value) orelse
        ((type_support.baseTypeNameFromTypeRef(std.heap.page_allocator, fallback) catch null) orelse type_support.typeRefRawName(fallback));
}

fn genericParamOwnsName(generic_params: []const typed.GenericParam, name: []const u8) bool {
    for (generic_params) |param| {
        if (param.kind == .type_param and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn packageIndexForModule(active: *const session.Session, module_id: session.ModuleId) usize {
    const module_entry = active.semantic_index.moduleEntry(module_id);
    return active.semantic_index.packageEntry(module_entry.package_id).package_index;
}

fn packageIndexForItem(active: *const session.Session, item_id: session.ItemId) usize {
    return packageIndexForModule(active, active.semantic_index.itemEntry(item_id).module_id);
}

fn ownerPackageIndexForTraitHead(
    active: *const session.Session,
    trait_head: query_types.CanonicalTraitHead,
) ?usize {
    return switch (trait_head) {
        .trait_item => |trait_id| packageIndexForItem(active, active.semantic_index.traitEntry(trait_id).item_id),
        .builtin_send, .builtin_eq, .builtin_hash, .opaque_name => null,
    };
}

fn ownerPackageIndexForTypeHead(
    active: *const session.Session,
    type_head: query_types.CanonicalTypeHead,
) ?usize {
    return switch (type_head) {
        .item => |item_id| packageIndexForItem(active, item_id),
        .builtin, .generic_param, .opaque_name => null,
    };
}

fn implOwnsCoherenceSide(
    impl_package_index: usize,
    trait_owner_package: ?usize,
    type_owner_package: ?usize,
) bool {
    if (trait_owner_package) |trait_owner| {
        if (impl_package_index == trait_owner) return true;
    }
    if (type_owner_package) |type_owner| {
        if (impl_package_index == type_owner) return true;
    }
    return false;
}
