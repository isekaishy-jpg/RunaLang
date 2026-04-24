pub const workspace = @import("workspace/root.zig");
pub const build = @import("build/root.zig");
pub const package = @import("package/root.zig");
pub const publish = @import("publish/root.zig");
pub const fmt = @import("fmt/root.zig");
pub const doc = @import("doc/root.zig");
pub const lsp = @import("lsp/root.zig");
pub const testing = @import("test/root.zig");

pub const workflow_subcommands = [_][]const u8{
    "new",
    "build",
    "check",
    "test",
    "fmt",
    "doc",
    "publish",
};
