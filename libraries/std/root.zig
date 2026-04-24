pub const reflect = @import("reflect/root.zig");
pub const option = @import("option.zig");
pub const result = @import("result.zig");
pub const collections_api = @import("collections.zig");
pub const async_runtime = @import("async.zig");
pub const boundary_runtime = @import("boundary.zig");

pub const collections = struct {
    pub const ordered_families = [_][]const u8{
        "List",
        "Bytes",
        "ByteBuffer",
        "[T; N]",
    };

    pub const associative_families = [_][]const u8{
        "Map",
    };
};

pub const text = struct {
    pub const families = [_][]const u8{
        "Str",
        "Utf16",
        "Utf16Buffer",
        "Bytes",
        "ByteBuffer",
        "Char",
    };
};

pub const async = struct {
    pub const task_family = "Task";
    pub const scheduler_policy_is_explicit = async_runtime.scheduler_policy_is_explicit;
};

pub const boundary = struct {
    pub const api_attribute = boundary_runtime.api_attribute;
    pub const value_attribute = boundary_runtime.value_attribute;
    pub const capability_attribute = boundary_runtime.capability_attribute;
};
