const query = @import("../query/root.zig");
const session = @import("../session/root.zig");
const driver = @import("../driver/root.zig");
const Allocator = @import("std").mem.Allocator;

pub const summary = "Query-backed semantic session entrypoints.";

pub fn openFiles(allocator: Allocator, io: @import("std").Io, file_paths: []const []const u8) !session.Session {
    var active = try session.prepareFiles(allocator, io, file_paths);
    errdefer active.deinit();
    try query.finalizeSemanticChecks(&active);
    return active;
}

pub fn openGraph(allocator: Allocator, io: @import("std").Io, graph: driver.GraphInput) !session.Session {
    var active = try session.prepareGraph(allocator, io, graph);
    errdefer active.deinit();
    try query.finalizeSemanticChecks(&active);
    return active;
}
