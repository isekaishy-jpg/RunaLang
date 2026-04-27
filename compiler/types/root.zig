const std = @import("std");

pub const Builtin = enum {
    unit,
    bool,
    i32,
    u32,
    index,
    isize,
    str,
    unsupported,

    pub fn fromName(raw: []const u8) Builtin {
        if (std.mem.eql(u8, raw, "Unit")) return .unit;
        if (std.mem.eql(u8, raw, "Bool")) return .bool;
        if (std.mem.eql(u8, raw, "I32")) return .i32;
        if (std.mem.eql(u8, raw, "U32")) return .u32;
        if (std.mem.eql(u8, raw, "Index")) return .index;
        if (std.mem.eql(u8, raw, "ISize")) return .isize;
        if (std.mem.eql(u8, raw, "Str")) return .str;
        return .unsupported;
    }

    pub fn isNumeric(self: Builtin) bool {
        return switch (self) {
            .i32, .u32, .index, .isize => true,
            else => false,
        };
    }

    pub fn isInteger(self: Builtin) bool {
        return switch (self) {
            .i32, .u32, .index, .isize => true,
            else => false,
        };
    }

    pub fn isCAbiSafe(self: Builtin) bool {
        return switch (self) {
            .unit, .bool, .i32, .u32, .index, .isize => true,
            .str, .unsupported => false,
        };
    }

    pub fn cName(self: Builtin) []const u8 {
        return switch (self) {
            .unit => "void",
            .bool => "bool",
            .i32 => "int32_t",
            .u32 => "uint32_t",
            .index => "size_t",
            .isize => "intptr_t",
            .str => "const char*",
            .unsupported => "void*",
        };
    }

    pub fn displayName(self: Builtin) []const u8 {
        return switch (self) {
            .unit => "Unit",
            .bool => "Bool",
            .i32 => "I32",
            .u32 => "U32",
            .index => "Index",
            .isize => "ISize",
            .str => "Str",
            .unsupported => "Unsupported",
        };
    }
};

pub const CanonicalTypeId = struct {
    index: usize,

    pub fn eql(lhs: CanonicalTypeId, rhs: CanonicalTypeId) bool {
        return lhs.index == rhs.index;
    }
};

pub const TypeFamily = enum {
    builtin_scalar,
    c_abi_alias,
    nominal,
    generic_param,
    generic_application,
    fixed_array,
    tuple,
    raw_pointer,
    callable,
    c_va_list,
    handle,
    option,
    result,
    unsupported,
};

pub const BuiltinScalar = enum {
    unit,
    bool,
    i32,
    u32,
    index,
    isize,
    str,

    pub fn fromBuiltin(value: Builtin) ?BuiltinScalar {
        return switch (value) {
            .unit => .unit,
            .bool => .bool,
            .i32 => .i32,
            .u32 => .u32,
            .index => .index,
            .isize => .isize,
            .str => .str,
            .unsupported => null,
        };
    }

    pub fn toBuiltin(self: BuiltinScalar) Builtin {
        return switch (self) {
            .unit => .unit,
            .bool => .bool,
            .i32 => .i32,
            .u32 => .u32,
            .index => .index,
            .isize => .isize,
            .str => .str,
        };
    }
};

pub const CAbiAlias = enum {
    c_bool,
    c_char,
    c_signed_char,
    c_unsigned_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_long_long,
    c_ulong_long,
    c_size,
    c_ptr_diff,
    c_wchar,
    c_void,

    pub fn fromName(raw: []const u8) ?CAbiAlias {
        if (std.mem.eql(u8, raw, "CBool")) return .c_bool;
        if (std.mem.eql(u8, raw, "CChar")) return .c_char;
        if (std.mem.eql(u8, raw, "CSignedChar")) return .c_signed_char;
        if (std.mem.eql(u8, raw, "CUnsignedChar")) return .c_unsigned_char;
        if (std.mem.eql(u8, raw, "CShort")) return .c_short;
        if (std.mem.eql(u8, raw, "CUShort")) return .c_ushort;
        if (std.mem.eql(u8, raw, "CInt")) return .c_int;
        if (std.mem.eql(u8, raw, "CUInt")) return .c_uint;
        if (std.mem.eql(u8, raw, "CLong")) return .c_long;
        if (std.mem.eql(u8, raw, "CULong")) return .c_ulong;
        if (std.mem.eql(u8, raw, "CLongLong")) return .c_long_long;
        if (std.mem.eql(u8, raw, "CULongLong")) return .c_ulong_long;
        if (std.mem.eql(u8, raw, "CSize")) return .c_size;
        if (std.mem.eql(u8, raw, "CPtrDiff")) return .c_ptr_diff;
        if (std.mem.eql(u8, raw, "CWChar")) return .c_wchar;
        if (std.mem.eql(u8, raw, "CVoid")) return .c_void;
        return null;
    }

    pub fn displayName(self: CAbiAlias) []const u8 {
        return switch (self) {
            .c_bool => "CBool",
            .c_char => "CChar",
            .c_signed_char => "CSignedChar",
            .c_unsigned_char => "CUnsignedChar",
            .c_short => "CShort",
            .c_ushort => "CUShort",
            .c_int => "CInt",
            .c_uint => "CUInt",
            .c_long => "CLong",
            .c_ulong => "CULong",
            .c_long_long => "CLongLong",
            .c_ulong_long => "CULongLong",
            .c_size => "CSize",
            .c_ptr_diff => "CPtrDiff",
            .c_wchar => "CWChar",
            .c_void => "CVoid",
        };
    }
};

pub const NominalType = struct {
    item_index: usize,
};

pub const GenericParamType = struct {
    owner_item_index: usize,
    param_index: usize,
};

pub const GenericApplication = struct {
    base: CanonicalTypeId,
    args: []const CanonicalTypeId,
};

pub const FixedArray = struct {
    element: CanonicalTypeId,
    length: u64,
};

pub const Tuple = struct {
    elements: []const CanonicalTypeId,
};

pub const PointerAccess = enum {
    read,
    edit,
};

pub const RawPointer = struct {
    access: PointerAccess,
    pointee: CanonicalTypeId,
};

pub const ParameterMode = enum {
    owned,
    take,
    read,
    edit,
};

pub const CallableAbi = enum {
    runa,
    c,
    system,
};

pub const CallableParameter = struct {
    mode: ParameterMode,
    ty: CanonicalTypeId,
};

pub const CallableType = struct {
    abi: CallableAbi,
    is_suspend: bool = false,
    parameters: []const CallableParameter,
    return_type: CanonicalTypeId,
    variadic_tail: ?CanonicalTypeId = null,
};

pub const HandleType = struct {
    target: CanonicalTypeId,
};

pub const OptionType = struct {
    payload: CanonicalTypeId,
};

pub const ResultType = struct {
    ok: CanonicalTypeId,
    err: CanonicalTypeId,
};

pub const DeclaredRepr = union(enum) {
    default,
    c,
    c_enum: CanonicalTypeId,
};

pub const TypeKey = union(enum) {
    builtin_scalar: BuiltinScalar,
    c_abi_alias: CAbiAlias,
    nominal: NominalType,
    generic_param: GenericParamType,
    generic_application: GenericApplication,
    fixed_array: FixedArray,
    tuple: Tuple,
    raw_pointer: RawPointer,
    callable: CallableType,
    c_va_list,
    handle: HandleType,
    option: OptionType,
    result: ResultType,
    unsupported,

    pub fn family(self: TypeKey) TypeFamily {
        return switch (self) {
            .builtin_scalar => .builtin_scalar,
            .c_abi_alias => .c_abi_alias,
            .nominal => .nominal,
            .generic_param => .generic_param,
            .generic_application => .generic_application,
            .fixed_array => .fixed_array,
            .tuple => .tuple,
            .raw_pointer => .raw_pointer,
            .callable => .callable,
            .c_va_list => .c_va_list,
            .handle => .handle,
            .option => .option,
            .result => .result,
            .unsupported => .unsupported,
        };
    }

    pub fn eql(lhs: TypeKey, rhs: TypeKey) bool {
        return switch (lhs) {
            .builtin_scalar => |left| switch (rhs) {
                .builtin_scalar => |right| left == right,
                else => false,
            },
            .c_abi_alias => |left| switch (rhs) {
                .c_abi_alias => |right| left == right,
                else => false,
            },
            .nominal => |left| switch (rhs) {
                .nominal => |right| left.item_index == right.item_index,
                else => false,
            },
            .generic_param => |left| switch (rhs) {
                .generic_param => |right| left.owner_item_index == right.owner_item_index and left.param_index == right.param_index,
                else => false,
            },
            .generic_application => |left| switch (rhs) {
                .generic_application => |right| left.base.eql(right.base) and canonicalTypeIdsEqual(left.args, right.args),
                else => false,
            },
            .fixed_array => |left| switch (rhs) {
                .fixed_array => |right| left.element.eql(right.element) and left.length == right.length,
                else => false,
            },
            .tuple => |left| switch (rhs) {
                .tuple => |right| canonicalTypeIdsEqual(left.elements, right.elements),
                else => false,
            },
            .raw_pointer => |left| switch (rhs) {
                .raw_pointer => |right| left.access == right.access and left.pointee.eql(right.pointee),
                else => false,
            },
            .callable => |left| switch (rhs) {
                .callable => |right| callableTypesEqual(left, right),
                else => false,
            },
            .c_va_list => rhs == .c_va_list,
            .handle => |left| switch (rhs) {
                .handle => |right| left.target.eql(right.target),
                else => false,
            },
            .option => |left| switch (rhs) {
                .option => |right| left.payload.eql(right.payload),
                else => false,
            },
            .result => |left| switch (rhs) {
                .result => |right| left.ok.eql(right.ok) and left.err.eql(right.err),
                else => false,
            },
            .unsupported => rhs == .unsupported,
        };
    }
};

pub const CanonicalType = struct {
    id: CanonicalTypeId,
    key: TypeKey,
    declared_repr: DeclaredRepr = .default,

    pub fn family(self: CanonicalType) TypeFamily {
        return self.key.family();
    }
};

pub const TypeRef = union(enum) {
    builtin: Builtin,
    named: []const u8,
    unsupported,

    pub fn fromBuiltin(value: Builtin) TypeRef {
        return if (value == .unsupported) .unsupported else .{ .builtin = value };
    }

    pub fn eql(lhs: TypeRef, rhs: TypeRef) bool {
        return switch (lhs) {
            .builtin => |left_builtin| switch (rhs) {
                .builtin => |right_builtin| left_builtin == right_builtin,
                else => false,
            },
            .named => |left_name| switch (rhs) {
                .named => |right_name| std.mem.eql(u8, left_name, right_name),
                else => false,
            },
            .unsupported => rhs == .unsupported,
        };
    }

    pub fn isUnsupported(self: TypeRef) bool {
        return self == .unsupported;
    }

    pub fn isNumeric(self: TypeRef) bool {
        return switch (self) {
            .builtin => |builtin| builtin.isNumeric(),
            else => false,
        };
    }

    pub fn isInteger(self: TypeRef) bool {
        return switch (self) {
            .builtin => |builtin| builtin.isInteger(),
            else => false,
        };
    }

    pub fn isNamed(self: TypeRef, name: []const u8) bool {
        return switch (self) {
            .named => |existing| std.mem.eql(u8, existing, name),
            else => false,
        };
    }

    pub fn displayName(self: TypeRef) []const u8 {
        return switch (self) {
            .builtin => |builtin| builtin.displayName(),
            .named => |name| name,
            .unsupported => "Unsupported",
        };
    }
};

pub fn cloneTypeKey(allocator: std.mem.Allocator, key: TypeKey) !TypeKey {
    return switch (key) {
        .generic_application => |value| .{ .generic_application = .{
            .base = value.base,
            .args = try cloneCanonicalTypeIds(allocator, value.args),
        } },
        .tuple => |value| .{ .tuple = .{
            .elements = try cloneCanonicalTypeIds(allocator, value.elements),
        } },
        .callable => |value| .{ .callable = .{
            .abi = value.abi,
            .is_suspend = value.is_suspend,
            .parameters = try cloneCallableParameters(allocator, value.parameters),
            .return_type = value.return_type,
            .variadic_tail = value.variadic_tail,
        } },
        else => key,
    };
}

pub fn deinitTypeKey(allocator: std.mem.Allocator, key: *TypeKey) void {
    switch (key.*) {
        .generic_application => |value| if (value.args.len != 0) allocator.free(value.args),
        .tuple => |value| if (value.elements.len != 0) allocator.free(value.elements),
        .callable => |value| if (value.parameters.len != 0) allocator.free(value.parameters),
        else => {},
    }
    key.* = .unsupported;
}

pub fn deinitCanonicalType(allocator: std.mem.Allocator, canonical: *CanonicalType) void {
    deinitTypeKey(allocator, &canonical.key);
    canonical.* = .{
        .id = .{ .index = 0 },
        .key = .unsupported,
    };
}

fn cloneCanonicalTypeIds(allocator: std.mem.Allocator, values: []const CanonicalTypeId) ![]const CanonicalTypeId {
    if (values.len == 0) return &.{};
    return allocator.dupe(CanonicalTypeId, values);
}

fn cloneCallableParameters(allocator: std.mem.Allocator, values: []const CallableParameter) ![]const CallableParameter {
    if (values.len == 0) return &.{};
    return allocator.dupe(CallableParameter, values);
}

fn canonicalTypeIdsEqual(lhs: []const CanonicalTypeId, rhs: []const CanonicalTypeId) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!left.eql(right)) return false;
    }
    return true;
}

fn callableTypesEqual(lhs: CallableType, rhs: CallableType) bool {
    if (lhs.abi != rhs.abi or lhs.is_suspend != rhs.is_suspend) return false;
    if (lhs.parameters.len != rhs.parameters.len) return false;
    for (lhs.parameters, rhs.parameters) |left, right| {
        if (left.mode != right.mode or !left.ty.eql(right.ty)) return false;
    }
    if (lhs.variadic_tail) |left_tail| {
        const right_tail = rhs.variadic_tail orelse return false;
        if (!left_tail.eql(right_tail)) return false;
    } else {
        if (rhs.variadic_tail != null) return false;
    }
    return lhs.return_type.eql(rhs.return_type);
}
