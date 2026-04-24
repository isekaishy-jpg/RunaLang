const std = @import("std");
const diag = @import("../diag/root.zig");
const session = @import("../session/root.zig");
const typed_text = @import("../typed/text.zig");

const baseTypeName = typed_text.baseTypeName;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub fn validate(active: *const session.Session, diagnostics: *diag.Bag) !void {
    for (active.semantic_index.impls.items, 0..) |impl_entry, impl_index| {
        const checked = active.caches.signatures[impl_entry.item_id.index].value orelse continue;
        const impl_signature = switch (checked.facts) {
            .impl_block => |impl_signature| impl_signature,
            else => continue,
        };

        const trait_name = impl_signature.trait_name orelse continue;
        if (std.mem.eql(u8, baseTypeName(trait_name), "Send")) {
            try diagnostics.add(
                .@"error",
                "type.impl.send_builtin",
                checked.item.span,
                "user-written impls of built-in marker trait 'Send' are not part of v1",
                .{},
            );
        }

        const impl_package_index = packageIndexForModule(active, checked.module_id);
        const trait_owner_package = resolveOwnerPackageIndex(active, checked.module_id, trait_name);
        const type_owner_package = resolveOwnerPackageIndex(active, checked.module_id, impl_signature.target_type);
        if (trait_owner_package) |trait_owner| {
            if (type_owner_package) |type_owner| {
                if (impl_package_index != trait_owner and impl_package_index != type_owner) {
                    try diagnostics.add(
                        .@"error",
                        "type.impl.orphan",
                        checked.item.span,
                        "impl '{s} for {s}' violates the orphan-style coherence rule",
                        .{
                            baseTypeName(trait_name),
                            baseTypeName(impl_signature.target_type),
                        },
                    );
                }
            }
        }

        var other_index = impl_index + 1;
        while (other_index < active.semantic_index.impls.items.len) : (other_index += 1) {
            const other_entry = active.semantic_index.impls.items[other_index];
            const other_checked = active.caches.signatures[other_entry.item_id.index].value orelse continue;
            const other_signature = switch (other_checked.facts) {
                .impl_block => |other_signature| other_signature,
                else => continue,
            };
            const other_trait_name = other_signature.trait_name orelse continue;

            if (!std.mem.eql(u8, baseTypeName(trait_name), baseTypeName(other_trait_name))) continue;
            if (!implTargetsOverlap(active.allocator, impl_signature, other_signature)) continue;

            try diagnostics.add(
                .@"error",
                "type.impl.overlap",
                other_checked.item.span,
                "overlapping impls are not allowed for trait '{s}' and type '{s}'",
                .{
                    baseTypeName(trait_name),
                    baseTypeName(impl_signature.target_type),
                },
            );
        }
    }
}

fn implTargetsOverlap(allocator: std.mem.Allocator, lhs: anytype, rhs: anytype) bool {
    return typePatternsOverlap(
        allocator,
        lhs.target_type,
        lhs.generic_params,
        rhs.target_type,
        rhs.generic_params,
    );
}

fn implTargetIsGeneric(signature: anytype) bool {
    const target = baseTypeName(signature.target_type);
    for (signature.generic_params) |param| {
        if (param.kind != .type_param) continue;
        if (std.mem.eql(u8, param.name, target)) return true;
    }
    return false;
}

fn typePatternsOverlap(
    allocator: std.mem.Allocator,
    lhs_raw: []const u8,
    lhs_generics: anytype,
    rhs_raw: []const u8,
    rhs_generics: anytype,
) bool {
    const lhs = std.mem.trim(u8, lhs_raw, " \t");
    const rhs = std.mem.trim(u8, rhs_raw, " \t");
    if (genericParamOwnsName(lhs_generics, lhs) or genericParamOwnsName(rhs_generics, rhs)) return true;
    if (!std.mem.eql(u8, baseTypeName(lhs), baseTypeName(rhs))) return false;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const lhs_args = typeApplicationArgs(arena.allocator(), lhs) catch return true;
    const rhs_args = typeApplicationArgs(arena.allocator(), rhs) catch return true;
    if (lhs_args == null and rhs_args == null) return typeNamesEqual(lhs, rhs);
    if (lhs_args == null or rhs_args == null) return true;
    if (lhs_args.?.len != rhs_args.?.len) return false;

    for (lhs_args.?, rhs_args.?) |lhs_arg, rhs_arg| {
        if (!typePatternsOverlap(allocator, lhs_arg, lhs_generics, rhs_arg, rhs_generics)) return false;
    }
    return true;
}

fn typeApplicationArgs(allocator: std.mem.Allocator, raw_name: []const u8) !?[][]const u8 {
    const open_index = std.mem.indexOfScalar(u8, raw_name, '[') orelse return null;
    const close_index = findMatchingDelimiter(raw_name, open_index, '[', ']') orelse return null;
    if (std.mem.trim(u8, raw_name[close_index + 1 ..], " \t").len != 0) return null;
    return try splitTopLevelCommaParts(allocator, raw_name[open_index + 1 .. close_index]);
}

fn genericParamOwnsName(generic_params: anytype, name: []const u8) bool {
    for (generic_params) |param| {
        if (param.kind == .type_param and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn typeNamesEqual(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, lhs, " \t"), std.mem.trim(u8, rhs, " \t"));
}

fn packageIndexForModule(active: *const session.Session, module_id: session.ModuleId) usize {
    const module_entry = active.semantic_index.moduleEntry(module_id);
    return active.semantic_index.packageEntry(module_entry.package_id).package_index;
}

fn resolveOwnerPackageIndex(
    active: *const session.Session,
    module_id: session.ModuleId,
    raw_type_name: []const u8,
) ?usize {
    const target_name = baseTypeName(raw_type_name);
    if (target_name.len == 0) return null;

    for (active.semantic_index.items.items, 0..) |item_entry, index| {
        if (item_entry.module_id.index != module_id.index) continue;
        const item = active.item(.{ .index = index });
        if (item.kind == .use_decl or item.kind == .module_decl) continue;
        if (!std.mem.eql(u8, item.name, target_name)) continue;
        return packageIndexForModule(active, item_entry.module_id);
    }

    const module = active.module(module_id);
    for (module.imports.items) |binding| {
        if (!std.mem.eql(u8, binding.local_name, target_name)) continue;
        for (active.semantic_index.items.items, 0..) |item_entry, index| {
            const item = active.item(.{ .index = index });
            if (!std.mem.eql(u8, item.symbol_name, binding.target_symbol)) continue;
            return packageIndexForModule(active, item_entry.module_id);
        }
    }

    return null;
}
