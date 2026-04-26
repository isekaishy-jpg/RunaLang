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
    value_type_name: []const u8,
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
};
