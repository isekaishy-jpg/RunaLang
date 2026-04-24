const std = @import("std");
const workspace = @import("../workspace/root.zig");

pub const summary = "Test discovery and execution boundary over managed workspace products.";

pub fn isTestProduct(loaded: *const workspace.Loaded, artifact_name: []const u8) bool {
    for (loaded.products.items) |product| {
        if (product.kind != .bin) continue;
        if (!std.mem.eql(u8, product.name, artifact_name)) continue;
        if (std.mem.endsWith(u8, product.name, "_test")) return true;
        if (std.mem.indexOf(u8, product.root_path, "\\tests\\") != null) return true;
        if (std.mem.indexOf(u8, product.root_path, "/tests/") != null) return true;
    }
    return false;
}
