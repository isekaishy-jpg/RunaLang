const const_ir = @import("../query/const_ir.zig");
const typed = @import("../typed/root.zig");

pub const compile_time_first = true;
pub const runtime_metadata_opt_in = true;
pub const runtime_visibility = "exported_only";
pub const semantic_view = [_][]const u8{
    "types",
    "fields",
    "functions",
    "generics",
    "ownership",
    "lifetimes",
    "regions",
};

pub const ItemMetadata = struct {
    name: []const u8,
    kind: []const u8,
    exported: bool,
    runtime_retained: bool,
    boundary_api: bool,
    unsafe_item: bool,
    parameters: []const typed.Parameter = &.{},
    generic_params: []const typed.GenericParam = &.{},
    public_fields: []const typed.StructField = &.{},
    variants: []const typed.EnumVariant = &.{},
    parameter_count: usize = 0,
    take_parameter_count: usize = 0,
    read_parameter_count: usize = 0,
    edit_parameter_count: usize = 0,
    generic_param_count: usize = 0,
    field_count: usize = 0,
    public_field_count: usize = 0,
    variant_count: usize = 0,
    variant_payload_count: usize = 0,
    return_type_name: []const u8 = "",
    const_type_name: []const u8 = "",
    const_value_retained: bool = false,
    const_value: ?const_ir.Value = null,
    opaque_nominal_only: bool = false,
    handle_nominal_only: bool = false,
    owns_public_fields: bool = false,

    pub fn deinit(self: ItemMetadata, allocator: @import("std").mem.Allocator) void {
        if (self.owns_public_fields) allocator.free(self.public_fields);
    }
};
