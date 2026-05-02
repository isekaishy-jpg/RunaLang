const std = @import("std");
const driver = @import("../driver/root.zig");
const intern = @import("../intern/root.zig");
const query = @import("../query/root.zig");
const query_types = @import("../query/types.zig");
const cache = @import("cache.zig");
const ids = @import("ids.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Global compile session state with semantic ids and query caches.";

pub const CacheStore = cache.CacheStore;
pub const QueryState = cache.QueryState;
pub const ActiveQuery = cache.ActiveQuery;
pub const SemanticIndex = ids.SemanticIndex;
pub const PackageId = ids.PackageId;
pub const ModuleId = ids.ModuleId;
pub const ItemId = ids.ItemId;
pub const BodyId = ids.BodyId;
pub const TraitId = ids.TraitId;
pub const ImplId = ids.ImplId;
pub const AssociatedTypeId = ids.AssociatedTypeId;
pub const AssociatedConstId = ids.AssociatedConstId;
pub const ConstId = ids.ConstId;
pub const ReflectionId = ids.ReflectionId;

pub const Session = struct {
    allocator: Allocator,
    interner: intern.Interner,
    pipeline: driver.Pipeline,
    semantic_index: SemanticIndex,
    caches: CacheStore,
    active_queries: std.array_list.Managed(ActiveQuery),

    pub fn deinit(self: *Session) void {
        self.active_queries.deinit();
        self.caches.deinit(self.allocator);
        self.semantic_index.deinit();
        self.interner.deinit();
        self.pipeline.deinit();
    }

    pub fn itemCount(self: *const Session) usize {
        return self.semantic_index.items.items.len;
    }

    pub fn packageCount(self: *const Session) usize {
        return self.semantic_index.packages.items.len;
    }

    pub fn sourceFileCount(self: *const Session) usize {
        return self.pipeline.sourceFileCount();
    }

    pub fn internedNameCount(self: *const Session) usize {
        return self.interner.count();
    }

    pub fn internName(self: *Session, name: []const u8) !intern.SymbolId {
        return self.interner.intern(name);
    }

    pub fn internedName(self: *const Session, id: intern.SymbolId) ?[]const u8 {
        return self.interner.lookup(id);
    }

    pub fn moduleCount(self: *const Session) usize {
        return self.semantic_index.modules.items.len;
    }

    pub fn bodyCount(self: *const Session) usize {
        return self.semantic_index.bodies.items.len;
    }

    pub fn associatedTypeCount(self: *const Session) usize {
        return self.semantic_index.associated_types.items.len;
    }

    pub fn associatedConstCount(self: *const Session) usize {
        return self.semantic_index.associated_consts.items.len;
    }

    pub fn item(self: *const Session, id: ItemId) *const @import("../typed/root.zig").Item {
        const entry = self.semantic_index.itemEntry(id);
        return &self.pipeline.modules.items[entry.pipeline_module_index].typed.items.items[entry.item_index];
    }

    pub fn module(self: *const Session, id: ModuleId) *const @import("../typed/root.zig").Module {
        const entry = self.semantic_index.moduleEntry(id);
        return &self.pipeline.modules.items[entry.pipeline_index].typed;
    }

    pub fn body(self: *const Session, id: BodyId) struct {
        module_id: ModuleId,
        item_id: ItemId,
        module: *const @import("../typed/root.zig").Module,
        item: *const @import("../typed/root.zig").Item,
    } {
        const entry = self.semantic_index.bodyEntry(id);
        const body_item = self.item(entry.item_id);
        return .{
            .module_id = entry.module_id,
            .item_id = entry.item_id,
            .module = self.module(entry.module_id),
            .item = body_item,
        };
    }

    pub fn pushActiveQuery(self: *Session, family: query_types.QueryFamily, key_index: usize) !bool {
        for (self.active_queries.items) |active| {
            if (active.family == family and active.key_index == key_index) return false;
        }
        try self.active_queries.append(.{
            .family = family,
            .key_index = key_index,
        });
        return true;
    }

    pub fn popActiveQuery(self: *Session) void {
        _ = self.active_queries.pop();
    }
};

pub fn fromPipeline(allocator: Allocator, pipeline: driver.Pipeline) !Session {
    var owned_pipeline = pipeline;
    const had_interner = owned_pipeline.interner != null;
    var active = Session{
        .allocator = allocator,
        .interner = if (owned_pipeline.interner) |existing| blk: {
            owned_pipeline.interner = null;
            break :blk existing;
        } else intern.Interner.init(allocator),
        .pipeline = owned_pipeline,
        .semantic_index = undefined,
        .caches = undefined,
        .active_queries = std.array_list.Managed(ActiveQuery).init(allocator),
    };
    errdefer active.active_queries.deinit();
    errdefer active.pipeline.deinit();
    errdefer active.interner.deinit();

    if (!had_interner) {
        for (active.pipeline.modules.items) |module| {
            for (module.resolved.symbols.items) |symbol| {
                if (symbol.name.len == 0) continue;
                _ = try active.interner.intern(symbol.name);
            }
        }
    }

    active.semantic_index = try SemanticIndex.buildFromPipeline(allocator, &active.pipeline);
    errdefer active.semantic_index.deinit();

    active.caches = try CacheStore.init(allocator, &active.semantic_index);
    errdefer active.caches.deinit(allocator);

    return active;
}

pub fn intoPipeline(self: *Session) driver.Pipeline {
    var pipeline = self.pipeline;
    pipeline.interner = self.interner;
    self.active_queries.deinit();
    self.caches.deinit(self.allocator);
    self.semantic_index.deinit();
    self.* = undefined;
    return pipeline;
}

pub fn prepareFiles(allocator: Allocator, io: std.Io, file_paths: []const []const u8) !Session {
    return fromPipeline(allocator, try driver.prepareFiles(allocator, io, file_paths));
}

pub fn prepareGraph(allocator: Allocator, io: std.Io, graph: driver.GraphInput) !Session {
    return fromPipeline(allocator, try driver.prepareGraph(allocator, io, graph));
}

pub fn openFiles(allocator: Allocator, io: std.Io, file_paths: []const []const u8) !Session {
    var active = try prepareFiles(allocator, io, file_paths);
    errdefer active.deinit();
    try query.finalizeSemanticChecks(&active);
    return active;
}

pub fn openGraph(allocator: Allocator, io: std.Io, graph: driver.GraphInput) !Session {
    var active = try prepareGraph(allocator, io, graph);
    errdefer active.deinit();
    try query.finalizeSemanticChecks(&active);
    return active;
}
