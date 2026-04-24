pub const windows = @import("windows/root.zig");
pub const linux = @import("linux/root.zig");
const builtin = @import("builtin");

pub const Leaf = struct {
    name: []const u8,
    scope: []const u8,
    supported_stage0: bool,
};

pub fn hostLeaf() Leaf {
    return switch (builtin.os.tag) {
        .windows => .{
            .name = windows.name,
            .scope = windows.scope,
            .supported_stage0 = windows.supported_stage0,
        },
        .linux => .{
            .name = linux.name,
            .scope = linux.scope,
            .supported_stage0 = linux.supported_stage0,
        },
        else => .{
            .name = @tagName(builtin.os.tag),
            .scope = "runtime_leafs",
            .supported_stage0 = false,
        },
    };
}
