const ast = @import("../ast/root.zig");
const hir = @import("../hir/root.zig");
const Allocator = @import("std").mem.Allocator;

pub const summary = "AST-to-HIR lowering with explicit ownership and lifetime syntax preserved.";
pub const preserves_ownership_data = true;
pub const preserves_lifetime_data = true;

pub const Report = struct {
    items_lowered: usize = 0,
    attributes_preserved: usize = 0,
};

pub fn lowerParsedModule(allocator: Allocator, parsed: ast.Module) !hir.Module {
    return hir.lowerModule(allocator, parsed);
}

pub fn report(module: *const hir.Module) Report {
    var data = Report{};
    data.items_lowered = module.items.items.len;
    for (module.items.items) |item| data.attributes_preserved += item.attributes.len;
    return data;
}
