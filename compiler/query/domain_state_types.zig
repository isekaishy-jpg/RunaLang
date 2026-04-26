pub const AnchorAccess = enum {
    read,
    edit,
};

pub const Anchor = struct {
    field_name: []const u8,
    target_name: []const u8,
    access: AnchorAccess,
    lifetime_name: ?[]const u8,
};

pub const RootSignature = struct {
    parent_anchor: ?Anchor = null,
};

pub const ContextSignature = struct {
    root_anchor: Anchor,
};

pub const ItemSignature = union(enum) {
    none,
    root: RootSignature,
    context: ContextSignature,
};
