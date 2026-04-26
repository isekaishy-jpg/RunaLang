const types = @import("../types/root.zig");

pub const Mode = enum {
    implicit,
    explicit_infallible,
    explicit_checked,
};

pub fn allowed(mode: Mode, source_type: types.TypeRef, target_type: types.TypeRef) bool {
    if (source_type.isUnsupported() or target_type.isUnsupported()) return false;
    if (source_type.eql(target_type)) return true;
    return switch (mode) {
        .implicit => implicitAllowed(source_type, target_type),
        .explicit_infallible => explicitInfallibleAllowed(source_type, target_type),
        .explicit_checked => explicitCheckedAllowed(source_type, target_type),
    };
}

pub fn implicitAllowed(source_type: types.TypeRef, target_type: types.TypeRef) bool {
    _ = source_type;
    _ = target_type;
    return false;
}

pub fn explicitInfallibleAllowed(source_type: types.TypeRef, target_type: types.TypeRef) bool {
    return switch (source_type) {
        .builtin => |source_builtin| switch (target_type) {
            .builtin => |target_builtin| explicitInfallibleScalarAllowed(source_builtin, target_builtin),
            else => false,
        },
        else => false,
    };
}

pub fn explicitCheckedAllowed(source_type: types.TypeRef, target_type: types.TypeRef) bool {
    return source_type.isInteger() and target_type.isInteger();
}

pub fn explicitInfallibleScalarAllowed(source_builtin: types.Builtin, target_builtin: types.Builtin) bool {
    if (source_builtin == target_builtin) return true;
    return source_builtin == .u32 and target_builtin == .index;
}

pub fn explicitCheckedScalarAllowed(source_builtin: types.Builtin, target_builtin: types.Builtin) bool {
    if (source_builtin == target_builtin) return true;
    return source_builtin.isInteger() and target_builtin.isInteger();
}
