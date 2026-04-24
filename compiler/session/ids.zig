const std = @import("std");
const array_list = std.array_list;
const driver = @import("../driver/root.zig");

pub const ModuleId = struct { index: usize };
pub const PackageId = struct { index: usize };
pub const ItemId = struct { index: usize };
pub const BodyId = struct { index: usize };
pub const TraitId = struct { index: usize };
pub const ImplId = struct { index: usize };
pub const AssociatedTypeId = struct { index: usize };
pub const ConstId = struct { index: usize };
pub const ReflectionId = struct { index: usize };

pub const PackageEntry = struct {
    package_index: usize,
};

pub const ModuleEntry = struct {
    package_id: PackageId,
    pipeline_index: usize,
};

pub const ItemEntry = struct {
    module_id: ModuleId,
    pipeline_module_index: usize,
    item_index: usize,
    body_id: ?BodyId = null,
    trait_id: ?TraitId = null,
    impl_id: ?ImplId = null,
    const_id: ?ConstId = null,
    reflection_id: ?ReflectionId = null,
};

pub const BodyEntry = struct {
    module_id: ModuleId,
    item_id: ItemId,
};

pub const TraitEntry = struct {
    item_id: ItemId,
};

pub const ImplEntry = struct {
    item_id: ItemId,
};

pub const AssociatedTypeEntry = struct {
    item_id: ItemId,
    associated_index: usize,
};

pub const ConstEntry = struct {
    item_id: ItemId,
};

pub const ReflectionEntry = struct {
    item_id: ItemId,
};

pub const SemanticIndex = struct {
    packages: array_list.Managed(PackageEntry),
    modules: array_list.Managed(ModuleEntry),
    items: array_list.Managed(ItemEntry),
    bodies: array_list.Managed(BodyEntry),
    traits: array_list.Managed(TraitEntry),
    impls: array_list.Managed(ImplEntry),
    associated_types: array_list.Managed(AssociatedTypeEntry),
    consts: array_list.Managed(ConstEntry),
    reflections: array_list.Managed(ReflectionEntry),

    pub fn init(allocator: std.mem.Allocator) SemanticIndex {
        return .{
            .packages = array_list.Managed(PackageEntry).init(allocator),
            .modules = array_list.Managed(ModuleEntry).init(allocator),
            .items = array_list.Managed(ItemEntry).init(allocator),
            .bodies = array_list.Managed(BodyEntry).init(allocator),
            .traits = array_list.Managed(TraitEntry).init(allocator),
            .impls = array_list.Managed(ImplEntry).init(allocator),
            .associated_types = array_list.Managed(AssociatedTypeEntry).init(allocator),
            .consts = array_list.Managed(ConstEntry).init(allocator),
            .reflections = array_list.Managed(ReflectionEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SemanticIndex) void {
        self.packages.deinit();
        self.modules.deinit();
        self.items.deinit();
        self.bodies.deinit();
        self.traits.deinit();
        self.impls.deinit();
        self.associated_types.deinit();
        self.consts.deinit();
        self.reflections.deinit();
    }

    pub fn buildFromPipeline(allocator: std.mem.Allocator, pipeline: *const driver.Pipeline) !SemanticIndex {
        var index = SemanticIndex.init(allocator);
        errdefer index.deinit();

        for (pipeline.modules.items, 0..) |module_pipeline, module_index| {
            const module_id = ModuleId{ .index = index.modules.items.len };
            const package_id = try index.packageIdFor(module_pipeline.package_index);
            try index.modules.append(.{
                .package_id = package_id,
                .pipeline_index = module_index,
            });

            for (module_pipeline.typed.items.items, 0..) |item, item_index| {
                const item_id = ItemId{ .index = index.items.items.len };
                var entry = ItemEntry{
                    .module_id = module_id,
                    .pipeline_module_index = module_index,
                    .item_index = item_index,
                };

                switch (item.payload) {
                    .function => {
                        entry.body_id = BodyId{ .index = index.bodies.items.len };
                        try index.bodies.append(.{
                            .module_id = module_id,
                            .item_id = item_id,
                        });
                    },
                    .trait_type => |trait_type| {
                        entry.trait_id = TraitId{ .index = index.traits.items.len };
                        try index.traits.append(.{ .item_id = item_id });
                        for (trait_type.associated_types, 0..) |_, associated_index| {
                            try index.associated_types.append(.{
                                .item_id = item_id,
                                .associated_index = associated_index,
                            });
                        }
                    },
                    .impl_block => {
                        entry.impl_id = ImplId{ .index = index.impls.items.len };
                        try index.impls.append(.{ .item_id = item_id });
                    },
                    .const_item => {
                        entry.const_id = ConstId{ .index = index.consts.items.len };
                        try index.consts.append(.{ .item_id = item_id });
                    },
                    else => {},
                }

                if (item.is_reflectable) {
                    entry.reflection_id = ReflectionId{ .index = index.reflections.items.len };
                    try index.reflections.append(.{ .item_id = item_id });
                }

                try index.items.append(entry);
            }
        }

        return index;
    }

    fn packageIdFor(self: *SemanticIndex, package_index: usize) !PackageId {
        for (self.packages.items, 0..) |entry, index| {
            if (entry.package_index == package_index) return .{ .index = index };
        }
        const id = PackageId{ .index = self.packages.items.len };
        try self.packages.append(.{ .package_index = package_index });
        return id;
    }

    pub fn packageEntry(self: *const SemanticIndex, id: PackageId) PackageEntry {
        return self.packages.items[id.index];
    }

    pub fn moduleEntry(self: *const SemanticIndex, id: ModuleId) ModuleEntry {
        return self.modules.items[id.index];
    }

    pub fn itemEntry(self: *const SemanticIndex, id: ItemId) ItemEntry {
        return self.items.items[id.index];
    }

    pub fn bodyEntry(self: *const SemanticIndex, id: BodyId) BodyEntry {
        return self.bodies.items[id.index];
    }

    pub fn traitEntry(self: *const SemanticIndex, id: TraitId) TraitEntry {
        return self.traits.items[id.index];
    }

    pub fn implEntry(self: *const SemanticIndex, id: ImplId) ImplEntry {
        return self.impls.items[id.index];
    }

    pub fn associatedTypeEntry(self: *const SemanticIndex, id: AssociatedTypeId) AssociatedTypeEntry {
        return self.associated_types.items[id.index];
    }

    pub fn constEntry(self: *const SemanticIndex, id: ConstId) ConstEntry {
        return self.consts.items[id.index];
    }

    pub fn reflectionEntry(self: *const SemanticIndex, id: ReflectionId) ReflectionEntry {
        return self.reflections.items[id.index];
    }
};
