pub const entry = @import("entry/root.zig");
pub const abort = @import("abort/root.zig");
pub const target = @import("target/root.zig");

pub const private_to_compiler = true;
pub const owns_only = [_][]const u8{
    "entry",
    "abort",
    "target_leafs",
};

pub const forbidden = [_][]const u8{
    "allocation_policy",
    "defer",
    "syscall_wrappers",
    "threading",
    "scheduling",
    "async",
    "gc",
    "unwinding",
    "recovery",
    "public_api",
};

pub fn hostRuntimeLeafName() []const u8 {
    return target.hostLeaf().name;
}
