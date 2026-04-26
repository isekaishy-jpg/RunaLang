const std = @import("std");
const query_types = @import("../query/types.zig");
const session_ids = @import("ids.zig");
const typed = @import("../typed/root.zig");
const array_list = std.array_list;

pub const QueryState = enum {
    not_started,
    in_progress,
    complete,
};

pub const ActiveQuery = struct {
    family: query_types.QueryFamily,
    key_index: usize,
};

pub const TraitGoalEntry = struct {
    key: query_types.TraitGoalKey,
    where_predicates: []const typed.WherePredicate = &.{},
    state: QueryState = .not_started,
    failed: bool = false,
    value: ?query_types.TraitGoalResult = null,
};

pub const ImplLookupEntry = struct {
    key: query_types.ImplLookupKey,
    state: QueryState = .not_started,
    failed: bool = false,
    value: ?query_types.ImplLookupResult = null,
};

pub fn Entry(comptime T: type) type {
    return struct {
        state: QueryState = .not_started,
        failed: bool = false,
        value: ?T = null,
    };
}

pub const CacheStore = struct {
    signatures: []Entry(query_types.CheckedSignature),
    bodies: []Entry(query_types.CheckedBody),
    statements: []Entry(query_types.StatementResult),
    expressions: []Entry(query_types.ExpressionResult),
    module_signatures: []Entry(query_types.ModuleSignatureResult),
    consts: []Entry(query_types.ConstResult),
    associated_consts: []Entry(query_types.AssociatedConstResult),
    reflections: []Entry(query_types.ReflectionMetadata),
    runtime_reflections: Entry(query_types.RuntimeReflectionResult),
    module_reflections: []Entry(query_types.ModuleReflectionResult),
    package_reflections: []Entry(query_types.PackageReflectionResult),
    module_boundary_apis: []Entry(query_types.ModuleBoundaryApiResult),
    trait_goals: array_list.Managed(TraitGoalEntry),
    impl_index: Entry(query_types.ImplIndexResult),
    impl_lookups: array_list.Managed(ImplLookupEntry),
    local_consts: []Entry(query_types.LocalConstResult),
    callables: []Entry(query_types.CallableResult),
    patterns: []Entry(query_types.PatternResult),
    send: []Entry(query_types.SendResult),
    ownership: []Entry(query_types.OwnershipResult),
    borrow: []Entry(query_types.BorrowResult),
    lifetimes: []Entry(query_types.LifetimeResult),
    regions: []Entry(query_types.RegionResult),
    domain_state_items: []Entry(query_types.DomainStateItemResult),
    domain_state_bodies: []Entry(query_types.DomainStateBodyResult),

    pub fn init(allocator: std.mem.Allocator, index: *const session_ids.SemanticIndex) !CacheStore {
        return .{
            .signatures = try allocateEntries(query_types.CheckedSignature, allocator, index.items.items.len),
            .bodies = try allocateEntries(query_types.CheckedBody, allocator, index.bodies.items.len),
            .statements = try allocateEntries(query_types.StatementResult, allocator, index.bodies.items.len),
            .expressions = try allocateEntries(query_types.ExpressionResult, allocator, index.bodies.items.len),
            .module_signatures = try allocateEntries(query_types.ModuleSignatureResult, allocator, index.modules.items.len),
            .consts = try allocateEntries(query_types.ConstResult, allocator, index.consts.items.len),
            .associated_consts = try allocateEntries(query_types.AssociatedConstResult, allocator, index.associated_consts.items.len),
            .reflections = try allocateEntries(query_types.ReflectionMetadata, allocator, index.reflections.items.len),
            .runtime_reflections = .{},
            .module_reflections = try allocateEntries(query_types.ModuleReflectionResult, allocator, index.modules.items.len),
            .package_reflections = try allocateEntries(query_types.PackageReflectionResult, allocator, index.packages.items.len),
            .module_boundary_apis = try allocateEntries(query_types.ModuleBoundaryApiResult, allocator, index.modules.items.len),
            .trait_goals = array_list.Managed(TraitGoalEntry).init(allocator),
            .impl_index = .{},
            .impl_lookups = array_list.Managed(ImplLookupEntry).init(allocator),
            .local_consts = try allocateEntries(query_types.LocalConstResult, allocator, index.bodies.items.len),
            .callables = try allocateEntries(query_types.CallableResult, allocator, index.bodies.items.len),
            .patterns = try allocateEntries(query_types.PatternResult, allocator, index.bodies.items.len),
            .send = try allocateEntries(query_types.SendResult, allocator, index.bodies.items.len),
            .ownership = try allocateEntries(query_types.OwnershipResult, allocator, index.bodies.items.len),
            .borrow = try allocateEntries(query_types.BorrowResult, allocator, index.bodies.items.len),
            .lifetimes = try allocateEntries(query_types.LifetimeResult, allocator, index.bodies.items.len),
            .regions = try allocateEntries(query_types.RegionResult, allocator, index.bodies.items.len),
            .domain_state_items = try allocateEntries(query_types.DomainStateItemResult, allocator, index.items.items.len),
            .domain_state_bodies = try allocateEntries(query_types.DomainStateBodyResult, allocator, index.bodies.items.len),
        };
    }

    pub fn deinit(self: *CacheStore, allocator: std.mem.Allocator) void {
        for (self.signatures) |entry| {
            if (entry.value) |value| value.deinit(allocator);
        }
        allocator.free(self.signatures);
        for (self.bodies) |entry| {
            if (entry.value) |value| value.deinit(allocator);
        }
        allocator.free(self.bodies);
        allocator.free(self.statements);
        for (self.expressions) |entry| {
            if (entry.value) |value| value.deinit(allocator);
        }
        allocator.free(self.expressions);
        allocator.free(self.module_signatures);
        for (self.consts) |entry| {
            if (entry.value) |value| {
                var owned = value.value;
                @import("../query/const_ir.zig").deinitValue(allocator, &owned);
            }
        }
        allocator.free(self.consts);
        for (self.associated_consts) |entry| {
            if (entry.value) |value| {
                var owned = value.value;
                @import("../query/const_ir.zig").deinitValue(allocator, &owned);
            }
        }
        allocator.free(self.associated_consts);
        for (self.reflections) |entry| {
            if (entry.value) |value| value.metadata.deinit(allocator);
        }
        allocator.free(self.reflections);
        if (self.runtime_reflections.value) |value| allocator.free(value.metadata);
        for (self.module_reflections) |entry| {
            if (entry.value) |value| allocator.free(value.metadata);
        }
        allocator.free(self.module_reflections);
        for (self.package_reflections) |entry| {
            if (entry.value) |value| allocator.free(value.metadata);
        }
        allocator.free(self.package_reflections);
        for (self.module_boundary_apis) |entry| {
            if (entry.value) |value| allocator.free(value.apis);
        }
        allocator.free(self.module_boundary_apis);
        self.trait_goals.deinit();
        if (self.impl_index.value) |value| allocator.free(value.entries);
        for (self.impl_lookups.items) |entry| {
            if (entry.value) |value| allocator.free(value.impl_ids);
        }
        self.impl_lookups.deinit();
        allocator.free(self.local_consts);
        allocator.free(self.callables);
        allocator.free(self.patterns);
        allocator.free(self.send);
        allocator.free(self.ownership);
        allocator.free(self.borrow);
        allocator.free(self.lifetimes);
        allocator.free(self.regions);
        allocator.free(self.domain_state_items);
        allocator.free(self.domain_state_bodies);
    }
};

fn allocateEntries(comptime T: type, allocator: std.mem.Allocator, len: usize) ![]Entry(T) {
    const entries = try allocator.alloc(Entry(T), len);
    for (entries) |*entry| entry.* = .{};
    return entries;
}
