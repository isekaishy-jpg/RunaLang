const std = @import("std");
const array_list = std.array_list;
const ast = @import("../ast/root.zig");
const diag = @import("../diag/root.zig");
const hir = @import("../hir/root.zig");
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Top-level name, path, and symbol resolution.";
pub const owns_top_level_symbols = true;

pub const SymbolCategory = enum {
    value,
    type_decl,
    trait_decl,
    impl_block,
    foreign_decl,
    module_decl,
    import_binding,
};

pub const Symbol = struct {
    name: []const u8,
    category: SymbolCategory,
    visibility: ast.Visibility,
    span: source.Span,
    target_path: ?[]const u8 = null,
};

pub const Module = struct {
    file_id: source.FileId,
    symbols: array_list.Managed(Symbol),

    pub fn init(allocator: Allocator, file_id: source.FileId) Module {
        return .{
            .file_id = file_id,
            .symbols = array_list.Managed(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Module) void {
        self.symbols.deinit();
    }

    pub fn find(self: *const Module, name: []const u8) ?Symbol {
        for (self.symbols.items) |symbol| {
            if (std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }
};

pub fn resolveModule(allocator: Allocator, module: hir.Module, diagnostics: *diag.Bag) !Module {
    var resolved = Module.init(allocator, module.file_id);
    errdefer resolved.deinit();

    for (module.items.items) |item| {
        const symbol = Symbol{
            .name = item.name,
            .category = categoryFor(item.kind),
            .visibility = item.visibility,
            .span = item.span,
            .target_path = item.target_path,
        };

        if (symbol.name.len != 0 and symbol.category != .impl_block) {
            if (resolved.find(symbol.name) != null) {
                try diagnostics.add(.@"error", "resolve.duplicate", symbol.span, "duplicate top-level item '{s}'", .{symbol.name});
                continue;
            }
        }

        try resolved.symbols.append(symbol);
    }

    return resolved;
}

fn categoryFor(kind: ast.ItemKind) SymbolCategory {
    return switch (kind) {
        .function, .suspend_function, .const_item => .value,
        .struct_type, .enum_type, .union_type, .opaque_type => .type_decl,
        .trait_type => .trait_decl,
        .impl_block => .impl_block,
        .foreign_function => .foreign_decl,
        .module_decl => .module_decl,
        .use_decl => .import_binding,
    };
}
