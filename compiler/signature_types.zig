const ast = @import("ast/root.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GenericParamKind = enum {
    type_param,
    lifetime_param,
};

pub const GenericParam = struct {
    name: []const u8,
    kind: GenericParamKind,
};

pub const BoundPredicate = struct {
    subject_name: []const u8,
    contract_name: []const u8,
};

pub const ProjectionEqualityPredicate = struct {
    subject_name: []const u8,
    associated_name: []const u8,

    // Structured type syntax remains authoritative after slice 4.
    value_type_syntax: ast.TypeSyntax,

    pub fn clone(self: ProjectionEqualityPredicate, allocator: Allocator) !ProjectionEqualityPredicate {
        return .{
            .subject_name = self.subject_name,
            .associated_name = self.associated_name,
            .value_type_syntax = try self.value_type_syntax.clone(allocator),
        };
    }

    pub fn deinit(self: *ProjectionEqualityPredicate, allocator: Allocator) void {
        self.value_type_syntax.deinit(allocator);
        self.* = .{
            .subject_name = "",
            .associated_name = "",
            .value_type_syntax = .{
                .source = .{
                    .text = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                },
            },
        };
    }
};

pub const LifetimeOutlivesPredicate = struct {
    longer_name: []const u8,
    shorter_name: []const u8,
};

pub const TypeOutlivesPredicate = struct {
    type_name: []const u8,
    lifetime_name: []const u8,
};

pub const WherePredicate = union(enum) {
    bound: BoundPredicate,
    projection_equality: ProjectionEqualityPredicate,
    lifetime_outlives: LifetimeOutlivesPredicate,
    type_outlives: TypeOutlivesPredicate,

    pub fn clone(self: WherePredicate, allocator: Allocator) !WherePredicate {
        return switch (self) {
            .bound => |bound| .{ .bound = bound },
            .projection_equality => |projection| .{ .projection_equality = try projection.clone(allocator) },
            .lifetime_outlives => |outlives| .{ .lifetime_outlives = outlives },
            .type_outlives => |outlives| .{ .type_outlives = outlives },
        };
    }

    pub fn deinit(self: *WherePredicate, allocator: Allocator) void {
        switch (self.*) {
            .projection_equality => |*projection| projection.deinit(allocator),
            else => {},
        }
    }
};

pub fn cloneWherePredicates(allocator: Allocator, predicates: []const WherePredicate) ![]WherePredicate {
    const cloned = try allocator.alloc(WherePredicate, predicates.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*predicate| predicate.deinit(allocator);
        allocator.free(cloned);
    }

    for (predicates, 0..) |predicate, index| {
        cloned[index] = try predicate.clone(allocator);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitWherePredicates(allocator: Allocator, predicates: []const WherePredicate) void {
    for (predicates) |*predicate| @constCast(predicate).deinit(allocator);
    if (predicates.len != 0) allocator.free(predicates);
}
